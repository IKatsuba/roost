import Foundation

/// What one request cost, in tokens.
///
/// Five numbers rather than two: cache is billed at its own rates, and the two
/// kinds of cache write are billed differently from each other. Folding them
/// into one `input` would make the total look right and the money wrong.
public struct TokenUsage: Hashable, Sendable, Codable {
    /// Fresh input — the only tokens billed at the plain rate.
    public var input = 0

    public var output = 0

    /// Written into the cache with a five-minute life. Costs a quarter more
    /// than plain input.
    public var cacheWrite5m = 0

    /// Written into the cache with an hour's life. Costs twice plain input —
    /// Claude Code takes this one for everything it expects to reuse.
    public var cacheWrite1h = 0

    /// Read back out of the cache, at a tenth of the input rate. This is the
    /// bulk of a long session and the reason the totals look enormous next to
    /// the bill.
    public var cacheRead = 0

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        cacheRead: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    public static let zero = TokenUsage()

    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    /// Everything that went through the model, cache included.
    public var total: Int { input + output + cacheWrite + cacheRead }

    /// Everything that went *in* — what the context window was filled with.
    public var totalInput: Int { input + cacheWrite + cacheRead }

    public var isEmpty: Bool { total == 0 }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
            cacheRead: a.cacheRead + b.cacheRead
        )
    }

    public static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }

    /// Five numbers in a row rather than five named fields.
    ///
    /// The saved ledger holds one of these per reply in the last week —
    /// thousands of them — and the names would be most of the file. Nobody
    /// reads this one by hand, which is what the workspace snapshot's
    /// readability was for; here the order is the contract, and a row that is
    /// the wrong length is simply refused.
    public init(from decoder: Decoder) throws {
        let row = try decoder.singleValueContainer().decode([Int].self)
        guard row.count == 5 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "expected five counts")
            )
        }
        self.init(
            input: row[0],
            output: row[1],
            cacheWrite5m: row[2],
            cacheWrite1h: row[3],
            cacheRead: row[4]
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([input, output, cacheWrite5m, cacheWrite1h, cacheRead])
    }

    /// Field-by-field maximum — how a duplicate is merged rather than dropped.
    ///
    /// The same reply arrives more than once: a streamed response is written as
    /// it grows, and every copy carries the counters as they stood at that
    /// moment. Skipping the duplicate would keep whichever copy came first and
    /// lose the rest, so each field takes the largest it has seen. This is what
    /// tokscale does, and the reason it is worth copying: the obvious "seen
    /// already, skip" quietly undercounts.
    public func merging(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: max(input, other.input),
            output: max(output, other.output),
            cacheWrite5m: max(cacheWrite5m, other.cacheWrite5m),
            cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h),
            cacheRead: max(cacheRead, other.cacheRead)
        )
    }
}

/// What the tokens would have cost on the API.
///
/// "Would have": a subscription does not bill per token at all, so this is the
/// list price of the same work, not an invoice. It is worth showing anyway —
/// it is the only figure that puts a cache read and an output token on the same
/// scale.
public enum Pricing {
    /// Dollars per million tokens, as published.
    ///
    /// Written per family rather than per model id: within a family the price
    /// has held across versions, while the ids turn over every few months, and
    /// a table keyed by exact id would go stale silently — a model missing from
    /// it costs nothing at all, which reads as "free" rather than "unknown".
    private struct Rate {
        let input: Double
        let output: Double
    }

    private static let rates: [(family: String, rate: Rate)] = [
        // Fable and Mythos share a price and a tier — the most expensive thing
        // on the list, and worth telling apart from Opus at a glance.
        ("fable", Rate(input: 10, output: 50)),
        ("mythos", Rate(input: 10, output: 50)),
        ("opus", Rate(input: 5, output: 25)),
        ("sonnet", Rate(input: 3, output: 15)),
        ("haiku", Rate(input: 1, output: 5)),
    ]

    /// The cache multipliers, which are the same for every model.
    ///
    /// A five-minute write costs a quarter more than plain input, an hour's
    /// write twice as much, and a read a tenth. Kept as multipliers rather than
    /// as four more columns per family: they are a property of the cache, not
    /// of the model, and every family would repeat the same three numbers.
    private static let write5m = 1.25
    private static let write1h = 2.0
    private static let read = 0.1

    /// The price of this usage in dollars, or nil for a model nobody has a
    /// price for.
    ///
    /// nil rather than zero: an unknown model is not a free one, and the
    /// interface has to be able to say so instead of quietly shifting the total
    /// down.
    public static func cost(of usage: TokenUsage, model: String) -> Double? {
        guard let rate = rate(for: model) else { return nil }

        let input = rate.input / 1_000_000
        let output = rate.output / 1_000_000

        return Double(usage.input) * input
            + Double(usage.output) * output
            + Double(usage.cacheWrite5m) * input * write5m
            + Double(usage.cacheWrite1h) * input * write1h
            + Double(usage.cacheRead) * input * read
    }

    /// Matched by the family's name appearing anywhere in the id.
    ///
    /// The ids are not a closed set: `claude-opus-5`, `claude-opus-4-8`,
    /// `claude-haiku-4-5-20251001` and the bare alias `opus` all turn up in
    /// transcripts, and a new one arrives with every release. A substring
    /// answers all of them, including the ones written after this line.
    private static func rate(for model: String) -> Rate? {
        let name = model.lowercased()
        return rates.first { name.contains($0.family) }?.rate
    }

    /// Whether this model has a price at all — the same question `cost` asks,
    /// without the usage.
    public static func isPriced(_ model: String) -> Bool {
        rate(for: model) != nil
    }
}

/// Tokens in words: `1.2M`, `84k`, `512`.
///
/// Ours rather than a `Formatter`: those translate into the system language and
/// put a space before the suffix, while the interface here is English and its
/// columns are counted in characters.
public func formatTokens(_ count: Int) -> String {
    switch count {
    case ..<1_000: return "\(count)"
    case ..<1_000_000: return "\(count / 1_000)k"
    case ..<10_000_000: return String(format: "%.1fM", Double(count) / 1_000_000)
    default: return "\(count / 1_000_000)M"
    }
}

/// Money in words: `$4.20`, `$132`.
///
/// Cents are dropped past a hundred dollars — three significant figures is
/// already more than a spending estimate deserves, and the column is narrow.
public func formatCost(_ dollars: Double) -> String {
    if dollars >= 100 { return String(format: "$%.0f", dollars) }
    if dollars >= 1 { return String(format: "$%.2f", dollars) }
    return String(format: "$%.3f", dollars)
}
