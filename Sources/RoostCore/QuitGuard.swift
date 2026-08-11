/// The question asked before quitting while agents are still working.
///
/// Quitting takes every PTY with it, and an agent in the middle of a tool call
/// gets no chance to finish or to say what it managed to do — whatever the
/// interruption caught is what stays on disk. That is the only state worth a
/// dialog: `waiting` and `done` lose nothing but scrollback, and asking about
/// those would teach the hand to dismiss the question without reading it.
public enum QuitGuard {
    /// What the dialog says, or nothing at all when quitting costs nothing.
    public struct Prompt: Equatable, Sendable {
        public let title: String
        public let body: String
    }

    /// Beyond this the list stops being a list and becomes a wall — the rest
    /// is counted instead. Six rows still fit a dialog on any screen.
    static let maxNames = 6

    /// The names are listed rather than counted: with a dozen panes open, "3
    /// agents are working" is a riddle about which three, and the answer
    /// decides whether the quit is a mistake.
    public static func prompt(working names: [String]) -> Prompt? {
        guard !names.isEmpty else { return nil }

        let title = names.count == 1
            ? "quit while an agent is working?"
            : "quit while \(names.count) agents are working?"

        var lines = names.prefix(maxNames).map { $0 }
        if names.count > maxNames {
            lines.append("and \(names.count - maxNames) more")
        }
        lines.append("")
        lines.append("their work stops where it is.")

        return Prompt(title: title, body: lines.joined(separator: "\n"))
    }
}
