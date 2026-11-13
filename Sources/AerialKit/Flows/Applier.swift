import Foundation

public struct Preflight {
    public let catalogue: AerialCatalogue
    public let index: WallpaperIndex
    public let state: AppState?
    public let target: DownloadedAsset
}

public enum ApplyPhase: Equatable, Sendable {
    case converting(ConversionProgress)
    case installing
}

public struct ApplyOutcome: Equatable, Sendable {
    public let assetID: String
    public let assetName: String
    public let usedFallback: Bool
}

/// Converts a file and puts it in place of one of Apple's aerials.
public struct Applier {
    public var env: Environment
    public var settings: ConversionSettings
    public var forceRepeaterFailure = false

    public init(env: Environment, settings: ConversionSettings = .standard) {
        self.env = env
        self.settings = settings
    }

    static let headroom: Int64 = 500_000_000

    /// Checks everything that can be checked without changing anything.
    public func preflight() throws -> Preflight {
        if let kind = AerialLayout.detect(env).unsupportedKind { throw LoopError.unsupportedLayout(kind) }
        let catalogue = try AerialCatalogue.load(env)
        let index = try WallpaperIndex.load(env.indexURL)
        guard !index.desktopPaths().isEmpty else { throw LoopError.noDesktopEntries }
        let state = try StateStore.load(env)
        switch AssetDiscovery.chooseTarget(env, catalogue: catalogue, state: state, index: index) {
        case .needsDownload: throw LoopError.needsDownload
        case .asset(let target): return Preflight(catalogue: catalogue, index: index, state: state, target: target)
        }
    }

    /// The name of the aerial that would be replaced, for the note under the button.
    public func targetName() -> String? {
        try? preflight().target.asset.displayName
    }

    /// Downloads one of Apple's aerials into the place macOS keeps them.
    public func download(_ asset: AerialAsset, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try await OperationLock.with(env) {
            try await AerialFetch.fetch(asset, env: env, destination: env.videoURL(for: asset.id), progress: progress)
        }
    }

    public func apply(source: URL, fit: FitMode, phase: @escaping (ApplyPhase) -> Void = { _ in }) async throws -> ApplyOutcome {
        try await OperationLock.with(env) {
            let pre = try preflight()
            let media = try await SourceMedia.probe(source)
            var converter = Converter(settings: settings, displayAspect: env.mainDisplayAspect() ?? CanvasGeometry.sixteenNine)
            converter.forceRepeaterFailure = forceRepeaterFailure
            let plan = converter.plan(for: media)
            try checkSpace(plan: plan, pre: pre)
            let job = try env.makeJobDir()
            defer { try? FileManager.default.removeItem(at: job) }
            let result: ConversionResult
            do {
                result = try await converter.run(media, fit: fit, workDir: job.appendingPathComponent("convert")) { phase(.converting($0)) }
            } catch let error as LoopError {
                throw error
            } catch {
                throw LoopError.conversionFailed(filename: media.filename, detail: error.localizedDescription)
            }
            try Task.checkCancellation()
            phase(.installing)
            try await install(prepared: result.output, sourceName: media.filename, fit: fit, pre: pre, job: job)
            return ApplyOutcome(assetID: pre.target.asset.id, assetName: pre.target.asset.displayName, usedFallback: result.usedFallback)
        }
    }

    /// Installs a file that is already converted. Used by tests and by apply.
    public func applyPrepared(_ file: URL, sourceName: String, fit: FitMode) async throws -> ApplyOutcome {
        try await OperationLock.with(env) {
            let pre = try preflight()
            let job = try env.makeJobDir()
            defer { try? FileManager.default.removeItem(at: job) }
            try await install(prepared: file, sourceName: sourceName, fit: fit, pre: pre, job: job)
            return ApplyOutcome(assetID: pre.target.asset.id, assetName: pre.target.asset.displayName, usedFallback: false)
        }
    }

    /// "Use my video again": puts the kept copy back in place and chooses the aerial again.
    public func reapplyCurrent() async throws -> ApplyOutcome {
        try await OperationLock.with(env) {
            if let kind = AerialLayout.detect(env).unsupportedKind { throw LoopError.unsupportedLayout(kind) }
            guard let state = try StateStore.load(env), let installed = state.installed else {
                throw LoopError.swapFailed(Copy.revertedCopyGone)
            }
            let current = env.currentURL(for: state.assetID)
            guard FileManager.default.fileExists(atPath: current.path) else { throw LoopError.swapFailed(Copy.revertedCopyGone) }
            let catalogue = try AerialCatalogue.load(env)
            let index = try WallpaperIndex.load(env.indexURL)
            guard !index.desktopPaths().isEmpty else { throw LoopError.noDesktopEntries }
            let asset = catalogue.asset(id: state.assetID)
                ?? AerialAsset(id: state.assetID, accessibilityLabel: state.assetLabel, shotID: nil, preferredOrder: nil, rawURL: nil)
            let live = AssetDiscovery.liveVideoURL(env, assetID: state.assetID)
            let target = DownloadedAsset(asset: asset, fileURL: live, modified: Date())
            let pre = Preflight(catalogue: catalogue, index: index, state: state, target: target)
            let job = try env.makeJobDir()
            defer { try? FileManager.default.removeItem(at: job) }
            let staged = job.appendingPathComponent("again.mov")
            try FileManager.default.copyItem(at: current, to: staged)
            try await install(prepared: staged, sourceName: installed.sourceName, fit: installed.fit, pre: pre, job: job)
            return ApplyOutcome(assetID: asset.id, assetName: asset.displayName, usedFallback: false)
        }
    }

