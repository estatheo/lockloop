import AerialKit
import Foundation

struct Commands {
    let env: Environment
    var isTerminal: Bool { isatty(STDOUT_FILENO) == 1 }

    func run(_ command: CLICommand) async throws {
        switch command {
        case .help:
            print(Copy.cliHelp)
        case .set(let file, let fit, let download, let keep):
            try await set(file: file, fit: fit, download: download, keep: keep)
        case .restore:
            switch try await Restorer(env: env).restore() {
            case .restored: print(Copy.cliRestored)
            case .nothingToRestore: print(Copy.cliNothingToRestore)
            }
        case .status(let json):
            try status(json: json)
        case .keep(let on):
            if on {
                try await Keeper(env: env).enable(programPath: Self.ownPath())
                print(Copy.cliKeepOn)
            } else {
                try await Keeper(env: env).disable()
                print(Copy.cliKeepOff)
            }
        case .reapply(let quiet):
            let outcome = try await Keeper(env: env).reapply()
            if !quiet { print("\(outcome)") }
        }
    }

    static func ownPath() -> String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func set(file: String, fit: FitMode, download: String?, keep: Bool) async throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CLIUsageError(message: Copy.cliFileNotFound(url.path)) }
        let applier = Applier(env: env)
        if let download {
            if let kind = AerialLayout.detect(env).unsupportedKind { throw LoopError.unsupportedLayout(kind) }
            let catalogue = try AerialCatalogue.load(env)
            guard let asset = catalogue.asset(id: download), asset.downloadURL != nil else {
                throw CLIUsageError(message: Copy.cliUnknownAsset(download))
            }
            let alreadyThere = AssetDiscovery.downloaded(env, catalogue: catalogue).contains { $0.asset.id == asset.id }
            if !alreadyThere {
                let terminal = isTerminal
                try await applier.download(asset) { done, total in
                    if terminal, let total, total > 0 {
                        print("\r" + Copy.cliDownloading(asset.displayName, percent: Int(Double(done) * 100 / Double(total))), terminator: "")
                    }
                }
                if isTerminal { print("") }
            }
        }
        var lastLine = ""
        let terminal = isTerminal
        let outcome = try await applier.apply(source: url, fit: fit) { phase in
            guard terminal else { return }
            let line: String
            switch phase {
            case .converting(let p):
                let percent = Int(p.fraction * 100)
                line = p.stage == .encoding ? Copy.cliConverting(percent) : Copy.cliRepeating(percent)
            case .installing:
                line = Copy.installing
            }
            if line != lastLine { print("\r\u{1B}[K" + line, terminator: ""); lastLine = line }
        }
        if terminal { print("") }
        _ = outcome
        print(Copy.cliDone)
        if keep {
            try await Keeper(env: env).enable(programPath: Self.ownPath())
            print(Copy.cliKeepOn)
        }
    }

    func status(json: Bool) throws {
        let report = try Status.compute(env)
        if json {
            print(String(decoding: try StatusReport.encoder.encode(report), as: UTF8.self))
            return
        }
        switch report.status {
        case .unsupportedLegacy: throw LoopError.unsupportedLayout(.legacy)
        case .unsupportedNone: throw LoopError.unsupportedLayout(.none)
        case .applied:
            let date = report.appliedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
            print(Copy.cliStatusApplied(report.sourceName ?? "", aerialName: report.assetName ?? "", assetID: report.assetID ?? "", date: date))
        case .appliedNotSelected: print(Copy.cliStatusOtherWallpaper)
        case .reverted: print(Copy.cliStatusReverted)
        case .missing: print(Copy.cliStatusMissing)
        case .notApplied:
            print(Copy.cliStatusNotApplied)
            print(Copy.cliDownloadedHeader)
            if report.downloaded.isEmpty { print("  " + Copy.cliNone) }
            for aerial in report.downloaded { print("  \(aerial.name) (\(aerial.id))") }
            if report.downloaded.isEmpty, let catalogue = try? AerialCatalogue.load(env) {
                print(Copy.cliDownloadableHeader)
                for asset in catalogue.downloadable { print("  \(asset.displayName) (\(asset.id))") }
            }
        }
        if report.status != .notApplied { print(Copy.cliStatusKeep(report.keepApplied)) }
    }
}
