import RoostCore
import SwiftUI

/// The left edge of the window bar: where I am.
///
/// The path is muted as a whole and the project's name is in the ordinary
/// colour: the line answers "where am I" rather than decorating the window.
struct TitleBarPath: View {
    let model: WorkspaceModel

    var body: some View {
        let project = model.activeProject

        return HStack(spacing: 0) {
            if let project {
                Text(shortened(project.path).dropLast(project.name.count))
                    .foregroundStyle(Palette.muted)
                Text(project.name)
                    .foregroundStyle(Palette.text)
            }
        }
        .font(Typography.item)
        .lineLimit(1)
        .truncationMode(.head)
        .padding(.leading, 12)
        // A long path must not crawl as far as the switch at the other edge.
        .frame(maxWidth: 520, alignment: .leading)
        .frame(height: Metrics.titleBar)
    }

    private func shortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// The right edge of the window bar: what I am doing — working or looking over.
///
/// Nothing here changes from session to session: in the overview there is no
/// active project at all, and tabs or a path would have nothing to lean on.
struct ViewSwitch: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            Hairline(vertical: true)
            button("WORK", mode: .work, badge: nil)
            Hairline(vertical: true)
            // The waiting counter sits right on the button: it is the reason to
            // go to the overview in the first place.
            // Not `statusCounts[.waiting]`: with nobody waiting that is nil, the
            // room for the counter would not be taken, and the accessory would
            // end up narrower than its content.
            button("OVERVIEW", mode: .deck, badge: model.statusCounts[.waiting] ?? 0)
        }
        .frame(height: Metrics.titleBar)
    }

    private func button(_ title: String, mode: WorkspaceModel.Mode, badge: Int?) -> some View {
        let isActive = model.mode == mode

        return Button {
            model.mode = mode
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(Typography.label)
                    .kerning(1)
                    .foregroundStyle(isActive ? Palette.text : Palette.faint)

                // The room for the counter is always held: an accessory in the
                // window bar is given its frame once, and its width must not
                // change.
                if let badge {
                    Text(badge > 0 ? "\(badge)" : " ")
                        .font(Typography.label)
                        .monospacedDigit()
                        // Full text weight, where everything around it is muted:
                        // that is what a count of waiting agents gets instead of
                        // a colour.
                        .foregroundStyle(Palette.text)
                        .frame(width: 8, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            .background(isActive ? Palette.terminal : .clear)
            // Without this only the text itself is clickable: a transparent
            // background has no hit area of its own.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
