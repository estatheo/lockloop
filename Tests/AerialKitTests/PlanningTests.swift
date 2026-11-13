import CoreGraphics
import Foundation
import Testing
@testable import AerialKit

@Suite("Conversion planning and geometry")
struct PlanningTests {
    let canvas = CGSize(width: 3840, height: 2160)

    @Test("Output frame rate table", arguments: [
        (24.0, 24.0), (25, 25), (30, 30), (50, 25), (60, 30), (120, 30), (240, 30), (0, 30), (29.97, 29.97), (59.94, 29.97),
    ])
    func frameRates(input: Double, expected: Double) {
        #expect(abs(ConversionPlan.outputFrameRate(sourceFPS: input, isGIF: false) - expected) < 0.001)
    }

    @Test("GIFs always come out at 30 fps")
    func gifRate() {
        #expect(ConversionPlan.outputFrameRate(sourceFPS: nil, isGIF: true) == 30)
    }

    @Test("The test clip: 14.4 s at 30 fps gives L 432, k 1, N 21, 9,072 frames")
    func testClip() {
        let p = ConversionPlan(sourceDuration: 14.4, sourceFPS: 30, isGIF: false)
        #expect(p.loopFrames == 432)
        #expect(p.unitLoops == 1)
        #expect(p.repeats == 21)
        #expect(p.totalFrames == 9_072)
        #expect(abs(p.totalSeconds - 302.4) < 0.001)
    }

    @Test("The test GIF: 1.6 s gives whole loops near 5 minutes")
    func testGIF() {
        let p = ConversionPlan(sourceDuration: 1.6, sourceFPS: nil, isGIF: true)
        #expect(p.loopFrames == 48)
        #expect(p.unitLoops == 2)
        #expect(p.unitFrames == 96)
        #expect(p.repeats == 94)
        #expect(abs(p.totalSeconds - 300.8) < 0.001)
    }

    @Test("A 0.1 s loop gives a unit of at least 2 s made of whole loops")
    func tinyLoop() {
        let p = ConversionPlan(sourceDuration: 0.1, sourceFPS: nil, isGIF: true)
        #expect(p.loopFrames == 3)
        #expect(p.unitSeconds >= 2)
        #expect(p.unitFrames % p.loopFrames == 0)
    }

    @Test("Long clips: 200 s gives N 2, 250 and 300 s give N 1, 400 s is trimmed")
    func longClips() {
        #expect(ConversionPlan(sourceDuration: 200, sourceFPS: 30, isGIF: false).repeats == 2)
        #expect(ConversionPlan(sourceDuration: 250, sourceFPS: 30, isGIF: false).repeats == 1)
        #expect(ConversionPlan(sourceDuration: 300, sourceFPS: 30, isGIF: false).repeats == 1)
        let long = ConversionPlan(sourceDuration: 400, sourceFPS: 30, isGIF: false)
        #expect(long.trimmed)
        #expect(long.loopFrames == 9_000)
        #expect(long.repeats == 1)
        #expect(!ConversionPlan(sourceDuration: 300, sourceFPS: 30, isGIF: false).trimmed)
    }

    @Test("One-frame GIF plans fine; length is always whole loops", arguments: [0.1, 0.5, 1, 1.6, 3.3, 14.4, 77, 299])
    func wholeLoops(seconds: Double) {
        let p = ConversionPlan(sourceDuration: seconds, sourceFPS: 30, isGIF: false)
        #expect(p.totalFrames % p.loopFrames == 0)
        #expect(p.totalFrames >= p.loopFrames)
        #expect(abs(p.totalSeconds - 300) <= p.unitSeconds / 2 + 0.01)
    }

    @Test("GIF delays: unclamped first, zero and tiny delays become 0.1 s")
    func delays() {
        #expect(FrameTiming.normalisedDelay(unclamped: 0.05, clamped: 0.1) == 0.05)
        #expect(FrameTiming.normalisedDelay(unclamped: nil, clamped: 0.2) == 0.2)
        #expect(FrameTiming.normalisedDelay(unclamped: 0, clamped: 0) == 0.1)
        #expect(FrameTiming.normalisedDelay(unclamped: 0.01, clamped: nil) == 0.1)
    }

    @Test("Frame choice for unequal GIF delays and for 60 to 30 fps")
    func frameChoice() {
        let starts = FrameTiming.startTimes(delays: [0.1, 0.5, 0.2, 0.2])
        #expect(starts == [0, 0.1, 0.6, 0.8])
        let p = ConversionPlan(sourceDuration: 1.0, sourceFPS: nil, isGIF: true)
        let picks = (0..<30).map { FrameTiming.frameIndex(at: p.loopTime(ofFrame: $0), starts: starts) }
        #expect(picks.filter { $0 == 0 }.count == 3)
        #expect(picks.filter { $0 == 1 }.count == 15)
        #expect(picks.filter { $0 == 2 }.count == 6)
        #expect(picks.filter { $0 == 3 }.count == 6)
        // 60 fps source, 30 fps output: every second source frame.
        let sixty = (0..<120).map { Double($0) / 60 }
        let q = ConversionPlan(sourceDuration: 2, sourceFPS: 60, isGIF: false)
        #expect((0..<5).map { FrameTiming.frameIndex(at: q.loopTime(ofFrame: $0), starts: sixty) } == [0, 2, 4, 6, 8])
    }

