import Foundation

/// A non-blocking flock on <support>/lock, so the app, the CLI and the background
/// agent never run a flow at the same time.
public final class OperationLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func acquire(_ env: Environment) throws -> OperationLock {
        try FileManager.default.createDirectory(at: env.supportDir, withIntermediateDirectories: true)
        let fd = open(env.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw LoopError.wrap(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), path: env.lockURL) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw LoopError.busy
        }
        return OperationLock(fd: fd)
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

public extension OperationLock {
    static func with<T>(_ env: Environment, _ body: () async throws -> T) async throws -> T {
        let lock = try acquire(env)
        defer { lock.release() }
        return try await body()
    }
}
