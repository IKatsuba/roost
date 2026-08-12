import Foundation

/// Reading spending out of Claude Code's transcripts.
///
/// Nobody hands the numbers out — not the agent, not the API. But every reply
/// the agent gets is written down with its `usage` block attached, and the same
/// files [SessionCatalog] already walks for session names hold, line by line,
/// what the work cost.
public enum UsageScan {
    /// One reply, and what it cost.
    public struct Record: Hashable, Sendable, Codable {
        /// `msgId:requestId` — what tells a genuinely new reply from another
        /// copy of one already counted. See [TokenUsage.merging].
        public let key: String

        public let model: String
        public let at: Date
        public let usage: TokenUsage

        public init(key: String, model: String, at: Date, usage: TokenUsage) {
            self.key = key
            self.model = model
            self.at = at
            self.usage = usage
        }

        /// A row — time, model, then the five counts — and no key.
        ///
        /// The key answers "counted already?", and that question is settled
        /// before a record is saved: what is kept afterwards is only ever read
        /// back to be summed inside a window. Saving it would be a third of the
        /// file for an answer nobody asks. A restored record therefore has an
        /// empty one, and must not be put back through [UsageLedger.absorb].
        public init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()

            key = ""
            at = Date(timeIntervalSince1970: try row.decode(Double.self))
            model = try row.decode(String.self)
            usage = TokenUsage(
                input: try row.decode(Int.self),
                output: try row.decode(Int.self),
                cacheWrite5m: try row.decode(Int.self),
                cacheWrite1h: try row.decode(Int.self),
                cacheRead: try row.decode(Int.self)
            )
        }

