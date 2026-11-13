import Foundation

public enum LoopStatus: String, Codable, Equatable, Sendable {
    case unsupportedLegacy, unsupportedNone, notApplied, applied, appliedNotSelected, reverted, missing
}

public struct StatusReport: Codable, Equatable, Sendable {
    public struct Aerial: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
    }

    public var status: LoopStatus
    public var assetID: String?
    public var assetName: String?
    public var sourceName: String?
    public var appliedAt: Date?
    public var keepApplied: Bool
    public var needsAttention: String?
    public var currentCopyExists: Bool
    public var downloaded: [Aerial]

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Works out the current status from the disk alone.
public enum Status {
    public static func compute(_ env: Environment) throws -> StatusReport {
        let layout = AerialLayout.detect(env)
        var report = StatusReport(status: .notApplied, keepApplied: false, currentCopyExists: false, downloaded: [])
        switch layout {
        case .legacy: report.status = .unsupportedLegacy; return report
        case .none: report.status = .unsupportedNone; return report
        case .modern: break
        }
        let catalogue = try? AerialCatalogue.load(env)
        if let catalogue {
            report.downloaded = AssetDiscovery.downloaded(env, catalogue: catalogue).map { .init(id: $0.asset.id, name: $0.asset.displayName) }
        }
        guard let state = try StateStore.load(env) else { return report }
        report.assetID = state.assetID
        report.assetName = catalogue?.asset(id: state.assetID)?.displayName ?? state.assetLabel
        report.keepApplied = state.keepApplied
        report.needsAttention = state.needsAttention
        report.currentCopyExists = FileManager.default.fileExists(atPath: env.currentURL(for: state.assetID).path)
        guard let installed = state.installed else { return report }
        report.sourceName = installed.sourceName
        report.appliedAt = installed.appliedAt

        let live = AssetDiscovery.liveVideoURL(env, assetID: state.assetID)
        guard let liveFP = Fingerprint.ofIfPresent(live) else { report.status = .missing; return report }
        guard liveFP == installed.fingerprint || Swap.isOurs(live, fingerprint: liveFP, state: state) else {
            report.status = .reverted
            return report
        }
        if let index = try? WallpaperIndex.load(env.indexURL), index.paths(pointingAt: state.assetID).isEmpty {
            report.status = .appliedNotSelected
        } else {
            report.status = .applied
        }
        return report
    }
}
