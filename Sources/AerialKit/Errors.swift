import Foundation

public enum AerialLayoutKind: String, Codable, Sendable { case legacy, none }

/// One case per failure the person can meet. The words for each are in `Copy`.
public enum LoopError: Error, Equatable, Sendable {
    case unsupportedLayout(AerialLayoutKind)
    case catalogueUnreadable
    case indexUnreadable
    case noDesktopEntries
    case permissionDenied(path: String, detail: String)
    case needsDownload
    case downloadFailed(String)
    case unsupportedFile(filename: String)
    case noPicture(filename: String)
    case protectedFile(filename: String)
    case unreadableFile(filename: String)
    case notEnoughSpace(needed: Int64, free: Int64)
    case conversionFailed(filename: String, detail: String)
    case cancelled
    case swapFailed(String)
    case rollbackFailed(originalPath: String)
    case choiceNotAccepted(assetLabel: String)
    case originalMissing
    case busy
    case keeperFailed(String)
    case stateUnreadable(String)

    public static let allCaseSamples: [LoopError] = [
        .unsupportedLayout(.legacy), .unsupportedLayout(.none), .catalogueUnreadable, .indexUnreadable,
        .noDesktopEntries, .permissionDenied(path: "/x", detail: "detail"), .needsDownload,
        .downloadFailed("detail"), .unsupportedFile(filename: "a.txt"), .noPicture(filename: "a.m4a"),
        .protectedFile(filename: "a.m4v"), .unreadableFile(filename: "a.mp4"),
        .notEnoughSpace(needed: 2_000_000_000, free: 1_000_000_000),
        .conversionFailed(filename: "a.mp4", detail: "detail"), .cancelled, .swapFailed("detail"),
        .rollbackFailed(originalPath: "/x/y.mov"), .choiceNotAccepted(assetLabel: "Golden Gate"),
        .originalMissing, .busy, .keeperFailed("detail"), .stateUnreadable("detail"),
    ]

    public var message: String { Copy.message(for: self) }

    /// Wraps a Cocoa or POSIX permission error, passes anything else through.
    static func wrap(_ error: Error, path: URL) -> Error {
        if error is LoopError { return error }
        let ns = error as NSError
        let posix: Int32? = {
            if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain { return Int32(underlying.code) }
            return nil
        }()
        if posix == EPERM || posix == EACCES || (ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError)) {
            return LoopError.permissionDenied(path: path.path, detail: ns.localizedDescription)
        }
        return error
    }
}

extension LoopError: LocalizedError {
    public var errorDescription: String? { message }
}
