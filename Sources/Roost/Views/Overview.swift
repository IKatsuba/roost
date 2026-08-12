import RoostCore
import SwiftUI

/// Every session of every project in four columns — waiting, working, done,
/// idle — with the last lines of output.
///
/// The state used to be readable only off a card, which made "how many are
/// waiting" a question you answered by counting squares. A column answers it by
/// being there, and it does the job the filter row above the grid used to do
/// badly: that one showed one state at a time and hid the rest.
struct Overview: View {
    let model: WorkspaceModel

    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Below four of these the cards stop being readable, so the strip scrolls
    /// sideways instead of crushing them.
    private let minColumn: CGFloat = 240

    var body: some View {
        GeometryReader { geometry in
            // Counted rather than negotiated, and it has to be: a scroll view
            // offers its content infinite width, and under an infinite proposal
            // `maxWidth: .infinity` resolves to the *ideal* width — which for a
            // card holding one long line of an agent's reply is that whole line.
            // One talkative agent used to stretch its column past the window and
            // push the rest off the screen.
            let width = max(
                minColumn,
                (geometry.size.width - CGFloat(AgentStatus.columns.count - 1) * Metrics.hairline)
                    / CGFloat(AgentStatus.columns.count)
            )

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(AgentStatus.columns.enumerated()), id: \.element) { index, status in
                        if index > 0 { Hairline(vertical: true) }

                        Column(
                            model: model,
                            status: status,
                            items: model.columns[status] ?? []
                        )
                        .frame(width: width)
                    }
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.never)
        }
        .background(Palette.chrome)
        .onReceive(tick) { now = $0 }
    }
}

private struct Column: View {
    let model: WorkspaceModel
    let status: AgentStatus
    let items: [WorkspaceModel.Located]

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            // Each column scrolls on its own: a long queue of waiting agents
            // must not push the others off the screen.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        OverviewCard(model: model, item: item)
                        Hairline()
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// The header sits on the session bar's line, as the sidebar's and the side
    /// panel's do: the hairlines under all of them meet in one line.
    private var header: some View {
        HStack(spacing: 7) {
            AgentMark(status: status)

            Text(status.rawValue.uppercased())
                .font(Typography.label)
                .kerning(1)
                .foregroundStyle(Palette.faint)
                .lineLimit(1)

            Spacer(minLength: 6)

            // Counted off the column itself rather than off `statusCounts`:
            // that one knows only live sessions, and would disagree with the
            // cards below by every pane whose tab has not been opened.
            Text("\(items.count)")
                .font(Typography.label)
                .monospacedDigit()
                .foregroundStyle(Palette.faint)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.sessionBar)
        .background(Palette.sunken)
    }
}

private struct OverviewCard: View {
    let model: WorkspaceModel
    let item: WorkspaceModel.Located

    @State private var hovered = false

    var body: some View {
        // No urgency stripe down the left any more: its whole job was the
        // ladder the columns now carry, and a stripe repeating the column it
        // stands in says nothing twice.
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                // The square stays even under a header that shows it: in the
                // idle column it is the only thing telling an idle session from
                // one that has exited or never started.
                AgentMark(status: item.status)
                Text(item.project.name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(formatAge(item.age))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faint)
            }
            .font(Typography.label)
            .foregroundStyle(Palette.muted)

            Text(item.title)
                .font(Typography.item)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Palette.text)

            Group {
                // The agent's message instead of the output: the bottom of
                // a terminal holds the input line and hints, and on a card
                // those mean nothing.
                if let said = item.session?.lastAgentMessage, !said.isEmpty {
                    Text(said)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            .font(Typography.label)
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)

            // What the session has come to, on the card's bottom line.
            // Only where there is something to say: a shell pane has no
            // spending, and a claude one that has not answered yet would
            // otherwise carry a confident zero.
            if let spend {
                HStack(spacing: 6) {
                    Text(formatTokens(spend.usage.total))
                        .foregroundStyle(Palette.muted)
                    Text("·")
                        .foregroundStyle(Palette.faint)
                    Text(spend.cost.map(formatCost) ?? "")
                        .foregroundStyle(Palette.text)

                    Spacer(minLength: 6)

                    // The model is the reason two sessions of the same
                    // length cost differently — it belongs next to the
                    // money rather than in a panel elsewhere.
                    if let model = spend.models.first?.model {
                        Text(shortened(model))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                    }
                }
                .font(Typography.label)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(hovered ? Palette.lineSoft : Palette.chrome)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.focusPane(item.pane.id) }
    }

    /// Panes of invisible tabs are not raised — they have neither a buffer nor
    /// output.
    private var lines: [String] {
        item.session?.recentLines(4) ?? ["session not started"]
    }

    /// What this pane's session has spent, if it has spent anything.
    private var spend: UsageLedger.Session? {
        guard let id = item.pane.agentSessionID,
            let session = model.usage.snapshot.sessions[id],
            !session.usage.isEmpty
        else { return nil }

        return session
    }

    /// `claude-` is on every model's name and buys nothing on a card.
    private func shortened(_ model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}
