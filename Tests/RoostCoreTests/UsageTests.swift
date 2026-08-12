import Foundation
import Testing

@testable import RoostCore

@Suite("Usage")
struct UsageTests {
    // MARK: - Reading a line

    /// The shape a real transcript writes, trimmed to the fields that matter.
    private func line(
        id: String = "msg_1",
        request: String? = "req_1",
        model: String = "claude-opus-5",
        timestamp: String = "2026-08-12T17:12:04.756Z",
        usage: String = """
            {"input_tokens":2,"output_tokens":653,"cache_read_input_tokens":52182,\
            "cache_creation_input_tokens":7369,\
            "cache_creation":{"ephemeral_1h_input_tokens":7369,"ephemeral_5m_input_tokens":0}}
            """
    ) -> String {
        let requestField = request.map { "\"requestId\":\"\($0)\"," } ?? ""
        return """
            {"type":"assistant",\(requestField)"timestamp":"\(timestamp)",\
            "message":{"id":"\(id)","model":"\(model)","usage":\(usage)}}
            """
    }

    @Test func readsUsageOutOfAnAssistantLine() {
        let record = UsageScan.record(in: Data(line().utf8))

        #expect(record?.key == "msg_1:req_1")
        #expect(record?.model == "claude-opus-5")
        #expect(record?.usage.input == 2)
        #expect(record?.usage.output == 653)
        #expect(record?.usage.cacheRead == 52182)
        #expect(record?.usage.cacheWrite1h == 7369)
        #expect(record?.usage.cacheWrite5m == 0)
    }

    /// Without the breakdown the whole cache write counts as the short kind —
    /// the cheaper of the two, so an old transcript is under-priced rather than
    /// invented.
    @Test func treatsCacheWriteAsShortLivedWhenTheBreakdownIsMissing() {
        let record = UsageScan.record(
            in: Data(
                line(
                    usage: """
                        {"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":900}
                        """
                ).utf8
            )
        )

        #expect(record?.usage.cacheWrite5m == 900)
        #expect(record?.usage.cacheWrite1h == 0)
    }

    /// An API error is written as a reply from `<synthetic>`. Its usage is all
    /// zeroes, so it would cost nothing — but it would also price a model that
    /// has no price, and drag the total into "unknown".
    @Test func skipsSyntheticErrorReplies() {
        #expect(UsageScan.record(in: Data(line(model: "<synthetic>").utf8)) == nil)
    }

    @Test func skipsLinesThatAreNotReplies() {
        let user = #"{"type":"user","message":{"content":"has the word usage in it"}}"#
        #expect(UsageScan.record(in: Data(user.utf8)) == nil)
        #expect(UsageScan.record(in: Data("not json at all".utf8)) == nil)
        #expect(UsageScan.record(in: Data("".utf8)) == nil)
    }

    /// A reply that arrived without a request id still has its own, and one
    /// name is enough to recognise it a second time.
    @Test func fallsBackToTheMessageIdAloneAsAKey() {
        #expect(UsageScan.record(in: Data(line(request: nil).utf8))?.key == "msg_1")
    }

