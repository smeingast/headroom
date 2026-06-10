import Foundation
import Darwin   // sysctl / kinfo_proc, for the process-identity (anti-PID-reuse) check

/// One live, local Claude Code session: the registry entry plus the current
/// context fill read from the tail of its transcript.
struct SessionInfo: Sendable {
    var pid: Int32
    var sessionId: String
    var cwd: String
    var status: String          // "busy" / "idle" / …
    var model: String?          // e.g. "claude-opus-4-8"
    var contextTokens: Int?     // context fill as of the last assistant turn; nil if unknown
    var updatedAt: Date?

    /// Last path component of the working directory (the project name).
    var projectName: String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? cwd : base
    }

    /// "Opus" / "Sonnet" / "Haiku", else the raw model id.
    var shortModel: String? {
        guard let m = model else { return nil }
        let lower = m.lowercased()
        if lower.contains("opus")   { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku")  { return "Haiku" }
        return m
    }
}

/// Reads Claude Code's local session registry (`~/.claude/sessions/<pid>.json`)
/// and the tail of each transcript to report live sessions and their context
/// fill. Pure local file I/O, no network, no auth. Undocumented internal state
/// of Claude Code — best-effort, and liable to change between CLI versions.
///
/// Empty struct so it is trivially `Sendable` and safe to call off the main actor.
struct SessionsClient: Sendable {
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var sessionsDir: URL { home.appendingPathComponent(".claude/sessions") }
    private var projectsDir: URL { home.appendingPathComponent(".claude/projects") }

