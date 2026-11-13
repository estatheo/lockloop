import CoreMedia
import Foundation

/// Sizes and lengths for the output. Tests shrink these so conversions finish in seconds.
public struct ConversionSettings: Equatable, Sendable {
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var targetSeconds: Double
    public var minUnitSeconds: Double
    public var bitRate: Int
    public var maxFPS: Double

    public init(canvasWidth: Int = 3840, canvasHeight: Int = 2160, targetSeconds: Double = 300,
                minUnitSeconds: Double = 2, bitRate: Int = 8_000_000, maxFPS: Double = 30) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.targetSeconds = targetSeconds
        self.minUnitSeconds = minUnitSeconds
        self.bitRate = bitRate
        self.maxFPS = maxFPS
    }

    public static let standard = ConversionSettings()
    public var canvas: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }
}

/// How many frames to encode once and how often to repeat them. Pure maths.
public struct ConversionPlan: Equatable, Sendable {
    public let outputFPS: Double
    /// One frame lasts frameValue / frameTimescale seconds.
    public let frameValue: Int64
    public let frameTimescale: Int32
    public let sourceDuration: Double
    public let trimmed: Bool
    /// Frames in one loop of the source.
    public let loopFrames: Int
    /// Loops per encoded unit.
    public let unitLoops: Int
    public let unitFrames: Int
    public let repeats: Int
    public var totalFrames: Int { repeats * unitFrames }
    public var totalSeconds: Double { Double(totalFrames) * Double(frameValue) / Double(frameTimescale) }
    public var unitSeconds: Double { Double(unitFrames) * Double(frameValue) / Double(frameTimescale) }

    public static func outputFrameRate(sourceFPS: Double?, isGIF: Bool, maxFPS: Double = 30) -> Double {
        if isGIF { return maxFPS }
        guard let f = sourceFPS, f.isFinite, f > 0.5 else { return maxFPS }
        if f <= maxFPS + 0.01 { return f }
        return f / (f / maxFPS).rounded(.up)
    }

    public init(sourceDuration d: Double, sourceFPS: Double?, isGIF: Bool, settings: ConversionSettings = .standard) {
        let fps = Self.outputFrameRate(sourceFPS: sourceFPS, isGIF: isGIF, maxFPS: settings.maxFPS)
        outputFPS = fps
        (frameValue, frameTimescale) = Self.rational(fps)
        sourceDuration = d
        trimmed = d > settings.targetSeconds
        let used = min(d, settings.targetSeconds)
        let L = max(1, Int((used * fps).rounded()))
        loopFrames = L
        let k = max(1, Int((settings.minUnitSeconds * fps / Double(L)).rounded(.up)))
        unitLoops = k
        unitFrames = k * L
        repeats = max(1, Int((settings.targetSeconds * fps / Double(k * L)).rounded()))
    }

    /// Frame duration as a rational, exact for whole and NTSC rates.
    static func rational(_ fps: Double) -> (Int64, Int32) {
        let whole = fps.rounded()
        if abs(fps - whole) < 0.001 { return (1, Int32(whole)) }
        let ntsc = (fps * 1.001).rounded()
        if abs(fps * 1.001 - ntsc) < 0.01 { return (1001, Int32(ntsc * 1000)) }
        return (Int64((600_000 / fps).rounded()), 600_000)
    }

    public func time(ofFrame n: Int) -> CMTime {
        CMTime(value: Int64(n) * frameValue, timescale: frameTimescale)
    }

    /// Seconds into the source loop that output frame n shows.
    public func loopTime(ofFrame n: Int) -> Double {
        Double(n % loopFrames) * Double(frameValue) / Double(frameTimescale)
    }

    /// Estimated output size in bytes.
    public func estimatedBytes(bitRate: Int) -> Int64 {
        Int64(Double(bitRate) * totalSeconds / 8)
    }
}

public enum FrameTiming {
    /// GIF delays the way browsers treat them: unclamped first, tiny or zero delays become 0.1 s.
    public static func normalisedDelay(unclamped: Double?, clamped: Double?) -> Double {
        let raw = (unclamped ?? 0) > 0 ? unclamped! : (clamped ?? 0)
        return raw < 0.011 ? 0.1 : raw
    }

    public static func startTimes(delays: [Double]) -> [Double] {
        var t = 0.0
        return delays.map { d in defer { t += d }; return t }
    }

    /// The frame on screen at time t: the last one starting at or before t.
    public static func frameIndex(at t: Double, starts: [Double]) -> Int {
        var lo = 0, hi = starts.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= t + 1e-6 { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }
}
