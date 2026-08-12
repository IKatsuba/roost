import Foundation

/// Everything the transcripts add up to.
///
/// The ledger is read once and then only caught up: each file remembers where
/// the last pass stopped, so a refresh costs the few kilobytes the agents have
/// written since rather than the gigabytes on disk. What it keeps is totals —
/// per session, per model — plus the recent records themselves, which is the
/// only part a five-hour window needs.
public struct UsageLedger: Sendable, Codable {
    /// What one session came to.
    public struct Session: Hashable, Sendable, Codable {
        public var id: String
        public var project: String
        public var usage = TokenUsage.zero
        public var cost: Double?
        public var last: Date = .distantPast

        /// The same total, split by the model that answered.
        ///
        /// A session rarely stays on one: a subagent runs on something cheap
        /// while the conversation itself is on Opus, and the sum alone cannot
        /// say which of them the money went to. This is the one question the
        /// interface asks that a single figure cannot answer.
        public var byModel: [String: TokenUsage] = [:]

        /// Models by what they cost here, dearest first — the order the
        /// interface lists them in.
        public var models: [(model: String, usage: TokenUsage)] {
            byModel
                .map { (model: $0.key, usage: $0.value) }
                .sorted {
                    let left = Pricing.cost(of: $0.usage, model: $0.model) ?? 0
                    let right = Pricing.cost(of: $1.usage, model: $1.model) ?? 0
                    // By money, then by tokens: two free models would otherwise
                    // swap places between refreshes.
                    return (left, $0.usage.total) > (right, $1.usage.total)
                }
        }
    }

    /// Where a file was left off, and what had already been counted out of it.
    ///
    /// The keys are kept as hashes rather than as the ids they came from: a
    /// long-lived machine has hundreds of thousands of replies, and the ids
    /// alone would be tens of megabytes to answer a yes-or-no question. A
    /// 64-bit collision across that many entries is likelier to be a bug in
    /// this comment than to happen.
    struct File: Sendable, Codable {
        /// The session this file counts against, and the project it lives in.
        ///
        /// The totals are kept here, per file, and the sessions are added up
        /// from them — because a session is not one file. A subagent writes a
        /// transcript of its own, and if the running total lived on the session
        /// then one of its files starting over would have to take the others'
        /// tokens with it. Per file there is nothing to unwind: the entry is
        /// replaced, and the sum comes out right on its own.
        var session: String = ""
        var project: String = ""

        var usage = TokenUsage.zero
        var cost: Double?
        var byModel: [String: TokenUsage] = [:]
        var last: Date = .distantPast

        var offset: UInt64 = 0

        /// The inode the offset belongs to.
        ///
        /// A path is not a file. Something else may be at this one now — a
        /// session cleared, a transcript restored from a backup, a name reused
        /// — and then the saved offset points into the middle of a line that
        /// was never read. Size alone does not catch it: the replacement is as
        /// likely to be longer than the original as shorter, and a longer one
        /// looks exactly like an ordinary append.
        var inode: UInt64 = 0

        /// Left out of the keys below, and so out of the file: they recognise a
        /// duplicate on a second pass over the same bytes, and those bytes are
        /// never read again.
        var keys: Set<UInt64> = []

        private enum CodingKeys: String, CodingKey {
            case session, project, usage, cost, byModel, last, offset, inode
        }
    }

