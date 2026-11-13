import CoreGraphics
import Foundation

public struct RGBColour: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    public static let black = RGBColour(red: 0, green: 0, blue: 0)

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])!
    }
}

/// The background colour for Fit: the median of the picture's edges that touch the bars.
public enum EdgeColour {
    static let samplesPerEdge = 64

    public static func sample(_ images: [CGImage], sides: CanvasGeometry.BarSides) -> RGBColour {
        guard sides != .none else { return .black }
        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
        for image in images {
            let w = min(image.width, samplesPerEdge), h = min(image.height, samplesPerEdge)
            guard w > 0, h > 0, let pixels = render(image, width: w, height: h) else { continue }
            let thickX = max(1, Int((Double(w) * 0.02).rounded()))
            let thickY = max(1, Int((Double(h) * 0.02).rounded()))
            func take(_ x: Int, _ y: Int) {
                let i = (y * w + x) * 4
                reds.append(pixels[i]); greens.append(pixels[i + 1]); blues.append(pixels[i + 2])
            }
            switch sides {
            case .leftRight:
                for y in 0..<h { for x in 0..<thickX { take(x, y); take(w - 1 - x, y) } }
            case .topBottom:
                for x in 0..<w { for y in 0..<thickY { take(x, y); take(x, h - 1 - y) } }
            case .none: break
            }
        }
        guard !reds.isEmpty else { return .black }
        func median(_ v: [UInt8]) -> Double { Double(v.sorted()[v.count / 2]) / 255 }
        return RGBColour(red: median(reds), green: median(greens), blue: median(blues))
    }

    /// Draws the image over black into a small RGBA buffer, so transparent pixels count as black.
    static func render(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }
}
