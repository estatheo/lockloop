import Foundation

/// An aerial whose video file is on this Mac.
public struct DownloadedAsset: Equatable, Sendable {
    public let asset: AerialAsset
    public let fileURL: URL
    public let modified: Date
}

public enum TargetChoice: Equatable, Sendable {
    case asset(DownloadedAsset)
    case needsDownload
}

public enum AssetDiscovery {
    /// Videos in aerials/videos whose name matches a catalogue id. Nothing else in that folder is read.
    public static func downloaded(_ env: Environment, catalogue: AerialCatalogue) -> [DownloadedAsset] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: env.videosDir.path) else { return [] }
        var result: [DownloadedAsset] = []
        for name in names {
            let url = env.videosDir.appendingPathComponent(name)
            guard url.pathExtension.lowercased() == "mov" else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard let asset = catalogue.asset(id: stem) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? Int64, size >= env.minimumAerialBytes else { continue }
            let modified = attrs[.modificationDate] as? Date ?? .distantPast
            result.append(DownloadedAsset(asset: asset, fileURL: url, modified: modified))
        }
        return result.sorted { $0.modified > $1.modified }
    }

    /// Picks the one aerial Lockloop will replace, in the order the plan sets out.
    public static func chooseTarget(_ env: Environment, catalogue: AerialCatalogue, state: AppState?, index: WallpaperIndex?) -> TargetChoice {
        let downloaded = downloaded(env, catalogue: catalogue)
        if let state, let match = downloaded.first(where: { $0.asset.id == state.assetID.uppercased() }) {
            return .asset(match)
        }
        if let current = index?.currentAerialAssetID(), let match = downloaded.first(where: { $0.asset.id == current }) {
            return .asset(match)
        }
        if let newest = downloaded.first { return .asset(newest) }
        return .needsDownload
    }

    /// The live video for an asset id, matching the file name without regard to case.
    public static func liveVideoURL(_ env: Environment, assetID: String) -> URL {
        let upper = assetID.uppercased()
        if let names = try? FileManager.default.contentsOfDirectory(atPath: env.videosDir.path),
           let match = names.first(where: { ($0 as NSString).deletingPathExtension.uppercased() == upper && ($0 as NSString).pathExtension.lowercased() == "mov" }) {
            return env.videosDir.appendingPathComponent(match)
        }
        return env.videoURL(for: upper)
    }
}
