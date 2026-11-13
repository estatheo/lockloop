import Foundation

/// One step in a path through the Index.plist tree.
public enum PlistPathElement: Hashable, Sendable, CustomStringConvertible {
    case key(String)
    case index(Int)
    public var description: String {
        switch self {
        case .key(let k): return "/\(k.isEmpty ? "\"\"" : k)"
        case .index(let i): return "[\(i)]"
        }
    }
}

public typealias PlistPath = [PlistPathElement]

public struct DesktopChoice: Equatable, Sendable {
    public let path: PlistPath
    public let provider: String?
    /// Set for aerial choices whose Configuration decodes.
    public let assetID: String?

    public var pathString: String { path.map(\.description).joined() }
}

/// Reads, edits and writes ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist.
public struct WallpaperIndex {
    public static let aerialsProvider = "com.apple.wallpaper.choice.aerials"
    public static let nullString = "$null"

    public private(set) var root: [String: Any]
    public let format: PropertyListSerialization.PropertyListFormat

    public init(data: Data) throws {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format),
              let dict = object as? [String: Any] else {
            throw LoopError.indexUnreadable
        }
        self.root = dict
        self.format = format
    }

    public static func load(_ url: URL) throws -> WallpaperIndex {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            let wrapped = LoopError.wrap(error, path: url)
            if wrapped is LoopError { throw wrapped }
            throw LoopError.indexUnreadable
        }
        return try WallpaperIndex(data: data)
    }

    public func data() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: Self.canonical(root), format: format, options: 0)
    }

    /// Rebuilds dictionaries with keys inserted in sorted order, so equal trees give equal bytes.
    static func canonical(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            let out = NSMutableDictionary(capacity: dict.count)
            for key in dict.keys.sorted() { out[key] = canonical(dict[key]!) }
            return out
        }
        if let array = value as? [Any] { return NSArray(array: array.map(canonical)) }
        return value
    }

    /// Serialises, checks the bytes parse back with the same Desktop choices, then writes atomically with mode 0644.
    public func write(to url: URL) throws {
        let bytes = try data()
        let reparsed = try WallpaperIndex(data: bytes)
        guard reparsed.desktopChoices() == desktopChoices() else { throw LoopError.indexUnreadable }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch {
            throw LoopError.wrap(error, path: url)
        }
    }

    // MARK: Walking

    /// Every `Desktop` entry whose value is a dictionary with a `Content` dictionary. Found by shape, at any depth.
    public func desktopPaths() -> [PlistPath] {
        var found: [PlistPath] = []
        func walk(_ value: Any, _ path: PlistPath) {
            if let dict = value as? [String: Any] {
                for key in dict.keys.sorted() {
                    let child = dict[key]!
                    let childPath = path + [.key(key)]
                    if key == "Desktop", let entry = child as? [String: Any], entry["Content"] is [String: Any] {
                        found.append(childPath)
                    } else {
                        walk(child, childPath)
                    }
                }
            } else if let array = value as? [Any] {
                for (i, child) in array.enumerated() { walk(child, path + [.index(i)]) }
            }
        }
        walk(root, [])
        return found
    }

    public func value(at path: PlistPath) -> Any? {
        var current: Any = root
        for element in path {
            switch element {
            case .key(let k):
                guard let dict = current as? [String: Any], let next = dict[k] else { return nil }
                current = next
            case .index(let i):
                guard let array = current as? [Any], array.indices.contains(i) else { return nil }
                current = array[i]
            }
        }
        return current
    }

    public mutating func setValue(_ value: Any, at path: PlistPath) {
        func set(_ container: Any, _ rest: ArraySlice<PlistPathElement>) -> Any {
            guard let first = rest.first else { return value }
            switch first {
            case .key(let k):
                var dict = container as? [String: Any] ?? [:]
                dict[k] = set(dict[k] as Any, rest.dropFirst())
                return dict
            case .index(let i):
                var array = container as? [Any] ?? []
                guard array.indices.contains(i) else { return array }
                array[i] = set(array[i], rest.dropFirst())
                return array
            }
        }
        root = set(root, path[...]) as! [String: Any]
    }

    // MARK: Reading the choice

    public func desktopChoices() -> [DesktopChoice] {
        desktopPaths().map { path in
            let entry = value(at: path) as? [String: Any]
            let content = entry?["Content"] as? [String: Any]
            let choice = (content?["Choices"] as? [Any])?.first as? [String: Any]
            let provider = choice?["Provider"] as? String
            var assetID: String?
            if provider == Self.aerialsProvider, let config = choice?["Configuration"] as? Data {
                assetID = Self.decodeAssetID(config)
            }
            return DesktopChoice(path: path, provider: provider, assetID: assetID)
        }
    }

    public static func decodeAssetID(_ configuration: Data) -> String? {
        guard !configuration.isEmpty,
              let object = try? PropertyListSerialization.propertyList(from: configuration, options: [], format: nil),
              let dict = object as? [String: Any], let id = dict["assetID"] as? String else { return nil }
        return id.uppercased()
    }

    public static func configuration(assetID: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID.uppercased()], format: .binary, options: 0)
    }

    /// Paths of Desktop entries that point at the asset.
    public func paths(pointingAt assetID: String) -> [PlistPath] {
        desktopChoices().filter { $0.assetID == assetID.uppercased() }.map(\.path)
    }

    /// The aerial chosen at /SystemDefault/Desktop, else the most common aerial across all Desktop entries.
    public func currentAerialAssetID() -> String? {
        let choices = desktopChoices()
        if let system = choices.first(where: { $0.path == [.key("SystemDefault"), .key("Desktop")] }), let id = system.assetID {
            return id
        }
        var counts: [String: Int] = [:]
        for c in choices { if let id = c.assetID { counts[id, default: 0] += 1 } }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    // MARK: Editing

    /// Points every Desktop entry at the aerial. Idle, Linked and Type are left as they were.
    @discardableResult
    public mutating func selectAerial(assetID: String, now: Date) throws -> Int {
        let paths = desktopPaths()
        guard !paths.isEmpty else { throw LoopError.noDesktopEntries }
        let configuration = try Self.configuration(assetID: assetID)
        for path in paths {
            var entry = value(at: path) as! [String: Any]
            var content = entry["Content"] as! [String: Any]
            content["Choices"] = [[
                "Configuration": configuration,
                "Files": [Any](),
                "Provider": Self.aerialsProvider,
            ] as [String: Any]]
            content["Shuffle"] = Self.nullString
            entry["Content"] = content
            entry["LastSet"] = now
            entry["LastUse"] = now
            setValue(entry, at: path)
        }
        return paths.count
    }

    /// Puts back the pre-apply choice on every Desktop entry that still points at the asset.
    /// Entries the person has since changed are left alone. Returns how many were restored.
    @discardableResult
    public mutating func restoreChoices(from backup: WallpaperIndex?, assetID: String, now: Date) -> Int {
        guard let backup else { return 0 }
        let systemPath: PlistPath = [.key("SystemDefault"), .key("Desktop")]
        var restored = 0
        for path in paths(pointingAt: assetID) {
            let source = (backup.value(at: path) as? [String: Any]).flatMap { $0["Content"] is [String: Any] ? $0 : nil }
                ?? (backup.value(at: systemPath) as? [String: Any]).flatMap { $0["Content"] is [String: Any] ? $0 : nil }
            guard let source else { continue }
            var entry = value(at: path) as! [String: Any]
            entry["Content"] = source["Content"]
            if let lastSet = source["LastSet"] { entry["LastSet"] = lastSet }
            entry["LastUse"] = now
            setValue(entry, at: path)
            restored += 1
        }
        return restored
    }
}
