import Foundation
import Network

/// Where a claude pane should knock, and which settings it starts with.
public struct AgentHooksConfig: Hashable, Sendable {
    /// The receiver's full URL, port included: the OS picks one every launch.
    public let hookURL: String

    /// The JSON registering the hooks, the one that goes to `claude --settings`.
    public let settingsPath: String
}

/// A status change of one pane.
public struct HookEvent: Hashable, Sendable {
    public let paneID: String
    public let status: AgentStatus

    /// The notification's text — what the agent asked about. The same text goes
    /// onto the card in the attention queue.
    public let message: String?

    /// The Claude Code session's UUID. It comes with every event, including the
    /// very first one: `SessionStart` happens right after the launch, so a pane
    /// knows its session within seconds.
    public let sessionID: String?

    /// The path to that session's JSONL transcript — from the same hook field.
    public let transcriptPath: String?

    public init(
        paneID: String,
        status: AgentStatus,
        message: String? = nil,
        sessionID: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.paneID = paneID
        self.status = status
        self.message = message
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
    }
}

/// A local receiver of Claude Code lifecycle events.
///
/// Claude Code does not hand its state out, but it can call commands on events.
/// So the app raises a tiny server on the loopback, puts a hook script next to
/// it and passes the address to the claude pane through the environment: the
/// hook inherits the `claude` process's environment and reports who exactly
/// came alive.
///
/// The stored properties are immutable and the state lives inside `NWListener`,
/// which makes the class safe to pass between tasks.
public final class AgentHooks: @unchecked Sendable {
    public let config: AgentHooksConfig
    public let events: AsyncStream<HookEvent>

    private let listener: NWListener
    private let continuation: AsyncStream<HookEvent>.Continuation

    private init(
        listener: NWListener,
        events: AsyncStream<HookEvent>,
        continuation: AsyncStream<HookEvent>.Continuation,
        config: AgentHooksConfig
    ) {
        self.listener = listener
        self.events = events
        self.continuation = continuation
        self.config = config
    }

