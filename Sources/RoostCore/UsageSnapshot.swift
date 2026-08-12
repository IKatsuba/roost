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
