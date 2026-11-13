import CryptoKit
import Foundation

/// File size plus the SHA-256 of the first and last MiB. Fast on a 600 MB file.
public enum Fingerprint {
    static let chunk = 1 << 20

    public static func of(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
        if size > UInt64(chunk) {
            try handle.seek(toOffset: size - UInt64(min(UInt64(chunk), size)))
            hasher.update(data: try handle.read(upToCount: chunk) ?? Data())
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(size):\(hex)"
    }

    public static func ofIfPresent(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? of(url)
    }

    /// Full SHA-256, for tests and final checks.
    public static func fullHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Extended attributes the aerials extension stores on each video.
public enum ExtendedAttributes {
    public static let carried = ["LastETag", "SourceURL"]

    public static func read(_ url: URL, names: [String] = carried) -> [String: Data] {
        var result: [String: Data] = [:]
        for name in names {
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { continue }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            if read >= 0 { result[name] = data.prefix(read) }
        }
        return result
    }

    public static func write(_ attributes: [String: Data], to url: URL) throws {
        for (name, value) in attributes {
            let status = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
            if status != 0 { throw LoopError.wrap(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), path: url) }
        }
    }
}
