import Foundation

/// A git worktree that Claude Code creates for itself under `--worktree`.
///
/// Roost neither creates nor removes them: `claude -w name` runs `git worktree
/// add` in `<project>/.claude/worktrees/<name>` on branch `worktree-<name>`,
/// and running it again with the same name simply enters the existing one. All
/// the app has to do is remember the name and pass the flag again — including
/// when restoring a snapshot. Without it `--resume` would look for the session
/// in the project directory, while the session lives in the worktree.
public enum Worktree {
    /// Where Claude Code keeps them, relative to the project root.
    public static let container = ".claude/worktrees"

    public static func path(inside project: String, name: String) -> String {
        "\(project)/\(container)/\(name)"
    }

    /// Worktree names this project already has.
    public static func names(inside project: String) -> [String] {
        let directory = URL(fileURLWithPath: project).appendingPathComponent(container)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Whether the directory has git at all: without it `--worktree` only swears.
    public static func isRepository(_ project: String) -> Bool {
        // Not `.git` as a directory: inside a worktree or a submodule it is a
        // pointer file, and that does not make the project any less of a repo.
        FileManager.default.fileExists(atPath: "\(project)/.git")
    }

    /// A name fit for a branch and for a shell string alike.
    ///
    /// The strictness is not about looks: the name ends up inside single quotes
    /// in the pane's command, and one quote in the middle would turn the rest
    /// into somebody else's command. It also drops what `git branch` refuses.
    public static func sanitize(_ raw: String) -> String? {
        let allowed = raw.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character
                : (character == "." || character == "_" || character == "-") ? character
                : "-"
        }

        // Dashes collapse and get trimmed: `fix login (2)` would otherwise turn
        // into `fix-login--2-`, and that is a branch name a human still has to
        // read.
        let name = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
            .prefix(64)

        return name.isEmpty ? nil : String(name)
    }
}
