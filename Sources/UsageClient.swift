import Foundation

/// One rate-limit window as reported by the usage endpoint.
struct LimitWindow {
    var utilization: Double      // percent, 0…100(+)
    var resetsAt: Date?
}

/// A full snapshot of the account's current limit utilization.
struct UsageSnapshot {
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var sevenDayOpus: LimitWindow?
    var sevenDaySonnet: LimitWindow?
    var fetchedAt: Date
}

enum UsageError: Error, CustomStringConvertible {
    case auth                    // 401/403 — token rejected, user must sign in
    case stale                   // token expired; waiting for Claude Code to renew it
    case http(Int)
    case transport(String)
    case decode

    var description: String {
        switch self {
        case .auth:           return "Not authorized. Open Claude Code and sign in."
        case .stale:          return "Waiting for Claude Code to refresh the sign-in token"
        case .http(let c):    return "Server returned HTTP \(c)."
        case .transport(let m): return "Network error: \(m)"
        case .decode:         return "Could not parse usage response."
        }
    }
}

/// Talks to the Claude usage endpoint as a polite guest on Claude Code's
/// credentials. The OAuth refresh token is single-use (rotate-on-use, no grace
/// window), and a running Claude Code keeps its copy in memory — so if WE spend
/// it, that session is stranded and the user gets logged out. The rules:
///
/// - Credentials are cached in memory; the Keychain is read only at launch, at
///   token expiry, or on a 401 — not on every poll.
/// - On expiry/rejection, first ADOPT: re-read the Keychain and use any fresher
///   token Claude Code has written, without rotating anything.
/// - Self-refresh is a last resort and only with `allowRefresh` (the caller
///   passes false whenever any local Claude Code process is alive). A freshly
///   LAUNCHED Claude Code re-reads the Keychain, so rotating while none runs is
///   safe; rotating while one runs is what causes the forced /login.
/// - Before spending the refresh token, prove the write-back can succeed
///   (`Keychain.canWrite`); after rotating, persist immediately, retry on later
///   polls until it lands, and never clobber a pair someone else wrote meanwhile.
@MainActor
final class UsageClient {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "claude-cli/2.1.160 (external, cli)"

    private var creds: OAuthCredentials?
    // A rotated pair that hasn't reached the Keychain yet. Until it lands, a newly
    // launched Claude Code would inherit the dead pre-rotation pair — so retry
    // persisting on every poll, and never drop it on the floor.
    private var pendingWriteBack: OAuthCredentials?
    private var pendingRotatedFrom: String?
    // When WE last spent a refresh token (server accepted the POST). Guards the
    // pathological loop where the usage endpoint persistently rejects a perfectly
    // fresh token for non-token reasons (403 on entitlement / policy / headers):
    // without it, every poll would spend one rotation against the token endpoint.
    private var lastRotationAt = Date.distantPast
    private let rotationRetryGap: TimeInterval = 1800

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    func fetch(allowRefresh: Bool,
               isClaudeAlive: @escaping @Sendable () -> Bool) async throws -> UsageSnapshot {
        if let pending = pendingWriteBack {
            await persist(pending, rotatedFrom: pendingRotatedFrom)
        }

        if creds == nil { creds = try await keychainRead() }
        guard var current = creds else { throw KeychainError.notFound }

        if isExpired(current) {
            // Adopt any pair Claude Code wrote since we cached ours — EVEN an
            // expired one: a refresh, if it comes to that, must spend the newest
            // refresh token (replaying a superseded single-use token is a
            // guaranteed invalid_grant, or worse, reuse-detection). Skipped while
            // a write-back is parked: then OUR in-memory pair is the newest.
            if pendingWriteBack == nil,
               let fresh = try await freshFromKeychain(), fresh.accessToken != current.accessToken {
                current = fresh
                creds = fresh
            }
            if isExpired(current) {
                guard allowRefresh else { throw UsageError.stale }
                current = try await refreshAndPersist(current, isClaudeAlive: isClaudeAlive)
            }
        }

        do {
            return try await getUsage(token: current.accessToken)
        } catch UsageError.auth {
            // Rejected server-side. Adopt a fresher stored pair if one appeared;
            // refresh ourselves only when allowed; otherwise wait politely.
            if pendingWriteBack == nil,
               let fresh = try await freshFromKeychain(), fresh.accessToken != current.accessToken {
                creds = fresh
                do {
                    return try await getUsage(token: fresh.accessToken)
                } catch UsageError.auth {
                    current = fresh                      // also rejected — fall through
                }
            }
            guard allowRefresh else { throw UsageError.stale }
            // A pair we rotated moments ago and that is nowhere near expiry will
            // not be fixed by rotating again — the rejection is about the account
            // or the request, not token freshness. Surface the auth state instead
            // of spending a refresh per poll. (First-ever rejection of a stored,
            // unexpired token still refreshes: lastRotationAt is distantPast.)
            if !isExpired(current),
               Date().timeIntervalSince(lastRotationAt) < rotationRetryGap {
                throw UsageError.auth
            }
            let rotated = try await refreshAndPersist(current, isClaudeAlive: isClaudeAlive)
            return try await getUsage(token: rotated.accessToken)
        }
    }

