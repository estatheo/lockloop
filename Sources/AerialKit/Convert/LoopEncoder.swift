import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

/// Renders frames onto the canvas and encodes them as HEVC (hvc1) in a QuickTime movie, no audio.
public struct LoopEncoder {
    public let settings: ConversionSettings
    public let plan: ConversionPlan
    public let destination: CGRect
    public let background: RGBColour
    public let filename: String

    static let context = CIContext(options: [.cacheIntermediates: false])

    public static func videoSettings(_ settings: ConversionSettings, fps: Double, includeProfile: Bool = true) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitRate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int((2 * fps).rounded())),
            AVVideoAllowFrameReorderingKey: false,
        ]
        if includeProfile { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String }
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: settings.canvasWidth,
            AVVideoHeightKey: settings.canvasHeight,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// Encodes `frameCount` frames, looping the source every `plan.loopFrames`.
    /// `progress` gets 0...1. Checks for cancellation on every frame.
    public func encode(source: FrameSource, frameCount: Int, to output: URL, progress: (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var outputSettings = Self.videoSettings(settings, fps: plan.outputFPS)
        if !writer.canApply(outputSettings: outputSettings, forMediaType: .video) {
            outputSettings = Self.videoSettings(settings, fps: plan.outputFPS, includeProfile: false)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: settings.canvasWidth,
            kCVPixelBufferHeightKey as String: settings.canvasHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw failure("writer input") }
        writer.add(input)
        guard writer.startWriting() else { throw failure(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        let canvasRect = CGRect(origin: .zero, size: settings.canvas)
        let backgroundImage = CIImage(color: CIColor(cgColor: background.cgColor)).cropped(to: canvasRect)
        let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var cursor: FrameCursor?
        var lastID = -1
        var lastBuffer: CVPixelBuffer?

        do {
            for n in 0..<frameCount {
                if Task.isCancelled { throw LoopError.cancelled }
                if n % plan.loopFrames == 0 { cursor = try await source.makeCursor(); lastID = -1 }
                let (image, id) = try cursor!.image(at: plan.loopTime(ofFrame: n))
                let buffer: CVPixelBuffer
                if id == lastID, let lastBuffer {
                    buffer = lastBuffer
                } else {
                    guard let pool = adaptor.pixelBufferPool else { throw failure(writer.error?.localizedDescription ?? "no pixel buffer pool") }
                    var made: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
                    guard let made else { throw failure("pixel buffer") }
                    let composed = place(image).composited(over: backgroundImage).cropped(to: canvasRect)
                    Self.context.render(composed, to: made, bounds: canvasRect, colorSpace: colourSpace)
                    buffer = made
                    lastBuffer = made
                    lastID = id
                }
                while !input.isReadyForMoreMediaData {
                    if Task.isCancelled { throw LoopError.cancelled }
                    if writer.status == .failed { throw failure(writer.error?.localizedDescription ?? "writer") }
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                guard adaptor.append(buffer, withPresentationTime: plan.time(ofFrame: n)) else {
                    throw failure(writer.error?.localizedDescription ?? "append")
                }
                if n % 8 == 0 || n == frameCount - 1 { progress(Double(n + 1) / Double(frameCount)) }
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: plan.time(ofFrame: frameCount))
        await writer.finishWriting()
        guard writer.status == .completed else { throw failure(writer.error?.localizedDescription ?? "finish") }
    }

    /// Scales and moves the upright source image into the destination rectangle (top-left origin).
    func place(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let sx = destination.width / extent.width
        let sy = destination.height / extent.height
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(image.clampedToExtent().cropped(to: extent), forKey: kCIInputImageKey)
        filter.setValue(sy, forKey: kCIInputScaleKey)
        filter.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
        let scaled = filter.outputImage!
        let originY = settings.canvas.height - destination.maxY
        return scaled
            .transformed(by: CGAffineTransform(translationX: destination.minX - scaled.extent.minX, y: originY - scaled.extent.minY))
            .cropped(to: destination)
    }

    func failure(_ detail: String) -> LoopError {
        .conversionFailed(filename: filename, detail: detail)
    }
}
