import Foundation

/// Reading a Claude Code session transcript.
///
/// A hook brings only the occasion — "needs permission for Bash". Everything
/// else worth showing a human the agent writes here: what it said, and the name
/// it came up with for the session.
public enum Transcript {
    /// What could be read out of the transcript's tail.
    public struct Reading: Hashable, Sendable {
        /// The last thing the agent said out loud — or the question, if it
        /// asked with a list of answers.
        public let message: String?

        /// The session's name, if it has one.
        ///
        /// Claude Code invents a name **from the human's first message**, and
        /// only if it is longer than ten characters. A session that started
        /// with "hi" stays nameless forever — it will not ask again. A name can
        /// always be given by hand though: `/rename`.
        public let title: String?
    }

    /// Reads the tail of the transcript in a single pass.
    ///
    /// The file is read from the end: a long session grows to hundreds of
    /// megabytes, and parsing all of it for two lines is not an option. What
    /// did not fit into the tail does not exist — there is nothing to make up,
    /// and the side that displays it has a fallback.
    public static func read(at path: String, tail: Int = 512 * 1024) -> Reading {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return Reading(message: nil, title: nil)
        }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else {
            return Reading(message: nil, title: nil)
        }
        let offset = size > UInt64(tail) ? size - UInt64(tail) : 0

        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return Reading(message: nil, title: nil) }

        var message: String?
        var customTitle: String?
        var aiTitle: String?
        var agentName: String?

        // The first line of the tail is almost certainly cut in half — and it
        // drops out on JSON parsing anyway, so no separate check is needed.
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            // We stop only at a name given by a human: everything else may lie
            // further down, and nothing can outrank it.
            guard message == nil || customTitle == nil else { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line))
                as? [String: Any]
            else { continue }

            if message == nil { message = agentText(in: object) }

            switch object["type"] as? String {
            case "custom-title" where customTitle == nil:
                customTitle = flattened(object["customTitle"] as? String ?? "")
            case "ai-title" where aiTitle == nil:
                aiTitle = flattened(object["aiTitle"] as? String ?? "")
            case "agent-name" where agentName == nil:
                agentName = flattened(object["agentName"] as? String ?? "")
            default:
                break
            }
        }

        // In descending order of the right to name it: what the human called
        // it, what the conversation called itself, what the agent is called.
        return Reading(message: message, title: customTitle ?? aiTitle ?? agentName)
    }

    /// The agent's last message — the same reading, only shorter at the call site.
    public static func lastAgentMessage(at path: String, tail: Int = 512 * 1024) -> String? {
        read(at: path, tail: tail).message
    }

    /// How the human opened the conversation.
    ///
    /// Needed where a session has no name: Claude Code does not count a short
    /// first message as one and will not invent anything. We read from the
    /// head — the first message sits in the first kilobytes, and it is exactly
    /// what the session is remembered by.
    public static func firstPrompt(at path: String, head: Int = 64 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: head) else { return nil }

        // The last line of the chunk is almost certainly cut in half — and it
        // drops out on JSON parsing anyway, so no separate check is needed.
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line))
                as? [String: Any],
                object["type"] as? String == "user",
                let message = object["message"] as? [String: Any],
                // What the human typed themselves arrives as a string. Tool
                // results and attachments come with the same type but as a
                // list of blocks — and a conversation never starts with those.
                let text = message["content"] as? String,
                let flat = flattened(text)
            else { continue }

            // Slash command output was not written by the human either, though
            // it looks like an ordinary message with `<command-name>` markup.
            guard !flat.hasPrefix("<") else { continue }
            return flat
        }

        return nil
    }

    /// What a human actually sees in an `assistant` record.
    ///
    /// Thinking and plain tool calls are skipped — they are not for them. But a
    /// question with a list of answers arrives as a tool call, and on screen it
    /// is the main thing: the text before it is just a preamble.
    private static func agentText(in object: [String: Any]) -> String? {
        guard object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return nil }

        if let asked = flattened(question(in: blocks)) { return asked }

        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")

        return flattened(text)
    }

    /// The question out of a multiple-choice dialog. Recognised by the shape of
    /// the input rather than the tool's name: the name may change, `questions`
    /// hardly will.
    private static func question(in blocks: [[String: Any]]) -> String {
        blocks
            .filter { $0["type"] as? String == "tool_use" }
            .compactMap { $0["input"] as? [String: Any] }
            .compactMap { $0["questions"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["question"] as? String }
            .joined(separator: " ")
    }

    /// Line breaks and indentation collapse into spaces: a card is three lines
    /// tall, and vertical markup would eat them without saying anything.
    static func flattened(_ text: String) -> String? {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? nil : flat
    }
}
