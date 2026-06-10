import Foundation
import Security

/// The OAuth credentials Claude Code stores in the login Keychain under the
/// generic-password service "Claude Code-credentials". The JSON is wrapped in a
/// top-level `claudeAiOauth` object.
struct OAuthCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double            // epoch milliseconds
    var scopes: [String]?
    var subscriptionType: String?
    var rateLimitTier: String?
}

private struct CredentialsWrapper: Codable {
    var claudeAiOauth: OAuthCredentials
}

enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case unexpectedData
    case osStatus(OSStatus)
    case cli(Int32, String)          // /usr/bin/security failed: exit code + stderr

    var description: String {
        switch self {
        case .notFound:
            return "Not logged in. Open Claude Code and sign in on this Mac."
        case .unexpectedData:
            return "Keychain item had an unexpected format."
        case .osStatus(let s):
            let msg = (SecCopyErrorMessageString(s, nil) as String?) ?? "OSStatus \(s)"
            return "Keychain error: \(msg)"
        case .cli(let code, let msg):
            return "Keychain tool failed (\(code)): \(msg)"
        }
    }
}

/// Reads/writes the shared Claude Code credentials. We match on the service name
/// only (never a hardcoded account) so this works as-is on any Mac and any user.
///
/// Access is designed to never show a Keychain prompt in normal operation:
///
/// - Reads first try the native API with UI suppressed (silent while our
///   "Always Allow" grant is intact), then fall back to `/usr/bin/security` —
///   the same Apple tool Claude Code itself uses for every access, so the
///   item's partition list (`apple-tool:`) admits it without a prompt even
///   after a Claude Code re-login recreates the item and wipes our grant.
///   Only if both silent paths fail do we allow the one real prompt.
/// - Writes never prompt at all: the item's encrypt ACL admits any application
///   (verified empirically), so `SecItemUpdate` is silent. The prompt people
///   used to see on "writes" was the read inside our read-modify-write.
enum Keychain {
    static let service = "Claude Code-credentials"

    static func readCredentials() throws -> OAuthCredentials {
        let data = try readRawData()
        do {
            return try JSONDecoder().decode(CredentialsWrapper.self, from: data).claudeAiOauth
        } catch {
            throw KeychainError.unexpectedData
        }
    }

    /// Outcome of a guarded write-back. `.conflict` means another process rotated
    /// the stored pair after we read it — the caller should adopt the live pair
    /// instead of clobbering it.
    enum WriteOutcome {
        case written
        case conflict(OAuthCredentials)
    }

    /// Writes refreshed token fields back into Claude Code's shared item without
    /// disturbing anything else. We re-read the live JSON and patch only the three
    /// fields a refresh rotates — so every other key Claude Code stores (scopes,
    /// subscriptionType, and any field this struct doesn't model or that Anthropic
    /// adds later) survives untouched. Encoding our narrow struct instead would
    /// silently drop those keys on every refresh and corrupt Claude Code's item.
    ///
    /// `ifRefreshTokenWas` guards against a lost update: if the stored refresh
    /// token no longer matches the one we rotated from, someone else (a re-login,
    /// another refresher) wrote a newer pair in the window — we must not overwrite
    /// it, so the live credentials are returned as `.conflict` for adoption.
    static func writeCredentials(_ creds: OAuthCredentials,
                                 ifRefreshTokenWas expected: String?) throws -> WriteOutcome {
        let data = try readRawData()
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any]
        else { throw KeychainError.unexpectedData }

        if let expected, let liveRefresh = oauth["refreshToken"] as? String, liveRefresh != expected {
            guard let live = try? JSONDecoder().decode(CredentialsWrapper.self, from: data).claudeAiOauth
            else { throw KeychainError.unexpectedData }
            return .conflict(live)
        }

        // Patch only the fields a token refresh changes; leave the rest verbatim.
        oauth["accessToken"] = creds.accessToken
        oauth["refreshToken"] = creds.refreshToken
        oauth["expiresAt"] = creds.expiresAt
        root["claudeAiOauth"] = oauth

