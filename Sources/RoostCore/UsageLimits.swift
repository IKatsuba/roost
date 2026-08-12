import Foundation

/// One of the ceilings a subscription is measured against.
public struct LimitWindow: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        /// The five-hour window — the one that stops work in the middle of an
        /// afternoon.
        case session

        /// The seven-day window. Sometimes scoped to one model, in which case
        /// [label] says which.
        case week
    }

    public let kind: Kind

    /// The model this window is scoped to, when it is scoped to one — `opus`,
    /// `sonnet`. nil for the plain windows everything counts against.
    public let label: String?

    /// How much of it is gone, 0 to 100. The API reports the percentage and
    /// not the tokens behind it, which is why Roost counts those itself.
    public let usedPercent: Double

    public let resetsAt: Date?

    public var id: String { "\(kind.rawValue):\(label ?? "")" }

    public init(kind: Kind, label: String? = nil, usedPercent: Double, resetsAt: Date? = nil) {
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// What to call it in a line of interface: `5H`, `7D`, `7D OPUS`.
    public var title: String {
        let base = kind == .session ? "5H" : "7D"
        return label.map { "\(base) \($0.uppercased())" } ?? base
    }
}

/// The limits, as Anthropic reports them.
///
/// Claude Code does not write these down anywhere — it asks, and so do we, at
/// the same address with the same token. Everything else in this app is read
/// off the disk; this is the one thing that cannot be, because the percentages
/// exist only on the other side.
public enum UsageLimits {
    /// Where the answer comes from and what it said.
    public struct Reading: Sendable {
        public var windows: [LimitWindow] = []
        public var at = Date()

        /// Why there is nothing to show, when there is nothing to show. Not an
        /// error to raise: a machine that has never run `claude` has no token,
        /// and that is an ordinary state rather than a fault.
        public var trouble: Trouble?

        public init(windows: [LimitWindow] = [], at: Date = Date(), trouble: Trouble? = nil) {
            self.windows = windows
            self.at = at
            self.trouble = trouble
        }
    }

    public enum Trouble: String, Sendable {
        /// No credentials anywhere — nobody has logged in on this machine.
        case noCredentials

        /// The token was refused. It expires every few hours; Claude Code
        /// replaces it on its own, so the answer is to wait rather than to act.
        case tokenExpired

        case unreachable
    }

    // MARK: - Reading the token

    /// Where Claude Code keeps its credentials.
    ///
    /// Two places, in this order. The file is what Linux and a
    /// `CLAUDE_CONFIG_DIR` install use; on a plain Mac it does not exist at all
    /// and the keychain is the only copy.
    static func credentialsFile(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL
    {
        let base =
            environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent(".credentials.json")
    }

    /// The access token, wherever it is kept.
    ///
    /// The keychain is read by running `/usr/bin/security` rather than through
    /// `SecItemCopyMatching`. That is not laziness: the entry was written by
    /// Claude Code, so its access list names Claude Code's binary, and any
    /// other program asking for it gets the "wants to use your confidential
    /// information" dialog. Asked for by `security`, the permission a human
    /// grants once belongs to `security` — a program every other tool on the
    /// machine already goes through, including the widgets people run beside
    /// this one.
    public static func accessToken() -> String? {
        if let data = try? Data(contentsOf: credentialsFile()),
            let token = token(inCredentials: data)
        {
            return token
        }

        guard let output = run("/usr/bin/security", [
            "find-generic-password", "-s", service, "-w",
        ]) else { return nil }

        return token(inCredentials: Data(output.utf8))
    }

    static let service = "Claude Code-credentials"

    /// `{"claudeAiOauth": {"accessToken": …}}` — the shape both places hold.
    static func token(inCredentials data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { return nil }

        return token
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }

        // Read before waiting: a pipe nobody drains fills up, and the process
        // then blocks on the write while we block on the exit.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Asking

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Asks Anthropic what is left.
    ///
    /// **The token is used and never renewed.** Both of the tools that do this
    /// refresh it themselves when it expires and write the new one back into
    /// the keychain — and that is the one thing worth not copying. The refresh
    /// token is rotated on use: spend it and the copy Claude Code holds is
    /// dead, so a bug in the write-back logs a human out of the agent this
    /// whole app exists to run. An expired token is instead simply reported as
    /// such, and the next read finds the one Claude Code has already replaced
    /// it with — it is doing this anyway, in the pane next door.
    public static func fetch(session: URLSession = .shared) async -> Reading {
        guard let token = accessToken() else {
            return Reading(windows: [], trouble: .noCredentials)
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 401 || status == 403 {
                return Reading(windows: [], trouble: .tokenExpired)
            }
            guard status == 200,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return Reading(windows: [], trouble: .unreachable)
            }

            return Reading(windows: windows(in: object))
        } catch {
            return Reading(windows: [], trouble: .unreachable)
        }
    }

    // MARK: - Reading the answer

    /// The windows in a `/api/oauth/usage` body.
    ///
    /// Read by name, and a name that is not there is simply a window this
    /// account does not have: the set differs by plan, and one that shows up
    /// after this was written should cost nothing rather than break the rest.
    public static func windows(in body: [String: Any]) -> [LimitWindow] {
        var found: [LimitWindow] = []

        if let window = window(body["five_hour"], kind: .session) {
            found.append(window)
        }
        if let window = window(body["seven_day"], kind: .week) {
            found.append(window)
        }

        // The per-model weeks are their own ceilings — a plan can be out of
        // Opus while the plain weekly still has room, and a human needs to see
        // which one stopped them.
        for (key, value) in body {
            guard key.hasPrefix("seven_day_"),
                let window = window(value, kind: .week, label: String(key.dropFirst(10)))
            else { continue }
            found.append(window)
        }

        // Stable order, or the row would rearrange itself on every poll: the
        // five-hour window first, then the weeks by name.
        return found.sorted {
            ($0.kind == .week ? 1 : 0, $0.label ?? "") < ($1.kind == .week ? 1 : 0, $1.label ?? "")
        }
    }

    private static func window(_ raw: Any?, kind: LimitWindow.Kind, label: String? = nil)
        -> LimitWindow?
    {
        guard let object = raw as? [String: Any] else { return nil }

        // A window with no utilization is one the account does not have. Zero
        // would draw an empty bar, which is a different claim entirely.
        guard let used = number(object["utilization"]) else { return nil }

        return LimitWindow(
            kind: kind,
            label: label,
            usedPercent: min(max(used, 0), 100),
            resetsAt: (object["resets_at"] as? String).flatMap(UsageScan.date(from:))
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
}
