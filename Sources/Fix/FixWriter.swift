import Foundation
import Shared
import SystemPackage

/// Writes the changes of a plan, each file atomically and only if it still holds the buffer the edits were made on.
public enum FixWriter {
    /// Writes every change or none: each file is checked before the first write, and when a write fails, the files
    /// already written get their original buffer back.
    public static func apply(_ plan: FixPlan) throws {
        try apply(plan, setPermissions: setPermissions)
    }

    static func apply(_ plan: FixPlan, setPermissions: PermissionSetter) throws {
        for change in plan.changes where try !holds(change.original, change) {
            throw PeripheryError.underlyingError(FixWriterError.fileChanged(change.path.string))
        }

        var written: [FixPlan.Change] = []
        do {
            for change in plan.changes {
                guard try write(change.fixed, to: change, ifHolding: change.original, setPermissions: setPermissions) else {
                    throw PeripheryError.underlyingError(FixWriterError.fileChanged(change.path.string))
                }

                written.append(change)
            }
        } catch {
            let notRestored = written.filter { change in
                do {
                    return try !write(change.original, to: change, ifHolding: change.fixed, setPermissions: setPermissions)
                } catch {
                    return true
                }
            }
            guard notRestored.isEmpty else {
                throw PeripheryError.underlyingError(FixWriterError.partiallyWritten(error, notRestored.map(\.path.string)))
            }

            throw error
        }
    }

    /// Writes back the original buffer of every change whose file still holds the fixed buffer, byte for byte.
    public static func restore(_ plan: FixPlan) -> FixRestoration {
        var restoration = FixRestoration()
        for change in plan.changes {
            do {
                if try write(change.original, to: change, ifHolding: change.fixed, setPermissions: setPermissions) {
                    restoration.restored.append(change.path)
                } else {
                    restoration.notRestored.append(change.path)
                }
            } catch {
                restoration.notRestored.append(change.path)
            }
        }
        return restoration
    }

    // MARK: - Private

    /// The real path of the file, which must still be the one the planner checked: a link created since, on the file
    /// or on one of its directories, could lead outside the project.
    private static func realPath(of change: FixPlan.Change) throws -> String {
        let path = RealPath.resolve(change.path.string)
        guard path == change.realPath else {
            throw PeripheryError.underlyingError(FixWriterError.pathChanged(change.path.string))
        }

        return path
    }

    private static func holds(_ expected: [UInt8], _ change: FixPlan.Change) throws -> Bool {
        let url = try URL(fileURLWithPath: realPath(of: change))
        return try [UInt8](Data(contentsOf: url)) == expected
    }

    /// Gives the temporary file the permissions of the file it replaces; tests inject a failure there.
    typealias PermissionSetter = (_ permissions: Any, _ path: String) throws -> Void

    private static func setPermissions(_ permissions: Any, of path: String) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }

    /// Writes the bytes to a temporary file next to the file, gives it the permissions of the file, then renames it
    /// over the file: the file holds its previous bytes or the new ones, never a mix, and no step that can fail follows
    /// the rename, so a file whose bytes were replaced is always known to the caller.
    private static func write(_ bytes: [UInt8], to change: FixPlan.Change, ifHolding expected: [UInt8], setPermissions: PermissionSetter) throws -> Bool {
        let path = try realPath(of: change)
        guard try holds(expected, change) else { return false }

        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        let url = URL(fileURLWithPath: path)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).outskirts-\(UUID().uuidString)")
        do {
            try Data(bytes).write(to: temporary, options: .withoutOverwriting)
            if let permissions {
                try setPermissions(permissions, temporary.path)
            }
            if rename(temporary.path, path) != 0 {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
            }
        } catch {
            try removeTemporaryFile(temporary, after: error)
            throw error
        }
        return true
    }

    private static func removeTemporaryFile(_ temporary: URL, after error: Error) throws {
        guard FileManager.default.fileExists(atPath: temporary.path) else { return }

        do {
            try FileManager.default.removeItem(at: temporary)
        } catch let removal {
            throw PeripheryError.underlyingError(FixWriterError.temporaryFileLeft(temporary.path, error, removal))
        }
    }
}

/// The files that `FixWriter.restore` wrote back, and those that changed after the fixes were written, which it
/// leaves as they are.
public struct FixRestoration: Equatable {
    internal(set) var restored: [FilePath] = []
    internal(set) var notRestored: [FilePath] = []

    /// What a failed verification, or another `cause`, did to the files: each restored file, and each file left as it
    /// is.
    public func summary(relativeTo root: FilePath, changeCount: Int, cause: String = "The fixes break the build") -> String {
        var lines = ["\(cause), restored \(restored.count) of \(changeCount) file\(changeCount == 1 ? "" : "s"):"]
        lines += restored.map { "  restored \($0.relativePath(from: root))" }
        lines += notRestored.map { "  not restored \($0.relativePath(from: root)): changed after the fixes were written" }
        return lines.joined(separator: "\n")
    }
}

enum FixWriterError: Error, CustomStringConvertible {
    case fileChanged(String)
    case partiallyWritten(Error, [String])
    case pathChanged(String)
    case temporaryFileLeft(String, Error, Error)

    var description: String {
        switch self {
        case let .fileChanged(path):
            "\(path) changed while the fixes were being prepared, no file was written."
        case let .partiallyWritten(error, paths):
            "Writing the fixes failed (\(error)), and these files keep their fixes because they changed since: \(paths.joined(separator: ", "))."
        case let .pathChanged(path):
            "\(path) now leads to another file through a symbolic link, no file was written."
        case let .temporaryFileLeft(path, error, removal):
            "Writing the fixes failed (\(error)), and the temporary file \(path) could not be removed (\(removal))."
        }
    }
}
