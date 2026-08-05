import Foundation

/// Claude Code sessions that are already on disk.
///
/// Claude Code does not hand its session list out, so we read it where it is
/// kept: `~/.claude/projects/<directory>/<uuid>.jsonl`. The knowledge is forced
/// upon us, but it buys what cannot be had otherwise — picking a session before
/// the pane starts, rather than afterwards inside somebody else's interface.
public enum SessionCatalog {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// One session in the list.
    public struct Record: Identifiable, Hashable, Sendable {
        public let id: String
        public let transcriptPath: String
        public let title: String?
        public let modified: Date

        /// The worktree's name, if the session lived in one. Without it,
        /// continuing would open the session in the project directory, where
        /// there is no such session.
        public let worktree: String?

        public init(
            id: String,
            transcriptPath: String,
            title: String?,
            modified: Date,
            worktree: String? = nil
        ) {
            self.id = id
            self.transcriptPath = transcriptPath
            self.title = title
            self.modified = modified
            self.worktree = worktree
        }

        /// What the session is called in the list. Nameless are the ones whose
        /// first message Claude Code found too short to name; for those the
        /// head of the uuid is the only thing telling them from their
        /// neighbours.
        public var label: String { title ?? "session \(id.prefix(8))" }
    }

    /// Where to look for the transcript of a session named by id.
    public enum Resolution: Hashable, Sendable {
        /// Lies exactly where `--resume` will look for it.
        case here(Record)

        /// Found, but under another project. `--resume` only looks into its own
        /// cwd's directory and will not see it from here — the path is inside.
        case elsewhere(String)

        /// Found nowhere. Inside is the directory it has to be put into.
        case missing(String)
    }

    // MARK: - Project directory

    /// What the session directory for this path may be called.
    ///
    /// Claude Code's replacement rule has changed over time: directories made
    /// in spring keep the dot as is (`…-katsuba.live`), summer ones replace it
    /// too (`/Users/me/.superset` → `-Users-me--superset`). Hence two
    /// candidates, and the disk decides which one is real. The current rule
    /// comes first: it is what creates a directory that does not exist yet.
    public static func directoryNames(for cwd: String) -> [String] {
        // Symlinks get resolved: the name is built from the cwd the process
        // itself sees, and that one is always the real path — a pane started in
        // `/tmp` keeps its sessions in `-private-tmp`.
        let cwd = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path

        // Letters are counted as ASCII rather than by `isLetter`: the other
        // side uses a plain `[^a-zA-Z0-9]` class, and accented letters fall
        // under it too.
        let current = String(
            cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "-" ? $0 : "-" }
        )
        let legacy = cwd.replacingOccurrences(of: "/", with: "-")

