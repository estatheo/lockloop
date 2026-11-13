import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import AerialKit

enum IDs {
    static let goldenGate = "4207734D-74FE-4F92-B5E1-6EC8DEE24A15"
    static let goldenGateB = "B2C3D4E5-0000-4000-8000-000000000002"
    static let noURL = "C3D4E5F6-0000-4000-8000-000000000003"
    static let foreignHost = "D4E5F6A7-0000-4000-8000-000000000004"
    static let noLabel = "E5F6A7B8-0000-4000-8000-000000000005"
    static let other = "11111111-2222-4333-8444-555555555555"
}

struct TestFailure: Error {}

/// A temp directory removed when the test is done.
final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("lockloop-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

func fixtureURL(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
}

/// Counts restarts and can rewrite Index.plist to mimic WallpaperAgent reverting a choice.
final class RecordingAgent: WallpaperAgentControl, @unchecked Sendable {
    var restarts = 0
    var onRestart: ((Int) -> Void)?
    func restart() async {
        restarts += 1
        onRestart?(restarts)
    }
}

final class RecordingLaunchd: LaunchdControl, @unchecked Sendable {
    var bootstraps: [URL] = []
    var bootouts: [String] = []
    func bootstrap(plist: URL) throws { bootstraps.append(plist) }
    func bootout(label: String) throws { bootouts.append(label) }
}

// MARK: Index.plist fixtures

enum IndexFixture {
    static let display1 = "AAAAAAAA-1111-4111-8111-111111111111"
    static let display2 = "BBBBBBBB-2222-4222-8222-222222222222"
    static let space = "CCCCCCCC-3333-4333-8333-333333333333"
    static let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)

    static func choice(provider: String, configuration: Data) -> [String: Any] {
        ["Configuration": configuration, "Files": [Any](), "Provider": provider]
    }

    static func entry(provider: String, configuration: Data, shuffle: Any = "$null") -> [String: Any] {
        [
            "Content": [
                "Choices": [choice(provider: provider, configuration: configuration)],
                "EncodedOptionValues": "$null",
                "Shuffle": shuffle,
            ] as [String: Any],
            "LastSet": fixedDate,
            "LastUse": fixedDate.addingTimeInterval(60),
        ]
    }

    static func aerial(_ id: String) -> [String: Any] {
        entry(provider: WallpaperIndex.aerialsProvider, configuration: try! WallpaperIndex.configuration(assetID: id))
    }

    static func idle() -> [String: Any] {
        let config = try! PropertyListSerialization.data(fromPropertyList: ["module": ["relative": "file:///test/Neutral.saver"]], format: .binary, options: 0)
        return entry(provider: "com.apple.wallpaper.choice.screen-saver", configuration: config)
    }

    static func linked() -> [String: Any] {
        entry(provider: "default", configuration: Data())
    }

    static func individual(_ desktop: [String: Any]) -> [String: Any] {
        ["Type": "individual", "Desktop": desktop, "Idle": idle()]
    }

    /// The structure seen on the owner's Mac: 9 Desktop, 10 Idle, 2 Linked, an empty-string space key.
    static func observed(desktop: [String: Any] = aerial(IDs.goldenGate)) -> [String: Any] {
        [
            "AllSpacesAndDisplays": ["Type": "idle", "Idle": idle()] as [String: Any],
            "SystemDefault": individual(desktop),
            "Displays": [
                display1: individual(desktop),
                display2: individual(desktop),
            ] as [String: Any],
            "Spaces": [
                "": [
                    "Default": individual(desktop),
                    "Displays": [display1: individual(desktop), display2: ["Type": "linked", "Linked": linked()] as [String: Any]] as [String: Any],
                ] as [String: Any],
                space: [
                    "Default": individual(desktop),
                    "Displays": [
                        display1: individual(desktop),
                        display2: ["Type": "linked", "Linked": linked()] as [String: Any],
                        "EEEEEEEE-5555-4555-8555-555555555555": individual(desktop),
                    ] as [String: Any],
                    "Extra": individual(desktop),
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    static func single(desktop: [String: Any] = aerial(IDs.goldenGate)) -> [String: Any] {
        ["SystemDefault": individual(desktop)]
    }

    static func linkedOnly() -> [String: Any] {
        ["SystemDefault": ["Type": "linked", "Linked": linked()] as [String: Any]]
    }

    static func data(_ root: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
    }
}

// MARK: Media

enum MediaFactory {
    struct Colour { var r: UInt8; var g: UInt8; var b: UInt8 }

    /// Writes a small H.264 movie. `paint` fills each BGRA frame.
    static func movie(at url: URL, width: Int = 320, height: Int = 180, fps: Int32 = 30, frames: Int = 60,
                      transform: CGAffineTransform = .identity, withAudio: Bool = false,
                      paint: (Int, UnsafeMutablePointer<UInt8>, Int) -> Void = { n, p, bpr in
                          defaultPaint(n, p, bpr)
                      }) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        var audioInput: AVAssetWriterInput?
        if withAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
            ])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            audioInput = a
        }
        guard writer.startWriting() else { throw writer.error ?? TestFailure() }
        writer.startSession(atSourceTime: .zero)
        for n in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buffer!)
            for y in 0..<height { for x in 0..<width { let i = y * bpr + x * 4; base[i] = 0; base[i + 1] = 0; base[i + 2] = 0; base[i + 3] = 255 } }
            paintContext = (width, height)
            paint(n, base, bpr)
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: fps))
        }
        input.markAsFinished()
        if let audioInput {
            let seconds = Double(frames) / Double(fps)
            try appendSilence(audioInput, seconds: seconds)
            audioInput.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? TestFailure() }
    }

    nonisolated(unsafe) static var paintContext = (0, 0)

    static func defaultPaint(_ n: Int, _ p: UnsafeMutablePointer<UInt8>, _ bpr: Int) {
        let (w, h) = paintContext
        let shade = UInt8((n * 37) % 200 + 30)
        for y in 0..<h { for x in 0..<w { let i = y * bpr + x * 4; p[i] = shade; p[i + 1] = UInt8(x % 256); p[i + 2] = UInt8(y % 256) } }
    }

    static func appendSilence(_ input: AVAssetWriterInput, seconds: Double) throws {
        let rate = 44100.0
        let count = Int(seconds * rate)
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: count * 2)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
        while !input.isReadyForMoreMediaData { usleep(1000) }
        input.append(sample!)
    }

    /// A solid-colour movie, used as a stand-in for Apple's aerials.
    static func solidMovie(at url: URL, colour: Colour, frames: Int = 10) async throws {
        try await movie(at: url, width: 64, height: 36, fps: 10, frames: frames) { _, p, bpr in
            for y in 0..<36 { for x in 0..<64 { let i = y * bpr + x * 4; p[i] = colour.b; p[i + 1] = colour.g; p[i + 2] = colour.r } }
        }
    }

    /// Writes a GIF. Each frame is drawn by `draw` into an RGBA context of the frame's size.
    static func gif(at url: URL, width: Int, height: Int, delays: [Double], unclamped: Bool = true,
                    frameRects: [CGRect]? = nil, draw: (Int, CGContext, CGRect) -> Void) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, delays.count, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (i, delay) in delays.enumerated() {
            let rect = frameRects?[i] ?? CGRect(x: 0, y: 0, width: width, height: height)
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            draw(i, ctx, rect)
            var gifProps: [CFString: Any] = [kCGImagePropertyGIFDelayTime: delay]
            if unclamped { gifProps[kCGImagePropertyGIFUnclampedDelayTime] = delay }
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: gifProps] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw TestFailure() }
    }

    /// Reads the colour at a point (top-left origin) of a frame decoded at `time`.
    static func colour(of url: URL, at time: Double, x: Double, y: Double) async throws -> Colour {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        return pixel(image, x: x, y: y)
    }

    static func pixel(_ image: CGImage, x: Double, y: Double) -> Colour {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = min(w - 1, Int(x * Double(w))), py = min(h - 1, Int(y * Double(h)))
        let i = (py * w + px) * 4
        return Colour(r: data[i], g: data[i + 1], b: data[i + 2])
    }
}

