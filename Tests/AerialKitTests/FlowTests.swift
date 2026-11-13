import Foundation
import Testing
@testable import AerialKit

struct InjectedFault: Error {}

/// Serves a local file as if it came from Apple.
struct FileCopyDownloader: AerialDownloading {
    let source: URL
    func contentLength(of url: URL) async -> Int64? { Swap.fileSize(source) }
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> DownloadResult {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        progress(Swap.fileSize(source), Swap.fileSize(source))
        return DownloadResult(file: destination, etag: "\"FRESH\"", expectedLength: Swap.fileSize(source))
    }
}

@Suite("Apply, restore and status")
struct FlowTests {
    func applied(_ root: FakeRoot, colour: MediaFactory.Colour = .init(r: 20, g: 200, b: 60)) async throws -> URL {
        var file = root.temp.file("mine-\(colour.r)-\(colour.g).mov")
        if !FileManager.default.fileExists(atPath: file.path) { file = try await root.prepared(file.lastPathComponent, colour: colour) }
        _ = try await Applier(env: root.env).applyPrepared(file, sourceName: file.lastPathComponent, fit: .fit)
        return file
    }

    @Test("Apply from clean puts everything where it belongs")
    func applyFromClean() async throws {
        let root = FakeRoot()
        let live = try await root.addAerial()
        let appleHash = try root.liveHash()
        let appleXattrs = ExtendedAttributes.read(live)
        let mine = try await applied(root)

        #expect(try root.liveHash() == (try Fingerprint.fullHash(mine)))
        #expect(try Fingerprint.fullHash(root.env.originalURL(for: IDs.goldenGate)) == appleHash)
        #expect(try Fingerprint.fullHash(root.env.currentURL(for: IDs.goldenGate)) == (try Fingerprint.fullHash(mine)))
        #expect(FileManager.default.fileExists(atPath: root.env.preApplyIndexURL.path))
        let state = try #require(try StateStore.load(root.env))
        #expect(state.assetID == IDs.goldenGate)
        #expect(state.installed?.sourceName == mine.lastPathComponent)
        #expect(state.everInstalled.count == 1)
        #expect(state.original?.xattrs == appleXattrs)
        #expect(root.agent.restarts == 1)
        // Mode 0600 and the xattrs of the file it replaced.
        #expect(try FileManager.default.attributesOfItem(atPath: live.path)[.posixPermissions] as? Int == 0o600)
        #expect(ExtendedAttributes.read(live) == appleXattrs)
        #expect(try Status.compute(root.env).status == .applied)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.env.workDir.path).isEmpty)
    }