    /// Writes the hook files, raises the receiver and returns a ready object.
    /// The OS picks the port: a fixed number is bound to be taken by somebody
    /// else's process sooner or later.
    public static func start(
        directory: URL = WorkspaceStore.defaultDirectory
    ) async throws -> AgentHooks {
        let settingsPath = try writeHookFiles(in: directory)
        let queue = DispatchQueue(label: "dev.katsuba.roost.hooks")

        var sink: AsyncStream<HookEvent>.Continuation!
        let events = AsyncStream<HookEvent> { sink = $0 }
        let continuation = sink!

        let listener = try NWListener(using: .tcp, on: .any)

        // The connection handler has to be in place before start(): without it
        // the listener fails immediately with EINVAL. Serving deliberately
        // knows nothing about AgentHooks itself — otherwise it would have to be
        // created before the port is even known.
        listener.newConnectionHandler = { connection in
            serve(connection, on: queue, into: continuation)
        }

        let port = try await withCheckedThrowingContinuation { ready in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port, once.claim() else { return }
                    ready.resume(returning: port.rawValue)
                case .failed(let error):
                    guard once.claim() else { return }
                    ready.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        return AgentHooks(
            listener: listener,
            events: events,
            continuation: continuation,
            config: AgentHooksConfig(
                hookURL: "http://127.0.0.1:\(port)/hook",
                settingsPath: settingsPath
            )
        )
    }

    public func stop() {
        listener.cancel()
        continuation.finish()
    }

    /// A one-time ticket: `stateUpdateHandler` is called more than once, while
    /// a continuation may be resumed only a single time.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}

// MARK: - Serving requests

private func serve(
    _ connection: NWConnection,
    on queue: DispatchQueue,
    into sink: AsyncStream<HookEvent>.Continuation
) {
    // The receiver listens on every interface, but we serve the loopback only:
    // a pane's status is not something the network gets to set.
    guard isLoopback(connection.endpoint) else {
        connection.cancel()
        return
    }

    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
        if let data, let request = String(data: data, encoding: .utf8) {
            handle(request, into: sink)
        }

        // The answer goes out at once: the hook stands in the agent's way, and
        // a delay here turns into a delay of its every step.
        let response = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}

private func handle(_ request: String, into sink: AsyncStream<HookEvent>.Continuation) {
    guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return }

    let parts = line.split(separator: " ")
    guard parts.count >= 2,
          let components = URLComponents(string: String(parts[1])),
          let encoded = components.percentEncodedQuery
    else { return }

    // Parsed by hand rather than through queryItems: curl sends a form, where a
    // space is `+`, and by the URL standard that is what it stays. The
    // replacement has to happen before decoding, otherwise a real plus (`%2B`)
    // would turn into a space.
    var query: [String: String] = [:]
    for pair in encoded.split(separator: "&") {
        let field = pair.split(separator: "=", maxSplits: 1)
        guard let name = field.first else { continue }

        let value = field.count > 1 ? String(field[1]) : ""
        query[String(name)] = value
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? ""
    }

    guard let paneID = query["pane"], let event = query["event"],
          let status = statusForEvent(event, notification: query["notification"])
    else { return }

    func value(_ name: String) -> String? {
        query[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    sink.yield(
        HookEvent(
            paneID: paneID,
            status: status,
            message: value("message"),
            sessionID: value("session"),
            transcriptPath: value("transcript")
        )
    )
}

func isLoopback(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }

    switch host {
    case .ipv4(let address): return address.isLoopback
    case .ipv6(let address): return address.isLoopback
    @unknown default: return false
    }
}

/// A Claude Code event turned into a pane's status. `nil` — leave the status be.
public func statusForEvent(_ event: String, notification: String? = nil) -> AgentStatus? {
    switch event {
    case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
        return .working

    // The agent cannot grant itself permission for a tool — it waits for a human.
    case "PermissionRequest":
        return .waiting

    case "Notification":
        switch notification {
        case "permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog":
            return .waiting
        case "agent_completed":
            return .done
        // Other notifications (a successful login, an answer to an
        // elicitation) say nothing about whether the agent is busy.
        default:
            return nil
        }

    // The turn is over, but nobody has read the output yet — that is `done`,
    // not rest. It becomes `idle` once a human opens the pane.
    case "Stop":
        return .done

    case "SessionStart":
        return .idle

    case "SessionEnd":
        return .exited

    default:
        return nil
    }
}

// MARK: - Hook files

extension AgentHooks {
    /// Writes the hook script and the settings next to the workspace snapshot.
    ///
    /// The script is called through `/bin/sh` rather than marked executable:
    /// the Application Support path contains a space, and the execute bit would
    /// have to be set by an external process.
    static func writeHookFiles(in directory: URL) throws -> String {
        let hooksDirectory = directory.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: hooksDirectory,
            withIntermediateDirectories: true
        )

        let script = hooksDirectory.appendingPathComponent("notify.sh")
        try Data(notifyScript.utf8).write(to: script, options: .atomic)

        let settings = hooksDirectory.appendingPathComponent("claude-settings.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settingsDocument(scriptPath: script.path))
            .write(to: settings, options: .atomic)

        return settings.path
    }

    /// The minimal shape of Claude Code settings: hook registration only.
    struct HookSettings: Encodable {
        struct Command: Encodable {
            let type = "command"
            let command: String
        }

        struct Entry: Encodable {
            let matcher: String?
            let hooks: [Command]
        }

        let hooks: [String: [Entry]]
    }

    static func settingsDocument(scriptPath: String) -> HookSettings {
        let command = HookSettings.Command(command: "/bin/sh '\(scriptPath)'")

        func entry(matcher: Bool = false) -> [HookSettings.Entry] {
            [HookSettings.Entry(matcher: matcher ? "*" : nil, hooks: [command])]
        }

        return HookSettings(hooks: [
            "SessionStart": entry(),
            "UserPromptSubmit": entry(),
            "PreToolUse": entry(matcher: true),
            "PostToolUse": entry(matcher: true),
            "PermissionRequest": entry(matcher: true),
            "Notification": entry(),
            "Stop": entry(),
            "SessionEnd": entry(),
        ])
    }
}

/// The hook is deliberately undemanding: `grep` instead of `jq`, short timeouts
/// and `exit 0` whatever happens. It stands in the agent's way — breaking or
/// hanging here means breaking or hanging the session itself.
let notifyScript = #"""
#!/bin/sh
# roost hook: tells the app what is going on in a pane.
# Installed through `claude --settings`; the address and the pane id arrive in
# the environment.

[ -z "$ROOST_HOOK_URL" ] && exit 0
[ -z "$ROOST_PANE_ID" ] && exit 0

INPUT=$(cat)

field() {
  printf '%s' "$INPUT" \
    | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | grep -oE '"[^"]*"$' \
    | tr -d '"' \
    | head -n 1
}

EVENT=$(field hook_event_name)
[ -z "$EVENT" ] && exit 0

curl -sG "$ROOST_HOOK_URL" \
  --connect-timeout 1 --max-time 2 \
  --data-urlencode "pane=$ROOST_PANE_ID" \
  --data-urlencode "event=$EVENT" \
  --data-urlencode "notification=$(field notification_type)" \
  --data-urlencode "message=$(field message)" \
  --data-urlencode "session=$(field session_id)" \
  --data-urlencode "transcript=$(field transcript_path)" \
  > /dev/null 2>&1

exit 0
"""#