        return current == legacy ? [current] : [current, legacy]
    }

    /// The session directory of this path: the one that exists on disk,
    /// otherwise the one that will.
    public static func directory(for cwd: String, root: URL = defaultRoot) -> URL {
        let candidates = directoryNames(for: cwd).map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? candidates[0]
    }

    // MARK: - Listing

    /// A project's sessions, freshest first.
    ///
    /// `limit` is not decoration: a session's title costs a file read, and a
    /// long-lived project has hundreds of them. We cut by date rather than at
    /// random: what did not fit is not what the human was looking for.
    public static func sessions(
        for cwd: String,
        root: URL = defaultRoot,
        limit: Int = 40
    ) -> [Record] {
        sessions(in: [Place(cwd: cwd)], root: root, limit: limit)
    }

    /// A project's sessions together with the ones living in its worktrees.
    ///
    /// For a human this is one project: the worktree was made for a branch, not
    /// for a separate place in the interface. For Claude Code these are
    /// different cwds and different transcript directories, so they have to be
    /// walked one by one.
    public static func sessions(
        forProject project: String,
        root: URL = defaultRoot,
        limit: Int = 40
    ) -> [Record] {
        sessions(in: places(of: project), root: root, limit: limit)
    }

    /// A directory Claude Code keeps sessions in, plus the worktree's name if
    /// that is what it is.
    private struct Place {
        let cwd: String
        var worktree: String?
    }

    private static func places(of project: String) -> [Place] {
        [Place(cwd: project)] + Worktree.names(inside: project).map {
            Place(cwd: Worktree.path(inside: project, name: $0), worktree: $0)
        }
    }

    private static func sessions(in places: [Place], root: URL, limit: Int) -> [Record] {
        var seen = Set<String>()

        return places
            .flatMap { place in transcripts(of: place.cwd, root: root).map { ($0, place.worktree) } }
            .sorted { $0.0.modified > $1.0.modified }
            .filter { seen.insert($0.0.id).inserted }
            .prefix(limit)
            .map { record(at: $0.0, worktree: $0.1) }
    }

    /// The transcript of a session kept in this directory — if there is one
    /// already.
    ///
    /// Existence is the whole answer. A session's id is known before the
    /// session begins — Roost assigns it — and only the file tells a started
    /// session from a merely named one: an empty `--resume` has nothing to
    /// continue, and a taken `--session-id` is what claude refuses.
    public static func transcript(
        of sessionID: String,
        cwd: String,
        root: URL = defaultRoot
    ) -> String? {
        directoryNames(for: cwd)
            .map { root.appendingPathComponent($0).appendingPathComponent("\(sessionID).jsonl").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Where a session's transcript lies — across the whole catalog, not just
    /// under one project.
    ///
    /// A session started on another machine arrives here as a file, and a human
    /// puts it wherever. Answering "no such session" without walking the
    /// catalog would be a lie.
    public static func locate(_ sessionID: String, root: URL = defaultRoot) -> String? {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories
            .map { $0.appendingPathComponent("\(sessionID).jsonl").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// A project walks its own worktrees on equal terms with itself: a session
    /// from a branch is its own, and calling it a stranger would send the human
    /// looking for a file that is right where it belongs.
    public static func resolve(
        _ sessionID: String,
        project: String,
        root: URL = defaultRoot
    ) -> Resolution {
        let own = places(of: project).lazy.compactMap { place -> (File, String?)? in
            transcript(of: sessionID, cwd: place.cwd, root: root)
                .map { (File(url: URL(fileURLWithPath: $0)), place.worktree) }
        }.first

        if let own { return .here(record(at: own.0, worktree: own.1)) }
        if let found = locate(sessionID, root: root) { return .elsewhere(found) }

        return .missing(directory(for: project, root: root).path)
    }

    // MARK: - Reading

    /// A transcript file before anybody read it: the directory hands out the
    /// date, while the title costs opening the file and waits its turn.
    private struct File {
        let url: URL
        let modified: Date

        var id: String { url.deletingPathExtension().lastPathComponent }

        init(url: URL) {
            self.url = url
            self.modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
    }

    private static func transcripts(in directory: URL) -> [File] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.filter { $0.pathExtension == "jsonl" }.map(File.init)
    }

    /// The transcripts of one cwd — under both name-encoding rules.
    private static func transcripts(of cwd: String, root: URL) -> [File] {
        directoryNames(for: cwd)
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .flatMap { transcripts(in: $0) }
    }

    private static func record(at file: File, worktree: String? = nil) -> Record {
        Record(
            id: file.id,
            transcriptPath: file.url.path,
            title: title(of: file.url.path),
            modified: file.modified,
            worktree: worktree
        )
    }

    /// A session's name: what it was called, and failing that, how the human
    /// began.
    ///
    /// The tail is read shorter than usual: `ai-title` is appended as the
    /// conversation goes and sits right at the end, while a listing is dozens
    /// of files in a row.
    static func title(of path: String) -> String? {
        if let named = Transcript.read(at: path, tail: 64 * 1024).title { return named }
        return Transcript.firstPrompt(at: path).map { String($0.prefix(120)) }
    }
}

/// Age in words: `just now`, `20m ago`, `3d ago`.
///
/// Ours rather than `RelativeDateTimeFormatter`: that one translates the string
/// into the system language, while the interface here is English no matter
/// where it runs.
public func relativeAge(_ interval: TimeInterval) -> String {
    let seconds = Int(max(interval, 0))

    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(seconds / 60)m ago"
    case ..<86_400: return "\(seconds / 3600)h ago"
    default: return "\(seconds / 86_400)d ago"
    }
}
