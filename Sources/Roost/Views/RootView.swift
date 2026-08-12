import AppKit
import RoostCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    let model: WorkspaceModel

    var body: some View {
        // The palette is deliberately absent here: it lives in a window of its
        // own, or the keyboard would stay with the terminal.
        VStack(spacing: 0) {
            Hairline()

            switch model.mode {
            case .work:
                // Three columns rather than a bar over three columns: the side
                // columns own their top row, so each reaches the title bar and
                // can be put away whole. Their headers share the session bar's
                // height, and the hairlines under them meet in one line.
                HStack(spacing: 0) {
                    if !model.sidebarHidden {
                        VStack(spacing: 0) {
                            SidebarHeader(model: model)
                            Hairline()
                            ProjectSidebar(model: model)
                        }
                        // Pinned from outside: the hairline inside stretches to
                        // any width it is given, and would bloat the column.
                        .frame(width: Metrics.sidebarWidth)
                        Hairline(vertical: true)
                    }

                    VStack(spacing: 0) {
                        SessionBar(model: model)
                        Hairline()
                        mainArea
                    }

                    if !model.sidePanelHidden {
                        Hairline(vertical: true)
                        SidePanel(model: model)
                    }
                }
            case .deck:
                // No session bar over it: in the overview there is no single
                // project for tabs to lean on, and the columns own that line
                // themselves — their headers are the row, exactly as the
                // sidebar's and the side panel's are in "work".
                Overview(model: model)
            }

            Hairline()
            StatusBar(model: model)
        }
        .background(Palette.chrome)
        .frame(minWidth: 720, minHeight: 420)
    }

    @ViewBuilder
    private var mainArea: some View {
        if model.activeProject == nil {
            EmptyState(
                title: "no projects yet",
                hint: "sessions and layout survive a restart",
                action: "open a directory",
                shortcut: "⌘N"
            ) { openProject(model: model) }
        } else if let tab = model.activeTab {
            PaneTreeView(model: model, tab: tab, node: tab.layout)
                .id(tab.id)
        } else {
            EmptyState(
                title: "no sessions in this project",
                hint: nil,
                action: "new claude session",
                shortcut: "⌘T"
            ) { model.newTab() }
        }
    }
}

/// The shared directory picker: the empty state, the menu and the palette all
/// use it.
@MainActor
func openProject(model: WorkspaceModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"

    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.addProject(path: url.path)
}

/// The sidebar's own top row: the active project's name, on the session bar's
/// line. The strips below continue this column instead of arguing with it.
private struct SidebarHeader: View {
    let model: WorkspaceModel

    var body: some View {
        Text((model.activeProject?.name ?? "SESSIONS").uppercased())
            .font(Typography.label)
            .kerning(1)
            .foregroundStyle(Palette.faint)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, Metrics.gutter)
            .frame(width: Metrics.sidebarWidth, height: Metrics.sessionBar, alignment: .leading)
            .background(Palette.sunken)
    }
}

private struct EmptyState: View {
    let title: String
    let hint: String?
    let action: String
    let shortcut: String
    let perform: () -> Void

    var body: some View {
        ZStack {
            Palette.terminal
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Typography.item).foregroundStyle(Palette.muted)
                if let hint {
                    Text(hint).font(Typography.item).foregroundStyle(Palette.faint)
                }
                Button(action: perform) {
                    HStack(spacing: 8) {
                        Text(action).font(Typography.item).foregroundStyle(Palette.accent)
                        Text(shortcut).font(Typography.label).foregroundStyle(Palette.faint)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusBar: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            Text(shortened(model.activeProject?.path ?? ""))
                .font(Typography.label)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            // The ceilings belong here rather than in the window bar: they are
            // a property of the machine, like the counts beside them, and not
            // of the session in front of you.
            UsageMeter(model: model)
                .padding(.trailing, 4)

            // A summary across every project, not just the visible one: an
            // agent's question in a background tab would otherwise go unnoticed.
            let counts = model.statusCounts
            ForEach(AgentStatus.columns, id: \.self) { status in
                if let count = counts[status], count > 0 {
                    HStack(spacing: 5) {
                        AgentMark(status: status)
                        Text("\(count) \(Self.word(for: status))")
                            .font(Typography.label)
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.leading, 14)
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.statusBarHeight)
        .background(Palette.chrome)
    }

    private static func word(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "waiting"
        case .working: "working"
        case .done: "done"
        default: "idle"
        }
    }

    /// The home directory folds into a tilde — as in a shell prompt.
    private func shortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