    /// Last-chance, synchronous attempt to land a parked write-back (called from
    /// applicationWillTerminate) — otherwise the Keychain keeps the dead
    /// pre-rotation pair and the next Claude Code launch is forced to /login.
    func flushPendingWriteBack() {
        guard let pending = pendingWriteBack else { return }
        if (try? Keychain.writeCredentials(pending, ifRefreshTokenWas: pendingRotatedFrom)) != nil {
            pendingWriteBack = nil
            pendingRotatedFrom = nil
        }
    }

    // MARK: - Private

    /// Treat the token as unusable slightly before its stated expiry.
    private func isExpired(_ creds: OAuthCredentials) -> Bool {
        let nowMs = Date().timeIntervalSince1970 * 1000
        return creds.expiresAt - nowMs < 30_000
    }

    /// Re-read the Keychain for adoption. A MISSING item is definitive — the user
    /// signed out of Claude Code — and must surface as the loud auth state, never
    /// be swallowed into calm staleness: reset all cached state and rethrow (the
    /// next poll then retakes the first-read path, so re-login recovers
    /// automatically). Any other read failure is transient → nil.
    private func freshFromKeychain() async throws -> OAuthCredentials? {
        do {
            return try await keychainRead()
        } catch KeychainError.notFound {
            creds = nil
            pendingWriteBack = nil
            pendingRotatedFrom = nil
            throw KeychainError.notFound
        } catch {
            return nil
        }
    }

    /// Keychain I/O can block (securityd IPC; the CLI fallback up to its timeout),
    /// so hop off the main actor for it.
    private func keychainRead() async throws -> OAuthCredentials {
        try await Task.detached(priority: .utility) { try Keychain.readCredentials() }.value
    }

