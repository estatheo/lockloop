import AVFoundation
import Foundation

public enum ConversionStage: String, Sendable { case encoding, repeating }

public struct ConversionProgress: Equatable, Sendable {
    public let stage: ConversionStage
    /// 0...1 over the whole conversion: encoding is the first 90%, repeating the last 10%.
    public let fraction: Double
}

public struct ConversionResult: Sendable {
    public let output: URL
    public let plan: ConversionPlan
    public let media: SourceMedia
    public let usedFallback: Bool
}

/// Runs probe, plan, encode, repeat and validate. Everything happens inside `workDir`.
public struct Converter {
    public var settings: ConversionSettings
    public var displayAspect: Double
    /// Tests set this to prove the full-encode fallback works.
    public var forceRepeaterFailure = false

    public init(settings: ConversionSettings = .standard, displayAspect: Double = CanvasGeometry.sixteenNine) {
        self.settings = settings
        self.displayAspect = displayAspect
    }

    public func plan(for media: SourceMedia) -> ConversionPlan {
        ConversionPlan(sourceDuration: media.duration, sourceFPS: media.frameRate, isGIF: media.kind == .gif, settings: settings)
    }

    public func run(_ media: SourceMedia, fit: FitMode, workDir: URL,
                    progress: @escaping (ConversionProgress) -> Void = { _ in }) async throws -> ConversionResult {
        let plan = plan(for: media)
        let source = makeFrameSource(media, maxSeconds: settings.targetSeconds)
        let destination = CanvasGeometry.destination(source: media.displaySize, canvas: settings.canvas, fit: fit, displayAspect: displayAspect)
        var background = RGBColour.black
        if fit == .fit {
            let sides = CanvasGeometry.barSides(source: media.displaySize, canvas: settings.canvas, displayAspect: displayAspect)
            if sides != .none { background = EdgeColour.sample(await source.sampleImages(), sides: sides) }
        }
        let encoder = LoopEncoder(settings: settings, plan: plan, destination: destination, background: background, filename: media.filename)
        let out = workDir.appendingPathComponent("out.mov")
        let unitURL = workDir.appendingPathComponent("unit.mov")

        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            if plan.repeats == 1 {
                try await encoder.encode(source: source, frameCount: plan.unitFrames, to: out) {
                    progress(ConversionProgress(stage: .encoding, fraction: $0))
                }
            } else {
                try await encoder.encode(source: source, frameCount: plan.unitFrames, to: unitURL) {
                    progress(ConversionProgress(stage: .encoding, fraction: 0.9 * $0))
                }
                do {
                    if forceRepeaterFailure { throw LoopError.conversionFailed(filename: media.filename, detail: "forced") }
                    try await LoopRepeater.repeatUnit(unitURL, times: plan.repeats, unitDuration: plan.time(ofFrame: plan.unitFrames),
                                                      to: out, filename: media.filename) {
                        progress(ConversionProgress(stage: .repeating, fraction: 0.9 + 0.1 * $0))
                    }
                    try await OutputValidation.validate(out, plan: plan, settings: settings, filename: media.filename)
                } catch LoopError.cancelled {
                    throw LoopError.cancelled
                } catch {
                    // Slow but certain: encode every frame.
                    try? FileManager.default.removeItem(at: out)
                    try await encoder.encode(source: source, frameCount: plan.totalFrames, to: out) {
                        progress(ConversionProgress(stage: .encoding, fraction: $0))
                    }
                    try? FileManager.default.removeItem(at: unitURL)
                    try await OutputValidation.validate(out, plan: plan, settings: settings, filename: media.filename)
                    progress(ConversionProgress(stage: .repeating, fraction: 1))
                    return ConversionResult(output: out, plan: plan, media: media, usedFallback: true)
                }
                try? FileManager.default.removeItem(at: unitURL)
            }
            try await OutputValidation.validate(out, plan: plan, settings: settings, filename: media.filename)
        } catch {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: unitURL)
            if Task.isCancelled { throw LoopError.cancelled }
            throw error
        }
        progress(ConversionProgress(stage: .repeating, fraction: 1))
        return ConversionResult(output: out, plan: plan, media: media, usedFallback: false)
    }
}

/// Checks a finished file before it may go near Apple's folder.
public enum OutputValidation {
    public static func validate(_ url: URL, plan: ConversionPlan, settings: ConversionSettings, filename: String) async throws {
        func fail(_ detail: String) -> LoopError { .conversionFailed(filename: filename, detail: detail) }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw fail("not playable") }
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard video.count == 1, audio.isEmpty else { throw fail("tracks: \(video.count) video, \(audio.count) audio") }
        let (formats, size) = try await video[0].load(.formatDescriptions, .naturalSize)
        guard let format = formats.first, CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC else {
            throw fail("not hvc1")
        }
        guard Int(size.width) == settings.canvasWidth, Int(size.height) == settings.canvasHeight else {
            throw fail("size \(Int(size.width))x\(Int(size.height))")
        }
        let duration = try await asset.load(.duration).seconds
        let frame = Double(plan.frameValue) / Double(plan.frameTimescale)
        guard abs(duration - plan.totalSeconds) <= frame + 0.001 else { throw fail("duration \(duration) not \(plan.totalSeconds)") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for t in [CMTime.zero, plan.time(ofFrame: plan.totalFrames - 1)] {
            do { _ = try await generator.image(at: t) } catch { throw fail("frame at \(t.seconds) s does not decode") }
        }
    }

    public static func mediaSubtype(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(format)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii)
    }
}