    /// The transcripts are written in UTC whatever the machine is set to, so
    /// the expected date is built in UTC rather than typed as a unix number —
    /// this test would otherwise pass in one timezone and fail in the next.
    @Test func readsTheTimestampAsUTC() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let expected = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 12, hour: 17, minute: 12, second: 4)
        )

        #expect(UsageScan.record(in: Data(line().utf8))?.at == expected)
    }

    @Test func survivesATimestampItCannotRead() {
        #expect(UsageScan.date(from: nil) == nil)
        #expect(UsageScan.date(from: "yesterday") == nil)
        #expect(UsageScan.date(from: "2026-08-12") == nil)
    }

    // MARK: - Scanning a file

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func scansAFileAndStopsAtItsEnd() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try write([line(id: "a"), line(id: "b")], to: url)
        let reading = UsageScan.scan(path: url.path)

        #expect(reading.records.count == 2)
        #expect(reading.offset == UInt64(try Data(contentsOf: url).count))
    }

    /// The line the agent is still writing has no newline yet. It must be left
    /// for the next pass whole rather than counted in halves.
    @Test func leavesAnIncompleteLastLineForTheNextPass() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let complete = line(id: "a") + "\n"
        try (complete + line(id: "b")).write(to: url, atomically: true, encoding: .utf8)

        let reading = UsageScan.scan(path: url.path)

        #expect(reading.records.count == 1)
        #expect(reading.offset == UInt64(complete.utf8.count))

        // The half-written line, now finished, is picked up from where we left.
        try (complete + line(id: "b") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let next = UsageScan.scan(path: url.path, from: reading.offset)

        #expect(next.records.map(\.key) == ["b:req_1"])
    }

    /// A record split across two reads must not be counted in halves either —
    /// the chunk size is deliberately smaller than one line here.
    @Test func stitchesLinesAcrossChunkBoundaries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try write([line(id: "a"), line(id: "b"), line(id: "c")], to: url)
        let reading = UsageScan.scan(path: url.path, chunk: 16)

        #expect(reading.records.map(\.key) == ["a:req_1", "b:req_1", "c:req_1"])
    }

    @Test func readsNothingFromAFileThatIsNotThere() {
        let reading = UsageScan.scan(path: "/no/such/transcript.jsonl")
        #expect(reading.records.isEmpty)
    }

    // MARK: - Pricing

    @Test func pricesEachFamilyAtItsOwnRate() {
        let million = TokenUsage(input: 1_000_000)

        #expect(Pricing.cost(of: million, model: "claude-opus-5") == 5)
        #expect(Pricing.cost(of: million, model: "claude-opus-4-8") == 5)
        #expect(Pricing.cost(of: million, model: "claude-sonnet-5") == 3)
        #expect(Pricing.cost(of: million, model: "claude-haiku-4-5-20251001") == 1)
        #expect(Pricing.cost(of: million, model: "claude-fable-5") == 10)
    }

    /// The bare aliases turn up in transcripts too, and a substring answers
    /// them without a table entry of their own.
    @Test func pricesTheBareAliases() {
        #expect(Pricing.cost(of: TokenUsage(input: 1_000_000), model: "opus") == 5)
        #expect(Pricing.cost(of: TokenUsage(input: 1_000_000), model: "sonnet") == 3)
    }

    /// Cache is the whole reason the five fields are kept apart: an hour's
    /// write costs twice plain input, a five-minute one a quarter more, and a
    /// read a tenth.
    @Test func pricesCacheAtItsOwnMultipliers() {
        let million = 1_000_000

        #expect(
            Pricing.cost(of: TokenUsage(cacheWrite1h: million), model: "claude-opus-5") == 10)
        #expect(
            Pricing.cost(of: TokenUsage(cacheWrite5m: million), model: "claude-opus-5") == 6.25)
        #expect(
            Pricing.cost(of: TokenUsage(cacheRead: million), model: "claude-opus-5") == 0.5)
        #expect(
            Pricing.cost(of: TokenUsage(output: million), model: "claude-opus-5") == 25)
    }

    /// An unknown model has no price — not a price of zero. The difference is
    /// the whole point: zero would quietly shrink the total.
    @Test func refusesToPriceAModelItDoesNotKnow() {
        #expect(Pricing.cost(of: TokenUsage(input: 1_000), model: "llama-7b") == nil)
        #expect(Pricing.isPriced("llama-7b") == false)
        #expect(Pricing.isPriced("claude-opus-5"))
    }

    // MARK: - The ledger

    private func ledgerFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        try write(lines, to: url)
        return url
    }

    @Test func addsUpASession() throws {
        let url = try ledgerFile([line(id: "a"), line(id: "b")])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        let now = UsageScan.date(from: "2026-08-12T18:00:00.000Z")!
        let found = ledger.absorb(transcript: url.path, session: "s1", project: "/p", now: now)

        #expect(found)
        #expect(ledger.sessions["s1"]?.usage.output == 653 * 2)
        #expect(ledger.byProject["/p"]?.output == 653 * 2)
        #expect(ledger.byModel["claude-opus-5"]?.output == 653 * 2)
        #expect(ledger.total.output == 653 * 2)
    }

    /// Nearly half the replies in a real transcript are written twice. Counting
    /// them as they come would put the bill at almost double.
    @Test func countsADuplicateReplyOnlyOnce() throws {
        let url = try ledgerFile([line(id: "a"), line(id: "a"), line(id: "b")])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        ledger.absorb(transcript: url.path, session: "s1", project: "/p")

        #expect(ledger.total.output == 653 * 2)
    }

    /// Copies of a streamed reply carry the counters as they stood at the time.
    /// Whichever field is largest is the one that is true.
    @Test func mergesDuplicatesFieldByField() throws {
        let partial = #"{"input_tokens":2,"output_tokens":100,"cache_read_input_tokens":5}"#
        let complete = #"{"input_tokens":2,"output_tokens":653,"cache_read_input_tokens":5}"#
        let url = try ledgerFile([line(id: "a", usage: partial), line(id: "a", usage: complete)])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        ledger.absorb(transcript: url.path, session: "s1", project: "/p")

        #expect(ledger.total.output == 653)
    }

    /// The second pass reads only what arrived since the first, and adds it to
    /// what was already counted rather than counting the file again.
    @Test func picksUpOnlyWhatWasAppended() throws {
        let url = try ledgerFile([line(id: "a")])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        ledger.absorb(transcript: url.path, session: "s1", project: "/p")
        #expect(ledger.total.output == 653)

        // Nothing new: the pass finds nothing and says so.
        let again = ledger.absorb(transcript: url.path, session: "s1", project: "/p")
        #expect(again == false)
        #expect(ledger.total.output == 653)

        try write([line(id: "a"), line(id: "b")], to: url)
        let appended = ledger.absorb(transcript: url.path, session: "s1", project: "/p")
        #expect(appended)
        #expect(ledger.total.output == 653 * 2)
    }

    /// `/clear` writes a new session over the same name. What was counted out
    /// of the old contents does not describe the new ones.
    @Test func startsOverWhenAFileShrinks() throws {
        let url = try ledgerFile([line(id: "a"), line(id: "b"), line(id: "c")])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        ledger.absorb(transcript: url.path, session: "s1", project: "/p")
        #expect(ledger.total.output == 653 * 3)

        try write([line(id: "z")], to: url)
        ledger.absorb(transcript: url.path, session: "s1", project: "/p")

        #expect(ledger.sessions["s1"]?.usage.output == 653)
    }

    @Test func pricesASessionAsItGoes() throws {
        let url = try ledgerFile([
            line(id: "a", model: "claude-opus-5", usage: #"{"output_tokens":1000000}"#),
            line(id: "b", model: "claude-haiku-4-5", usage: #"{"output_tokens":1000000}"#),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        ledger.absorb(transcript: url.path, session: "s1", project: "/p")

        // Priced per reply, not by pricing the sum at one model's rate: $25 for
        // the opus million and $5 for the haiku one.
        #expect(ledger.totalCost == 30)
    }

    /// A session rarely stays on one model — a subagent runs on something cheap
    /// beside a conversation on Opus — and the sum alone cannot say which of
    /// them the money went to.
    @Test func splitsASessionByModel() throws {
        let url = try ledgerFile([
            line(id: "a", model: "claude-opus-5", usage: #"{"output_tokens":1000000}"#),
            line(id: "b", model: "claude-haiku-4-5", usage: #"{"output_tokens":2000000}"#),
            line(id: "c", model: "claude-opus-5", usage: #"{"output_tokens":1000000}"#),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        ledger.absorb(transcript: url.path, session: "s1", project: "/p")

        let session = ledger.sessions["s1"]
        #expect(session?.byModel["claude-opus-5"]?.output == 2_000_000)
        #expect(session?.byModel["claude-haiku-4-5"]?.output == 2_000_000)

        // Dearest first, not largest: haiku sent more tokens, opus cost more.
        #expect(session?.models.map(\.model) == ["claude-opus-5", "claude-haiku-4-5"])

        // The machine-wide split is the sessions added up, so it agrees by
        // construction rather than by being kept in step.
        #expect(ledger.byModel["claude-opus-5"]?.output == 2_000_000)
    }

    /// A session is not one file: every subagent it spawns writes a transcript
    /// of its own, and all of them count against the session that spawned them.
    /// Reading the second must add to the first rather than replace it.
    @Test func addsUpTheFilesOfOneSession() throws {
        let main = try ledgerFile([line(id: "a", usage: #"{"output_tokens":100}"#)])
        let subagent = try ledgerFile([line(id: "b", usage: #"{"output_tokens":50}"#)])
        defer {
            try? FileManager.default.removeItem(at: main)
            try? FileManager.default.removeItem(at: subagent)
        }

        var ledger = UsageLedger()
        ledger.absorb(transcript: main.path, session: "s1", project: "/p")
        ledger.absorb(transcript: subagent.path, session: "s1", project: "/p")

        #expect(ledger.sessions["s1"]?.usage.output == 150)
        #expect(ledger.total.output == 150)

        // And a second pass over both changes nothing.
        ledger.absorb(transcript: main.path, session: "s1", project: "/p")
        ledger.absorb(transcript: subagent.path, session: "s1", project: "/p")
        #expect(ledger.total.output == 150)
    }

    /// One file of a session starting over must take only its own tokens with
    /// it — the subagents' stay.
    @Test func unwindsOnlyTheFileThatStartedOver() throws {
        let main = try ledgerFile([line(id: "a", usage: #"{"output_tokens":100}"#)])
        let subagent = try ledgerFile([line(id: "b", usage: #"{"output_tokens":50}"#)])
        defer {
            try? FileManager.default.removeItem(at: main)
            try? FileManager.default.removeItem(at: subagent)
        }

        var ledger = UsageLedger()
        ledger.absorb(transcript: main.path, session: "s1", project: "/p")
        ledger.absorb(transcript: subagent.path, session: "s1", project: "/p")

        // The main transcript is replaced; the subagent's is untouched.
        try write([line(id: "z", usage: #"{"output_tokens":7}"#)], to: main)
        ledger.absorb(transcript: main.path, session: "s1", project: "/p")

        #expect(ledger.sessions["s1"]?.usage.output == 57)
    }

    /// A session that starts over has to be taken back out of every total,
    /// models and money included — not just out of its own line.
    @Test func unwindsASessionThatStartedOver() throws {
        let url = try ledgerFile([
            line(id: "a", model: "claude-opus-5", usage: #"{"output_tokens":1000000}"#)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        ledger.absorb(transcript: url.path, session: "s1", project: "/p")
        #expect(ledger.totalCost == 25)

        try write([line(id: "z", model: "claude-haiku-4-5", usage: #"{"output_tokens":1000000}"#)], to: url)
        ledger.absorb(transcript: url.path, session: "s1", project: "/p")

        #expect(ledger.byModel["claude-opus-5"] == nil)
        #expect(ledger.totalCost == 5)
    }

    /// The windows are cut out of the records by time, so the same ledger
    /// answers for five hours and for a week.
    @Test func slicesAWindowByTime() throws {
        let url = try ledgerFile([
            line(id: "a", timestamp: "2026-08-12T09:00:00.000Z"),
            line(id: "b", timestamp: "2026-08-12T17:30:00.000Z"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        let now = UsageScan.date(from: "2026-08-12T18:00:00.000Z")!
        ledger.absorb(transcript: url.path, session: "s1", project: "/p", now: now)

        let window = ledger.usage(from: now.addingTimeInterval(-5 * 3600))

        #expect(window.output == 653)
        #expect(ledger.total.output == 653 * 2)
    }

    /// Records older than the horizon are let go — the totals keep them, but
    /// holding every reply ever made to answer a question about this afternoon
    /// is not a trade worth making.
    @Test func forgetsRecordsPastTheHorizon() throws {
        let url = try ledgerFile([
            line(id: "old", timestamp: "2026-07-01T09:00:00.000Z"),
            line(id: "new", timestamp: "2026-08-12T17:30:00.000Z"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = UsageLedger()
        let now = UsageScan.date(from: "2026-08-12T18:00:00.000Z")!
        ledger.absorb(transcript: url.path, session: "s1", project: "/p", now: now)

        #expect(ledger.recent.map(\.key) == ["new:req_1"])
        #expect(ledger.total.output == 653 * 2)
    }

    // MARK: - Keeping it

    private func store() -> (UsageStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return (UsageStore(directory: directory), directory)
    }

    /// The point of the file: a second launch reads the tails, not the
    /// gigabyte. What was counted before must survive, and must not be counted
    /// again on top of itself.
    @Test func picksUpWhereTheLastRunStopped() throws {
        let url = try ledgerFile([line(id: "a"), line(id: "b")])
        let (store, directory) = store()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: directory)
        }

        var first = UsageLedger()
        first.absorb(transcript: url.path, session: "s1", project: "/p")
        try store.save(first)

        // A fresh run, as after a restart.
        var second = store.load()
        #expect(second.total.output == 653 * 2)

        // The same file, unchanged: nothing to add, and nothing counted twice.
        let again = second.absorb(transcript: url.path, session: "s1", project: "/p")
        #expect(again == false)
        #expect(second.total.output == 653 * 2)

        // What arrived while the app was closed is picked up on its own.
        try write([line(id: "a"), line(id: "b"), line(id: "c")], to: url)
        let appended = second.absorb(transcript: url.path, session: "s1", project: "/p")
        #expect(appended)
        #expect(second.total.output == 653 * 3)
    }

    /// The records the windows are cut from have to survive too, or a restart
    /// would report an empty afternoon.
    @Test func keepsTheRecentRecords() throws {
        let url = try ledgerFile([line(id: "a", timestamp: "2026-08-12T17:30:00.000Z")])
        let (store, directory) = store()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: directory)
        }

        let now = UsageScan.date(from: "2026-08-12T18:00:00.000Z")!
        var ledger = UsageLedger()
        ledger.absorb(transcript: url.path, session: "s1", project: "/p", now: now)
        try store.save(ledger)

        let restored = store.load()
        #expect(restored.usage(from: now.addingTimeInterval(-5 * 3600)).output == 653)
        #expect(restored.sessions["s1"]?.cost == ledger.sessions["s1"]?.cost)
    }

    /// Nothing saved, a broken file, or one from another version: all the same
    /// answer — an empty ledger and a slow launch, never a crash and never a
    /// wrong number.
    @Test func startsCleanWhenThereIsNothingToRestore() throws {
        let (store, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.load().isEmpty)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.file)
        #expect(store.load().isEmpty)

        try Data(#"{"version": 999, "offsets": {}}"#.utf8).write(to: store.file)
        #expect(store.load().isEmpty)
    }

    /// The saved record is a row without its key: the question the key answers
    /// is settled before anything is written down.
    @Test func writesARecordAsARowWithoutItsKey() throws {
        let record = UsageScan.Record(
            key: "msg_1:req_1",
            model: "claude-opus-5",
            at: Date(timeIntervalSince1970: 100),
            usage: TokenUsage(input: 1, output: 2, cacheWrite5m: 3, cacheWrite1h: 4, cacheRead: 5)
        )

        let encoded = try JSONEncoder().encode(record)
        #expect(String(decoding: encoded, as: UTF8.self) == #"[100,"claude-opus-5",1,2,3,4,5]"#)

        let restored = try JSONDecoder().decode(UsageScan.Record.self, from: encoded)
        #expect(restored.key.isEmpty)
        #expect(restored.model == record.model)
        #expect(restored.at == record.at)
        #expect(restored.usage == record.usage)
    }

    /// Five numbers in a row, not five named fields — the file holds one per
    /// reply of the last week.
    @Test func writesUsageAsARow() throws {
        let usage = TokenUsage(input: 1, output: 2, cacheWrite5m: 3, cacheWrite1h: 4, cacheRead: 5)
        let encoded = try JSONEncoder().encode(usage)

        #expect(String(decoding: encoded, as: UTF8.self) == "[1,2,3,4,5]")
        #expect(try JSONDecoder().decode(TokenUsage.self, from: encoded) == usage)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TokenUsage.self, from: Data("[1,2,3]".utf8))
        }
    }

    // MARK: - Words

    @Test func writesTokensShort() {
        #expect(formatTokens(512) == "512")
        #expect(formatTokens(84_000) == "84k")
        #expect(formatTokens(1_200_000) == "1.2M")
        #expect(formatTokens(52_000_000) == "52M")
    }

    @Test func writesMoneyShort() {
        #expect(formatCost(0.004) == "$0.004")
        #expect(formatCost(4.2) == "$4.20")
        #expect(formatCost(132.7) == "$133")
    }
}