    func checkSpace(plan: ConversionPlan, pre: Preflight) throws {
        let estimate = plan.estimatedBytes(bitRate: settings.bitRate)
        var needed = 2 * estimate + Self.headroom
        let backup = env.originalURL(for: pre.target.asset.id)
        if !FileManager.default.fileExists(atPath: backup.path) { needed += Swap.fileSize(pre.target.fileURL) }
        if let free = env.freeSpace(env.home), free < needed {
            throw LoopError.notEnoughSpace(needed: needed, free: free)
        }
    }

    func install(prepared: URL, sourceName: String, fit: FitMode, pre: Preflight, job: URL) async throws {
        let fm = FileManager.default
        let asset = pre.target.asset
        let id = asset.id
        let live = pre.target.fileURL
        var state = (pre.state?.assetID.uppercased() == id ? pre.state : nil) ?? AppState(assetID: id, assetLabel: asset.displayName)
        state.assetLabel = asset.displayName
        let firstApply = state.installed == nil
        let previousState = try? Data(contentsOf: env.stateURL)

        func wrapped(_ error: Error) -> Error {
            if let loop = error as? LoopError { return loop }
            return LoopError.swapFailed(error.localizedDescription)
        }

        // 3. Back up Apple's video.
        do {
            try env.faultHook(.backupOriginal)
            try await Swap.backupOriginalIfNeeded(env, assetID: id, live: live, state: &state)
        } catch { throw wrapped(error) }

        // 4. Back up Index.plist.
        do {
            try env.faultHook(.backupIndex)
            _ = try Swap.backupIndex(env, alsoPreApply: firstApply)
        } catch { throw wrapped(error) }

        // 5 to 8, with rollback.
        let current = env.currentURL(for: id)
        let prevCurrent = job.appendingPathComponent("prev-current.mov")
        let prevLive = job.appendingPathComponent("prev-live.mov")
        var written: WallpaperIndex?
        do {
            try fm.createDirectory(at: env.currentDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: current.path) { try fm.copyItem(at: current, to: prevCurrent) }
            if fm.fileExists(atPath: live.path) { try fm.copyItem(at: live, to: prevLive) }

            try env.faultHook(.storeCurrent)
            let newCurrent = current.appendingPathExtension("new")
            if fm.fileExists(atPath: newCurrent.path) { try fm.removeItem(at: newCurrent) }
            try fm.copyItem(at: prepared, to: newCurrent)
            if rename(newCurrent.path, current.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

            try env.faultHook(.install)
            let fp = try Swap.installCurrent(env, assetID: id, live: live, state: state, job: job)

            try env.faultHook(.writeState)
            state.installed = .init(fingerprint: fp, sourceName: sourceName, fit: fit, appliedAt: env.now())
            if !state.everInstalled.contains(fp) { state.everInstalled.append(fp) }
            state.needsAttention = nil
            try StateStore.save(state, env)

            try env.faultHook(.writeIndex)
            var index = try WallpaperIndex.load(env.indexURL)
            try index.selectAerial(assetID: id, now: env.now())
            try index.write(to: env.indexURL)
            written = index
        } catch {
            do {
                try env.faultHook(.rollback)
                if fm.fileExists(atPath: prevLive.path) {
                    if rename(prevLive.path, live.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                }
                if fm.fileExists(atPath: prevCurrent.path) {
                    if rename(prevCurrent.path, current.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                } else if fm.fileExists(atPath: current.path) {
                    try fm.removeItem(at: current)
                }
                if let previousState { try previousState.write(to: env.stateURL, options: .atomic) } else { try StateStore.delete(env) }
            } catch {
                throw LoopError.rollbackFailed(originalPath: env.originalURL(for: id).path)
            }
            if case LoopError.permissionDenied = error { throw error }
            throw LoopError.swapFailed((error as? LoopError)?.message ?? error.localizedDescription)
        }

        // 9. Restart WallpaperAgent and check the choice stuck.
        if let written {
            let expected = Dictionary(uniqueKeysWithValues: written.desktopPaths().map { ($0, Optional(id)) })
            try await Swap.restartAndCheck(env, written: written, expected: expected, label: asset.displayName)
        }
        // 10. Tidy up.
        Swap.trimBackups(env)
    }
}
