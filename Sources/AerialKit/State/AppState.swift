import Foundation

public enum FitMode: String, Codable, CaseIterable, Sendable { case fit, fill }

/// What Lockloop has changed, kept in state.json in the support folder.
public struct AppState: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public struct Original: Codable, Equatable, Sendable {
        public var fingerprint: String
        public var size: Int64
        public var xattrs: [String: Data]
    }

    public struct Installed: Codable, Equatable, Sendable {
        public var fingerprint: String
        public var sourceName: String
        public var fit: FitMode
        public var appliedAt: Date
    }

    public var schema: Int = AppState.currentSchema
    public var assetID: String
    public var assetLabel: String
    public var original: Original?
    public var installed: Installed?
    public var everInstalled: [String] = []
    public var keepApplied: Bool = false
    public var needsAttention: String?

    public init(assetID: String, assetLabel: String) {
        self.assetID = assetID
        self.assetLabel = assetLabel
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum StateStore {
    /// Nil when there is no state file. Refuses a schema it doesn't know, without touching the file.
    public static func load(_ env: Environment) throws -> AppState? {
        guard FileManager.default.fileExists(atPath: env.stateURL.path) else { return nil }
        let data = try Data(contentsOf: env.stateURL)
        struct Header: Decodable { let schema: Int }
        guard let header = try? AppState.decoder.decode(Header.self, from: data) else {
            throw LoopError.stateUnreadable("state.json")
        }
        guard header.schema == AppState.currentSchema else {
            throw LoopError.stateUnreadable("state.json schema \(header.schema)")
        }
        do { return try AppState.decoder.decode(AppState.self, from: data) } catch {
            throw LoopError.stateUnreadable(error.localizedDescription)
        }
    }

    public static func save(_ state: AppState, _ env: Environment) throws {
        try FileManager.default.createDirectory(at: env.supportDir, withIntermediateDirectories: true)
        try AppState.encoder.encode(state).write(to: env.stateURL, options: .atomic)
    }

    public static func delete(_ env: Environment) throws {
        if FileManager.default.fileExists(atPath: env.stateURL.path) {
            try FileManager.default.removeItem(at: env.stateURL)
        }
    }
}
