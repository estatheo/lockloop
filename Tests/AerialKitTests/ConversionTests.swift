import AVFoundation
import Foundation
import Testing
@testable import AerialKit

let smallSettings = ConversionSettings(canvasWidth: 640, canvasHeight: 360, targetSeconds: 6, minUnitSeconds: 2, bitRate: 2_000_000)

func checkOutput(_ url: URL, plan: ConversionPlan, settings: ConversionSettings = smallSettings) async throws {
    let asset = AVURLAsset(url: url)
    let video = try await asset.loadTracks(withMediaType: .video)
    #expect(video.count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    #expect(await OutputValidation.mediaSubtype(url) == "hvc1")
    let size = try await video[0].load(.naturalSize)
    #expect(Int(size.width) == settings.canvasWidth && Int(size.height) == settings.canvasHeight)
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - plan.totalSeconds) < 0.05)
}

@Suite("Conversion on small inputs", .serialized)
struct ConversionTests {
    let converter = Converter(settings: smallSettings)

    @Test("MP4 in: one hvc1 track, right size, no audio, planned length, sync sample at each repeat")
    func mp4() async throws {
        let temp = TempDir()
        let src = temp.file("clip.mp4")
        try await MediaFactory.movie(at: src, frames: 45)  // 1.5 s at 30 fps
        let media = try await SourceMedia.probe(src)
        #expect(media.kind == .video)
        var stages: [ConversionProgress] = []
        let result = try await converter.run(media, fit: .fit, workDir: temp.file("work")) { stages.append($0) }
        #expect(!result.usedFallback)
        #expect(result.plan.repeats > 1)
        try await checkOutput(result.output, plan: result.plan)
        // Progress only goes up and ends at 1.
        let fractions = stages.map(\.fraction)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)

