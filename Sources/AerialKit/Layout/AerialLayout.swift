import Foundation

/// Where this Mac keeps Apple's moving wallpapers. Decided by which folders exist,
/// not by the macOS version number.
public enum AerialLayout: Equatable, Sendable {
    /// macOS 26 and later: in the person's own Library. Supported.
    case modern
    /// macOS 14 and 15: under /Library, needs an administrator. Detected and declined.
    case legacy
    case none

    public static func detect(_ env: Environment) -> AerialLayout {
        let fm = FileManager.default
        if fm.fileExists(atPath: env.entriesURL.path) { return .modern }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: env.legacyCustomerDir.path, isDirectory: &isDir), isDir.boolValue { return .legacy }
        return .none
    }

    public var unsupportedKind: AerialLayoutKind? {
        switch self {
        case .modern: return nil
        case .legacy: return .legacy
        case .none: return AerialLayoutKind.none
        }
    }
}
