import CoreGraphics
import Foundation

/// Where the picture goes on the canvas. Rectangles use a top-left origin. Pure maths.
public enum CanvasGeometry {
    public static let sixteenNine = 16.0 / 9.0

    /// The part of the canvas a screen of this aspect shows, given macOS scales the
    /// 16:9 video to cover the screen and crops what doesn't fit.
    public static func safeRect(canvas: CGSize, displayAspect a: Double) -> CGRect {
        let canvasAspect = Double(canvas.width / canvas.height)
        guard a.isFinite, a > 0 else { return CGRect(origin: .zero, size: canvas) }
        if a >= canvasAspect {
            let h = (Double(canvas.width) / a).rounded()
            return CGRect(x: 0, y: ((Double(canvas.height) - h) / 2).rounded(), width: Double(canvas.width), height: h)
        } else {
            let w = (Double(canvas.height) * a).rounded()
            return CGRect(x: ((Double(canvas.width) - w) / 2).rounded(), y: 0, width: w, height: Double(canvas.height))
        }
    }

    public static func destination(source: CGSize, canvas: CGSize, fit: FitMode, displayAspect: Double = sixteenNine) -> CGRect {
        guard source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let s: Double
        switch fit {
        case .fill:
            s = max(canvas.width / source.width, canvas.height / source.height)
        case .fit:
            let r = safeRect(canvas: canvas, displayAspect: displayAspect)
            s = min(r.width / source.width, r.height / source.height)
        }
        let w = (source.width * s).rounded()
        let h = (source.height * s).rounded()
        var rect = CGRect(x: ((canvas.width - w) / 2).rounded(), y: ((canvas.height - h) / 2).rounded(), width: w, height: h)
        if fit == .fit { rect = rect.intersection(CGRect(origin: .zero, size: canvas)) }
        return rect
    }

    /// True when Fit would already cover the canvas, so Fit and Fill look the same.
    public static func fitEqualsFill(source: CGSize, canvas: CGSize, displayAspect: Double = sixteenNine) -> Bool {
        let r = destination(source: source, canvas: canvas, fit: .fit, displayAspect: displayAspect)
        return abs(r.width - canvas.width) <= 1 && abs(r.height - canvas.height) <= 1
    }

    public enum BarSides: Equatable, Sendable { case leftRight, topBottom, none }

    /// Which edges of the picture touch the bars in Fit.
    public static func barSides(source: CGSize, canvas: CGSize, displayAspect: Double = sixteenNine) -> BarSides {
        let visible = safeRect(canvas: canvas, displayAspect: displayAspect)
        let r = destination(source: source, canvas: canvas, fit: .fit, displayAspect: displayAspect)
        if r.width < visible.width - 1 { return .leftRight }
        if r.height < visible.height - 1 { return .topBottom }
        return .none
    }
}
