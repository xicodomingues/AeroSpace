import AppKit
import Common

/// The layout on disk, so that a restart of AeroSpace puts every window back.
///
/// AeroSpace keeps no state of its own across a restart: every window is detected again and placed by
/// on-window-detected or on the focused workspace. The world is written here after each refresh that changed
/// it, and read once at startup into the closed windows cache, which then restores each window as it is
/// detected (the lock screen mechanism). Window ids are CGWindowIDs: they survive a restart of AeroSpace but
/// not a reboot, so a file from another boot is ignored.
@MainActor enum PersistedLayout {
    private static var lastWritten: Data? = nil
    /// Set once startup is over: before that the world is still being put together.
    static var isSavingEnabled = false
    /// The workspace that had focus in the file read at startup.
    private(set) static var focusedWorkspaceAtLoad: String? = nil
    /// A window of the file read at startup was found and put back. A file from this boot whose windows are
    /// all gone (logout and login, everything closed) restores nothing, and is no restored layout.
    private(set) static var didRestore = false
    private static var isLoaded = false

    private static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/bobko.aerospace")
    }
    private static var file: URL { dir.appending(path: "layout.json") }
    /// Exists while the running AeroSpace started from a saved layout and put at least one of its windows
    /// back. For after-startup-command scripts that seed a default layout and must leave a restored one alone.
    private static var restoredMarker: URL { dir.appending(path: "layout-restored") }

    static func saveIfChanged() {
        if !isSavingEnabled { return }
        // Asleep or locked, accessibility is blank and the tree may be missing windows that still exist.
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId { return }
        let workspaces = Workspace.all.map { FrozenWorkspace($0) }
        // Nothing worth a restore, and an empty world must not replace a good one (all windows gone at once
        // is how a failed read looks).
        if !Workspace.all.contains(where: { !collectAllWindowIdsRecursive($0).isEmpty }) { return }
        let dto = Dto(
            bootTime: bootTime(),
            focusedWorkspace: focus.workspace.name,
            workspaces: workspaces.map(WorkspaceDto.init),
            monitors: monitors.map { MonitorDto(FrozenMonitor($0)) },
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(dto), data != lastWritten else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            lastWritten = data
        } catch {
            aeroDebugLog("layout not saved: \(error)")
        }
    }

    /// The saved world, when the file is from this boot.
    static func load() -> FrozenWorld? {
        try? FileManager.default.removeItem(at: restoredMarker)
        guard let data = try? Data(contentsOf: file),
              let dto = try? JSONDecoder().decode(Dto.self, from: data),
              dto.bootTime == bootTime()
        else { return nil }
        let workspaces = dto.workspaces.map(\.frozen)
        let ids = workspaces.flatMap(\.allWindowIds).toSet()
        if ids.isEmpty { return nil }
        focusedWorkspaceAtLoad = dto.focusedWorkspace
        isLoaded = true
        aeroDebugLog("layout loaded: \(ids.count) windows on \(workspaces.count) workspaces")
        return FrozenWorld(workspaces: workspaces, monitors: dto.monitors.map(\.frozen), windowIds: ids)
    }

    /// Called for each window the closed windows cache puts back.
    static func windowRestored() {
        if !isLoaded || didRestore || isSavingEnabled { return }
        didRestore = true
        FileManager.default.createFile(atPath: restoredMarker.path, contents: nil)
        aeroDebugLog("layout restored from the saved file")
    }

    private static func bootTime() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        return sysctl(&mib, 2, &tv, &size, nil, 0) == 0 ? tv.tv_sec : 0
    }

    private struct Dto: Codable {
        let bootTime: Int
        let focusedWorkspace: String
        let workspaces: [WorkspaceDto]
        let monitors: [MonitorDto]
    }
}

private struct MonitorDto: Codable {
    let x: CGFloat
    let y: CGFloat
    let visibleWorkspace: String

