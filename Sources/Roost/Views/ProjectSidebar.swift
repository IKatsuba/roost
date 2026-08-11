import RoostCore
import SwiftUI

struct ProjectSidebar: View {
    let model: WorkspaceModel

    /// The row drag in flight, and the frames it does its arithmetic over —
    /// exactly as in the tab strip, only down instead of along. The model is
    /// left alone until the mouse comes up: reordering mid-gesture tears the
    /// rows out from under the gesture itself.
    @State private var drag: ReorderDrag?
    @State private var rowFrames: [String: CGRect] = [:]

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
                    // Not lazy any more: a drag needs every row's frame at
                    // once, and a lazy stack only reports the rows it has
                    // built. The list is as long as a human has projects.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.projects.enumerated()), id: \.element.id) {
                            index, project in
                            ProjectRow(
                                model: model,
                                project: project,
                                // The tenth project and beyond get no number:
                                // there is no key for them, and a digit would
                                // promise one.
                                number: index < 9 ? index + 1 : nil,
                                isActive: project.id == model.activeProjectID,
                                isCarried: drag?.id == project.id
                            )
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: ItemFramesKey.self,
                                        value: [project.id: proxy.frame(in: .named("projects"))]
                                    )
                                }
                            )
                            // Only the y: the sidebar is a column, and a row
                            // has nowhere to go sideways.
                            .offset(y: drag?.offset(of: project.id) ?? 0)
                            // The carried row rides over its neighbours, or the
                            // one drawn later would cut through it.
                            .zIndex(drag?.id == project.id ? 1 : 0)
                            .gesture(dragGesture(for: project.id))
                        }
                    }
                    .coordinateSpace(name: "projects")
                    .onPreferenceChange(ItemFramesKey.self) { [$rowFrames] frames in
                        $rowFrames.wrappedValue = frames
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

    /// Not the system drag-and-drop but a plain gesture, for the tab strip's
    /// reasons: the list reorders under the mouse, and a row never leaves its
    /// column — a floating preview would promise a drop somewhere else, and
    /// there is nowhere else.
    ///
    /// Four points before it starts, so a click still selects a project and a
    /// double click still opens the name for editing.
    private func dragGesture(for projectID: String) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if drag?.id != projectID {
                    drag = ReorderDrag(id: projectID, axis: .vertical, frames: rowFrames)
                }
                drag?.translation = value.translation.height

                // The carried row follows the mouse raw; the neighbours' shifts
                // flip in steps, and only those steps are animated. One
                // withAnimation over everything would drag the cursor itself on
                // a spring.
                guard let drag, drag.shifts != drag.currentShifts() else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.drag?.shifts = drag.currentShifts()
                }
            }
            .onEnded { _ in
                guard let drag else { return }
                // One animation over the commit and the cleanup together: the
                // layout change and the dying offsets cancel out, and the row
                // glides from under the cursor into its slot.
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.moveProject(drag.id, to: drag.targetIndex)
                    self.drag = nil
                }
            }
    }
}

private struct ProjectRow: View {
    let model: WorkspaceModel
    let project: Project
    let number: Int?
    let isActive: Bool

    /// Being dragged right now. A row is transparent by default, and a carried
    /// one would let the neighbour it passes over show through it — the fill
    /// under the cursor is what says the row has been picked up.
    let isCarried: Bool

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
        .background(isActive || hovered || isCarried ? Palette.lineSoft : .clear)
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