    @Test("Applying twice keeps Apple's backup; a second file keeps the pre-apply Index")
    func applyTwice() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        let appleHash = try root.liveHash()
        _ = try await applied(root)
        let preApply = try Data(contentsOf: root.env.preApplyIndexURL)
        _ = try await applied(root)
        #expect(try Fingerprint.fullHash(root.env.originalURL(for: IDs.goldenGate)) == appleHash)
        _ = try await applied(root, colour: .init(r: 90, g: 10, b: 200))
        #expect(try Fingerprint.fullHash(root.env.originalURL(for: IDs.goldenGate)) == appleHash)
        #expect(try Data(contentsOf: root.env.preApplyIndexURL) == preApply)
        #expect(try StateStore.load(root.env)?.everInstalled.count == 2)
    }

    @Test("When Apple ships a new video between applies, the backup is refreshed")
    func newAppleVideo() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        _ = try await applied(root)
        try await root.addAerial(colour: .init(r: 1, g: 2, b: 250), frames: 14)
        let newApple = try root.liveHash()
        _ = try await applied(root)
        #expect(try Fingerprint.fullHash(root.env.originalURL(for: IDs.goldenGate)) == newApple)
    }

    @Test("A file of ours is never saved as the original, even with state.json gone")
    func neverBackUpOurs() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        let appleHash = try root.liveHash()
        _ = try await applied(root)
        try FileManager.default.removeItem(at: root.env.stateURL)
        _ = try await applied(root, colour: .init(r: 90, g: 10, b: 200))
        #expect(try Fingerprint.fullHash(root.env.originalURL(for: IDs.goldenGate)) == appleHash)
    }

    @Test("A failure at each step leaves Apple's video and Index.plist as they were", arguments: [
        FlowStep.backupOriginal, .backupIndex, .storeCurrent, .install, .writeState, .writeIndex,
    ])
    func failureAtStep(step: FlowStep) async throws {
        let root = FakeRoot()
        try await root.addAerial()
        let videoBefore = try root.liveHash()
        let indexBefore = try root.indexData()
        root.env.faultHook = { if $0 == step { throw InjectedFault() } }
        await #expect(throws: LoopError.self) { _ = try await applied(root) }
        #expect(try root.liveHash() == videoBefore)
        #expect(try root.indexData() == indexBefore)
        #expect(try Status.compute(root.env).status == .notApplied)
        #expect(root.agent.restarts == 0)
    }

    @Test("A failure during rollback names where Apple's video is kept")
    func rollbackFails() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        root.env.faultHook = { if $0 == .writeIndex || $0 == .rollback { throw InjectedFault() } }
        let path = root.env.originalURL(for: IDs.goldenGate).path
        await #expect(throws: LoopError.rollbackFailed(originalPath: path)) { _ = try await applied(root) }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Restore after apply puts everything back and tidies up")
    func restoreAfterApply() async throws {
        let root = FakeRoot(index: IndexFixture.observed(desktop: IndexFixture.entry(provider: "com.apple.wallpaper.choice.image", configuration: Data([4, 2]))))
        let live = try await root.addAerial()
        let appleHash = try root.liveHash()
        let appleXattrs = ExtendedAttributes.read(live)
        let indexBefore = try root.index()
        _ = try await applied(root)
        #expect(try await Restorer(env: root.env).restore() == .restored)

        #expect(try root.liveHash() == appleHash)
        #expect(ExtendedAttributes.read(live) == appleXattrs)
        #expect(ExtendedAttributes.read(live, names: [Swap.markerName]).isEmpty)
        let after = try root.index()
        for path in indexBefore.desktopPaths() {
            var a = after.value(at: path) as! [String: Any]
            var b = indexBefore.value(at: path) as! [String: Any]
            a["LastUse"] = nil; b["LastUse"] = nil
            #expect(NSDictionary(dictionary: a) == NSDictionary(dictionary: b))
        }
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.env.currentDir.path))
        #expect(!fm.fileExists(atPath: root.env.originalURL(for: IDs.goldenGate).path))
        #expect(!fm.fileExists(atPath: root.env.stateURL.path))
        #expect(try Status.compute(root.env).status == .notApplied)

        // Twice is safe and changes nothing.
        let indexData = try root.indexData()
        #expect(try await Restorer(env: root.env).restore() == .nothingToRestore)
        #expect(try root.indexData() == indexData)
        #expect(try root.liveHash() == appleHash)
    }

    @Test("Restore with nothing applied changes nothing")
    func restoreNothing() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        let hash = try root.liveHash()
        let index = try root.indexData()
        #expect(try await Restorer(env: root.env).restore() == .nothingToRestore)
        #expect(try root.liveHash() == hash)
        #expect(try root.indexData() == index)
        #expect(root.agent.restarts == 0)
    }

    @Test("Restore when macOS already put its video back still restores the choice")
    func restoreAfterRevert() async throws {
        let root = FakeRoot(index: IndexFixture.observed(desktop: IndexFixture.aerial(IDs.other)))
        try await root.addAerial()
        _ = try await applied(root)
        try await root.addAerial(colour: .init(r: 5, g: 5, b: 5), frames: 11)  // macOS re-downloads
        let apple = try root.liveHash()
        #expect(try Status.compute(root.env).status == .reverted)
        #expect(try await Restorer(env: root.env).restore() == .restored)
        #expect(try root.liveHash() == apple)
        #expect(try root.index().desktopChoices().allSatisfy { $0.assetID == IDs.other })
    }

    @Test("Restore with the backup gone gives originalMissing; with a download it completes")
    func originalMissing() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        _ = try await applied(root)
        try FileManager.default.removeItem(at: root.env.originalURL(for: IDs.goldenGate))
        await #expect(throws: LoopError.originalMissing) { _ = try await Restorer(env: root.env).restore() }

        let fresh = try await root.prepared("fresh-apple.mov", colour: .init(r: 200, g: 120, b: 40), frames: 10)
        var env = root.env
        env.downloader = FileCopyDownloader(source: fresh)
        #expect(try await Restorer(env: env).downloadOriginalAndRestore { _, _ in } == .restored)
        #expect(try root.liveHash() == (try Fingerprint.fullHash(fresh)))
        #expect(try Status.compute(root.env).status == .notApplied)
    }

    @Test("Restore turns Keep applied off first")
    func restoreTurnsKeepOff() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        _ = try await applied(root)
        try await Keeper(env: root.env).enable(programPath: "/Applications/X.app/Contents/Helpers/x")
        #expect(FileManager.default.fileExists(atPath: root.env.keeperPlistURL.path))
        _ = try await Restorer(env: root.env).restore()
        #expect(!FileManager.default.fileExists(atPath: root.env.keeperPlistURL.path))
        #expect(root.launchd.bootouts == [Brand.agentLabel])
    }

    @Test("Status: every row of the table")
    func statuses() async throws {
        let legacy = FakeRoot(entries: false)
        try FileManager.default.createDirectory(at: legacy.env.legacyCustomerDir, withIntermediateDirectories: true)
        #expect(try Status.compute(legacy.env).status == .unsupportedLegacy)
        #expect(try Status.compute(FakeRoot(entries: false).env).status == .unsupportedNone)

        let root = FakeRoot(index: IndexFixture.observed(desktop: IndexFixture.aerial(IDs.other)))
        try await root.addAerial()
        #expect(try Status.compute(root.env).status == .notApplied)
        _ = try await applied(root)
        #expect(try Status.compute(root.env).status == .applied)

        var index = try root.index()
        try index.selectAerial(assetID: IDs.other, now: Date())
        try index.write(to: root.env.indexURL)
        #expect(try Status.compute(root.env).status == .appliedNotSelected)

        try await root.addAerial(colour: .init(r: 9, g: 9, b: 9), frames: 13)
        #expect(try Status.compute(root.env).status == .reverted)
        try FileManager.default.removeItem(at: root.env.videoURL(for: IDs.goldenGate))
        #expect(try Status.compute(root.env).status == .missing)
    }

    @Test("Use my video again: after a revert and after another wallpaper was chosen")
    func useAgain() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        let mine = try await applied(root)
        let ours = try Fingerprint.fullHash(mine)

        try await root.addAerial(colour: .init(r: 3, g: 3, b: 3), frames: 16)
        let newApple = try root.liveHash()
        _ = try await Applier(env: root.env).reapplyCurrent()
        #expect(try root.liveHash() == ours)
        #expect(try Fingerprint.fullHash(root.env.originalURL(for: IDs.goldenGate)) == newApple)
        #expect(try Status.compute(root.env).status == .applied)

        var index = try root.index()
        try index.selectAerial(assetID: IDs.other, now: Date())
        try index.write(to: root.env.indexURL)
        #expect(try Status.compute(root.env).status == .appliedNotSelected)
        _ = try await Applier(env: root.env).reapplyCurrent()
        #expect(try Status.compute(root.env).status == .applied)
        #expect(try StateStore.load(root.env)?.installed?.sourceName == mine.lastPathComponent)
    }

    @Test("A second flow while one holds the lock gets busy")
    func lock() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        let held = try OperationLock.acquire(root.env)
        await #expect(throws: LoopError.busy) { _ = try await applied(root) }
        await #expect(throws: LoopError.busy) { _ = try await Restorer(env: root.env).restore() }
        #expect(try await Keeper(env: root.env).reapply() == .busy)
        held.release()
        _ = try await applied(root)
    }

    @Test("A state.json with an unknown schema is refused and left alone")
    func unknownSchema() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        try FileManager.default.createDirectory(at: root.env.supportDir, withIntermediateDirectories: true)
        let data = Data(#"{"schema": 99, "assetID": "x"}"#.utf8)
        try data.write(to: root.env.stateURL)
        await #expect(throws: LoopError.self) { _ = try await applied(root) }
        #expect(try Data(contentsOf: root.env.stateURL) == data)
    }
}

