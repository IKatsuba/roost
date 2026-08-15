import RoostCore
import SwiftUI

/// The spending, in full — the third view of the right-hand strip.
///
/// It belongs beside the queue and the feed rather than in the overview: those
/// two answer "what is needed from me" and "what has been going on", and this
/// one answers "what has it cost" — three readings of the same work, in a
/// column narrow enough that each has to say one thing per line.
///
/// The order is the order the questions get asked in: how much is left, what
/// the session in front of me came to, which of the open ones is expensive, and
/// only then the standing totals.
struct SpendPanel: View {
    let model: WorkspaceModel

    @State private var now = Date()

    /// Reset times count down in minutes, so a minute is often enough. Half of
    /// one keeps the number from sitting visibly stale after a window turns
    /// over.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        let snapshot = model.usage.snapshot

        // Both lists are worked out once. They used to be built inside the
        // hierarchy — `openSessions` twice over, to ask whether it was empty
        // and then to walk it — and this body runs whenever any agent says
        // anything at all: it reads the sessions' own titles and statuses.
        let open = openSessions(snapshot)
        let shares = snapshot.shares(of: model.projectPlaces())

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                windows(snapshot)

                if let session = currentSession(snapshot) {
                    Section("THIS SESSION", trailing: money(session.cost)) {
                        ModelRows(session: session)
                    }
                }

                if !open.isEmpty {
                    Section("SESSIONS", trailing: "OPEN") {
                        ForEach(open, id: \.pane) { row in
                            SessionRow(row: row)
                        }
                    }
                }

                Section("PROJECTS", trailing: "ALL TIME") {
                    ForEach(shares, id: \.name) { row in
                        Row(name: row.name, tokens: row.usage.total, cost: row.cost, muted: !row.known)
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Windows

    @ViewBuilder
    private func windows(_ snapshot: UsageSnapshot) -> some View {
        if snapshot.limits.isEmpty {
            // No ceilings to draw against — nobody has logged in, or the token
            // wants replacing. The tokens are still ours to count, so the
            // window says what it spent, without a share of anything.
            Section("LAST 5H", trailing: money(snapshot.window.cost)) {
                Text(trouble(snapshot) ?? formatTokens(snapshot.window.usage.total))
                    .font(Typography.label)
                    .foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 8)
            }
        } else {
            ForEach(snapshot.limits) { window in
                Section(window.title, trailing: resets(window)) {
                    WindowBar(
                        percent: window.usedPercent,
                        spent: spent(for: window, in: snapshot)
                    )
                }
            }
        }
    }

    private func resets(_ window: LimitWindow) -> String {
        guard let at = window.resetsAt else { return "" }
        return formatRemaining(at.timeIntervalSince(now))
    }

    /// Only the plain ceilings get a figure beside them: a per-model week
    /// counts one model's replies, and the sum of everything in those days
    /// would be a different number wearing the same label.
    private func spent(for window: LimitWindow, in snapshot: UsageSnapshot) -> UsageSnapshot.Slice? {
        guard window.label == nil else { return nil }
        return window.kind == .session ? snapshot.window : snapshot.week
    }

    private func trouble(_ snapshot: UsageSnapshot) -> String? {
        switch snapshot.trouble {
        case .noCredentials: "no claude login on this machine"
        case .tokenExpired: "token expired — claude code replaces it on its own"
        case .throttled: "anthropic is rate limiting — waiting it out"
        case .unreachable: "cannot reach anthropic"
        case nil: snapshot.isCounting ? "counting the transcripts…" : nil
        }
    }

    // MARK: - Rows

    private func currentSession(_ snapshot: UsageSnapshot) -> UsageLedger.Session? {
        guard let id = model.activeTab?.activePane.agentSessionID else { return nil }
        return snapshot.sessions[id]
    }

    struct Open {
        let pane: String
        let title: String
        let status: AgentStatus
        let usage: TokenUsage
        let cost: Double?
    }

    /// The sessions open in Roost, dearest first.
    ///
    /// Open ones rather than every session on the machine: these are the ones
    /// with names a human recognises, and the question the panel is answering
    /// is which of the things in front of them is expensive. The rest is what
    /// the project totals below are for.
    private func openSessions(_ snapshot: UsageSnapshot) -> [Open] {
        model.located
            .compactMap { item -> Open? in
                guard let id = item.pane.agentSessionID,
                    let session = snapshot.sessions[id],
                    !session.usage.isEmpty
                else { return nil }

                return Open(
                    pane: item.pane.id,
                    title: item.title,
                    status: item.status,
                    usage: session.usage,
                    cost: session.cost
                )
            }
            .sorted { ($0.cost ?? 0, $0.usage.total) > ($1.cost ?? 0, $1.usage.total) }
    }

    private func money(_ cost: Double?) -> String {
        cost.map(formatCost) ?? ""
    }
}

// MARK: - Pieces

/// A titled block. The heading carries the one number that belongs to the whole
/// block, right-aligned — the same shape in every section, so the eye finds it
/// without reading the label.
private struct Section<Content: View>: View {
    let title: String
    let trailing: String
    @ViewBuilder let content: Content

