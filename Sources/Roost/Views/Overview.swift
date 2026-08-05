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
                    AgentDot(status: item.status)
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
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(hovered ? Palette.chrome : Palette.terminal)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.focusPane(item.pane.id) }
    }

    private var marker: Color {
        switch item.status {
        case .waiting: Palette.danger
        case .working: Palette.accent
        case .done: Palette.ok
        default: .clear
        }
    }

    /// Panes of invisible tabs are not raised — they have neither a buffer nor
    /// output.
    private var lines: [String] {
        item.session?.recentLines(4) ?? ["session not started"]
    }
}