    /// What the filesystem calls the file at this path right now, or zero when
    /// there is nothing there to ask about.
    static func inode(of path: String) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// How long it is now — the second half of "is this still the file we were
    /// reading?", for a replacement that kept the inode.
    static func size(of path: String) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.uint64Value
    }

    private var files: [String: File] = [:]

    /// The sessions, added up out of the files that belong to them.
    ///
    /// Computed rather than kept: see [File]. Walking a few thousand entries is
    /// nothing next to being sure the two never drift apart.
    public var sessions: [String: Session] {
        files.values.reduce(into: [:]) { result, file in
            guard !file.usage.isEmpty else { return }

            var entry =
                result[file.session] ?? Session(id: file.session, project: file.project)

            entry.usage += file.usage
            entry.last = max(entry.last, file.last)
            for (model, usage) in file.byModel { entry.byModel[model, default: .zero] += usage }

            // A file whose models all lack a price adds nothing rather than
            // zero: the difference is "not counted" against "counted as free".
            if let cost = file.cost { entry.cost = (entry.cost ?? 0) + cost }

            result[file.session] = entry
        }
    }

    /// Every model that has answered, and what it came to.
    ///
    /// Added up from the sessions rather than kept alongside them: a session
    /// that starts over — `/clear`, a transcript replaced — has to be taken
    /// back out of the total, and a figure kept on the side would have to be
    /// unwound reply by reply to do it. Six models over a few thousand
    /// sessions is nothing to add up when asked.
    public var byModel: [String: TokenUsage] {
        sessions.values.reduce(into: [:]) { totals, session in
            for (model, usage) in session.byModel { totals[model, default: .zero] += usage }
        }
    }

    /// Recent replies, newest last — what the windows are cut out of.
    ///
    /// Only the recent ones: a window never looks further back than a week, and
    /// keeping the whole history here would mean holding every reply ever made
    /// in memory to answer a question about this afternoon.
    public private(set) var recent: [UsageScan.Record] = []

    /// How far back `recent` reaches. A day past the longest window, so that a
    /// weekly figure is never cut off at its own edge.
    public static let horizon: TimeInterval = 8 * 24 * 3600

    public init() {}

    /// Reads whatever has been appended to one session's transcript.
    ///
    /// Returns whether anything was found — the caller redraws on true and does
    /// nothing on false, which is the common case once the first pass is done.
    @discardableResult
    public mutating func absorb(
        transcript path: String,
        session: String,
        project: String,
        now: Date = Date()
    ) -> Bool {
        var file = files[path] ?? File(session: session, project: project)
        let inode = Self.inode(of: path)

        // Something else is at this path now — or the file was truncated where
        // a transcript is only ever appended to. Either way what was counted
        // out of the old contents does not describe the new ones, and reading
        // on from the old offset would land in the middle of a line.
        //
        // Only this file's own entry is dropped. Its session's other files —
        // the subagents' transcripts — counted their own tokens and keep them.
        if file.inode != inode || file.offset > (Self.size(of: path) ?? 0) {
            file = File(session: session, project: project, inode: inode)
        }

        let reading = UsageScan.scan(path: path, from: file.offset)

        file.offset = reading.offset
        file.inode = inode
        file.session = session
        file.project = project

        var fresh: [UsageScan.Record] = []

        // Within one pass a duplicate is merged field by field rather than
        // dropped — see [TokenUsage.merging]. Across passes it is dropped: the
        // copies Claude Code writes are byte-identical, so the second one has
        // nothing to add, and remembering every reply's numbers forever to
        // prove that would cost more than the answer is worth.
        var merged: [UInt64: Int] = [:]
        for record in reading.records {
            let key = hash(record.key)

            if let index = merged[key] {
                fresh[index] = UsageScan.Record(
                    key: record.key,
                    model: record.model,
                    at: fresh[index].at,
                    usage: fresh[index].usage.merging(record.usage)
                )
                continue
            }
            guard file.keys.insert(key).inserted else { continue }

            merged[key] = fresh.count
            fresh.append(record)
        }

        for record in fresh {
            file.usage += record.usage
            file.last = max(file.last, record.at)
            file.byModel[record.model, default: .zero] += record.usage

            // Priced per reply rather than by pricing the file's total: a
            // session that switched models mid-way has no single rate, and
            // pricing the sum by the last model seen would be wrong in
            // whichever direction that model is cheaper or dearer.
            if let cost = Pricing.cost(of: record.usage, model: record.model) {
                file.cost = (file.cost ?? 0) + cost
            }
        }

        files[path] = file
        guard !fresh.isEmpty else { return false }

        recent.append(contentsOf: fresh.filter { now.timeIntervalSince($0.at) < Self.horizon })
        recent.sort { $0.at < $1.at }
        prune(before: now.addingTimeInterval(-Self.horizon))

        return true
    }

    /// Drops what has fallen out of the horizon. The totals keep it — only the
    /// per-record detail the windows need is let go.
    public mutating func prune(before cutoff: Date) {
        guard let end = recent.firstIndex(where: { $0.at >= cutoff }), end > 0 else { return }
        recent.removeFirst(end)
    }

    // MARK: - Reading

    /// What was spent between two moments. The window's own boundaries decide
    /// what counts, so the same records answer for five hours and for a week.
    public func usage(from start: Date, to end: Date = .distantFuture) -> TokenUsage {
        recent.lazy
            .filter { $0.at >= start && $0.at < end }
            .reduce(.zero) { $0 + $1.usage }
    }

    /// The same slice, priced.
    public func cost(from start: Date, to end: Date = .distantFuture) -> Double {
        recent.lazy
            .filter { $0.at >= start && $0.at < end }
            .compactMap { Pricing.cost(of: $0.usage, model: $0.model) }
            .reduce(0, +)
    }

    /// Totals per project, with the sessions of its worktrees folded in — for
    /// a human a branch is the same project, and [SessionCatalog] hands them
    /// over on the same terms.
    public var byProject: [String: TokenUsage] {
        sessions.values.reduce(into: [:]) { totals, session in
            totals[session.project, default: .zero] += session.usage
        }
    }

    public var total: TokenUsage {
        sessions.values.reduce(.zero) { $0 + $1.usage }
    }

    public var totalCost: Double {
        sessions.values.compactMap(\.cost).reduce(0, +)
    }

    /// True while nothing has been read yet — the interface shows nothing
    /// rather than a confident zero.
    /// Nothing has been read yet — the interface shows nothing rather than a
    /// confident zero. Asked of the files rather than the sessions: a machine
    /// whose transcripts are all empty has still been counted.
    public var isEmpty: Bool { files.isEmpty }

    private func hash(_ key: String) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(key)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    // MARK: - Keeping it

    /// What is written down, and what is not.
    ///
    /// The offsets are saved; the keys counted out of them are not. They exist
    /// to recognise a duplicate on a second pass over the same bytes, and those
    /// bytes are never read again — the next run starts where this one stopped.
    /// Saving them would be the largest thing in the file to answer a question
    /// nobody asks again.
    private enum CodingKeys: String, CodingKey {
        case version, files, recent
    }

    /// Bumped when the shape changes. A file from another version is not
    /// migrated but dropped: everything in it can be read again off the
    /// transcripts, so the cost of being wrong is one slow launch, and the cost
    /// of a migration bug is a number nobody can explain.
    static let version = 3

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard try container.decode(Int.self, forKey: .version) == Self.version else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "ledger from another version")
            )
        }

        files = try container.decode([String: File].self, forKey: .files)
        recent = try container.decode([UsageScan.Record].self, forKey: .recent)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(Self.version, forKey: .version)
        try container.encode(files, forKey: .files)
        try container.encode(recent, forKey: .recent)
    }
}