@Suite("Keep applied")
struct KeeperTests {
    func appliedRoot(index: [String: Any] = IndexFixture.observed()) async throws -> FakeRoot {
        let root = FakeRoot(index: index)
        try await root.addAerial()
        let file = try await root.prepared()
        _ = try await Applier(env: root.env).applyPrepared(file, sourceName: "mine.mov", fit: .fit)
        root.agent.restarts = 0
        return root
    }

    @Test("Turning on writes the agent and loads it once; twice is the same; off removes it")
    func onOff() async throws {
        let root = try await appliedRoot()
        let keeper = Keeper(env: root.env)
        try await keeper.enable(programPath: "/A/lockloop")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.env.keeperPlistURL), format: nil) as! [String: Any]
        #expect(plist["Label"] as? String == Brand.agentLabel)
        #expect(plist["ProgramArguments"] as? [String] == ["/A/lockloop", "reapply", "--quiet"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["StartInterval"] as? Int == 3600)
        #expect(root.launchd.bootstraps.count == 1)
        #expect(try StateStore.load(root.env)?.keepApplied == true)
        try await keeper.enable(programPath: "/A/lockloop")
        #expect(keeper.installedProgramPath() == "/A/lockloop")
        try await keeper.disable()
        #expect(!keeper.isEnabled())
        #expect(try StateStore.load(root.env)?.keepApplied == false)
        try await keeper.disable()
    }

    @Test("A moved app rewrites the program path")
    func moved() async throws {
        let root = try await appliedRoot()
        let keeper = Keeper(env: root.env)
        try await keeper.enable(programPath: "/Old/lockloop")
        try await keeper.refreshProgramPath("/New/lockloop")
        #expect(keeper.installedProgramPath() == "/New/lockloop")
    }

    @Test("Reapply when applied does nothing")
    func reapplyApplied() async throws {
        let root = try await appliedRoot()
        #expect(try await Keeper(env: root.env).reapply() == .nothingToDo)
        #expect(root.agent.restarts == 0)
    }

    @Test("Reapply when reverted puts ours back, refreshes the backup, restarts the agent, and never edits Index.plist")
    func reapplyReverted() async throws {
        let root = try await appliedRoot()
        let ours = try Fingerprint.fullHash(root.env.currentURL(for: IDs.goldenGate))
        try await root.addAerial(colour: .init(r: 7, g: 7, b: 250), frames: 15)
        let newApple = try root.liveHash()
        let index = try root.indexData()
        #expect(try await Keeper(env: root.env).reapply() == .reinstalled(restartedAgent: true))
        #expect(try root.liveHash() == ours)
        #expect(try Fingerprint.fullHash(root.env.originalURL(for: IDs.goldenGate)) == newApple)
        #expect(try root.indexData() == index)
        #expect(root.agent.restarts == 1)
        #expect(try Status.compute(root.env).status == .applied)
    }

    @Test("Reapply with another wallpaper chosen puts the file back but leaves the agent alone")
    func reapplyOtherWallpaper() async throws {
        let root = try await appliedRoot()
        var index = try root.index()
        try index.selectAerial(assetID: IDs.other, now: Date())
        try index.write(to: root.env.indexURL)
        try await root.addAerial(colour: .init(r: 7, g: 7, b: 250), frames: 15)
        let before = try root.indexData()
        #expect(try await Keeper(env: root.env).reapply() == .reinstalled(restartedAgent: false))
        #expect(root.agent.restarts == 0)
        #expect(try root.indexData() == before)
    }

    @Test("Reapply with an unreadable live file waits")
    func reapplyHalfDownloaded() async throws {
        let root = try await appliedRoot()
        // Rewritten in place, so the xattrs (including Lockloop's marker) survive.
        let handle = try FileHandle(forWritingTo: root.env.videoURL(for: IDs.goldenGate))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(repeating: 1, count: 5000))
        try handle.close()
        let bytes = try Data(contentsOf: root.env.videoURL(for: IDs.goldenGate))
        #expect(try await Keeper(env: root.env).reapply() == .waitingForDownload)
        #expect(try Data(contentsOf: root.env.videoURL(for: IDs.goldenGate)) == bytes)
    }

    @Test("Reapply with current/ gone sets needsAttention")
    func reapplyNoCopy() async throws {
        let root = try await appliedRoot()
        try FileManager.default.removeItem(at: root.env.currentDir)
        try await root.addAerial(colour: .init(r: 7, g: 7, b: 250), frames: 15)
        #expect(try await Keeper(env: root.env).reapply() == .needsAttention)
        #expect(try StateStore.load(root.env)?.needsAttention != nil)
    }

    @Test("The log stays under its cap")
    func logCap() async throws {
        let root = try await appliedRoot()
        let keeper = Keeper(env: root.env)
        for _ in 0..<3000 { keeper.log(String(repeating: "x", count: 200)) }
        let size = try FileManager.default.attributesOfItem(atPath: root.env.keeperLogURL.path)[.size] as! Int
        #expect(size <= Keeper.logCap)
    }
}