        public func encode(to encoder: Encoder) throws {
            var row = encoder.unkeyedContainer()

            try row.encode(at.timeIntervalSince1970)
            try row.encode(model)
            try row.encode(usage.input)
            try row.encode(usage.output)
            try row.encode(usage.cacheWrite5m)
            try row.encode(usage.cacheWrite1h)
            try row.encode(usage.cacheRead)
        }
    }

    /// What a pass over a file found, and where to carry on from next time.
    public struct Reading: Sendable {
        public let records: [Record]

        /// The offset just past the last complete line. A transcript is only
        /// ever appended to, so the next pass starts here and reads the few
        /// kilobytes that arrived meanwhile instead of the hundred megabytes
        /// that did not.
        public let offset: UInt64
    }

    /// A transcript on disk, and the session whose spending it belongs to.
    public struct Transcript: Hashable, Sendable {
        public let path: String

        /// The session it counts against. For a subagent that is its parent —
        /// see [transcripts(in:)].
        public let session: String
    }

    /// Every transcript under one project's directory, subagents included.
    ///
    /// A session is not one file. Claude Code keeps the conversation in
    /// `<uuid>.jsonl`, and every subagent it spawns gets a transcript of its
    /// own under `<uuid>/subagents/`. Those are where the parallel work goes,
    /// and their replies are billed like any other — a count that walks only
    /// the top level misses the most expensive thing an agent does.
    ///
    /// Subagents count against the session that spawned them rather than
    /// standing on their own: for a human they are one piece of work, and the
    /// interface has nowhere to put a session that nobody started.
    public static func transcripts(in directory: URL) -> [Transcript] {
        let contents = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var found: [Transcript] = []

        while let url = contents?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }

            // `journal.jsonl` sits among the subagent transcripts and looks
            // exactly like one, but it is the orchestration log — spawn and
            // result events, no replies and no usage. Reading it costs nothing
            // and finds nothing; it is skipped by name because that is cheaper
            // than reading it to find out.
            guard url.lastPathComponent != "journal.jsonl" else { continue }

            let name = url.deletingPathExtension().lastPathComponent
            let parent = url.deletingLastPathComponent()

            // `<project>/<session>/subagents/agent-….jsonl` — the session is
            // two levels up. Anything else is a session's own transcript,
            // named after it.
            let session =
                parent.lastPathComponent == "subagents"
                ? parent.deletingLastPathComponent().lastPathComponent
                : name

            found.append(Transcript(path: url.path, session: session))
        }

        return found
    }

    /// Reads a transcript from `offset` to the end.
    ///
    /// In chunks rather than in one gulp: a long-lived session's transcript
    /// runs to hundreds of megabytes, and the first pass walks every project on
    /// the machine. Whatever the last chunk left half-written is carried over
    /// into the next one — and the final half-line, the one the agent is still
    /// writing, is left for the next pass to find whole.
    public static func scan(
        path: String,
        from offset: UInt64 = 0,
        chunk: Int = 4 * 1024 * 1024
    ) -> Reading {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return Reading(records: [], offset: offset)
        }
        defer { try? handle.close() }

        // A file that shrank was replaced rather than appended to — a session
        // cleared, or a name reused. The old offset points into the middle of
        // something else now, so the only safe answer is to start over.
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size < offset ? 0 : offset

        guard (try? handle.seek(toOffset: start)) != nil else {
            return Reading(records: [], offset: start)
        }

        var records: [Record] = []
        var pending = Data()
        var consumed = start

        while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            pending.append(data)

            let used = pending.withUnsafeBytes { raw -> Int in
                split(raw) { line in
                    if let record = record(in: line) { records.append(record) }
                }
            }

            consumed += UInt64(used)

            // What is left is the half-written line — the one the agent has not
            // finished, or one cut in two by the chunk boundary. It goes to the
            // front of the next read rather than being parsed in halves.
            pending.removeFirst(used)
        }

        return Reading(records: records, offset: consumed)
    }

    /// Hands every complete line in the buffer to `body`, and answers how many
    /// bytes that accounted for.
    ///
    /// By hand over the raw bytes rather than `Data.split`: the transcripts run
    /// to gigabytes, and `split` builds a subsequence per line — the boring
    /// nine lines in ten, the tool results nobody here will read, all copied
    /// before being discarded. `memchr` is a page-at-a-time scan for one byte,
    /// and it is the difference between a first pass measured in seconds and
    /// one measured in minutes.
    private static func split(
        _ raw: UnsafeRawBufferPointer,
        _ body: (UnsafeRawBufferPointer) -> Void
    ) -> Int {
        guard let base = raw.baseAddress else { return 0 }

        var start = 0
        while start < raw.count {
            guard let newline = memchr(base + start, 0x0A, raw.count - start) else { break }
            let end = UnsafeRawPointer(newline) - base

            body(UnsafeRawBufferPointer(start: base + start, count: end - start))
            start = end + 1
        }

        return start
    }

    /// One line of a transcript, if it holds a reply with usage on it.
    ///
    /// The substring check earns its place: a transcript is mostly tool calls
    /// and their results, and parsing every line as json to discard nine in ten
    /// costs more than the whole scan is worth. `memmem` does that check
    /// without copying the line first — which matters, because the lines it
    /// rejects are the megabyte-long ones.
    static func record(in line: UnsafeRawBufferPointer) -> Record? {
        guard let base = line.baseAddress, line.count > marker.count else { return nil }

        let found = marker.withUnsafeBytes { needle in
            memmem(base, line.count, needle.baseAddress, needle.count) != nil
        }
        guard found else { return nil }

        return record(in: Data(bytes: base, count: line.count))
    }

    /// The same, from bytes already in hand.
    static func record(in line: some DataProtocol) -> Record? {
        let data = Data(line)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let raw = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              // `<synthetic>` is not a model but a note that the API answered
              // with an error. Its usage is all zeroes, so counting it would
              // cost nothing — but it would price a model that has no price and
              // turn the whole total into "unknown".
              !model.hasPrefix("<")
        else { return nil }

        // Both halves of the key are needed. A reply without a request id can
        // still be told apart by its own — and a reply without either is not
        // one we can recognise a second time, so it is counted once and left
        // alone.
        guard let messageID = message["id"] as? String else { return nil }
        let key = (object["requestId"] as? String).map { "\(messageID):\($0)" } ?? messageID

        return Record(
            key: key,
            model: model,
            at: date(from: object["timestamp"] as? String) ?? .distantPast,
            usage: usage(from: raw)
        )
    }

    /// Narrower than `usage` alone: the word turns up in prose the agent wrote
    /// and in tool results it read, while the punctuation only appears where a
    /// json object opens.
    private static let marker = Data("\"usage\":{".utf8)

    static func usage(from raw: [String: Any]) -> TokenUsage {
        let write = number(raw["cache_creation_input_tokens"])

        // The split between the two cache lifetimes lives one level down, and
        // only in recent transcripts. Without it everything counts as the short
        // kind: that is what the field meant before the long one existed, and
        // it is the cheaper of the two — an estimate that errs downwards rather
        // than inventing spend.
        let detail = raw["cache_creation"] as? [String: Any]
        let long = number(detail?["ephemeral_1h_input_tokens"])
        let short = number(detail?["ephemeral_5m_input_tokens"])

        return TokenUsage(
            input: number(raw["input_tokens"]),
            output: number(raw["output_tokens"]),
            cacheWrite5m: detail == nil ? write : short,
            cacheWrite1h: detail == nil ? 0 : long,
            cacheRead: number(raw["cache_read_input_tokens"])
        )
    }

    /// Negative counts do not exist; a missing field is a zero.
    private static func number(_ value: Any?) -> Int {
        max(0, (value as? Int) ?? 0)
    }

    /// `2026-08-12T17:12:04.756Z` by hand.
    ///
    /// Not `ISO8601DateFormatter`: it is the single most expensive thing in the
    /// scan — hundreds of thousands of records go through here, and it costs
    /// more per call than parsing the whole json line around it. The shape is
    /// fixed, written by one program, so it is read by position.
    static func date(from text: String?) -> Date? {
        guard let text, text.count >= 19 else { return nil }
        let digits = Array(text.utf8)

        func value(at range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                let digit = Int(digits[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                result = result * 10 + digit
            }
            return result
        }

        guard let year = value(at: 0..<4),
              let month = value(at: 5..<7),
              let day = value(at: 8..<10),
              let hour = value(at: 11..<13),
              let minute = value(at: 14..<16),
              let second = value(at: 17..<19)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        return utc.date(from: components)
    }

    /// The transcripts are written in UTC, whatever the machine is set to.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
}
