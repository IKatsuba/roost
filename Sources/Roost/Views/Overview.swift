import RoostCore
import SwiftUI

/// Every session of every project as a grid, with the last lines of output.
///
/// The waiting come first, the working next, the idle at the tail — sorted by
/// urgency rather than alphabetically.
struct Overview: View {
    let model: WorkspaceModel

    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: Metrics.hairline)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Metrics.hairline) {
                ForEach(model.overview) { item in
                    OverviewCard(model: model, item: item)
                }
            }
            .padding(Metrics.hairline)
        }
        .scrollIndicators(.never)
        .background(Palette.line)
        .onReceive(tick) { now = $0 }
    }
}

private struct OverviewCard: View {
    let model: WorkspaceModel
    let item: WorkspaceModel.Located

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            // The urgency stripe on the left — the same trick as on the active
            // pane.
            Rectangle()
                .fill(marker)
                .frame(width: Metrics.marker)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
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
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(hovered ? Palette.lineSoft : Palette.chrome)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.focusPane(item.pane.id) }
    }

    /// The same ladder as the square: red only for the one that cannot move,
    /// then weight — solid, grey, nothing.
    private var marker: Color {
        switch item.status {
        case .waiting: Palette.text
        case .working: Palette.muted
        case .done: Palette.faint
        default: .clear
        }
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
