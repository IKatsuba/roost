import Foundation

/// A tab is a pane layout plus a pointer to the active pane.
///
/// A tab has no title of its own: the active pane gives it one. Otherwise we
/// would have to decide what to show after a split, and keep two sources of
/// truth about the very same name.
public struct TabSpec: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public private(set) var layout: PaneNode
    public private(set) var activePaneID: String

    public init(id: String = UUID().uuidString, layout: PaneNode, activePaneID: String) {
        self.id = id
        self.layout = layout
        self.activePaneID = layout.contains(activePaneID)
            ? activePaneID
            : layout.panes[0].id
    }

    public init(id: String = UUID().uuidString, pane: PaneSpec) {
        self.init(id: id, layout: .leaf(pane), activePaneID: pane.id)
    }

    public var panes: [PaneSpec] { layout.panes }
    public var paneCount: Int { panes.count }

    public var activePane: PaneSpec {
        layout.pane(activePaneID) ?? layout.panes[0]
    }

    public var title: String { activePane.title }

    /// Swaps the layout, making sure the active pane is still alive.
    public mutating func setLayout(_ layout: PaneNode, activePaneID: String? = nil) {
        let wanted = activePaneID ?? self.activePaneID
        self.layout = layout
        self.activePaneID = layout.contains(wanted) ? wanted : layout.panes[0].id
    }

    public mutating func focus(_ paneID: String) {
        guard layout.contains(paneID) else { return }
        activePaneID = paneID
    }

    // The initializer restores the active pane, which is what lets the decoder
    // survive a snapshot where that pane is already gone.
    private enum CodingKeys: String, CodingKey { case id, layout, activePaneID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let layout = try container.decode(PaneNode.self, forKey: .layout)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            layout: layout,
            activePaneID: try container.decodeIfPresent(String.self, forKey: .activePaneID) ?? ""
        )
    }
}

/// The whole workspace snapshot as it goes to disk.
public struct WorkspaceSnapshot: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var projects: [Project]

    /// projectID -> that project's tabs, in display order.
    public var tabs: [String: [TabSpec]]

    public var activeProjectID: String?

    /// projectID -> id of the active tab inside the project.
    public var activeTabIDs: [String: String]

    public init(
        version: Int = WorkspaceSnapshot.currentVersion,
        projects: [Project] = [],
        tabs: [String: [TabSpec]] = [:],
        activeProjectID: String? = nil,
        activeTabIDs: [String: String] = [:]
    ) {
        self.version = version
        self.projects = projects
        self.tabs = tabs
        self.activeProjectID = activeProjectID
        self.activeTabIDs = activeTabIDs
    }
}

/// Keeps the workspace snapshot in Application Support.
public struct WorkspaceStore: Sendable {
    public let directory: URL

    public init(directory: URL = WorkspaceStore.defaultDirectory) {
        self.directory = directory
    }

    public static let bundleID = "dev.katsuba.roost"

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return support.appendingPathComponent(bundleID, isDirectory: true)
    }

    public var file: URL { directory.appendingPathComponent("workspace.json") }

    /// A broken file must not stand in the way of launching — we start clean.
    public func load() -> WorkspaceSnapshot {
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        else { return WorkspaceSnapshot() }
        return snapshot
    }

    /// The write is atomic: a crash mid-save would otherwise leave truncated
    /// JSON and lose every project.
    public func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: file, options: .atomic)
    }
}
