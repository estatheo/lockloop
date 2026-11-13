import Foundation

public enum ReapplyOutcome: Equatable, Sendable {
    case nothingToDo
    case busy
    case reinstalled(restartedAgent: Bool)
    case waitingForDownload
    case needsAttention
}

/// Keep applied: a LaunchAgent that runs `lockloop reapply` at login and hourly.
/// It only ever puts the file back. It never edits Index.plist.
public struct Keeper {
    public var env: Environment
    public init(env: Environment) { self.env = env }

    static let logCap = 256 * 1024

    public func agentPlist(programPath: String) -> [String: Any] {
        [
            "Label": Brand.agentLabel,
            "ProgramArguments": [programPath, "reapply", "--quiet"],
            "RunAtLoad": true,
            "StartInterval": 3600,
            "ProcessType": "Background",
            "StandardErrorPath": env.keeperLogURL.path,
        ]
    }

    public func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: env.keeperPlistURL.path)
    }

    /// The program path in the installed agent, if there is one.
    public func installedProgramPath() -> String? {
        guard let data = try? Data(contentsOf: env.keeperPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    public func enable(programPath: String) async throws {
        try await OperationLock.with(env) { try enableLocked(programPath: programPath) }
    }

    func enableLocked(programPath: String) throws {
        guard var state = try StateStore.load(env), state.installed != nil else {
            throw LoopError.keeperFailed("Nothing is applied.")
        }
        do {
            try FileManager.default.createDirectory(at: env.launchAgentsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: env.logsDir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: agentPlist(programPath: programPath), format: .xml, options: 0)
            try data.write(to: env.keeperPlistURL, options: .atomic)
            try env.launchd.bootstrap(plist: env.keeperPlistURL)
        } catch {
            try? FileManager.default.removeItem(at: env.keeperPlistURL)
            if case LoopError.keeperFailed = error { throw error }
            throw LoopError.keeperFailed(error.localizedDescription)
        }
        state.keepApplied = true
        try StateStore.save(state, env)
    }

    public func disable() async throws {
        try await OperationLock.with(env) { try disableLocked() }
    }

    func disableLocked() throws {
        if isEnabled() {
            try? env.launchd.bootout(label: Brand.agentLabel)
            do { try FileManager.default.removeItem(at: env.keeperPlistURL) } catch {
                throw LoopError.keeperFailed(error.localizedDescription)
            }
        }
        if var state = try StateStore.load(env), state.keepApplied {
            state.keepApplied = false
            try StateStore.save(state, env)
        }
    }

    /// Rewrites the agent if the app or CLI has moved since it was turned on.
    public func refreshProgramPath(_ programPath: String) async throws {
        guard isEnabled(), installedProgramPath() != programPath else { return }
        try await enable(programPath: programPath)
    }

    /// What the background agent runs. Never waits for the lock and never edits Index.plist.
    public func reapply() async throws -> ReapplyOutcome {
        let lock: OperationLock
        do { lock = try OperationLock.acquire(env) } catch LoopError.busy { return .busy }
        defer { lock.release() }
        let outcome = try await reapplyLocked()
        log("\(outcome)")
        return outcome
    }

    func reapplyLocked() async throws -> ReapplyOutcome {
        let report = try Status.compute(env)
        guard report.status == .reverted || report.status == .missing, var state = try StateStore.load(env) else {
            return .nothingToDo
        }
        let id = state.assetID.uppercased()
        let live = AssetDiscovery.liveVideoURL(env, assetID: id)
        guard FileManager.default.fileExists(atPath: env.currentURL(for: id).path) else {
            state.needsAttention = "currentMissing"
            try StateStore.save(state, env)
            return .needsAttention
        }
        if report.status == .reverted {
            // macOS may be part-way through writing its download. Try again next hour.
            guard await MediaChecks.hasVideoTrack(live) else { return .waitingForDownload }
            try await Swap.backupOriginalIfNeeded(env, assetID: id, live: live, state: &state)
        }
        let job = try env.makeJobDir()
        defer { try? FileManager.default.removeItem(at: job) }
        let fp = try Swap.installCurrent(env, assetID: id, live: live, state: state, job: job)
        state.installed?.fingerprint = fp
        if !state.everInstalled.contains(fp) { state.everInstalled.append(fp) }
        try StateStore.save(state, env)
        let selected = (try? WallpaperIndex.load(env.indexURL))?.paths(pointingAt: id).isEmpty == false
        if selected { await env.agent.restart() }
        return .reinstalled(restartedAgent: selected)
    }

    func log(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: env.logsDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: env.now())
        let entry = Data("\(stamp) reapply: \(line)\n".utf8)
        var data = (try? Data(contentsOf: env.keeperLogURL)) ?? Data()
        data.append(entry)
        if data.count > Self.logCap {
            data = data.suffix(Self.logCap / 2)
            if let newline = data.firstIndex(of: UInt8(ascii: "\n")) { data = data.suffix(from: data.index(after: newline)) }
        }
        try? data.write(to: env.keeperLogURL, options: .atomic)
    }
}
