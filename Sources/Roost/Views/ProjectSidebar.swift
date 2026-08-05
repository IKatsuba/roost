import RoostCore
import SwiftUI

struct ProjectSidebar: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROJECTS")
                    .font(Typography.label)
                    .kerning(1)
                    .foregroundStyle(Palette.faint)

                Spacer()

                Text("\(model.projects.count)")
                    .font(Typography.label)
                    .monospacedDigit()
                    .foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 6)
            .padding(.bottom, 8)

            if model.projects.isEmpty {
                Text("none")
                    .font(Typography.item)
                    .foregroundStyle(Palette.faint)
                    .padding(.horizontal, Metrics.gutter)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.projects.enumerated()), id: \.element.id) {
                            index, project in
                            ProjectRow(
                                model: model,
                                project: project,
                                // The tenth project and beyond get no number:
                                // there is no key for them, and a digit would
                                // promise one.
                                number: index < 9 ? index + 1 : nil,
                                isActive: project.id == model.activeProjectID
                            )
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 0)

            Button {
                openProject(model: model)
            } label: {
                Text("⌘N PROJECT")
                    .font(Typography.label)
                    .kerning(1)
                    .foregroundStyle(Palette.faint)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: Metrics.sidebarWidth)
        .background(Palette.chrome)
    }
}

private struct ProjectRow: View {
    let model: WorkspaceModel
    let project: Project
    let number: Int?
    let isActive: Bool

    @State private var hovered = false

    /// Whether the name is being edited right now, and what is in the field.
    /// The draft is kept apart from the project: until Return the name does not
    /// change, and Esc puts everything back.
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(isActive ? Palette.accent : .clear)
                .frame(width: Metrics.marker)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if renaming {
                        TextField("", text: $draft)
                            .textFieldStyle(.plain)
                            .font(Typography.item)
                            .foregroundStyle(Palette.text)
                            .focused($editing)
                            .onSubmit(commit)
                            // Clicking away is consent too: the field must not
                            // hang over the sidebar waiting for Return.
                            .onChange(of: editing) { if !editing { commit() } }
                            .onExitCommand { renaming = false }
                    } else {
                        Text(project.name)
                            .font(Typography.item)
                            .lineLimit(1)
                            .truncationMode(.head)
                            // A directory that is gone is struck through rather
                            // than coloured — there is no colour left to spend,
                            // and a line through a name says "not there" in any
                            // palette.
                            .strikethrough(!project.exists, color: Palette.faint)
                            .foregroundStyle(
                                !project.exists
                                    ? Palette.faint
                                    : (isActive || hovered ? Palette.text : Palette.muted)
                            )

                        Spacer(minLength: 4)

                        // The number is ⌘⌥1…9 itself: the hint stands where it
                        // is pressed. Exactly like the tabs one row below.
                        if let number {
                            Text("\(number)")
                                .font(Typography.label)
                                .monospacedDigit()
                                .foregroundStyle(Palette.faint)
                        }

                        if hovered {
                            Button {
                                model.removeProject(project.id)
                            } label: {
                                Text("×").font(Typography.item).foregroundStyle(Palette.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // One dash per session: red shows even on a collapsed project,
                // or a question from a background directory would go unnoticed
                // until the evening.
                HStack(spacing: 3) {
                    ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                        Rectangle()
                            .fill(AgentMark.color(for: status))
                            .frame(width: 6, height: 3)
                    }
                }
            }
            .padding(.vertical, 5)
        }
        .padding(.trailing, Metrics.gutter)
        .frame(minHeight: 34)
        .background(isActive || hovered ? Palette.lineSoft : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // A double click on the name — as in Finder. The project deliberately
        // does not become active: editing a name is no reason to poke the
        // terminal.
        .onTapGesture(count: 2) { beginRename() }
        .onTapGesture { if !renaming { model.selectProject(project.id) } }
        .contextMenu {
            Button("rename") { beginRename() }
            Button("remove") { model.removeProject(project.id) }
        }
        .help(project.path)
    }

    private func beginRename() {
        draft = project.name
        renaming = true
        editing = true
    }

    private func commit() {
        guard renaming else { return }
        renaming = false
        model.renameProject(project.id, to: draft)
    }

    private var statuses: [AgentStatus] { model.statuses(of: project.id) }
}
