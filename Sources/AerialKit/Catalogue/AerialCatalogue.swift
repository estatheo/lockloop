import Foundation

/// One of Apple's moving wallpapers, as listed in entries.json.
public struct AerialAsset: Equatable, Sendable {
    public let id: String
    public let accessibilityLabel: String?
    public let shotID: String?
    public let preferredOrder: Int?
    /// Only set when the URL is https on sylvan.apple.com.
    public let downloadURL: URL?
    /// The name to show. Set by the catalogue so duplicates are told apart.
    public internal(set) var displayName: String

    public init(id: String, accessibilityLabel: String?, shotID: String?, preferredOrder: Int?, rawURL: String?) {
        self.id = id.uppercased()
        self.accessibilityLabel = accessibilityLabel
        self.shotID = shotID
        self.preferredOrder = preferredOrder
        self.downloadURL = AerialAsset.acceptedURL(rawURL)
        self.displayName = accessibilityLabel ?? shotID ?? self.id
    }

    public static let allowedHost = "sylvan.apple.com"

    static func acceptedURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == allowedHost else { return nil }
        return url
    }
}

private struct RawAsset: Decodable {
    let id: String
    let accessibilityLabel: String?
    let shotID: String?
    let preferredOrder: Int?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, accessibilityLabel, shotID, preferredOrder
        case url = "url-4K-SDR-240FPS"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accessibilityLabel = try? c.decodeIfPresent(String.self, forKey: .accessibilityLabel)
        shotID = try? c.decodeIfPresent(String.self, forKey: .shotID)
        preferredOrder = try? c.decodeIfPresent(Int.self, forKey: .preferredOrder)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
    }
}

/// Decodes one element, or nil, so one bad asset doesn't sink the list.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct RawCatalogue: Decodable {
    let assets: [Lenient<RawAsset>]
}

public struct AerialCatalogue: Sendable {
    public let assets: [AerialAsset]

    public init(assets: [AerialAsset]) {
        var assets = assets
        var labelCounts: [String: Int] = [:]
        for asset in assets { if let l = asset.accessibilityLabel { labelCounts[l, default: 0] += 1 } }
        for i in assets.indices {
            if let label = assets[i].accessibilityLabel, labelCounts[label, default: 0] > 1, let shot = assets[i].shotID {
                assets[i].displayName = "\(label) (\(shot))"
            }
        }
        self.assets = assets
    }

    public init(data: Data) throws {
        guard let raw = try? JSONDecoder().decode(RawCatalogue.self, from: data) else {
            throw LoopError.catalogueUnreadable
        }
        let assets = raw.assets.compactMap(\.value).filter { !$0.id.isEmpty }.map {
            AerialAsset(id: $0.id, accessibilityLabel: $0.accessibilityLabel, shotID: $0.shotID,
                        preferredOrder: $0.preferredOrder, rawURL: $0.url)
        }
        self.init(assets: assets)
    }

    public static func load(_ env: Environment) throws -> AerialCatalogue {
        let data: Data
        do { data = try Data(contentsOf: env.entriesURL) } catch {
            let wrapped = LoopError.wrap(error, path: env.entriesURL)
            if wrapped is LoopError { throw wrapped }
            throw LoopError.catalogueUnreadable
        }
        return try AerialCatalogue(data: data)
    }

    public func asset(id: String) -> AerialAsset? {
        let upper = id.uppercased()
        return assets.first { $0.id == upper }
    }

    /// Assets that can be downloaded, in Apple's preferred order.
    public var downloadable: [AerialAsset] {
        assets.filter { $0.downloadURL != nil }
            .sorted { ($0.preferredOrder ?? Int.max, $0.displayName) < ($1.preferredOrder ?? Int.max, $1.displayName) }
    }
}
