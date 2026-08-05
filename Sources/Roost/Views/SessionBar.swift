import RoostCore
import SwiftUI

/// The strip under the window: the active project's sessions in "work", the
/// filters in "overview".
///
/// Two rows, two jobs: the upper one belongs to the window, this one to the
/// view. In the overview there is no single project, and tabs would have
/// nothing to lean on there.
struct SessionBar: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            switch model.mode {
            case .work:
                label(model.activeProject?.name ?? "SESSIONS")
                Hairline(vertical: true)
                tabs
            case .deck:
                label("SHOW")
                Hairline(vertical: true)
                filters
            }
        }
        .frame(height: Metrics.sessionBar)
        .background(Palette.sunken)
    }

    /// The header is exactly the sidebar's width — the strips below continue
    /// its column instead of arguing with it.
    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typography.label)
            .kerning(1)
            .foregroundStyle(Palette.faint)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, Metrics.gutter)
            .frame(width: Metrics.sidebarWidth, alignment: .leading)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            if let project = model.activeProject {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.tabs(of: project.id).enumerated()), id: \.element.id) {
                            index, tab in
                            TabButton(
                                model: model,
                                tab: tab,
                                number: index + 1,
                                isActive: tab.id == model.activeTab?.id
                            )
                            Hairline(vertical: true)
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 0)
            Hairline(vertical: true)

            Button {
                model.newTab()
            } label: {
                Text("+")
                    .font(Typography.item)
                    .foregroundStyle(Palette.faint)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New claude session — ⌘T")
        }
    }

    private var filters: some View {
        let counts = model.statusCounts

        return HStack(spacing: 0) {
            filter(nil, "All", count: counts.values.reduce(0, +))
            ForEach([AgentStatus.waiting, .working, .done, .idle], id: \.self) { status in
                filter(status, status.rawValue.capitalized, count: counts[status] ?? 0)
            }
            Spacer(minLength: 0)
        }
    }

    private func filter(_ status: AgentStatus?, _ title: String, count: Int) -> some View {
        let isActive = model.filter == status

        return Button {
            model.filter = status
        } label: {
            HStack(spacing: 7) {
                if let status { AgentDot(status: status) }
                Text(title)
                    .font(Typography.item)
                    .foregroundStyle(isActive ? Palette.text : Palette.muted)
                Text("\(count)")
                    .font(Typography.label)
                    .monospacedDigit()
                    .foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background(isActive ? Palette.terminal : .clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Palette.accent : .clear)
                    .frame(height: Metrics.marker)
            }
            // Otherwise only the label is clickable: a transparent background
            // has no hit area of its own.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
    }
}

private struct TabButton: View {
    let model: WorkspaceModel
    let tab: TabSpec
    let number: Int
    let isActive: Bool

    @State private var hovered = false

    private var session: TerminalSession? { model.session(tab.activePaneID) }

    var body: some View {
        HStack(spacing: 7) {
            let status = session?.status ?? .none
            if status != .none {
                AgentDot(status: status)
            }

            Text(session?.name ?? tab.title)
                .font(Typography.item)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive || hovered ? Palette.text : Palette.muted)

            // The number is ⌘1…9 itself: the hint stands where it is pressed.
            Text("\(number)")
                .font(Typography.label)
                .monospacedDigit()
                .foregroundStyle(Palette.faint)

            if tab.paneCount > 1 {
                Text("▚")
                    .font(Typography.label)
                    .foregroundStyle(Palette.faint)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 190, maxHeight: .infinity)
        // The active tab is lighter than the strip — it continues the pane
        // beneath it.
        .background(isActive ? Palette.terminal : .clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? Palette.accent : .clear)
                .frame(height: Metrics.marker)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.selectTab(tab.id) }
    }
}