        let updated = try JSONSerialization.data(withJSONObject: root)
        try update(with: updated)
        return .written
    }

    /// Preflight for a token rotation: prove we can persist BEFORE spending the
    /// single-use refresh token. Rewrites the item with its own current bytes —
    /// a no-op for the content, but it exercises the exact write path. (Inherent
    /// residual: a writer landing between the read and the rewrite is reverted;
    /// the window is sub-millisecond and the final write-back is compare-guarded.)
    /// A missing item must surface as `notFound` (signed out), not as "can't
    /// write" — the two need opposite UI treatment.
    static func canWrite() throws -> Bool {
        let data: Data
        do {
            data = try readRawData()
        } catch KeychainError.notFound {
            throw KeychainError.notFound
        } catch {
            return false
        }
        return (try? update(with: data)) != nil
    }

    // MARK: - Raw item access (the silent ladder)

    /// The prompting last resort fires at most once per app run: if the user
    /// denies (or ignores) it, re-asking on every poll would be a prompt storm —
    /// the exact behavior this design exists to end. Benign race: all callers
    /// funnel through one fetch pipeline.
    nonisolated(unsafe) private static var didTryPromptingRead = false

    private static func readRawData() throws -> Data {
        do {
            return try nativeRead(allowUI: false)
        } catch KeychainError.notFound {
            throw KeychainError.notFound        // definitive: no item, no point falling back
        } catch {
            NSLog("ClaudeUsage: silent Keychain read failed (\(error)); trying security CLI")
        }
        let cliError: Error
        do {
            return try cliRead()
        } catch KeychainError.notFound {
            throw KeychainError.notFound
        } catch {
            NSLog("ClaudeUsage: security CLI read failed (\(error))")
            cliError = error
        }
        // Last resort — may show the one Keychain prompt. Only reachable when both
        // silent paths break (e.g. grant wiped AND the partition behavior changed).
        guard !didTryPromptingRead else { throw cliError }
        didTryPromptingRead = true
        return try nativeRead(allowUI: true)
    }

    private static func nativeRead(allowUI: Bool) throws -> Data {
        // SecKeychainSetUserInteractionAllowed is deprecated but remains the only
        // switch that suppresses ACL prompts for file-based login-keychain items
        // (kSecUseAuthenticationUI only governs data-protection keychain items).
        if !allowUI { SecKeychainSetUserInteractionAllowed(false) }
        defer { if !allowUI { SecKeychainSetUserInteractionAllowed(true) } }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = item as? Data else { throw KeychainError.unexpectedData }
        return data
    }

    /// Read via Apple's `security` tool. The credentials item is created and
    /// maintained through this tool by Claude Code itself, so its partition list
    /// always admits it silently — independent of our app's own (wipeable) grant.
    private static func cliRead() throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe(), stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch {
            throw KeychainError.cli(-1, error.localizedDescription)
        }
        // A healthy invocation returns in milliseconds. A hang means it is stuck
        // on a dialog we cannot see — kill it rather than leave it dangling.
        if done.wait(timeout: .now() + 15) == .timedOut {
            proc.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            throw KeychainError.cli(-2, "timed out")
        }

        // Draining after exit is safe here: the only stdout is the item's data
        // (a few KB), far below the 64 KB pipe buffer that could stall the child.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            // 44 == errSecItemNotFound mod 256 (verified); the text match is a
            // locale-fragile backstop only.
            if proc.terminationStatus == 44 || errText.contains("could not be found") {
                throw KeychainError.notFound
            }
            throw KeychainError.cli(proc.terminationStatus,
                                    errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var data = outData
        if data.last == 0x0A { data.removeLast() }      // the tool appends one newline
        // Non-ASCII secrets are printed hex-encoded; the credentials JSON is plain
        // ASCII in practice, but decode defensively if it ever isn't.
        if data.first != UInt8(ascii: "{"),
           let text = String(data: data, encoding: .utf8),
           let decoded = Data(hexString: text), decoded.first == UInt8(ascii: "{") {
            data = decoded
        }
        guard !data.isEmpty else { throw KeychainError.unexpectedData }
        return data
    }

    /// `SecItemUpdate` of the item's data. The shared item's encrypt ACL admits
    /// any application, so this is silent; UI is suppressed anyway for safety.
    private static func update(with data: Data) throws {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }
}

private extension Data {
    /// Strict hex decode ("4a6f..." → bytes); nil unless the whole string is hex.
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        self.init(bytes)
    }
}