// MARK: Fake root

/// The wallpaper tree from the plan's section 1.1, under a temp directory.
final class FakeRoot {
    let temp = TempDir()
    let agent = RecordingAgent()
    let launchd = RecordingLaunchd()
    var clock = IndexFixture.fixedDate.addingTimeInterval(86_400)
    var free: Int64? = 100_000_000_000
    var env: Environment

    init(index: [String: Any]? = IndexFixture.observed(), entries: Bool = true) {
        let home = temp.url.appendingPathComponent("home", isDirectory: true)
        env = Environment(home: home, systemRoot: temp.url.appendingPathComponent("system", isDirectory: true),
                          agent: agent, launchd: launchd, isSandboxed: true)
        env.minimumAerialBytes = 1_000
        env.now = { [unowned self] in self.clock }
        env.freeSpace = { [unowned self] _ in self.free }
        let fm = FileManager.default
        try! fm.createDirectory(at: env.videosDir, withIntermediateDirectories: true)
        try! fm.createDirectory(at: env.thumbnailsDir, withIntermediateDirectories: true)
        if entries {
            try! fm.createDirectory(at: env.entriesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! fm.copyItem(at: fixtureURL("entries-small.json"), to: env.entriesURL)
        }
        if let index {
            try! fm.createDirectory(at: env.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! IndexFixture.data(index).write(to: env.indexURL)
        }
    }

    /// Puts an "Apple" aerial in place with the xattrs macOS's own downloads carry.
    @discardableResult
    func addAerial(_ id: String = IDs.goldenGate, colour: MediaFactory.Colour = .init(r: 200, g: 120, b: 40), frames: Int = 10,
                   modified: Date? = nil) async throws -> URL {
        let url = env.videoURL(for: id)
        try await MediaFactory.solidMovie(at: url, colour: colour, frames: frames)
        try ExtendedAttributes.write([
            "LastETag": Data("\"ETAG-\(id.prefix(4))\"".utf8),
            "SourceURL": Data("https://sylvan.apple.com/test/\(id).mov".utf8),
        ], to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    /// A small already-converted video to install.
    func prepared(_ name: String = "mine.mov", colour: MediaFactory.Colour = .init(r: 20, g: 200, b: 60), frames: Int = 12) async throws -> URL {
        let url = temp.file(name)
        try await MediaFactory.solidMovie(at: url, colour: colour, frames: frames)
        return url
    }

    func indexData() throws -> Data { try Data(contentsOf: env.indexURL) }
    func index() throws -> WallpaperIndex { try WallpaperIndex.load(env.indexURL) }
    func liveHash(_ id: String = IDs.goldenGate) throws -> String { try Fingerprint.fullHash(env.videoURL(for: id)) }
}
