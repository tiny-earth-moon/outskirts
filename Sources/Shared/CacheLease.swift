import Foundation
import Synchronization

/// Advisory locks on the build folders of the cache that the current scan uses (DerivedData folders, scratch paths).
/// Eviction and `clear-cache` skip a folder while a scan holds its lock. The locks are released when the lease is
/// deallocated or the process exits.
public final class CacheLease: Sendable {
    private let descriptors = Mutex<[String: Int32]>([:])

    public init() {}

    deinit {
        descriptors.withLock { descriptors in
            for descriptor in descriptors.values {
                close(descriptor)
            }
        }
    }

    /// Releases the folder, before this scan removes it for instance.
    public func release(_ directory: URL) {
        descriptors.withLock { descriptors in
            if let descriptor = descriptors.removeValue(forKey: directory.path) {
                close(descriptor)
            }
        }
    }

    /// Takes a shared lock on the folder and marks it as used now. A missing folder is created when `creating` is true,
    /// left alone otherwise. Holding a folder again takes the lock anew when the folder was removed since, by a clean
    /// build for instance.
    public func hold(_ directory: URL, creating: Bool = true, fileManager: FileManager = .default) throws {
        let path = directory.path
        guard creating || fileManager.fileExists(atPath: path) else { return }

        try descriptors.withLock { descriptors in
            if let descriptor = descriptors[path] {
                if CacheLock.isCurrent(descriptor, in: directory) {
                    return
                }

                close(descriptor)
                descriptors[path] = nil
            }
            descriptors[path] = try CacheLock.acquireShared(in: directory, fileManager: fileManager)
            try CacheManager.touch(directory, fileManager: fileManager)
        }
    }
}

enum CacheLock {
    static let fileName = ".outskirts-lock"

    /// Takes a shared lock, waiting for an eviction in progress. The lock is taken again when the folder was removed
    /// while waiting.
    static func acquireShared(in directory: URL, fileManager: FileManager) throws -> Int32 {
        while true {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = try open(in: directory)
            if flock(descriptor, LOCK_SH) != 0 {
                let error = posixError(errno, directory)
                close(descriptor)
                throw error
            }
            if isCurrent(descriptor, in: directory) {
                return descriptor
            }
            close(descriptor)
        }
    }

    /// Takes an exclusive lock without waiting. Returns nil when a scan holds the folder.
    static func tryExclusive(in directory: URL) throws -> Int32? {
        let descriptor = try open(in: directory)
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                return nil
            }
            throw posixError(code, directory)
        }
        return descriptor
    }

    /// Whether the descriptor still refers to the lock file of the folder, which is not the case once the folder was
    /// removed.
    static func isCurrent(_ descriptor: Int32, in directory: URL) -> Bool {
        var held = stat()
        var current = stat()
        guard fstat(descriptor, &held) == 0,
              stat(directory.appendingPathComponent(fileName).path, &current) == 0 else { return false }

        return held.st_dev == current.st_dev && held.st_ino == current.st_ino
    }

    // MARK: - Private

    private static func open(in directory: URL) throws -> Int32 {
        let descriptor = Foundation.open(directory.appendingPathComponent(fileName).path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw posixError(errno, directory) }

        return descriptor
    }

    private static func posixError(_ code: Int32, _ directory: URL) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: directory.path])
    }
}