    /// Enumerate live local sessions, most recently active first.
    func fetch() -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }

        var out: [SessionInfo] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  let sid = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String
            else { continue }
            // Drop stale registry files: the PID must be alive AND still be the same
            // process that wrote this entry (guards against the OS reusing a dead
            // session's PID for an unrelated process).
            let startedAtMs = (obj["startedAt"] as? NSNumber)?.doubleValue
            guard isAlive(pid), isSameProcess(pid: pid, startedAtMs: startedAtMs) else { continue }

            let status = (obj["status"] as? String) ?? "—"
            let updatedAt = (obj["updatedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            let (model, ctx) = lastContext(sessionId: sid, cwd: cwd)

            out.append(SessionInfo(pid: pid, sessionId: sid, cwd: cwd, status: status,
                                   model: model, contextTokens: ctx, updatedAt: updatedAt))
        }
        out.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return out
    }

    /// True if ANY local Claude Code process is plausibly alive. This gates token
    /// rotation (see UsageClient): rotating the single-use refresh token while a
    /// Claude Code holds the old one in memory forces the user to /login again.
    /// Two layers, deliberately erring toward true — a false "alive" only delays a
    /// usage fetch, a false "dead" can log the user out:
    /// - the session registry (interactive sessions), liveness-checked but without
    ///   the transcript reads `fetch()` does, and
    /// - a process-table scan for anything literally named "claude", which also
    ///   catches headless `claude -p` runs that never join the registry.
    func anyClaudeAlive() -> Bool {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = (obj["pid"] as? NSNumber)?.int32Value
                else { continue }
                let startedAtMs = (obj["startedAt"] as? NSNumber)?.doubleValue
                if isAlive(pid), isSameProcess(pid: pid, startedAtMs: startedAtMs) { return true }
            }
        }
        return anyProcessNamed("claude")
    }

    /// Scan the kernel process table for an exact (case-sensitive) p_comm match.
    /// "claude" is the CLI binary in every install mode; the desktop app is
    /// "Claude" and does not share these credentials. On any sysctl failure,
    /// report true — the conservative answer for the rotation gate.
    private func anyProcessNamed(_ name: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return true }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return true }
        for i in 0..<(size / stride) {
            let match = withUnsafeBytes(of: procs[i].kp_proc.p_comm) { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                return strncmp(base.assumingMemoryBound(to: CChar.self), name, raw.count) == 0
            }
            if match { return true }
        }
        return false
    }

    // MARK: - Liveness

    /// True if `pid` is a running process. `kill(pid, 0)` sends no signal: it
    /// returns 0 when the process exists, or fails with EPERM when it exists but
    /// we may not signal it (still alive). ESRCH means no such process.
    private func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// True if `pid` is still the process that recorded this session. The kernel's
    /// process start time must match the registry's `startedAt` (these agree within
    /// ~1s in practice; a reused PID is off by minutes or more, so 30s is a safe
    /// margin). If the start time can't be read, trust liveness rather than risk
    /// hiding a real session.
    private func isSameProcess(pid: Int32, startedAtMs: Double?) -> Bool {
        guard let startedAtMs, let actual = startTimeMillis(pid) else { return true }
        return abs(actual - startedAtMs) < 30_000
    }

    /// Kernel process start time (epoch ms) via sysctl, or nil if unavailable.
    private func startTimeMillis(_ pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
    }

    // MARK: - Context fill from the transcript tail

    /// (model, contextTokens) from the last main-chain assistant message.
    /// contextTokens ≈ the prompt that turn occupied (input + cache + output),
    /// which is robust to compaction: the latest message already reflects the
    /// post-compaction prompt size.
    private func lastContext(sessionId: String, cwd: String) -> (String?, Int?) {
        guard let url = transcriptURL(sessionId: sessionId, cwd: cwd),
              let obj = lastAssistantUsageEntry(url),
              let msg = obj["message"] as? [String: Any]
        else { return (nil, nil) }

        let model = msg["model"] as? String
        guard let usage = msg["usage"] as? [String: Any] else { return (model, nil) }
        func tok(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let ctx = tok("input_tokens") + tok("cache_creation_input_tokens")
                + tok("cache_read_input_tokens") + tok("output_tokens")
        return (model, ctx)
    }

    /// Locate `<sessionId>.jsonl`. Claude Code encodes the project dir by
    /// replacing "/" and "." in the cwd with "-"; if that guess misses (unknown
    /// encoding rules), fall back to scanning the project directories.
    private func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let encoded = String(cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
        let guess = projectsDir.appendingPathComponent(encoded)
                               .appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: guess.path) { return guess }

        if let dirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let cand = dir.appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: cand.path) { return cand }
            }
        }
        return nil
    }

    /// Scan the transcript backward from EOF for the last main-chain assistant
    /// message carrying a `usage` block. Reads fixed 256 KB windows from high to
    /// low offsets, carrying a straddling line fragment across the boundary, so
    /// every byte is read at most once and complete lines are never dropped. The
    /// target sits a few KB from EOF in practice, so this almost always returns on
    /// the first window; a `scanCap` bounds the pathological whole-file walk.
    private func lastAssistantUsageEntry(_ url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }

        let newline: UInt8 = 0x0A
        let chunk: UInt64 = 256 * 1024
        let scanCap: UInt64 = 32 * 1024 * 1024   // safety bound for a pathological tail
        var pos = end
        var carry = Data()                       // a line's tail, awaiting its head lower down

        while pos > 0 {
            if end - pos > scanCap { return nil }
            let readLen = min(chunk, pos)
            let start = pos - readLen
            guard (try? handle.seek(toOffset: start)) != nil,
                  let buf = try? handle.read(upToCount: Int(readLen)) else { return nil }

            var data = buf
            if !carry.isEmpty { data.append(carry) }

            if let nl = data.firstIndex(of: newline) {
                // Everything after the first newline is complete lines (the appended
                // carry completes the highest one); scan them newest-first.
                let after = Data(data[data.index(after: nl)...])
                for line in after.split(separator: newline, omittingEmptySubsequences: true).reversed() {
                    if let obj = assistantUsageEntry(Data(line)) { return obj }
                }
                carry = Data(data[..<nl])        // head fragment continues into the next window
            } else {
                carry = data                     // no newline yet — keep accumulating downward
            }
            pos = start
        }
        // Reached byte 0: the remaining carry is the file's first (complete) line.
        return carry.isEmpty ? nil : assistantUsageEntry(carry)
    }

    /// Parse one JSONL line; return it only if it is a main-chain assistant message
    /// with a `usage` block. A cheap substring pre-filter avoids JSON-parsing the
    /// large tool-result / user lines that dominate a transcript.
    private func assistantUsageEntry(_ line: Data) -> [String: Any]? {
        guard let s = String(data: line, encoding: .utf8),
              s.contains("\"usage\""), s.contains("\"assistant\"") else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              (obj["isSidechain"] as? Bool) != true,
              let msg = obj["message"] as? [String: Any],
              msg["usage"] is [String: Any] else { return nil }
        return obj
    }
}
