import AVFoundation
import Foundation

public struct DownloadResult: Sendable {
    public let file: URL
    public let etag: String?
    public let expectedLength: Int64?
}

/// Fetches a file over HTTPS with progress. Cancel by cancelling the Swift task.
public protocol AerialDownloading: Sendable {
    func contentLength(of url: URL) async -> Int64?
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> DownloadResult
}

public final class AssetDownloader: NSObject, AerialDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func contentLength(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let length = http.expectedContentLength
        return length > 0 ? length : nil
    }

    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> DownloadResult {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Int64, Int64?) -> Void
    var continuation: CheckedContinuation<DownloadResult, Error>?
    private var result: DownloadResult?
    private var failure: Error?

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let http = downloadTask.response as? HTTPURLResponse
        guard let http, http.statusCode == 200 else {
            failure = LoopError.downloadFailed("HTTP \(http?.statusCode ?? 0)")
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            let expected = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            result = DownloadResult(file: destination, etag: http.value(forHTTPHeaderField: "ETag"), expectedLength: expected)
        } catch {
            failure = LoopError.downloadFailed(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { continuation.resume(throwing: LoopError.cancelled) }
            else { continuation.resume(throwing: LoopError.downloadFailed(error.localizedDescription)) }
        } else if let result {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: failure ?? LoopError.downloadFailed("no file"))
        }
    }
}

/// Downloads an aerial from Apple and puts it where macOS keeps it, or where Lockloop keeps originals.
public enum AerialFetch {
    /// Downloads into the job directory, validates, writes the xattrs macOS's own downloads carry,
    /// and renames into `destination`.
    public static func fetch(_ asset: AerialAsset, env: Environment, destination: URL,
                             progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        guard let url = asset.downloadURL else { throw LoopError.downloadFailed("not downloadable") }
        let job = try env.makeJobDir()
        defer { try? FileManager.default.removeItem(at: job) }
        let temp = job.appendingPathComponent("download.mov")
        let result = try await env.downloader.download(url, to: temp, progress: progress)
        try Task.checkCancellation()
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
        if let expected = result.expectedLength, expected != size {
            throw LoopError.downloadFailed("size \(size) of \(expected)")
        }
        guard await MediaChecks.hasVideoTrack(temp) else { throw LoopError.downloadFailed("not a video") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        var xattrs: [String: Data] = ["SourceURL": Data(url.absoluteString.utf8)]
        if let etag = result.etag { xattrs["LastETag"] = Data(etag.utf8) }
        try ExtendedAttributes.write(xattrs, to: temp)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if rename(temp.path, destination.path) != 0 {
            throw LoopError.wrap(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), path: destination)
        }
    }
}

public enum MediaChecks {
    public static func hasVideoTrack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video) else { return false }
        return !tracks.isEmpty
    }
}
