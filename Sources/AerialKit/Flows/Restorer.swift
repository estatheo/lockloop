import Foundation

public enum RestoreOutcome: Equatable, Sendable {
    case restored
    case nothingToRestore
}

/// Puts Apple's video and the earlier wallpaper choice back, then deletes Lockloop's copies.
public struct Restorer {
    public var env: Environment
    public init(env: Environment) { self.env = env }

    public func restore() async throws -> RestoreOutcome {
        try await OperationLock.with(env) { try await restoreLocked() }
    }

    /// For when Lockloop's copy of Apple's video is gone: fetch a fresh one from Apple, then restore.
    public func downloadOriginalAndRestore(progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> RestoreOutcome {
        try await OperationLock.with(env) {
            guard let state = try StateStore.load(env) else { return try await restoreLocked() }
            let catalogue = try AerialCatalogue.load(env)
            guard let asset = catalogue.asset(id: state.assetID) else { throw LoopError.originalMissing }
            let backup = env.originalURL(for: state.assetID)
            try await AerialFetch.fetch(asset, env: env, destination: backup, progress: progress)
            var updated = state
            updated.original = .init(fingerprint: try Fingerprint.of(backup), size: Swap.fileSize(backup),
                                     xattrs: ExtendedAttributes.read(backup))
            try StateStore.save(updated, env)
            return try await restoreLocked()
        }
    }

    func restoreLocked() async throws -> RestoreOutcome {
        let fm = FileManager.default
        // 1. Turn off Keep applied first, or the agent would undo the restore.
        try Keeper(env: env).disableLocked()

        guard let state = try StateStore.load(env) else {
            cleanUp(assetID: nil)
            return .nothingToRestore
        }
        let id = state.assetID.uppercased()
        let live = AssetDiscovery.liveVideoURL(env, assetID: id)
        let liveFP = Fingerprint.ofIfPresent(live)
        let liveIsOurs = liveFP.map { Swap.isOurs(live, fingerprint: $0, state: state) } ?? false
        var fileChanged = false

        if state.installed == nil && !liveIsOurs {
            cleanUp(assetID: id)
            return .nothingToRestore
        }

        // 2 to 4. Put Apple's video back if the live file is ours or missing.
        if liveIsOurs || liveFP == nil {
            let backup = env.originalURL(for: id)
            guard let original = state.original, Fingerprint.ofIfPresent(backup) == original.fingerprint else {
                throw LoopError.originalMissing
            }
            let job = try env.makeJobDir()
            defer { try? fm.removeItem(at: job) }
            do {
                try env.faultHook(.restoreFile)
                try Swap.copyThenRename(backup, staging: job.appendingPathComponent("restore.mov"), destination: live,
                                        xattrs: original.xattrs, removing: [Swap.markerName])
            } catch {
                if let loop = error as? LoopError { throw loop }
                throw LoopError.swapFailed(error.localizedDescription)
            }
            fileChanged = true
        }

        // 5. Put the earlier wallpaper choice back.
        var choiceError: Error?
        do {
            try env.faultHook(.restoreIndex)
            var index = try WallpaperIndex.load(env.indexURL)
            let backup = try? WallpaperIndex.load(env.preApplyIndexURL)
            let paths = index.paths(pointingAt: id)
            let restored = index.restoreChoices(from: backup, assetID: id, now: env.now())
            if restored > 0 {
                _ = try? Swap.backupIndex(env, alsoPreApply: false)
                try index.write(to: env.indexURL)
                let choices = Dictionary(index.desktopChoices().map { ($0.path, $0.assetID) }, uniquingKeysWith: { a, _ in a })
                let expected = Dictionary(uniqueKeysWithValues: paths.map { ($0, choices[$0] ?? nil) })
                try await Swap.restartAndCheck(env, written: index, expected: expected, label: state.assetLabel)
            } else if fileChanged {
                await env.agent.restart()
            }
        } catch {
            choiceError = error
            if fileChanged { await env.agent.restart() }
        }

        // 6. Only tidy up once Apple's file is really back.
        if let nowFP = Fingerprint.ofIfPresent(live), Swap.isOurs(live, fingerprint: nowFP, state: state) {
            throw LoopError.swapFailed("The video at \(live.path) is still \(Brand.displayName)'s.")
        }
        cleanUp(assetID: id)
        Swap.trimBackups(env)
        if let choiceError { throw choiceError }
        return .restored
    }

    func cleanUp(assetID: String?) {
        let fm = FileManager.default
        try? fm.removeItem(at: env.currentDir)
        if let assetID { try? fm.removeItem(at: env.originalURL(for: assetID)) }
        if let rest = try? fm.contentsOfDirectory(atPath: env.originalsDir.path), rest.isEmpty {
            try? fm.removeItem(at: env.originalsDir)
        }
        try? fm.removeItem(at: env.preApplyIndexURL)
        try? StateStore.delete(env)
    }
}