    init(_ title: String, trailing: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .kerning(1)
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 6)
                Text(trailing)
                    .monospacedDigit()
                    .foregroundStyle(Palette.faint)
            }
            .font(Typography.label)
            .lineLimit(1)
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 10)
            .padding(.bottom, 6)

            content
            Hairline()
        }
    }
}

/// A window's fill, with what it cost under it.
///
/// The bar runs the full width of the column rather than being a row of marks:
/// here there is room for it, and a continuous fill reads as a share of
/// something in a way eight cells cannot.
private struct WindowBar: View {
    let percent: Double
    let spent: UsageSnapshot.Slice?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Palette.lineSoft)
                    Rectangle()
                        .fill(Palette.text)
                        .frame(width: max(1, proxy.size.width * percent / 100))
                }
            }
            .frame(height: 6)

            HStack(spacing: 6) {
                Text("\(Int(percent.rounded()))%")
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 6)
                if let spent, !spent.usage.isEmpty {
                    Text("\(formatTokens(spent.usage.total)) · \(formatCost(spent.cost))")
                        .foregroundStyle(Palette.muted)
                }
            }
            .font(Typography.label)
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 10)
    }
}

/// The models a session ran on, and what each of them read and wrote.
///
/// Cache is kept apart from the rest and not folded into the input: it is the
/// bulk of any long session and a tenth of the price, so a single "input"
/// figure would be both the largest number on screen and the least informative.
private struct ModelRows: View {
    let session: UsageLedger.Session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.models, id: \.model) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(shortened(entry.model))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(formatCost(Pricing.cost(of: entry.usage, model: entry.model) ?? 0))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                    }

                    Text(
                        "\(formatTokens(entry.usage.input)) in · \(formatTokens(entry.usage.output)) out"
                    )
                    .foregroundStyle(Palette.faint)

                    Text(
                        "\(formatTokens(entry.usage.cacheRead)) cache read · "
                            + "\(formatTokens(entry.usage.cacheWrite)) write"
                    )
                    .foregroundStyle(Palette.faint)
                }
                .font(Typography.label)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `claude-opus-5` is the name; `claude-` is on every one of them and buys
    /// nothing in a column this narrow.
    private func shortened(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}

private struct SessionRow: View {
    let row: SpendPanel.Open

    var body: some View {
        HStack(spacing: 7) {
            AgentMark(status: row.status)

            Text(row.title)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Text(formatTokens(row.usage.total))
                .monospacedDigit()
                .foregroundStyle(Palette.faint)

            Text(row.cost.map(formatCost) ?? "")
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                // Held at a width, so the money lines up down the column
                // whatever the names beside it do.
                .frame(width: 52, alignment: .trailing)
        }
        .font(Typography.label)
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 4)
    }
}

private struct Row: View {
    let name: String
    let tokens: Int
    let cost: Double?
    let muted: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(name)
                .foregroundStyle(muted ? Palette.faint : Palette.text)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 6)

            Text(formatTokens(tokens))
                .monospacedDigit()
                .foregroundStyle(Palette.faint)

            Text(cost.map(formatCost) ?? "")
                .monospacedDigit()
                .foregroundStyle(Palette.muted)
                .frame(width: 52, alignment: .trailing)
        }
        .font(Typography.label)
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 4)
    }
}
