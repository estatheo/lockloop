import AerialKit
import AppKit
import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A file that has been read and is ready to apply.
struct LoadedFile {
    let media: SourceMedia
    var fit: FitMode
    let background: RGBColour
    let fitEqualsFill: Bool
    let displayAspect: Double
    /// The aerial it will replace, when known.
    let targetName: String?
    let alreadyApplied: Bool
    var notes: [String]
}

enum AttentionKind: Equatable {
    case reverted(copyExists: Bool)
    case otherWallpaper(aerialName: String)
}

enum Screen {
    case launching
    case unsupported(AerialLayoutKind)
    case empty
    case loadingFile(String)
    case ready(LoadedFile)
    case needsAerial
    case downloading(name: String, done: Int64, total: Int64?)
    case working(String, Double?, canCancel: Bool)
    case applied(filename: String, justApplied: Bool)
    case attention(AttentionKind)
    case restoring
    case restored(nothingToRestore: Bool)
    case failed(LoopError)
}

@MainActor
@Observable
final class AppModel {
    var screen: Screen = .launching
    var keepApplied = false
    var keepNote: String?
    var readyNote: String?
    var downloadNote: String?
    var aerials: [AerialAsset] = []
    var selectedAerialID: String?
    var selectedAerialSize: Int64?
    var isDropTargeted = false
    /// The file waiting for an aerial to be downloaded.
    private var pending: LoadedFile?
    /// The file being converted, shown paused in the frame while working.
    private(set) var lastLoaded: LoadedFile?
    private var task: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var retry: (() -> Void)?

    let env = AerialKit.Environment.live()
    var testModePath: String? { AerialKit.Environment.sandboxRoot() }

    var windowTitle: String {
        testModePath.map(Copy.windowTitleTestMode) ?? Copy.windowTitle
    }

    var canRestore: Bool {
        switch screen {
        case .applied, .attention: return true
        case .failed(.rollbackFailed), .failed(.choiceNotAccepted): return true
        default: return false
        }
    }

