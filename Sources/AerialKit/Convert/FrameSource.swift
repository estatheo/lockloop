import AVFoundation
import CoreImage
import Foundation
import ImageIO

/// Gives the picture on screen at a time in one pass over the source loop.
/// Times passed to one cursor must not go backwards.
public protocol FrameCursor {
    /// The upright image on screen at t seconds, and an id that changes when the frame does.
    mutating func image(at t: Double) throws -> (image: CIImage, id: Int)
}

public protocol FrameSource {
    var displaySize: CGSize { get }
    func makeCursor() async throws -> FrameCursor
    /// Up to three frames (first, middle, last) for the edge colour.
    func sampleImages() async -> [CGImage]
}

public func makeFrameSource(_ media: SourceMedia, maxSeconds: Double) -> FrameSource {
    switch media.kind {
    case .gif: return GIFFrameSource(media: media)
    case .video: return VideoFrameSource(media: media, maxSeconds: maxSeconds)
    }
}

// MARK: GIF

public final class GIFFrameSource: FrameSource {
    let media: SourceMedia
    let starts: [Double]
    public var displaySize: CGSize { media.displaySize }

    init(media: SourceMedia) {
        self.media = media
        self.starts = FrameTiming.startTimes(delays: media.frameDelays)
    }

    func imageSource() throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(media.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw LoopError.unreadableFile(filename: media.filename)
        }
        return source
    }

    public func makeCursor() async throws -> FrameCursor {
        Cursor(source: try imageSource(), starts: starts, filename: media.filename)
    }

    public func sampleImages() async -> [CGImage] {
        guard let source = try? imageSource() else { return [] }
        let n = media.frameCount
        return Array(Set([0, n / 2, n - 1])).sorted().compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
    }

    struct Cursor: FrameCursor {
        let source: CGImageSource
        let starts: [Double]
        let filename: String
        var cachedIndex = -1
        var cached: CIImage?

        mutating func image(at t: Double) throws -> (image: CIImage, id: Int) {
            let index = FrameTiming.frameIndex(at: t, starts: starts)
            if index != cachedIndex || cached == nil {
                guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                    throw LoopError.conversionFailed(filename: filename, detail: "GIF frame \(index)")
                }
                cached = CIImage(cgImage: cg)
                cachedIndex = index
            }
            return (cached!, index)
        }
    }
}

// MARK: Video

public final class VideoFrameSource: FrameSource {
    let media: SourceMedia
    let maxSeconds: Double
    public var displaySize: CGSize { media.displaySize }

    init(media: SourceMedia, maxSeconds: Double) {
        self.media = media
        self.maxSeconds = maxSeconds
    }

    public func makeCursor() async throws -> FrameCursor {
        let asset = AVURLAsset(url: media.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LoopError.noPicture(filename: media.filename)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let range = try await track.load(.timeRange)
        if range.duration.seconds > maxSeconds {
            reader.timeRange = CMTimeRange(start: range.start, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        }
        guard reader.startReading() else {
            throw LoopError.conversionFailed(filename: media.filename, detail: reader.error?.localizedDescription ?? "reader")
        }
        return Cursor(reader: reader, output: output, start: range.start.seconds,
                      orientation: Self.orientation(for: media.preferredTransform), filename: media.filename)
    }

    /// The EXIF orientation that turns the stored picture upright.
    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
        switch (t.a, t.b, t.c, t.d) {
        case let (a, b, c, d) where near(a, 0) && near(b, 1) && near(c, -1) && near(d, 0): return .right
        case let (a, b, c, d) where near(a, 0) && near(b, -1) && near(c, 1) && near(d, 0): return .left
        case let (a, b, c, d) where near(a, -1) && near(b, 0) && near(c, 0) && near(d, -1): return .down
        case let (a, b, c, d) where near(a, -1) && near(b, 0) && near(c, 0) && near(d, 1): return .upMirrored
        case let (a, b, c, d) where near(a, 1) && near(b, 0) && near(c, 0) && near(d, -1): return .downMirrored
        default: return .up
        }
    }

    public func sampleImages() async -> [CGImage] {
        let asset = AVURLAsset(url: media.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let used = min(media.duration, maxSeconds)
        var images: [CGImage] = []
        for t in [0, used / 2, max(0, used - 0.1)] {
            if let (image, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                images.append(image)
            }
        }
        return images
    }

    struct Cursor: FrameCursor {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let start: Double
        let orientation: CGImagePropertyOrientation
        let filename: String
        var current: (image: CIImage, time: Double, id: Int)?
        var upcoming: (image: CIImage, time: Double)?
        var ended = false
        var nextID = 0

        mutating func read() -> (image: CIImage, time: Double)? {
            while !ended {
                guard let sample = output.copyNextSampleBuffer() else { ended = true; return nil }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                var image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
                return (image, time)
            }
            return nil
        }

        mutating func image(at t: Double) throws -> (image: CIImage, id: Int) {
            if current == nil {
                guard let first = read() else {
                    throw LoopError.conversionFailed(filename: filename, detail: reader.error?.localizedDescription ?? "no frames")
                }
                current = (first.image, first.time, nextID); nextID += 1
                upcoming = read()
            }
            while let next = upcoming, next.time <= t + 1e-4 {
                current = (next.image, next.time, nextID); nextID += 1
                upcoming = read()
            }
            if reader.status == .failed {
                throw LoopError.conversionFailed(filename: filename, detail: reader.error?.localizedDescription ?? "reader")
            }
            return (current!.image, current!.id)
        }
    }
}