        // Repeater: N * U samples, increasing times, a sync sample at the start of every repeat.
        let asset = AVURLAsset(url: result.output)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var times: [Double] = []
        var syncs: Set<Int> = []
        while let s = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(s) > 0 else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            if !notSync { syncs.insert(times.count) }
            times.append(CMSampleBufferGetPresentationTimeStamp(s).seconds)
        }
        #expect(times.count == result.plan.totalFrames)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
        for r in 0..<result.plan.repeats { #expect(syncs.contains(r * result.plan.unitFrames)) }
    }

    @Test("GIF in: the same checks")
    func gif() async throws {
        let temp = TempDir()
        let src = temp.file("anim.gif")
        try MediaFactory.gif(at: src, width: 120, height: 90, delays: [0.1, 0.3, 0.2, 0.2]) { i, ctx, _ in
            ctx.setFillColor(red: CGFloat(i) / 4, green: 0.5, blue: 0.2, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        let media = try await SourceMedia.probe(src)
        #expect(media.kind == .gif)
        #expect(media.frameCount == 4)
        #expect(abs(media.duration - 0.8) < 0.001)
        let result = try await converter.run(media, fit: .fit, workDir: temp.file("work"))
        try await checkOutput(result.output, plan: result.plan)
    }

    @Test("A clip with sound comes out silent")
    func audioDropped() async throws {
        let temp = TempDir()
        let src = temp.file("sound.mov")
        try await MediaFactory.movie(at: src, frames: 30, withAudio: true)
        #expect(try await AVURLAsset(url: src).loadTracks(withMediaType: .audio).count == 1)
        let result = try await converter.run(try await SourceMedia.probe(src), fit: .fill, workDir: temp.file("work"))
        try await checkOutput(result.output, plan: result.plan)
    }

    @Test("A portrait clip with a rotation comes out upright")
    func portrait() async throws {
        let temp = TempDir()
        let src = temp.file("portrait.mov")
        // Stored landscape: left half red, right half blue. Rotated 90° clockwise, red ends up on top.
        try await MediaFactory.movie(at: src, width: 64, height: 32, frames: 20,
                                     transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)) { _, p, bpr in
            for y in 0..<32 { for x in 0..<64 {
                let i = y * bpr + x * 4
                if x < 32 { p[i] = 0; p[i + 1] = 0; p[i + 2] = 255 } else { p[i] = 255; p[i + 1] = 0; p[i + 2] = 0 }
            } }
        }
        let media = try await SourceMedia.probe(src)
        #expect(media.displaySize == CGSize(width: 32, height: 64))
        let result = try await converter.run(media, fit: .fit, workDir: temp.file("work"))
        let top = try await MediaFactory.colour(of: result.output, at: 0, x: 0.5, y: 0.2)
        let bottom = try await MediaFactory.colour(of: result.output, at: 0, x: 0.5, y: 0.8)
        #expect(top.r > 180 && top.b < 80)
        #expect(bottom.b > 180 && bottom.r < 80)
    }

    @Test("A GIF with partial frames and transparency decodes to the full composite")
    func partialGIF() async throws {
        let temp = TempDir()
        let src = temp.file("partial.gif")
        // Frame 0 paints everything green. Frame 1 only paints a red square in the middle, transparent elsewhere.
        try MediaFactory.gif(at: src, width: 160, height: 90, delays: [0.5, 0.5]) { i, ctx, _ in
            if i == 0 {
                ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            } else {
                ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 60, y: 25, width: 40, height: 40))
            }
        }
        let media = try await SourceMedia.probe(src)
        let result = try await converter.run(media, fit: .fill, workDir: temp.file("work"))
        let centre = try await MediaFactory.colour(of: result.output, at: 0.7, x: 0.5, y: 0.5)
        let corner = try await MediaFactory.colour(of: result.output, at: 0.7, x: 0.05, y: 0.05)
        #expect(centre.r > 180 && centre.g < 80)
        // ImageIO composites onto the previous frame, or leaves it transparent, which Lockloop draws over the black background.
        #expect((corner.g > 180 && corner.r < 80) || (corner.r < 40 && corner.g < 40 && corner.b < 40))
    }

    @Test("A forced repeater failure falls back to a full encode that still validates")
    func fallback() async throws {
        let temp = TempDir()
        let src = temp.file("clip.mp4")
        try await MediaFactory.movie(at: src, frames: 30)
        var c = converter
        c.forceRepeaterFailure = true
        let result = try await c.run(try await SourceMedia.probe(src), fit: .fit, workDir: temp.file("work"))
        #expect(result.usedFallback)
        try await checkOutput(result.output, plan: result.plan)
    }

    @Test("Cancel during encoding throws cancelled and leaves the work folder empty")
    func cancel() async throws {
        let temp = TempDir()
        let src = temp.file("clip.mp4")
        try await MediaFactory.movie(at: src, frames: 90)
        let media = try await SourceMedia.probe(src)
        let work = temp.file("work")
        let big = Converter(settings: ConversionSettings(canvasWidth: 1920, canvasHeight: 1080, targetSeconds: 60, minUnitSeconds: 2, bitRate: 4_000_000))
        let task = Task { try await big.run(media, fit: .fit, workDir: work) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: LoopError.cancelled) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }

    @Test("Refusals: a text file, a sound-only file, an empty file, a still picture")
    func refusals() async throws {
        let temp = TempDir()
        let text = temp.file("notes.mp4")
        try Data("hello".utf8).write(to: text)
        await #expect(throws: LoopError.unreadableFile(filename: "notes.mp4")) { _ = try await SourceMedia.probe(text) }

        let empty = temp.file("empty.mov")
        try Data().write(to: empty)
        await #expect(throws: LoopError.unreadableFile(filename: "empty.mov")) { _ = try await SourceMedia.probe(empty) }

        let txt = temp.file("notes.txt")
        try Data("hello".utf8).write(to: txt)
        await #expect(throws: LoopError.unsupportedFile(filename: "notes.txt")) { _ = try await SourceMedia.probe(txt) }

        let audio = temp.file("sound.m4a")
        let writer = try AVAssetWriter(outputURL: audio, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        try MediaFactory.appendSilence(input, seconds: 1)
        input.markAsFinished()
        await writer.finishWriting()
        await #expect(throws: LoopError.noPicture(filename: "sound.m4a")) { _ = try await SourceMedia.probe(audio) }

        let png = temp.file("still.png")
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        await #expect(throws: LoopError.unsupportedFile(filename: "still.png")) { _ = try await SourceMedia.probe(png) }
    }

    @Test("Not enough space fails before any encoding")
    func notEnoughSpace() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        root.free = 10_000_000
        let src = root.temp.file("clip.mp4")
        try await MediaFactory.movie(at: src, frames: 30)
        var applier = Applier(env: root.env, settings: smallSettings)
        applier.settings = smallSettings
        var sawProgress = false
        await #expect(throws: LoopError.self) {
            _ = try await applier.apply(source: src, fit: .fit) { _ in sawProgress = true }
        }
        #expect(!sawProgress)
        #expect(!FileManager.default.fileExists(atPath: root.env.currentDir.path))
    }

    @Test("Full apply from a file on a fake root, end to end")
    func applyEndToEnd() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        let src = root.temp.file("clip.mp4")
        try await MediaFactory.movie(at: src, frames: 30)
        let outcome = try await Applier(env: root.env, settings: smallSettings).apply(source: src, fit: .fit)
        #expect(outcome.assetID == IDs.goldenGate)
        #expect(try Status.compute(root.env).status == .applied)
        try await checkOutput(root.env.videoURL(for: IDs.goldenGate), plan: ConversionPlan(sourceDuration: 1, sourceFPS: 30, isGIF: false, settings: smallSettings))
    }
}

/// A full-size run on a real clip. Only runs when LOCKLOOP_FULL_RUN=1 and LOCKLOOP_FULL_SRC points at a video.
@Suite("Full-size conversion", .serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCKLOOP_FULL_RUN"] == "1"))
struct FullSizeTests {
    @Test("A real clip at 3840x2160, about 5 minutes")
    func ownersClip() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LOCKLOOP_FULL_SRC"], "Set LOCKLOOP_FULL_SRC to a video file")
        let src = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCKLOOP_FULL_OUT"] ?? NSTemporaryDirectory())
        let start = Date()
        let result = try await Converter().run(try await SourceMedia.probe(src), fit: .fit, workDir: out)
        try await checkOutput(result.output, plan: result.plan, settings: .standard)
        print("full run: \(Date().timeIntervalSince(start)) s, \(Swap.fileSize(result.output)) bytes")
    }
}