    @Test("Fit with a 16:9 source fills the canvas and matches Fill")
    func fitSixteenNine() {
        let r = CanvasGeometry.destination(source: CGSize(width: 1920, height: 1080), canvas: canvas, fit: .fit)
        #expect(r == CGRect(origin: .zero, size: canvas))
        #expect(CanvasGeometry.fitEqualsFill(source: CGSize(width: 1920, height: 1080), canvas: canvas))
        #expect(CanvasGeometry.barSides(source: CGSize(width: 1920, height: 1080), canvas: canvas) == .none)
    }

    @Test("Fit with 4:3, 21:9 and portrait sources")
    func fitShapes() {
        let fourThree = CanvasGeometry.destination(source: CGSize(width: 640, height: 480), canvas: canvas, fit: .fit)
        #expect(fourThree == CGRect(x: 480, y: 0, width: 2880, height: 2160))
        #expect(CanvasGeometry.barSides(source: CGSize(width: 640, height: 480), canvas: canvas) == .leftRight)

        let wide = CanvasGeometry.destination(source: CGSize(width: 2560, height: 1080), canvas: canvas, fit: .fit)
        #expect(wide.width == 3840)
        #expect(wide.minY > 0 && abs(wide.minY - (2160 - wide.maxY)) <= 1)
        #expect(CanvasGeometry.barSides(source: CGSize(width: 2560, height: 1080), canvas: canvas) == .topBottom)

        let portrait = CanvasGeometry.destination(source: CGSize(width: 1080, height: 1920), canvas: canvas, fit: .fit)
        #expect(portrait.height == 2160)
        #expect(abs(portrait.midX - 1920) <= 1)
    }

    @Test("Fill covers the canvas with symmetrical overflow")
    func fill() {
        for source in [CGSize(width: 640, height: 480), CGSize(width: 1080, height: 1920)] {
            let r = CanvasGeometry.destination(source: source, canvas: canvas, fit: .fill)
            #expect(r.width >= 3840 && r.height >= 2160)
            #expect(abs(r.midX - 1920) <= 1 && abs(r.midY - 1080) <= 1)
        }
    }

    @Test("Safe rectangles for 16:10, 16:9, 21:9 and 3:2 displays")
    func safeRects() {
        #expect(CanvasGeometry.safeRect(canvas: canvas, displayAspect: 16.0 / 10) == CGRect(x: 192, y: 0, width: 3456, height: 2160))
        #expect(CanvasGeometry.safeRect(canvas: canvas, displayAspect: 16.0 / 9) == CGRect(origin: .zero, size: canvas))
        #expect(CanvasGeometry.safeRect(canvas: canvas, displayAspect: 21.0 / 9) == CGRect(x: 0, y: 257, width: 3840, height: 1646))
        #expect(CanvasGeometry.safeRect(canvas: canvas, displayAspect: 3.0 / 2) == CGRect(x: 300, y: 0, width: 3240, height: 2160))
    }

    @Test("Fit in a 16:10 safe area: a 16:9 source gets bars above and below inside the visible part")
    func fitSafeArea() {
        let r = CanvasGeometry.destination(source: CGSize(width: 1920, height: 1080), canvas: canvas, fit: .fit, displayAspect: 1.6)
        #expect(r.width == 3456)
        #expect(r.height == 1944)
        #expect(CanvasGeometry.barSides(source: CGSize(width: 1920, height: 1080), canvas: canvas, displayAspect: 1.6) == .topBottom)
    }

    @Test("Fit rectangles are whole pixels and inside the canvas", arguments: [
        CGSize(width: 333, height: 777), CGSize(width: 1601, height: 1026), CGSize(width: 1, height: 1), CGSize(width: 4000, height: 10),
    ])
    func wholePixels(source: CGSize) {
        for aspect in [1.6, 16.0 / 9, 2.33] {
            let r = CanvasGeometry.destination(source: source, canvas: canvas, fit: .fit, displayAspect: aspect)
            #expect(r.minX == r.minX.rounded() && r.width == r.width.rounded() && r.minY == r.minY.rounded() && r.height == r.height.rounded())
            #expect(CGRect(origin: .zero, size: canvas).contains(r))
        }
    }

    // MARK: Edge colour

    func image(width: Int, height: Int, paint: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        paint(ctx)
        return ctx.makeImage()!
    }

    @Test("Edge colour: red edges give red, a few white pixels don't move it, transparent gives black")
    func edgeColour() {
        let red = image(width: 200, height: 100) { ctx in
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 20, y: 20, width: 160, height: 60))
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 5))
        }
        let c = EdgeColour.sample([red, red, red], sides: .leftRight)
        #expect(c.red > 0.95 && c.green < 0.05 && c.blue < 0.05)

        let clear = image(width: 100, height: 100) { $0.clear(CGRect(x: 0, y: 0, width: 100, height: 100)) }
        #expect(EdgeColour.sample([clear], sides: .topBottom) == .black)
    }

    @Test("Edge colour samples the edges that touch the bars")
    func edgeSides() {
        // Green on the left and right, blue along the top and bottom.
        let img = image(width: 100, height: 100) { ctx in
            ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 10, width: 10, height: 80)); ctx.fill(CGRect(x: 90, y: 10, width: 10, height: 80))
        }
        let lr = EdgeColour.sample([img], sides: .leftRight)
        #expect(lr.green > 0.9 && lr.blue < 0.1)
        let tb = EdgeColour.sample([img], sides: .topBottom)
        #expect(tb.blue > 0.9 && tb.green < 0.1)
    }
}