    private func getUsage(token: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: Self.usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw UsageError.transport("no response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.auth }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }

        guard let dto = try? JSONDecoder().decode(UsageDTO.self, from: data) else {
            throw UsageError.decode
        }
        return UsageSnapshot(
            fiveHour: dto.five_hour?.window,
            sevenDay: dto.seven_day?.window,
            sevenDayOpus: dto.seven_day_opus?.window,
            sevenDaySonnet: dto.seven_day_sonnet?.window,
            fetchedAt: Date()
        )
    }

    /// Exchanges the refresh token for a fresh access token and persists the
    /// rotated pair back into the shared Keychain item. Only called when no
    /// local Claude Code is running (see `fetch`).
    private func refreshAndPersist(_ old: OAuthCredentials,
                                   isClaudeAlive: @escaping @Sendable () -> Bool) async throws -> OAuthCredentials {
        // Never chain a rotation off a pair the Keychain hasn't seen: the
        // compare-guard in the write-back keys on the STORED refresh token, so
        // rotating from a parked pair would false-conflict and adopt a dead pair.
        // The parked write is retried at the top of every poll; rotation simply
        // resumes once it lands.
        guard pendingWriteBack == nil else {
            NSLog("ClaudeUsage: skipping token refresh — a write-back is still pending")
            throw UsageError.stale
        }
        // The refresh token dies the moment we spend it — prove the write-back
        // can succeed first, or the Keychain would be left holding a dead pair.
        // A missing item here means the user signed out: surface it loudly.
        let writable: Bool
        do {
            writable = try await Task.detached(priority: .utility) { try Keychain.canWrite() }.value
        } catch KeychainError.notFound {
            creds = nil
            throw KeychainError.notFound
        } catch {
            writable = false        // canWrite only throws notFound today; defensive
        }
        guard writable else {
            NSLog("ClaudeUsage: skipping token refresh — Keychain write preflight failed")
            throw UsageError.stale
        }
        // Re-check the gate at the last possible moment: the answer computed at
        // fetch start can be many seconds stale (keychain ladders, HTTP timeouts),
        // and a Claude Code launched in that window would read the pre-rotation
        // pair and be stranded by our rotation.
        let alive = await Task.detached(priority: .utility) { isClaudeAlive() }.value
        guard !alive else {
            NSLog("ClaudeUsage: skipping token refresh — a Claude Code process appeared")
            throw UsageError.stale
        }

        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": old.refreshToken,
            "client_id": Self.clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw UsageError.transport("no response") }
        // Only a genuine token rejection should raise the loud "sign in" warning.
        // 429 / 5xx are transient: surface them as .http so the menu bar stays calm
        // ("…") and we simply retry, instead of falsely claiming the user is logged out.
        switch http.statusCode {
        case 200:
            break
        case 429, 500...599:
            throw UsageError.http(http.statusCode)
        default:
            // invalid_grant can mean someone rotated this pair before us (e.g. a
            // re-login on another path). If a different pair is stored now, adopt
            // it instead of declaring the user signed out.
            if let fresh = try? await keychainRead(),
               fresh.refreshToken != old.refreshToken || fresh.accessToken != old.accessToken {
                creds = fresh
                return fresh
            }
            throw UsageError.auth
        }
        // The 200 means the old refresh token is spent server-side from here on,
        // whatever happens to the response body.
        lastRotationAt = Date()
        guard let tr = try? JSONDecoder().decode(TokenDTO.self, from: data) else {
            throw UsageError.decode
        }

        var updated = old
        updated.accessToken = tr.access_token
        if let rt = tr.refresh_token { updated.refreshToken = rt }
        let expiresIn = tr.expires_in ?? 3600
        updated.expiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        creds = updated
        await persist(updated, rotatedFrom: old.refreshToken)
        // On a write conflict, persist adopted the live pair into `creds` — return
        // that truth, not the pair we just discarded.
        return creds ?? updated
    }

    /// Persist a rotated pair, without ever clobbering a newer one. Failure is
    /// non-fatal for THIS fetch (the in-memory pair works) but must not be
    /// dropped: park it and retry on subsequent polls until it lands.
    private func persist(_ updated: OAuthCredentials, rotatedFrom: String?) async {
        do {
            let outcome = try await Task.detached(priority: .utility) {
                try Keychain.writeCredentials(updated, ifRefreshTokenWas: rotatedFrom)
            }.value
            switch outcome {
            case .written:
                break
            case .conflict(let live):
                // Someone wrote a different pair after we read — theirs is the
                // truth now (e.g. a fresh /login). Adopt it, drop ours.
                creds = live
            }
            pendingWriteBack = nil
            pendingRotatedFrom = nil
        } catch KeychainError.notFound {
            // The item vanished while we held a rotated pair: the user signed
            // out. Definitive, same contract as freshFromKeychain - there is no
            // item left to persist into, so parking would pin the app in calm
            // staleness forever. Drop the pair and reset; the next poll re-reads
            // the Keychain and surfaces the loud auth state.
            creds = nil
            pendingWriteBack = nil
            pendingRotatedFrom = nil
            NSLog("ClaudeUsage: Keychain item disappeared during write-back — treating as signed out")
        } catch {
            pendingWriteBack = updated
            pendingRotatedFrom = rotatedFrom
            NSLog("ClaudeUsage: token write-back to Keychain failed (will retry): \(error)")
        }
    }
}

// MARK: - Wire format

private struct UsageDTO: Decodable {
    let five_hour: WindowDTO?
    let seven_day: WindowDTO?
    let seven_day_opus: WindowDTO?
    let seven_day_sonnet: WindowDTO?
}

private struct WindowDTO: Decodable {
    let utilization: Double?
    let resets_at: String?

    /// Maps to a `LimitWindow`, dropping windows that carry no utilization value.
    var window: LimitWindow? {
        guard let utilization else { return nil }
        return LimitWindow(utilization: utilization, resetsAt: ISO.parse(resets_at))
    }
}

private struct TokenDTO: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
}

/// Lenient ISO-8601 parsing (the endpoint emits fractional seconds, e.g.
/// "2026-06-02T15:40:00.217970+00:00").
enum ISO {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }
}