    init(_ monitor: FrozenMonitor) {
        x = monitor.topLeftCorner.x
        y = monitor.topLeftCorner.y
        visibleWorkspace = monitor.visibleWorkspace
    }

    var frozen: FrozenMonitor { FrozenMonitor(topLeftCorner: CGPoint(x: x, y: y), visibleWorkspace: visibleWorkspace) }
}

private struct WindowDto: Codable {
    let id: UInt32
    let weight: CGFloat

    init(_ window: FrozenWindow) {
        id = window.id
        weight = window.weight
    }

    var frozen: FrozenWindow { FrozenWindow(id: id, weight: weight) }
}

private struct ContainerDto: Codable {
    let children: [NodeDto]
    let layout: String
    let horizontal: Bool
    let weight: CGFloat

    init(_ container: FrozenContainer) {
        children = container.children.map(NodeDto.init)
        layout = container.layout.rawValue
        horizontal = container.orientation == .h
        weight = container.weight
    }

    var frozen: FrozenContainer {
        FrozenContainer(
            children: children.compactMap(\.frozen),
            layout: Layout(rawValue: layout) ?? .tiles,
            orientation: horizontal ? .h : .v,
            weight: weight,
        )
    }
}

/// A window or a container, never both.
private struct NodeDto: Codable {
    let window: WindowDto?
    let container: ContainerDto?

    init(_ node: FrozenTreeNode) {
        switch node {
            case .window(let w): (window, container) = (WindowDto(w), nil)
            case .container(let c): (window, container) = (nil, ContainerDto(c))
        }
    }

    var frozen: FrozenTreeNode? {
        if let window { return .window(window.frozen) }
        if let container { return .container(container.frozen) }
        return nil
    }
}

private struct WorkspaceDto: Codable {
    let name: String
    let monitor: MonitorDto
    let root: ContainerDto
    let floating: [WindowDto]
    let unconventional: [WindowDto]

    init(_ workspace: FrozenWorkspace) {
        name = workspace.name
        monitor = MonitorDto(workspace.monitor)
        root = ContainerDto(workspace.rootTilingNode)
        floating = workspace.floatingWindows.map(WindowDto.init)
        unconventional = workspace.macosUnconventionalWindows.map(WindowDto.init)
    }

    var frozen: FrozenWorkspace {
        FrozenWorkspace(
            name: name,
            monitor: monitor.frozen,
            rootTilingNode: root.frozen,
            floatingWindows: floating.map(\.frozen),
            macosUnconventionalWindows: unconventional.map(\.frozen),
        )
    }
}

extension FrozenMonitor {
    init(topLeftCorner: CGPoint, visibleWorkspace: String) {
        self.topLeftCorner = topLeftCorner
        self.visibleWorkspace = visibleWorkspace
    }
}

extension FrozenWindow {
    init(id: UInt32, weight: CGFloat) {
        self.id = id
        self.weight = weight
    }
}

extension FrozenContainer {
    init(children: [FrozenTreeNode], layout: Layout, orientation: Orientation, weight: CGFloat) {
        self.children = children
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
    }

    var allWindowIds: [UInt32] {
        children.flatMap {
            switch $0 {
                case .window(let w): [w.id]
                case .container(let c): c.allWindowIds
            }
        }
    }
}

extension FrozenWorkspace {
    init(name: String, monitor: FrozenMonitor, rootTilingNode: FrozenContainer, floatingWindows: [FrozenWindow], macosUnconventionalWindows: [FrozenWindow]) {
        self.name = name
        self.monitor = monitor
        self.rootTilingNode = rootTilingNode
        self.floatingWindows = floatingWindows
        self.macosUnconventionalWindows = macosUnconventionalWindows
    }

    var allWindowIds: [UInt32] {
        rootTilingNode.allWindowIds + floatingWindows.map(\.id) + macosUnconventionalWindows.map(\.id)
    }
}
