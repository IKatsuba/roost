import RoostCore
import SwiftUI

/// The right-hand strip: two views of one and the same thing.
///
/// The queue is a list of debts: who ran into a question and has waited the
/// longest. The feed is the same thing over time: who started, who finished, who
/// dropped out. The first answers "what is needed from me right now", the second
/// "what is going on at all".
struct SidePanel: View {
    let model: WorkspaceModel

    enum Side: Hashable {
        case queue
        case feed
    }

    @State private var side: Side = .queue

    /// Age runs in seconds, so the column is driven by a timer rather than by
    /// changes in the model.
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let queue = model.waitingQueue

        VStack(spacing: 0) {
            header(waiting: queue.count)
            Hairline()

            switch side {
            case .queue: queueBody(queue)
            case .feed: feedBody
            }

            Spacer(minLength: 0)
            Hairline()
            footer(queue: queue)
        }
        .frame(width: 272)
        .background(Palette.chrome)
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Header

    private func header(waiting: Int) -> some View {
        HStack(spacing: 0) {
            tab(.queue, "WAITING", count: waiting, isAlarm: waiting > 0)
            tab(.feed, "ACTIVITY", count: model.activity.count, isAlarm: false)
            Spacer(minLength: 0)
        }
        .frame(height: Metrics.rowHeight)
    }

    private func tab(_ value: Side, _ title: String, count: Int, isAlarm: Bool) -> some View {
        let isActive = side == value

        return Button {
            side = value
        } label: {
            HStack(spacing: 6) {
                if value == .queue { AgentMark(status: .waiting) }

                Text(title)
                    .font(Typography.label)
                    .kerning(1)
                    .foregroundStyle(isActive ? Palette.text : Palette.faint)

                Text("\(count)")
                    .font(Typography.label)
                    .monospacedDigit()
                    .foregroundStyle(isAlarm ? Palette.text : Palette.faint)
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
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
    }

    // MARK: - Queue

    @ViewBuilder
    private func queueBody(_ queue: [WorkspaceModel.Located]) -> some View {
        if queue.isEmpty {
            hint("Nobody is waiting — the queue is empty.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue) { item in
                        QueueCard(model: model, item: item)
                        Hairline()
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: - Feed

    @ViewBuilder
    private var feedBody: some View {
        if model.activity.isEmpty {
            hint("Nothing has happened yet.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.activity) { entry in
                        FeedRow(model: model, entry: entry, now: now)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Typography.item)
            .foregroundStyle(Palette.muted)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(queue: [WorkspaceModel.Located]) -> some View {
        HStack {
            switch side {
            case .queue:
                Text("⌘⇧A — jump to first")
                Spacer()
                Text(queue.first.map { "\(formatAge($0.age)) idle" } ?? "empty")
                    .monospacedDigit()
            case .feed:
                Text("newest first")
                Spacer()
                Text(model.activity.last.map { "\(formatAge(now.timeIntervalSince($0.at))) back" }
                    ?? "empty")
                    .monospacedDigit()
            }
        }
        .font(Typography.label)
        .foregroundStyle(Palette.faint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// A feed row: who did what, and how long ago.
private struct FeedRow: View {
    let model: WorkspaceModel
    let entry: WorkspaceModel.Activity
    let now: Date

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            AgentMark(status: entry.status)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(entry.project) / \(entry.title)")
                    .font(Typography.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Palette.muted)

                Text(verb)
                    .font(Typography.item)
                    .lineLimit(1)
                    .foregroundStyle(hovered ? Palette.text : colour)
            }

            Spacer(minLength: 6)

            Text(formatAge(now.timeIntervalSince(entry.at)))
                .font(Typography.label)
                .monospacedDigit()
                .foregroundStyle(Palette.faint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovered ? Palette.lineSoft : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.focusPane(entry.paneID) }
    }

    /// A verb rather than the name of a state: the feed reads as an account of
    /// what happened, not as a table of values.
    private var verb: String {
        if entry.byHand { return "marked as handled" }

        return switch entry.status {
        case .working: "started working"
        case .waiting: "needs you"
        case .done: "finished"
        case .idle: "went idle"
        case .exited: "session ended"
        case .none: "—"
        }
    }

    /// The same order as the marks: what is owed reads at full strength, what
    /// is finished a step below, the rest quietly.
    private var colour: Color {
        switch entry.status {
        case .waiting: Palette.text
        case .done: Palette.muted
        default: Palette.muted
        }
    }
}

private struct QueueCard: View {
    let model: WorkspaceModel
    let item: WorkspaceModel.Located

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                AgentMark(status: .waiting)
                Text("\(item.project.name) / \(item.title)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(formatAge(item.age))
                    .monospacedDigit()
                    .foregroundStyle(Palette.text)
            }
            .font(Typography.label)
            .foregroundStyle(Palette.muted)

            Text(question)
                .font(Typography.item)
                .foregroundStyle(Palette.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // The occasion from the hook does not replace what was said, but it
            // does not vanish either: "needs permission for Bash" explains why
            // the agent stopped.
            if let reason {
                Text(reason)
                    .font(Typography.label)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // There are deliberately no answer buttons here: the agent's
            // questions differ, and "yes/no" would fit half of them at best. The
            // card does one thing — it takes you to the pane where the whole
            // question is visible. The exception is "handled": it answers the
            // agent nothing and only clears the debt.
            HStack(spacing: 8) {
                Text(hovered ? "click to open the session" : " ")
                    .font(Typography.label)
                    .foregroundStyle(Palette.faint)

                Spacer(minLength: 4)

                if hovered {
                    Button {
                        model.markHandled(item.pane.id)
                    } label: {
                        Text("handled ✓")
                            .font(Typography.label)
                            .foregroundStyle(Palette.text)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(
                                Rectangle().strokeBorder(Palette.line, lineWidth: Metrics.hairline)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear the debt without answering — the agent is untouched")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Palette.lineSoft : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.focusPane(item.pane.id) }
    }

    /// What to show on the card, in descending order of meaning: what the agent
    /// said in the dialog, the occasion from the hook ("needs permission"), the
    /// last line on screen.
    private var question: String {
        guard let session = item.session else { return "Waiting for an answer in the pane." }

        if let said = session.lastAgentMessage, !said.isEmpty { return said }
        if let question = session.question, !question.isEmpty { return question }
        return session.recentLines(1).first ?? "Waiting for an answer in the pane."
    }

    /// The occasion is shown only when it is not the only thing there is —
    /// otherwise the line would repeat itself.
    private var reason: String? {
        guard let session = item.session, session.lastAgentMessage?.isEmpty == false else {
            return nil
        }
        return session.question
    }
}
