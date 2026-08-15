import Foundation

/// What the interface shows, cut once and handed over whole.
///
/// The ledger holds hundreds of thousands of records and lives on a background
/// actor; views get this instead — a few dozen numbers, already added up.
public struct UsageSnapshot: Sendable {
    /// Spending between two moments, priced.
    public struct Slice: Hashable, Sendable {
        public var usage = TokenUsage.zero
        public var cost: Double = 0

        /// When the window began, and when it starts over. Both nil for the
        /// running total, which has neither.
        public var since: Date?
        public var until: Date?

        public init(
            usage: TokenUsage = .zero,
            cost: Double = 0,
            since: Date? = nil,
            until: Date? = nil
        ) {
            self.usage = usage
            self.cost = cost
            self.since = since
            self.until = until
        }

        /// How long until it starts over, if that is known.
        public func remaining(at now: Date) -> TimeInterval? {
            until.map { max(0, $0.timeIntervalSince(now)) }
        }
    }

    /// The five-hour window — what a human is actually working against.
    public var window = Slice()

    /// The seven-day one.
    public var week = Slice()

    /// Everything the transcripts remember, from the first session onwards.
    public var total = Slice()

    public var byProject: [String: TokenUsage] = [:]
    public var sessions: [String: UsageLedger.Session] = [:]

    /// The ceilings, as Anthropic reports them. Empty when nobody has logged
    /// in, or when the token needs replacing — see [UsageLimits.Reading].
    public var limits: [LimitWindow] = []
    public var trouble: UsageLimits.Trouble?

    /// True until the first pass over the transcripts has finished. The
    /// interface shows nothing rather than a confident zero while it holds.
    public var isCounting = true

    public init() {}

    public var isEmpty: Bool { total.usage.isEmpty && limits.isEmpty }

    /// The window a human wants named: whichever ceiling is closest to full.
    ///
    /// Not always the five-hour one — a week can run out first, and the number
    /// worth putting in the window bar is the one that will stop the work.
    public var tightest: LimitWindow? {
        limits.max { $0.usedPercent < $1.usedPercent }
    }

    /// A project and the catalogs its sessions can be kept in — its own, and one
    /// per worktree. One project to a human, several directories to Claude Code.
    public struct ProjectPlaces: Sendable, Hashable {
        public let name: String
        public let directories: [String]

        public init(name: String, directories: [String]) {
            self.name = name
            self.directories = directories
        }
    }

    /// What one project came to.
    public struct ProjectShare: Sendable, Hashable {
        public let name: String
        public let usage: TokenUsage

        /// Nil when nothing under it could be priced — not zero. See
        /// [UsageLedger.Session.cost].
        public let cost: Double?

        /// Open in Roost, as opposed to the leftovers of the catalog.
        public let known: Bool

        public init(name: String, usage: TokenUsage, cost: Double?, known: Bool) {
            self.name = name
            self.usage = usage
            self.cost = cost
            self.known = known
        }
    }

    /// The projects by what they came to, dearest first, with everything else
    /// on one line at the end.
    ///
    /// One pass over the totals rather than a search per project. The panel
    /// that shows this is rebuilt whenever any agent says anything — it reads
    /// the sessions' own titles and statuses — so what used to be a scan of
    /// every session for every project, twice over (once for the tokens and
    /// again for the money), ran dozens of times a second.
    ///
    /// The leftovers are kept rather than dropped: the five-hour window is
    /// spent by whatever ran in it, and a human working in a directory Roost
    /// does not have open is owed the difference.
    public func shares(of places: [ProjectPlaces]) -> [ProjectShare] {
        var owner: [String: Int] = [:]
        for (index, place) in places.enumerated() {
            for directory in place.directories { owner[directory] = index }
        }

        var usage = [TokenUsage](repeating: .zero, count: places.count)
        var elsewhere = TokenUsage.zero

        for (directory, tokens) in byProject {
            if let index = owner[directory] {
                usage[index] += tokens
            } else {
                elsewhere += tokens
            }
        }

        // Money is added up per session rather than by pricing a project's
        // tokens: the tokens are a sum over models, and a sum has no single
        // rate.
        var cost = [Double?](repeating: nil, count: places.count)
        for session in sessions.values {
            guard let index = owner[session.project], let priced = session.cost else { continue }
            cost[index] = (cost[index] ?? 0) + priced
        }

        var shares = places.indices
            .filter { !usage[$0].isEmpty }
            .map {
                ProjectShare(
                    name: places[$0].name,
                    usage: usage[$0],
                    cost: cost[$0],
                    known: true
                )
            }

        shares.sort { $0.usage.total > $1.usage.total }

        if !elsewhere.isEmpty {
            shares.append(
                ProjectShare(name: "elsewhere", usage: elsewhere, cost: nil, known: false)
            )
        }

        return shares
    }
}

extension UsageLedger {
    /// The five-hour window a subscription is measured in.
    public static let sessionWindow: TimeInterval = 5 * 3600
    public static let weekWindow: TimeInterval = 7 * 24 * 3600

    /// Cuts the snapshot.
    ///
    /// The window's boundaries come from the limits when there are any: the
    /// reset time is the one thing the API knows and the transcripts cannot —
    /// a window opens at the first request after the last one closed, which is
    /// not the same as five hours ago. Without them the fallback is exactly
    /// that, five hours back, and it is an approximation the interface says so
    /// about by having no percentage beside it.
    public func snapshot(
        now: Date = Date(),
        limits: UsageLimits.Reading = UsageLimits.Reading(),
        counting: Bool = false
    ) -> UsageSnapshot {
        var snapshot = UsageSnapshot()

        snapshot.limits = limits.windows
        snapshot.trouble = limits.trouble
        snapshot.isCounting = counting
        snapshot.byProject = byProject
        snapshot.sessions = sessions

        let session = limits.windows.first { $0.kind == .session }
        let week = limits.windows.first { $0.kind == .week && $0.label == nil }

        snapshot.window = slice(
            ending: session?.resetsAt,
            lasting: Self.sessionWindow,
            now: now
        )
        snapshot.week = slice(
            ending: week?.resetsAt,
            lasting: Self.weekWindow,
            now: now
        )

        snapshot.total = UsageSnapshot.Slice(usage: total, cost: totalCost)

        return snapshot
    }

    private func slice(ending: Date?, lasting: TimeInterval, now: Date) -> UsageSnapshot.Slice {
        let start = ending.map { $0.addingTimeInterval(-lasting) } ?? now.addingTimeInterval(-lasting)

        return UsageSnapshot.Slice(
            usage: usage(from: start),
            cost: cost(from: start),
            since: start,
            until: ending
        )
    }
}

/// Time left in words: `1h 48m`, `12m`, `4d 3h`.
///
/// Coarser than [formatAge] and rounded down on purpose — this counts towards
/// a reset hours away, where seconds are noise and a number that ticks every
/// second is a distraction in the corner of the window.
public func formatRemaining(_ interval: TimeInterval) -> String {
    let minutes = Int(max(0, interval)) / 60

    switch minutes {
    case ..<1: return "now"
    case ..<60: return "\(minutes)m"
    case ..<1440: return "\(minutes / 60)h \(minutes % 60)m"
    default: return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
    }
}