/// Keeps the count beside the workspace snapshot.
///
/// Without it every launch re-reads every transcript on the machine — a
/// gigabyte and change, twelve seconds, for numbers that have not moved since
/// the app was last closed. With it a launch reads the tails and is done in a
/// fifth of a second.
///
/// Losing this file costs nothing but that: it holds no truth of its own, only
/// what the transcripts already say.
public struct UsageStore: Sendable {
    public let file: URL

    public init(directory: URL = WorkspaceStore.defaultDirectory) {
        self.file = directory.appendingPathComponent("usage.json")
    }

    /// A broken or outdated file is not an error — it is a slow launch. The
    /// ledger comes back empty and the transcripts are read again.
    public func load() -> UsageLedger {
        guard let data = try? Data(contentsOf: file),
            let ledger = try? JSONDecoder().decode(UsageLedger.self, from: data)
        else { return UsageLedger() }

        return ledger
    }

    /// Atomic, like the workspace snapshot: a crash mid-write would otherwise
    /// leave truncated json, which is a slow launch rather than a lost one —
    /// but a slow launch nobody could explain.
    ///
    /// Not pretty-printed, and this is the one file in the app that is not:
    /// it holds a row per reply of the last week, and the indentation would be
    /// most of it.
    public func save(_ ledger: UsageLedger) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
    }
}
