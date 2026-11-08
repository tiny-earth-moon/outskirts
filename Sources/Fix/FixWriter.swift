import Foundation
import Shared
import SystemPackage

/// Writes the changes of a plan, each file atomically and only if it still holds the buffer the edits were made on.
public enum FixWriter {
    /// Writes every change or none: each file is checked before the first write, and when a write fails, the files
    /// already written get their original buffer back.
    public static func apply(_ plan: FixPlan) throws {
        for change in plan.changes where try !holds(change.original, change) {
            throw PeripheryError.underlyingError(FixWriterError.fileChanged(change.path.string))
        }

        var written: [FixPlan.Change] = []
        do {
            for change in plan.changes {
                guard try write(change.fixed, to: change, ifHolding: change.original) else {
                    throw PeripheryError.underlyingError(FixWriterError.fileChanged(change.path.string))
                }

                written.append(change)
            }
        } catch {
            let notRestored = written.filter { change in
                do {
                    return try !write(change.original, to: change, ifHolding: change.fixed)
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
                if try write(change.original, to: change, ifHolding: change.fixed) {
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

    private static func holds(_ expected: [UInt8], _ change: FixPlan.Change) throws -> Bool {
        let url = URL(fileURLWithPath: RealPath.resolve(change.path.string))
        return try [UInt8](Data(contentsOf: url)) == expected
    }

    private static func write(_ bytes: [UInt8], to change: FixPlan.Change, ifHolding expected: [UInt8]) throws -> Bool {
        // The planner refuses symbolic links; the real path also covers a link created since.
        let path = RealPath.resolve(change.path.string)
        let url = URL(fileURLWithPath: path)
        guard try holds(expected, change) else { return false }

        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        try Data(bytes).write(to: url, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
        return true
    }
}

/// The files that `FixWriter.restore` wrote back, and those that changed after the fixes were written, which it
/// leaves as they are.
public struct FixRestoration: Equatable {
    public internal(set) var restored: [FilePath] = []
    public internal(set) var notRestored: [FilePath] = []

    /// What a failed verification did to the files: each restored file, and each file left as it is.
    public func summary(relativeTo root: FilePath, changeCount: Int) -> String {
        var lines = ["The fixes break the build, restored \(restored.count) of \(changeCount) file\(changeCount == 1 ? "" : "s"):"]
        lines += restored.map { "  restored \($0.relativePath(from: root))" }
        lines += notRestored.map { "  not restored \($0.relativePath(from: root)): changed after the fixes were written" }
        return lines.joined(separator: "\n")
    }
}

enum FixWriterError: Error, CustomStringConvertible {
    case fileChanged(String)
    case partiallyWritten(Error, [String])

    var description: String {
        switch self {
        case let .fileChanged(path):
            "\(path) changed while the fixes were being prepared, no file was written."
        case let .partiallyWritten(error, paths):
            "Writing the fixes failed (\(error)), and these files keep their fixes because they changed since: \(paths.joined(separator: ", "))."
        }
    }
}
