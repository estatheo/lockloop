import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a dropped file is, decided by its content, not its extension.
public struct SourceMedia: Sendable {
    public enum Kind: Equatable, Sendable { case gif, video }

    public let url: URL
    public let kind: Kind
    /// Upright size, with any rotation applied.
    public let displaySize: CGSize
    public let duration: Double
    public let frameRate: Double?
    /// GIF only.
    public let frameDelays: [Double]
    public let preferredTransform: CGAffineTransform

    public var filename: String { url.lastPathComponent }
    public var frameCount: Int { frameDelays.count }

    static let knownExtensions: Set<String> = ["mp4", "mov", "m4v", "gif"]

    public static func probe(_ url: URL) async throws -> SourceMedia {
        let filename = url.lastPathComponent
        let damaged = knownExtensions.contains(url.pathExtension.lowercased())
            ? LoopError.unreadableFile(filename: filename) : LoopError.unsupportedFile(filename: filename)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { throw LoopError.unreadableFile(filename: filename) }
        if (attrs[.size] as? Int64 ?? 0) == 0 { throw LoopError.unreadableFile(filename: filename) }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let type = CGImageSourceGetType(source) as String? {
            if type == UTType.gif.identifier { return try probeGIF(url, source: source) }
            if CGImageSourceGetCount(source) > 0 && !type.contains("movie") && !type.contains("mpeg") {
                // A still picture such as a PNG or JPEG.
                throw LoopError.unsupportedFile(filename: filename)
            }
        }

        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack]
        do { videoTracks = try await asset.loadTracks(withMediaType: .video) } catch { throw damaged }
        guard let track = videoTracks.first else {
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            throw audio.isEmpty ? damaged : LoopError.noPicture(filename: filename)
        }
        if (try? await asset.load(.hasProtectedContent)) == true { throw LoopError.protectedFile(filename: filename) }
        let (natural, transform, fps, range) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
        let upright = natural.applying(transform)
        let size = CGSize(width: abs(upright.width).rounded(), height: abs(upright.height).rounded())
        var duration = range.duration.seconds
        if !duration.isFinite || duration <= 0 { duration = (try? await asset.load(.duration))?.seconds ?? 0 }
        guard size.width > 0, size.height > 0, duration.isFinite, duration > 0 else { throw damaged }
        return SourceMedia(url: url, kind: .video, displaySize: size, duration: duration,
                           frameRate: fps > 0 ? Double(fps) : nil, frameDelays: [], preferredTransform: transform)
    }

    static func probeGIF(_ url: URL, source: CGImageSource) throws -> SourceMedia {
        let filename = url.lastPathComponent
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw LoopError.unreadableFile(filename: filename) }
        var delays: [Double] = []
        var size = CGSize.zero
        for i in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] ?? [:]
            if i == 0 {
                let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                size = CGSize(width: w, height: h)
            }
            let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
            delays.append(FrameTiming.normalisedDelay(
                unclamped: (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue,
                clamped: (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue))
        }
        if size == .zero, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            size = CGSize(width: first.width, height: first.height)
        }
        guard size.width > 0, size.height > 0 else { throw LoopError.unreadableFile(filename: filename) }
        return SourceMedia(url: url, kind: .gif, displaySize: size, duration: delays.reduce(0, +),
                           frameRate: nil, frameDelays: delays, preferredTransform: .identity)
    }
}
