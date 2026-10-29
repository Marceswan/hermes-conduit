import Foundation

// The open chat's artifacts as a folder tree (D33): each file under the folders of its host path,
// links in a group of their own. A plain value, so the panel's layout is tested without a view.
// No upstream counterpart.

struct MacArtifactTree: Equatable {
    struct Folder: Equatable, Identifiable {
        /// The folder's host path: its identity, and the key of its collapsed state.
        let path: String
        /// The row's name: one folder, or a chain of folders that hold only the next one, joined
        /// by "/".
        let name: String
        let folders: [Folder]
        let files: [ArtifactItem]

        var id: String { path }
    }

    /// One line of the panel, in drawing order.
    struct Row: Equatable, Identifiable {
        enum Kind: Equatable {
            case folder(path: String, isExpanded: Bool)
            case file(ArtifactItem)
            case links(isExpanded: Bool)
            case link(ArtifactItem)
        }

        let kind: Kind
        let name: String
        /// Levels of indent under the root.
        let depth: Int

        var id: String {
            switch kind {
            case .folder(let path, _): return "folder\u{0}\(path)"
            case .file(let item), .link(let item): return "item\u{0}\(item.id)"
            case .links: return MacArtifactTree.linksKey
            }
        }
    }

    /// The collapsed-state key of the Links group: not a path a host can send.
    static let linksKey = "links\u{0}"

    /// The deepest folder all files share; nil when there is no file.
    let root: Folder?
    /// Links (and anything else without a host path), newest first as the host lists them.
    let links: [ArtifactItem]

    init(items: [ArtifactItem]) {
        var files: [(components: [String], item: ArtifactItem)] = []
        var links: [ArtifactItem] = []
        var absolute = true
        for item in items {
            guard let path = item.path, case let components = Self.components(path), !components.isEmpty else {
                links.append(item)
                continue
            }
            if !path.hasPrefix("/") { absolute = false }
            files.append((components, item))
        }
        self.links = links
        guard !files.isEmpty else {
            root = nil
            return
        }
        // The shared folders: every component but each file's own name.
        var shared = Array(files[0].components.dropLast())
        for file in files.dropFirst() {
            let folders = file.components.dropLast()
            var count = 0
            while count < shared.count, count < folders.count, shared[count] == folders[count] { count += 1 }
            shared.removeLast(shared.count - count)
        }
        // Mixed absolute and relative paths share no folder.
        if !absolute, files.contains(where: { $0.item.path?.hasPrefix("/") == true }) { shared = [] }
        let prefix = absolute ? "/" : ""
        let rootPath = prefix + shared.joined(separator: "/")
        let rootName = shared.last ?? (absolute ? "/" : ".")
        root = Self.folder(path: rootPath, name: rootName, depth: shared.count,
                           files: files, prefix: prefix, mergesChain: false)
    }

    /// Every artifact in the tree.
    var count: Int { (root.map(Self.fileCount) ?? 0) + links.count }

    /// The lines to draw. A collapsed folder (or Links group) hides what is under it.
    func rows(collapsed: Set<String>) -> [Row] {
        var rows: [Row] = []
        if let root { Self.append(root, depth: 0, collapsed: collapsed, to: &rows) }
        if !links.isEmpty {
            let isExpanded = !collapsed.contains(Self.linksKey)
            rows.append(Row(kind: .links(isExpanded: isExpanded), name: AppLocalization.string("Links"), depth: 0))
            if isExpanded {
                rows += links.map { Row(kind: .link($0), name: $0.name, depth: 1) }
            }
        }
        return rows
    }

    // MARK: - Building

    /// A path's folder and file names. Empty and "." parts carry no folder.
    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
    }

    /// The folder `depth` components deep that holds `files`. Below the root, a folder that holds
    /// only one folder and no file is drawn as one row with it.
    private static func folder(path: String, name: String, depth: Int,
                               files: [(components: [String], item: ArtifactItem)],
                               prefix: String, mergesChain: Bool) -> Folder {
        var own: [ArtifactItem] = []
        var order: [String] = []
        var groups: [String: [(components: [String], item: ArtifactItem)]] = [:]
        for file in files {
            if file.components.count == depth + 1 {
                own.append(file.item)
            } else {
                let next = file.components[depth]
                if groups[next] == nil { order.append(next) }
                groups[next, default: []].append(file)
            }
        }
        if mergesChain, own.isEmpty, order.count == 1, let only = order.first, let inner = groups[only] {
            return folder(path: path + "/" + only, name: name + "/" + only, depth: depth + 1,
                          files: inner, prefix: prefix, mergesChain: true)
        }
        let folders = order.sorted(by: Self.namesAscending).map { next -> Folder in
            let child = path == prefix ? prefix + next : path + "/" + next
            return Self.folder(path: child, name: next, depth: depth + 1, files: groups[next] ?? [],
                               prefix: prefix, mergesChain: true)
        }
        return Folder(path: path, name: name, folders: folders,
                      files: own.sorted { namesAscending($0.name, $1.name) })
    }

    private static func namesAscending(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    private static func fileCount(_ folder: Folder) -> Int {
        folder.files.count + folder.folders.reduce(0) { $0 + fileCount($1) }
    }

    private static func append(_ folder: Folder, depth: Int, collapsed: Set<String>, to rows: inout [Row]) {
        let isExpanded = !collapsed.contains(folder.path)
        rows.append(Row(kind: .folder(path: folder.path, isExpanded: isExpanded), name: folder.name, depth: depth))
        guard isExpanded else { return }
        for child in folder.folders {
            append(child, depth: depth + 1, collapsed: collapsed, to: &rows)
        }
        rows += folder.files.map { Row(kind: .file($0), name: $0.name, depth: depth + 1) }
    }
}
