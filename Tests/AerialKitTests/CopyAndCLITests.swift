import Foundation
import Testing
@testable import AerialKit

@Suite("Copy, CLI and environment")
struct CopyAndCLITests {
    static let copySource: String = {
        let here = URL(fileURLWithPath: #filePath)
        let url = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AerialKit/Copy.swift")
        return try! String(contentsOf: url, encoding: .utf8)
    }()

    /// Every string literal in Copy.swift.
    static var literals: [String] {
        let regex = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        let ns = copySource as NSString
        let multi = copySource.components(separatedBy: "\"\"\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        return regex.matches(in: copySource, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) } + multi
    }

    static var rendered: [String] {
        LoopError.allCaseSamples.map(\.message) + [
            Copy.aboutText, Copy.dropHeading, Copy.dropHelp, Copy.fitHelp, Copy.fillHelp, Copy.sameShapeHelp, Copy.longerThanFive,
            Copy.noteFirstApply("Golden Gate"), Copy.noteFirstApplyUnknown, Copy.noteAlreadyApplied, Copy.needsAerialHeading,
            Copy.needsAerialBody, Copy.needsAerialOtherRoute, Copy.noDownloadableAerials, Copy.installingHelp,
            Copy.keepAppliedHelp, Copy.keepAppliedJustOn, Copy.revertedBody, Copy.revertedCopyGone, Copy.otherWallpaperBody("Golden Gate"),
            Copy.restored, Copy.nothingToRestoreApp, Copy.cliHelp, Copy.cliKeepOn, Copy.cliStatusReverted, Copy.cliStatusMissing,
            Copy.downloading("Golden Gate", done: 1_000_000, total: 600_000_000), Copy.downloadButton(size: 605_456_066),
        ]
    }

    @Test("No em dash, en dash or double hyphen in any user-facing string")
    func dashes() {
        for text in Self.literals + Self.rendered {
            #expect(!text.contains("\u{2014}"), "\(text)")
            #expect(!text.contains("\u{2013}"), "\(text)")
            let withoutFlags = text.replacingOccurrences(of: #"--[a-z]"#, with: "", options: .regularExpression)
            #expect(!withoutFlags.contains("--"), "\(text)")
        }
    }

    @Test("No banned CTA words or buzzwords")
    func bannedWords() {
        let banned = ["get started", "learn more", "try now", "explore", "discover", "ai powered", "ai-powered", "next generation",
                      "revolutionary", "seamless", "cutting edge", "cutting-edge", "intelligent", "ultimate", "powerful", "effortless",
                      "magic", "simply", "just "]
        for text in Self.rendered + Self.literals {
            let lower = text.lowercased()
            for word in banned { #expect(!lower.contains(word), "\(word) in \(text)") }
        }
    }

    @Test("Every error has a message with no unfilled placeholders")
    func errorMessages() {
        for error in LoopError.allCaseSamples {
            let m = error.message
            #expect(!m.isEmpty)
            #expect(!m.contains("{") && !m.contains("}"), "\(m)")
        }
    }

    @Test("The product name only appears in Copy.swift through Brand")
    func brandOnly() {
        #expect(!Self.copySource.contains(Brand.displayName))
        #expect(!Self.copySource.contains("\"\(Brand.cliName)") && !Self.copySource.contains(" \(Brand.cliName) "))
    }

    @Test("CLI parsing")
    func parsing() throws {
        #expect(try CLIArguments.parse([]) == .help)
        #expect(try CLIArguments.parse(["help"]) == .help)
        #expect(try CLIArguments.parse(["set", "a.gif"]) == .set(file: "a.gif", fit: .fit, download: nil, keep: false))
        #expect(try CLIArguments.parse(["set", "--fill", "a.gif", "--keep"]) == .set(file: "a.gif", fit: .fill, download: nil, keep: true))
        #expect(try CLIArguments.parse(["set", "a.mp4", "--download", IDs.goldenGate]) == .set(file: "a.mp4", fit: .fit, download: IDs.goldenGate, keep: false))
        #expect(try CLIArguments.parse(["restore"]) == .restore)
        #expect(try CLIArguments.parse(["status"]) == .status(json: false))
        #expect(try CLIArguments.parse(["status", "--json"]) == .status(json: true))
        #expect(try CLIArguments.parse(["keep", "on"]) == .keep(on: true))
        #expect(try CLIArguments.parse(["keep", "off"]) == .keep(on: false))
        #expect(try CLIArguments.parse(["reapply", "--quiet"]) == .reapply(quiet: true))
        for bad in [["set"], ["set", "a.gif", "--wobble"], ["set", "a.gif", "--download"], ["keep"], ["keep", "maybe"], ["frobnicate"], ["restore", "now"]] {
            #expect(throws: CLIUsageError.self, "\(bad)") { try CLIArguments.parse(bad) }
        }
    }

    @Test("Exit codes")
    func exitCodes() {
        #expect(CLIExit.code(for: LoopError.unsupportedLayout(.legacy)) == 3)
        #expect(CLIExit.code(for: LoopError.needsDownload) == 4)
        #expect(CLIExit.code(for: LoopError.busy) == 1)
        #expect(CLIExit.usage == 2)
    }

    @Test("status --json decodes back")
    func statusJSON() async throws {
        let root = FakeRoot()
        try await root.addAerial()
        let report = try Status.compute(root.env)
        let data = try StatusReport.encoder.encode(report)
        #expect(try StatusReport.decoder.decode(StatusReport.self, from: data) == report)
        #expect(report.downloaded.map(\.id) == [IDs.goldenGate])
    }

    @Test("LOCKLOOP_ROOT points every path inside it and switches off side effects")
    func sandbox() {
        let env = Environment.live(processEnvironment: [Brand.rootOverrideVariable: "/tmp/ll-test-root"])
        #expect(env.isSandboxed)
        let root = URL(fileURLWithPath: "/tmp/ll-test-root").standardizedFileURL.path
        for url in [env.home, env.systemRoot, env.supportDir, env.launchAgentsDir, env.indexURL, env.videosDir, env.entriesURL, env.legacyCustomerDir, env.stateURL, env.keeperPlistURL] {
            #expect(url.standardizedFileURL.path.hasPrefix(root), "\(url.path)")
        }
        #expect(env.agent is NoopWallpaperAgent)
        #expect(env.launchd is NoopLaunchd)
        #expect(!Environment.live(processEnvironment: [:]).isSandboxed)
    }
}