    var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(Brand.cliName)").path
    }

    // MARK: Launch and status

    func refreshStatus() {
        let report: StatusReport
        do { report = try Status.compute(env) } catch {
            screen = .failed(error as? LoopError ?? .stateUnreadable(error.localizedDescription))
            return
        }
        keepApplied = report.keepApplied
        if keepApplied {
            let path = helperPath
            let env = env
            Task { try? await Keeper(env: env).refreshProgramPath(path) }
        }
        if report.needsAttention != nil && !report.currentCopyExists {
            screen = .attention(.reverted(copyExists: false)); return
        }
        switch report.status {
        case .unsupportedLegacy: screen = .unsupported(.legacy)
        case .unsupportedNone: screen = .unsupported(.none)
        case .notApplied: screen = .empty
        case .applied: screen = .applied(filename: report.sourceName ?? "", justApplied: false)
        case .reverted, .missing: screen = .attention(.reverted(copyExists: report.currentCopyExists))
        case .appliedNotSelected: screen = .attention(.otherWallpaper(aerialName: report.assetName ?? ""))
        }
    }

    /// Called when the app becomes active, so fixes made in System Settings show up.
    func refreshIfWaiting() {
        switch screen {
        case .unsupported(.none), .failed(.choiceNotAccepted), .failed(.catalogueUnreadable), .failed(.indexUnreadable),
             .failed(.noDesktopEntries), .attention, .applied(_, false):
            refreshStatus()
        default: break
        }
    }

    // MARK: Files

    static let allowedTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video, .gif, UTType("com.apple.m4v-video") ?? .movie, .movie]

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = Copy.panelPrompt
        panel.message = Copy.panelMessage
        if panel.runModal() == .OK, let url = panel.url { load([url]) }
    }

    var canAcceptFile: Bool {
        switch screen {
        case .empty, .ready, .applied, .restored, .failed, .attention: return true
        default: return false
        }
    }

    func load(_ urls: [URL]) {
        guard let url = urls.first, canAcceptFile else { return }
        task?.cancel()
        screen = .loadingFile(url.lastPathComponent)
        readyNote = nil
        let env = env
        let extra = urls.count > 1 ? Copy.oneFileOnly(url.lastPathComponent) : nil
        task = Task {
            do {
                let media = try await SourceMedia.probe(url)
                let aspect = env.mainDisplayAspect() ?? CanvasGeometry.sixteenNine
                let canvas = ConversionSettings.standard.canvas
                let sides = CanvasGeometry.barSides(source: media.displaySize, canvas: canvas, displayAspect: aspect)
                let source = makeFrameSource(media, maxSeconds: ConversionSettings.standard.targetSeconds)
                let background = sides == .none ? RGBColour.black : EdgeColour.sample(await source.sampleImages(), sides: sides)
                let report = try? Status.compute(env)
                let applied = [.applied, .appliedNotSelected].contains(report?.status)
                var notes: [String] = []
                if let extra { notes.append(extra) }
                if media.duration > ConversionSettings.standard.targetSeconds { notes.append(Copy.longerThanFive) }
                let file = LoadedFile(media: media, fit: .fit, background: background,
                                      fitEqualsFill: CanvasGeometry.fitEqualsFill(source: media.displaySize, canvas: canvas, displayAspect: aspect),
                                      displayAspect: aspect, targetName: Applier(env: env).targetName(),
                                      alreadyApplied: applied, notes: notes)
                guard !Task.isCancelled else { return }
                lastLoaded = file
                screen = .ready(file)
            } catch {
                guard !Task.isCancelled else { return }
                retry = nil
                screen = .failed(error as? LoopError ?? .unreadableFile(filename: url.lastPathComponent))
            }
        }
    }

    func setFit(_ fit: FitMode) {
        guard case .ready(var file) = screen else { return }
        file.fit = fit
        lastLoaded = file
        screen = .ready(file)
    }

    func chooseAnother() {
        task?.cancel()
        readyNote = nil
        screen = .empty
        chooseFile()
    }

    func backToEmpty() {
        readyNote = nil
        screen = .empty
    }

    // MARK: Apply

    func apply() {
        guard case .ready(let file) = screen else { return }
        start(file)
    }

    private func start(_ file: LoadedFile) {
        readyNote = nil
        let env = env
        let isGIF = file.media.kind == .gif
        screen = .working(isGIF ? Copy.convertingGIF(0) : Copy.convertingVideo(0), 0, canCancel: true)
        announce(isGIF ? Copy.convertingGIF(0) : Copy.convertingVideo(0))
        var lastQuarter = 0
        task = Task {
            do {
                _ = try await Applier(env: env).apply(source: file.media.url, fit: file.fit) { phase in
                    Task { @MainActor in
                        guard case .working = self.screen else { return }
                        switch phase {
                        case .converting(let p):
                            let percent = Int(p.fraction * 100)
                            let text = p.stage == .encoding ? (isGIF ? Copy.convertingGIF(percent) : Copy.convertingVideo(percent)) : Copy.repeating(percent)
                            self.screen = .working(text, p.fraction, canCancel: true)
                            if percent / 25 > lastQuarter { lastQuarter = percent / 25; self.announce(Copy.percentAnnouncement(lastQuarter * 25)) }
                        case .installing:
                            self.screen = .working(Copy.installing, nil, canCancel: false)
                            self.announce(Copy.installing)
                        }
                    }
                }
                try Task.checkCancellation()
                pending = nil
                screen = .applied(filename: file.media.filename, justApplied: true)
                keepApplied = (try? StateStore.load(env))?.keepApplied ?? false
                announce(Copy.doneJustApplied)
            } catch LoopError.needsDownload {
                pending = file
                showAerialPicker()
            } catch is CancellationError {
                cancelled(file)
            } catch LoopError.cancelled {
                cancelled(file)
            } catch {
                retry = { self.start(file) }
                screen = .failed(error as? LoopError ?? .conversionFailed(filename: file.media.filename, detail: error.localizedDescription))
                announce((error as? LoopError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func cancelled(_ file: LoadedFile) {
        screen = .ready(file)
        readyNote = Copy.cancelledNothingChanged
        announce(Copy.cancelledNothingChanged)
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Needs an aerial

    private func showAerialPicker() {
        aerials = (try? AerialCatalogue.load(env))?.downloadable ?? []
        selectedAerialID = selectedAerialID ?? aerials.first?.id
        downloadNote = nil
        screen = .needsAerial
        fetchSelectedSize()
        watchForAerial()
    }

    func selectAerial(_ id: String?) {
        selectedAerialID = id
        fetchSelectedSize()
    }

    private func fetchSelectedSize() {
        selectedAerialSize = nil
        guard let id = selectedAerialID, let url = aerials.first(where: { $0.id == id })?.downloadURL else { return }
        let env = env
        Task {
            let size = await env.downloader.contentLength(of: url)
            if self.selectedAerialID == id { self.selectedAerialSize = size }
        }
    }

    /// Carries on by itself when an aerial appears, for example one chosen in System Settings.
    private func watchForAerial() {
        watchTask?.cancel()
        let env = env
        watchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard case .needsAerial = self.screen else { return }
                if let catalogue = try? AerialCatalogue.load(env), !AssetDiscovery.downloaded(env, catalogue: catalogue).isEmpty,
                   let file = self.pending {
                    self.start(file)
                    return
                }
            }
        }
    }

    func downloadSelected() {
        guard let id = selectedAerialID, let asset = aerials.first(where: { $0.id == id }) else { return }
        watchTask?.cancel()
        downloadNote = nil
        let env = env
        screen = .downloading(name: asset.displayName, done: 0, total: selectedAerialSize)
        task = Task {
            do {
                try await Applier(env: env).download(asset) { done, total in
                    Task { @MainActor in
                        if case .downloading = self.screen { self.screen = .downloading(name: asset.displayName, done: done, total: total) }
                    }
                }
                if let file = pending { start(file) } else { screen = .empty }
            } catch LoopError.cancelled {
                downloadNote = Copy.downloadCancelled
                showAerialPicker()
                downloadNote = Copy.downloadCancelled
            } catch is CancellationError {
                showAerialPicker()
                downloadNote = Copy.downloadCancelled
            } catch {
                retry = { self.showAerialPicker() }
                screen = .failed(error as? LoopError ?? .downloadFailed(error.localizedDescription))
            }
        }
    }

    // MARK: Applied

    func setKeepApplied(_ on: Bool) {
        let env = env
        let path = helperPath
        keepNote = nil
        Task {
            do {
                if on { try await Keeper(env: env).enable(programPath: path) } else { try await Keeper(env: env).disable() }
                keepApplied = on
                keepNote = on ? Copy.keepAppliedJustOn : nil
            } catch {
                keepApplied = false
                keepNote = (error as? LoopError)?.message ?? LoopError.keeperFailed(error.localizedDescription).message
            }
        }
    }

    func useMyVideoAgain() {
        let env = env
        lastLoaded = nil
        screen = .working(Copy.installing, nil, canCancel: false)
        task = Task {
            do {
                _ = try await Applier(env: env).reapplyCurrent()
                let name = (try? StateStore.load(env))?.installed?.sourceName ?? ""
                screen = .applied(filename: name, justApplied: true)
                announce(Copy.doneJustApplied)
            } catch {
                retry = { self.useMyVideoAgain() }
                screen = .failed(error as? LoopError ?? .swapFailed(error.localizedDescription))
            }
        }
    }

    // MARK: Restore

    func restore() {
        let env = env
        screen = .restoring
        announce(Copy.restoring)
        task = Task {
            do {
                let outcome = try await Restorer(env: env).restore()
                keepApplied = false
                screen = .restored(nothingToRestore: outcome == .nothingToRestore)
                announce(outcome == .restored ? Copy.restored : Copy.nothingToRestoreApp)
            } catch {
                retry = { self.restore() }
                screen = .failed(error as? LoopError ?? .swapFailed(error.localizedDescription))
            }
        }
    }

    func downloadAndRestore() {
        let env = env
        screen = .restoring
        task = Task {
            do {
                let outcome = try await Restorer(env: env).downloadOriginalAndRestore { _, _ in }
                keepApplied = false
                screen = .restored(nothingToRestore: outcome == .nothingToRestore)
            } catch {
                retry = { self.downloadAndRestore() }
                screen = .failed(error as? LoopError ?? .downloadFailed(error.localizedDescription))
            }
        }
    }

    // MARK: Failed

    func tryAgain() {
        if let retry { self.retry = nil; retry() } else { refreshStatus() }
    }

    func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Helpers

    func announce(_ text: String) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// First frame of the video now on the lock screen.
    func appliedThumbnail() async -> CGImage? {
        guard let state = try? StateStore.load(env) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: env.currentURL(for: state.assetID)))
        generator.maximumSize = CGSize(width: 1280, height: 720)
        return try? await generator.image(at: .zero).image
    }
}
