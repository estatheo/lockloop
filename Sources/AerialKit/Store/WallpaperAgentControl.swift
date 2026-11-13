import Foundation

/// Restarts the process that draws the wallpaper so it reads Index.plist again.
public protocol WallpaperAgentControl: Sendable {
    func restart() async
}

/// Does nothing. Used in tests and under LOCKLOOP_ROOT.
public struct NoopWallpaperAgent: WallpaperAgentControl {
    public init() {}
    public func restart() async {}
}

/// `killall WallpaperAgent`, then waits up to 10 seconds for launchd to bring it back.
public struct KillallWallpaperAgent: WallpaperAgentControl {
    public init() {}

    public func restart() async {
        _ = try? Shell.run("/usr/bin/killall", ["WallpaperAgent"])
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if (try? Shell.run("/usr/bin/pgrep", ["-x", "WallpaperAgent"]))?.status == 0 { break }
        }
        // Give the agent a moment to read and possibly rewrite Index.plist before it is checked.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }
}

/// Loads and unloads the Keep applied agent.
public protocol LaunchdControl: Sendable {
    func bootstrap(plist: URL) throws
    func bootout(label: String) throws
}

public struct NoopLaunchd: LaunchdControl {
    public init() {}
    public func bootstrap(plist: URL) throws {}
    public func bootout(label: String) throws {}
}

public struct LaunchctlControl: LaunchdControl {
    public init() {}
    var domain: String { "gui/\(getuid())" }

    public func bootstrap(plist: URL) throws {
        // Unload any older copy first so the new arguments take effect.
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(Brand.agentLabel)"])
        let result = try Shell.run("/bin/launchctl", ["bootstrap", domain, plist.path])
        if result.status != 0 { throw LoopError.keeperFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public func bootout(label: String) throws {
        // Exit code 3 / 113 means it was not loaded, which is the state we want.
        _ = try Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
    }
}

enum Shell {
    struct Result { let status: Int32; let output: String }

    static func run(_ tool: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
