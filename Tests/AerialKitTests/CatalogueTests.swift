import Foundation
import Testing
@testable import AerialKit

@Suite("Catalogue and discovery")
struct CatalogueTests {
    func catalogue() throws -> AerialCatalogue {
        try AerialCatalogue(data: Data(contentsOf: fixtureURL("entries-small.json")))
    }

    @Test("The small catalogue decodes and skips the malformed asset")
    func decodes() throws {
        let c = try catalogue()
        #expect(c.assets.count == 5)
        #expect(c.asset(id: IDs.goldenGateB.lowercased())?.id == IDs.goldenGateB)
        #expect(c.asset(id: IDs.noLabel)?.accessibilityLabel == nil)
        #expect(c.asset(id: IDs.noLabel)?.displayName == "NL_E005")
    }

    @Test("Garbage is catalogueUnreadable")
    func garbage() {
        #expect(throws: LoopError.catalogueUnreadable) { try AerialCatalogue(data: Data("{".utf8)) }
    }

    @Test("Only https URLs on Apple's host are downloadable")
    func hosts() throws {
        let c = try catalogue()
        #expect(c.asset(id: IDs.goldenGate)?.downloadURL != nil)
        #expect(c.asset(id: IDs.noURL)?.downloadURL == nil)
        #expect(c.asset(id: IDs.foreignHost)?.downloadURL == nil)
        #expect(AerialAsset.acceptedURL("http://sylvan.apple.com/a.mov") == nil)
        #expect(AerialAsset.acceptedURL("https://sylvan.apple.com.evil.com/a.mov") == nil)
        #expect(c.downloadable.map(\.id) == [IDs.goldenGateB, IDs.goldenGate, IDs.noLabel])
    }

    @Test("Duplicate labels get the shot id")
    func duplicates() throws {
        let c = try catalogue()
        #expect(c.asset(id: IDs.goldenGate)?.displayName == "Golden Gate Sunset (GG_A001)")
        #expect(c.asset(id: IDs.goldenGateB)?.displayName == "Golden Gate Sunset (GG_B002)")
        #expect(c.asset(id: IDs.noURL)?.displayName == "Desert Night")
    }

    @Test("Layout detection by folder")
    func layout() throws {
        let modern = FakeRoot()
        #expect(AerialLayout.detect(modern.env) == .modern)
        try FileManager.default.createDirectory(at: modern.env.legacyCustomerDir, withIntermediateDirectories: true)
        #expect(AerialLayout.detect(modern.env) == .modern)

        let legacy = FakeRoot(entries: false)
        try FileManager.default.createDirectory(at: legacy.env.legacyCustomerDir, withIntermediateDirectories: true)
        #expect(AerialLayout.detect(legacy.env) == .legacy)

        let none = FakeRoot(entries: false)
        #expect(AerialLayout.detect(none.env) == .none)
    }

    @Test("Downloaded set: real catalogue videos only")
    func downloadedSet() async throws {
        let root = FakeRoot()
        let fm = FileManager.default
        try await root.addAerial(IDs.goldenGate)
        // Lower-case name still matches.
        try await MediaFactory.solidMovie(at: root.env.videosDir.appendingPathComponent("\(IDs.goldenGateB.lowercased()).mov"), colour: .init(r: 1, g: 2, b: 3))
        // Excluded: symlink, tiny file, unknown id, .mp4.
        try fm.createSymbolicLink(at: root.env.videoURL(for: IDs.noURL), withDestinationURL: root.env.videoURL(for: IDs.goldenGate))
        try Data(count: 10).write(to: root.env.videoURL(for: IDs.foreignHost))
        try await MediaFactory.solidMovie(at: root.env.videoURL(for: IDs.other), colour: .init(r: 1, g: 2, b: 3))
        try await MediaFactory.solidMovie(at: root.env.videosDir.appendingPathComponent("\(IDs.noLabel).mp4"), colour: .init(r: 1, g: 2, b: 3))

        let c = try AerialCatalogue.load(root.env)
        let ids = Set(AssetDiscovery.downloaded(root.env, catalogue: c).map(\.asset.id))
        #expect(ids == [IDs.goldenGate, IDs.goldenGateB])
    }

