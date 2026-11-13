import Foundation
import Testing
@testable import AerialKit

@Suite("Index.plist")
struct WallpaperIndexTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func load(_ root: [String: Any], format: PropertyListSerialization.PropertyListFormat = .binary) throws -> WallpaperIndex {
        try WallpaperIndex(data: IndexFixture.data(root, format: format))
    }

    func entries(_ index: WallpaperIndex, key: String) -> [NSDictionary] {
        var found: [NSDictionary] = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                for (k, child) in d { if k == key, let e = child as? [String: Any] { found.append(e as NSDictionary) } else { walk(child) } }
            } else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(index.root)
        return found
    }

    @Test("Edit sets the aerial on all 9 Desktop entries, with the right shape")
    func editsAllDesktops() throws {
        var index = try load(IndexFixture.observed(desktop: IndexFixture.aerial(IDs.other)))
        #expect(index.desktopPaths().count == 9)
        #expect(try index.selectAerial(assetID: IDs.goldenGate.lowercased(), now: now) == 9)
        for choice in index.desktopChoices() {
            #expect(choice.provider == WallpaperIndex.aerialsProvider)
            #expect(choice.assetID == IDs.goldenGate)
        }
        for path in index.desktopPaths() {
            let entry = index.value(at: path) as! [String: Any]
            let content = entry["Content"] as! [String: Any]
            let choices = content["Choices"] as! [[String: Any]]
            #expect(choices.count == 1)
            #expect((choices[0]["Files"] as! [Any]).isEmpty)
            #expect(choices[0]["Provider"] as? String == WallpaperIndex.aerialsProvider)
            #expect(entry["LastSet"] as? Date == now)
            #expect(entry["LastUse"] as? Date == now)
            #expect(content["EncodedOptionValues"] as? String == "$null")
        }
    }

    @Test("Idle, Linked, Type and top-level keys are untouched")
    func leavesOthersAlone() throws {
        let before = try load(IndexFixture.observed())
        var after = before
        try after.selectAerial(assetID: IDs.other, now: now)
        #expect(entries(before, key: "Idle") == entries(after, key: "Idle"))
        #expect(entries(before, key: "Idle").count == 10)
        #expect(entries(before, key: "Linked") == entries(after, key: "Linked"))
        #expect(entries(before, key: "Linked").count == 2)
        #expect(Set(before.root.keys) == Set(after.root.keys))
        #expect((after.root["SystemDefault"] as! [String: Any])["Type"] as? String == "individual")
    }

    @Test("Configuration is the 93 bytes macOS wrote for the observed asset")
    func configurationBytes() throws {
        let hex = "62706c6973743030d1010257617373657449445f1024" +
            "34323037373334442d373446452d344639322d423545312d364543384445453234413135" +
            "080b13000000000000010100000000000000030000000000000000000000000000003a"
        let expected = Data(stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
        })
        let data = try WallpaperIndex.configuration(assetID: IDs.goldenGate)
        #expect(data.count == 93)
        #expect(data == expected)
        #expect(WallpaperIndex.decodeAssetID(data) == IDs.goldenGate)
    }

    @Test("Shuffle becomes $null")
    func shuffleCleared() throws {
        let shuffled = IndexFixture.entry(provider: WallpaperIndex.aerialsProvider,
                                          configuration: try WallpaperIndex.configuration(assetID: IDs.other),
                                          shuffle: ["Type": "all"])
        var index = try load(IndexFixture.single(desktop: shuffled))
        try index.selectAerial(assetID: IDs.goldenGate, now: now)
        let content = (index.value(at: [.key("SystemDefault"), .key("Desktop")]) as! [String: Any])["Content"] as! [String: Any]
        #expect(content["Shuffle"] as? String == "$null")
    }

    @Test("The empty-string space key survives a write and read")
    func emptyKeyRoundTrip() throws {
        let temp = TempDir()
        var index = try load(IndexFixture.observed())
        try index.selectAerial(assetID: IDs.goldenGate, now: now)
        try index.write(to: temp.file("Index.plist"))
        let back = try WallpaperIndex.load(temp.file("Index.plist"))
        #expect((back.root["Spaces"] as! [String: Any])[""] != nil)
        #expect(back.paths(pointingAt: IDs.goldenGate).count == 9)
    }

    @Test("An image Desktop is replaced by the aerial")
    func imageReplaced() throws {
        var index = try load(IndexFixture.single(desktop: IndexFixture.entry(provider: "com.apple.wallpaper.choice.image", configuration: Data([1, 2, 3]))))
        try index.selectAerial(assetID: IDs.goldenGate, now: now)
        #expect(index.desktopChoices().first?.assetID == IDs.goldenGate)
    }

    @Test("Linked-only: noDesktopEntries and the file is untouched")
    func linkedOnly() async throws {
        let root = FakeRoot(index: IndexFixture.linkedOnly())
        try await root.addAerial()
        let before = try root.indexData()
        await #expect(throws: LoopError.noDesktopEntries) {
            _ = try await Applier(env: root.env).applyPrepared(try await root.prepared(), sourceName: "x", fit: .fit)
        }
        #expect(try root.indexData() == before)
    }

    @Test("Garbage: indexUnreadable and the file is untouched")
    func garbage() async throws {
        let root = FakeRoot(index: nil)
        try FileManager.default.createDirectory(at: root.env.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: root.env.indexURL)
        try await root.addAerial()
        await #expect(throws: LoopError.indexUnreadable) {
            _ = try await Applier(env: root.env).applyPrepared(try await root.prepared(), sourceName: "x", fit: .fit)
        }
        #expect(try root.indexData() == Data("not a plist".utf8))
    }

    @Test("XML stays XML, binary stays binary, mode is 0644")
    func formatAndMode() throws {
        let temp = TempDir()
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            var index = try load(IndexFixture.single(), format: format)
            try index.selectAerial(assetID: IDs.other, now: now)
            let url = temp.file("Index-\(format.rawValue).plist")
            try index.write(to: url)
            let data = try Data(contentsOf: url)
            var read = PropertyListSerialization.PropertyListFormat.binary
            _ = try PropertyListSerialization.propertyList(from: data, format: &read)
            #expect(read == format)
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
            #expect(mode == 0o644)
        }
    }

    @Test("Editing twice with the same clock gives the same bytes")
    func deterministic() throws {
        var a = try load(IndexFixture.observed())
        var b = try load(IndexFixture.observed())
        try a.selectAerial(assetID: IDs.other, now: now)
        try b.selectAerial(assetID: IDs.other, now: now)
        try b.selectAerial(assetID: IDs.other, now: now)
        #expect(try a.data() == b.data())
    }

    @Test("desktopChoices reports provider and id, nil id for an empty Configuration")
    func choices() throws {
        let index = try load(["SystemDefault": IndexFixture.individual(IndexFixture.aerial(IDs.goldenGate)),
                              "Other": IndexFixture.individual(IndexFixture.entry(provider: WallpaperIndex.aerialsProvider, configuration: Data()))])
        let choices = Dictionary(uniqueKeysWithValues: index.desktopChoices().map { ($0.pathString, $0) })
        #expect(choices["/SystemDefault/Desktop"]?.assetID == IDs.goldenGate)
        #expect(choices["/Other/Desktop"]?.provider == WallpaperIndex.aerialsProvider)
        #expect(choices["/Other/Desktop"]?.assetID == nil)
    }

    @Test("Restore copies each path back from the pre-apply backup")
    func restoreFromBackup() throws {
        let backup = try load(IndexFixture.observed(desktop: IndexFixture.aerial(IDs.other)))
        var index = backup
        try index.selectAerial(assetID: IDs.goldenGate, now: now)
        #expect(index.restoreChoices(from: backup, assetID: IDs.goldenGate, now: now) == 9)
        for c in index.desktopChoices() { #expect(c.assetID == IDs.other) }
        let entry = index.value(at: [.key("SystemDefault"), .key("Desktop")]) as! [String: Any]
        #expect(entry["LastSet"] as? Date == IndexFixture.fixedDate)
        #expect(entry["LastUse"] as? Date == now)
    }

    @Test("Restore uses SystemDefault for a path the backup lacks, and skips entries pointed elsewhere")
    func restoreFallbackAndSkip() throws {
        let backup = try load(IndexFixture.single(desktop: IndexFixture.aerial(IDs.other)))
        var index = try load(IndexFixture.observed(desktop: IndexFixture.aerial(IDs.goldenGate)))
        // The person points one display somewhere else after applying.
        let moved: PlistPath = [.key("Displays"), .key(IndexFixture.display1), .key("Desktop")]
        index.setValue(IndexFixture.entry(provider: "com.apple.wallpaper.choice.image", configuration: Data([9])), at: moved)
        #expect(index.restoreChoices(from: backup, assetID: IDs.goldenGate, now: now) == 8)
        let choices = Dictionary(uniqueKeysWithValues: index.desktopChoices().map { ($0.path, $0) })
        #expect(choices[moved]?.provider == "com.apple.wallpaper.choice.image")
        #expect(choices.values.filter { $0.assetID == IDs.other }.count == 8)
    }

    @Test("Restore with no backup changes nothing")
    func restoreNoBackup() throws {
        var index = try load(IndexFixture.observed())
        let before = try index.data()
        #expect(index.restoreChoices(from: nil, assetID: IDs.goldenGate, now: now) == 0)
        #expect(try index.data() == before)
    }

    @Test("Check after restart: one revert is retried, constant reverts give choiceNotAccepted")
    func checkAfterRestart() async throws {
        for alwaysRevert in [false, true] {
            let root = FakeRoot(index: IndexFixture.observed(desktop: IndexFixture.aerial(IDs.other)))
            try await root.addAerial(IDs.goldenGate)
            let original = try root.indexData()
            let indexURL = root.env.indexURL
            root.agent.onRestart = { n in
                if alwaysRevert || n == 1 { try! original.write(to: indexURL) }
            }
            let applier = Applier(env: root.env)
            if alwaysRevert {
                await #expect(throws: LoopError.choiceNotAccepted(assetLabel: "Golden Gate Sunset (GG_A001)")) {
                    _ = try await applier.applyPrepared(try await root.prepared(), sourceName: "mine.mov", fit: .fit)
                }
                // The files stay in place.
                #expect(try Status.compute(root.env).status == .appliedNotSelected)
            } else {
                _ = try await applier.applyPrepared(try await root.prepared(), sourceName: "mine.mov", fit: .fit)
                #expect(root.agent.restarts == 2)
                #expect(try root.index().paths(pointingAt: IDs.goldenGate).count == 9)
            }
        }
    }
}
