import CoreGraphics
import Foundation

/// Every path and side effect the core uses. Nothing in AerialKit reaches for the
/// real home directory or runs a system command except through this struct.
public struct Environment: @unchecked Sendable {
    public var home: URL
    public var systemRoot: URL
    public var supportDir: URL
    public var launchAgentsDir: URL
    public var agent: WallpaperAgentControl
    public var launchd: LaunchdControl
    public var now: () -> Date
    public var mainDisplayAspect: () -> Double?
    /// Free bytes on the volume holding the URL. Nil when unknown.
    public var freeSpace: (URL) -> Int64?
    /// A downloaded aerial must be at least this big to count.
    public var minimumAerialBytes: Int64
    /// True when LOCKLOOP_ROOT is set, or in tests.
    public var isSandboxed: Bool
    /// Called before each apply and restore step. Tests use it to inject failures.
    public var faultHook: (FlowStep) throws -> Void
    /// Downloads Apple's aerials. Replaced by a stub in tests.
    public var downloader: AerialDownloading

    public init(
        home: URL,
        systemRoot: URL,
        supportDir: URL? = nil,
        launchAgentsDir: URL? = nil,
        agent: WallpaperAgentControl,
        launchd: LaunchdControl,
        now: @escaping () -> Date = Date.init,
        mainDisplayAspect: @escaping () -> Double? = { nil },
        freeSpace: @escaping (URL) -> Int64? = Environment.volumeFreeSpace,
        minimumAerialBytes: Int64 = 1_000_000,
        isSandboxed: Bool,
        faultHook: @escaping (FlowStep) throws -> Void = { _ in },
        downloader: AerialDownloading = AssetDownloader()
    ) {
        self.home = home
        self.systemRoot = systemRoot
        self.supportDir = supportDir ?? home.appendingPathComponent("Library/Application Support/\(Brand.supportDirName)", isDirectory: true)
        self.launchAgentsDir = launchAgentsDir ?? home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.agent = agent
        self.launchd = launchd
        self.now = now
        self.mainDisplayAspect = mainDisplayAspect
        self.freeSpace = freeSpace
        self.minimumAerialBytes = minimumAerialBytes
        self.isSandboxed = isSandboxed
        self.faultHook = faultHook
        self.downloader = downloader
    }

    /// The real environment, or a sandbox when LOCKLOOP_ROOT is set.
    public static func live(processEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> Environment {
        if let root = processEnvironment[Brand.rootOverrideVariable], !root.isEmpty {
            let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            return Environment(
                home: rootURL.appendingPathComponent("home", isDirectory: true),
                systemRoot: rootURL.appendingPathComponent("system", isDirectory: true),
                agent: NoopWallpaperAgent(),
                launchd: NoopLaunchd(),
                mainDisplayAspect: Environment.liveDisplayAspect,
                isSandboxed: true
            )
        }
        return Environment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            systemRoot: URL(fileURLWithPath: "/", isDirectory: true),
            agent: KillallWallpaperAgent(),
            launchd: LaunchctlControl(),
            mainDisplayAspect: Environment.liveDisplayAspect,
            isSandboxed: false
        )
    }

    /// The directory LOCKLOOP_ROOT points at, if any.
    public static func sandboxRoot(processEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let root = processEnvironment[Brand.rootOverrideVariable], !root.isEmpty else { return nil }
        return root
    }

    /// The main display's width over height, or nil with no display (for example over SSH).
    public static func liveDisplayAspect() -> Double? {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return Double(bounds.width / bounds.height)
    }

    public static func volumeFreeSpace(_ url: URL) -> Int64? {
        var probe = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Apple's paths

    public var wallpaperDir: URL { home.appendingPathComponent("Library/Application Support/com.apple.wallpaper", isDirectory: true) }
    public var aerialsDir: URL { wallpaperDir.appendingPathComponent("aerials", isDirectory: true) }
    public var videosDir: URL { aerialsDir.appendingPathComponent("videos", isDirectory: true) }
    public var thumbnailsDir: URL { aerialsDir.appendingPathComponent("thumbnails", isDirectory: true) }
    public var entriesURL: URL { aerialsDir.appendingPathComponent("manifest/entries.json") }
    public var indexURL: URL { wallpaperDir.appendingPathComponent("Store/Index.plist") }
    public var legacyCustomerDir: URL { systemRoot.appendingPathComponent("Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true) }

    // MARK: Lockloop's own paths

    public var stateURL: URL { supportDir.appendingPathComponent("state.json") }
    public var lockURL: URL { supportDir.appendingPathComponent("lock") }
    public var originalsDir: URL { supportDir.appendingPathComponent("originals", isDirectory: true) }
    public var currentDir: URL { supportDir.appendingPathComponent("current", isDirectory: true) }
    public var backupsDir: URL { supportDir.appendingPathComponent("backups", isDirectory: true) }
    public var preApplyIndexURL: URL { backupsDir.appendingPathComponent("Index.pre-apply.plist") }
    public var workDir: URL { supportDir.appendingPathComponent("work", isDirectory: true) }
    public var logsDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }
    public var keeperLogURL: URL { logsDir.appendingPathComponent("keeper.log") }
    public var keeperPlistURL: URL { launchAgentsDir.appendingPathComponent("\(Brand.agentLabel).plist") }

    public func videoURL(for assetID: String) -> URL { videosDir.appendingPathComponent("\(assetID).mov") }
    public func originalURL(for assetID: String) -> URL { originalsDir.appendingPathComponent("\(assetID).mov") }
    public func currentURL(for assetID: String) -> URL { currentDir.appendingPathComponent("\(assetID).mov") }

    /// A fresh scratch directory for one job.
    public func makeJobDir() throws -> URL {
        let dir = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Steps the apply and restore flows announce through `Environment.faultHook`.
public enum FlowStep: String, CaseIterable, Sendable {
    case backupOriginal, backupIndex, storeCurrent, install, writeState, writeIndex, rollback
    case restoreFile, restoreIndex
}
