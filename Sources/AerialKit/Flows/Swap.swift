import Foundation

/// File moves shared by apply, restore and reapply. Every write into Apple's folder
/// is copy into Lockloop's work folder, then one atomic rename.
enum Swap {
    /// Marks files Lockloop put in Apple's folder, so they are never mistaken for Apple's.
    static let markerName = Brand.bundleID + ".installed"

    /// The marker holds the fingerprint of the file it was written on, so a file
    /// rewritten in place (which keeps xattrs) is not mistaken for ours.
    static func isOurs(_ url: URL, fingerprint: String?, state: AppState?) -> Bool {
        guard let fingerprint else { return false }
        if state?.everInstalled.contains(fingerprint) == true { return true }
        return ExtendedAttributes.read(url, names: [markerName])[markerName] == Data(fingerprint.utf8)
    }

    /// Copies `source` to `staging`, sets mode and xattrs, then renames over `destination`.
    static func copyThenRename(_ source: URL, staging: URL, destination: URL, mode: Int = 0o600,
                               xattrs: [String: Data], removing: [String] = []) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staging.path)
            for name in removing { removexattr(staging.path, name, XATTR_NOFOLLOW) }
            try ExtendedAttributes.write(xattrs, to: staging)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if rename(staging.path, destination.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw LoopError.wrap(error, path: destination)
        }
    }

    /// Saves Apple's video to originals/ unless it is already saved or the live file is one of ours.
    /// Returns true when a new backup was made.
    @discardableResult
    static func backupOriginalIfNeeded(_ env: Environment, assetID: String, live: URL, state: inout AppState) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: live.path) else { return false }
        let liveFP = try Fingerprint.of(live)
        if isOurs(live, fingerprint: liveFP, state: state) { return false }
        let backup = env.originalURL(for: assetID)
        if Fingerprint.ofIfPresent(backup) == liveFP {
            if state.original?.fingerprint != liveFP {
                state.original = .init(fingerprint: liveFP, size: fileSize(live), xattrs: ExtendedAttributes.read(live))
            }
            return false
        }
        guard await MediaChecks.hasVideoTrack(live) else {
            throw LoopError.swapFailed("Apple's video at \(live.path) doesn't open")
        }
        let fm = FileManager.default
        let partial = backup.appendingPathExtension("partial")
        do {
            try fm.createDirectory(at: env.originalsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            try fm.copyItem(at: live, to: partial)
            if rename(partial.path, backup.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } catch {
            try? fm.removeItem(at: partial)
            throw LoopError.wrap(error, path: backup)
        }
        state.original = .init(fingerprint: liveFP, size: fileSize(live), xattrs: ExtendedAttributes.read(live))
        return true
    }

    /// Puts current/<ID>.mov in Apple's folder with the xattrs Apple's file had. Returns its fingerprint.
    static func installCurrent(_ env: Environment, assetID: String, live: URL, state: AppState, job: URL) throws -> String {
        let current = env.currentURL(for: assetID)
        var xattrs = ExtendedAttributes.read(live)
        if xattrs.isEmpty { xattrs = state.original?.xattrs ?? [:] }
        let fingerprint = try Fingerprint.of(current)
        xattrs[markerName] = Data(fingerprint.utf8)
        try copyThenRename(current, staging: job.appendingPathComponent("install.mov"), destination: live, xattrs: xattrs)
        return fingerprint
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime]
        return f.string(from: date).replacingOccurrences(of: ":", with: "")
    }

    /// Copies Index.plist into backups/ and keeps the newest 10 timestamped copies.
    static func backupIndex(_ env: Environment, alsoPreApply: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: env.backupsDir, withIntermediateDirectories: true)
        var dest = env.backupsDir.appendingPathComponent("Index-\(timestamp(env.now())).plist")
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = env.backupsDir.appendingPathComponent("Index-\(timestamp(env.now()))-\(n).plist"); n += 1
        }
        do {
            try fm.copyItem(at: env.indexURL, to: dest)
            if alsoPreApply {
                if fm.fileExists(atPath: env.preApplyIndexURL.path) { try fm.removeItem(at: env.preApplyIndexURL) }
                try fm.copyItem(at: env.indexURL, to: env.preApplyIndexURL)
            }
        } catch { throw LoopError.wrap(error, path: env.indexURL) }
        return dest
    }

    static func trimBackups(_ env: Environment, keep: Int = 10) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: env.backupsDir.path) else { return }
        let stamped = names.filter { $0.hasPrefix("Index-") && $0 != env.preApplyIndexURL.lastPathComponent }.sorted()
        for name in stamped.dropLast(keep) { try? fm.removeItem(at: env.backupsDir.appendingPathComponent(name)) }
    }

    /// Restarts the agent and checks each path kept the expected choice. Retries the write once.
    static func restartAndCheck(_ env: Environment, written: WallpaperIndex, expected: [PlistPath: String?], label: String) async throws {
        func accepted() -> Bool {
            guard let now = try? WallpaperIndex.load(env.indexURL) else { return false }
            let choices = Dictionary(now.desktopChoices().map { ($0.path, $0.assetID) }, uniquingKeysWith: { a, _ in a })
            return expected.allSatisfy { path, id in choices[path] == .some(id) }
        }
        await env.agent.restart()
        if accepted() { return }
        try written.write(to: env.indexURL)
        await env.agent.restart()
        if accepted() { return }
        throw LoopError.choiceNotAccepted(assetLabel: label)
    }
}