    @Test("Target choice follows the order: state, desktop, newest, needsDownload")
    func targetChoice() async throws {
        let root = FakeRoot(index: IndexFixture.observed(desktop: IndexFixture.aerial(IDs.goldenGateB)))
        let c = try AerialCatalogue.load(root.env)
        let index = try root.index()
        #expect(AssetDiscovery.chooseTarget(root.env, catalogue: c, state: nil, index: index) == .needsDownload)

        try await root.addAerial(IDs.goldenGate, modified: Date(timeIntervalSince1970: 1_000))
        try await root.addAerial(IDs.noLabel, modified: Date(timeIntervalSince1970: 2_000))
        func chosen(_ state: AppState?) -> String? {
            if case .asset(let a) = AssetDiscovery.chooseTarget(root.env, catalogue: c, state: state, index: index) { return a.asset.id }
            return nil
        }
        #expect(chosen(nil) == IDs.noLabel)  // newest
        try await root.addAerial(IDs.goldenGateB, modified: Date(timeIntervalSince1970: 500))
        #expect(chosen(nil) == IDs.goldenGateB)  // the current desktop choice
        #expect(chosen(AppState(assetID: IDs.goldenGate, assetLabel: "x")) == IDs.goldenGate)  // state
        // A state asset whose file is gone is ignored.
        #expect(chosen(AppState(assetID: IDs.noURL, assetLabel: "x")) == IDs.goldenGateB)
    }
}

// MARK: Downloader against a local stub

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var declaredLength: Int?
    nonisolated(unsafe) static var chunkDelay: useconds_t = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let length = Self.declaredLength ?? Self.body.count
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(length)", "ETag": "\"STUB-ETAG\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod == "HEAD" { client?.urlProtocolDidFinishLoading(self); return }
        let chunk = max(1, Self.body.count / 8)
        var offset = 0
        while offset < Self.body.count {
            let end = min(Self.body.count, offset + chunk)
            client?.urlProtocol(self, didLoad: Self.body.subdata(in: offset..<end))
            offset = end
            if Self.chunkDelay > 0 { usleep(Self.chunkDelay) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Downloader", .serialized)
struct DownloaderTests {
    func stubbedEnv(_ root: FakeRoot) -> Environment {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        var env = root.env
        env.downloader = AssetDownloader(configuration: config)
        return env
    }

    @Test("Download: progress, xattrs, mode 0600, size check")
    func download() async throws {
        let root = FakeRoot()
        let source = try await root.prepared("apple.mov", frames: 40)
        StubProtocol.body = try Data(contentsOf: source)
        StubProtocol.declaredLength = nil
        StubProtocol.chunkDelay = 0
        let env = stubbedEnv(root)
        let asset = try AerialCatalogue.load(env).asset(id: IDs.goldenGate)!
        #expect(await env.downloader.contentLength(of: asset.downloadURL!) == Int64(StubProtocol.body.count))

        final class Box: @unchecked Sendable { var calls: [Int64] = [] }
        let box = Box()
        try await Applier(env: env).download(asset) { done, _ in box.calls.append(done) }
        let dest = env.videoURL(for: asset.id)
        #expect(try Data(contentsOf: dest) == StubProtocol.body)
        #expect(!box.calls.isEmpty)
        let xattrs = ExtendedAttributes.read(dest)
        #expect(xattrs["LastETag"] == Data("\"STUB-ETAG\"".utf8))
        #expect(xattrs["SourceURL"] == Data(asset.downloadURL!.absoluteString.utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: dest.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.workDir.path).isEmpty)
    }

    @Test("A body that isn't a video fails and leaves nothing in videos/")
    func badBody() async throws {
        let root = FakeRoot()
        StubProtocol.body = Data(repeating: 7, count: 5000)
        StubProtocol.declaredLength = nil
        let env = stubbedEnv(root)
        let asset = try AerialCatalogue.load(env).asset(id: IDs.goldenGate)!
        await #expect(throws: LoopError.self) { try await Applier(env: env).download(asset) { _, _ in } }
        #expect(!FileManager.default.fileExists(atPath: env.videoURL(for: asset.id).path))
    }

    @Test("Cancel leaves nothing in videos/")
    func cancel() async throws {
        let root = FakeRoot()
        StubProtocol.body = Data(repeating: 7, count: 400_000)
        StubProtocol.declaredLength = nil
        StubProtocol.chunkDelay = 100_000
        defer { StubProtocol.chunkDelay = 0 }
        let env = stubbedEnv(root)
        let asset = try AerialCatalogue.load(env).asset(id: IDs.goldenGate)!
        let task = Task { try await Applier(env: env).download(asset) { _, _ in } }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: env.videoURL(for: asset.id).path))
    }
}
