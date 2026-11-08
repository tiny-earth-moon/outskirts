import Foundation
import SystemPackage

/// The files that the earlier passes of `fix --iterate` wrote, with the bytes the last of them left. The planner only
/// edits files without uncommitted changes, so git can still restore these: a later pass may edit them again as long
/// as they hold exactly these bytes.
public struct IteratedFiles {
    /// The bytes written, by real path.
    private var written: [String: [UInt8]] = [:]

    public init() {}

    public mutating func record(_ plan: FixPlan) {
        for change in plan.changes {
            written[RealPath.resolve(change.path.string)] = change.fixed
        }
    }

    /// The working tree with the files that still hold the bytes of the earlier passes counted as committed; a file
    /// changed since keeps its uncommitted changes.
    public func workingTree(_ state: WorkingTreeState) -> WorkingTreeState {
        guard case let .repository(topLevel, uncommitted) = state else { return state }

        let unchanged = written.compactMap { path, bytes in
            Self.holds(path, bytes) ? path : nil
        }
        return .repository(topLevel: topLevel, uncommitted: uncommitted.subtracting(unchanged))
    }

    // MARK: - Private

    private static func holds(_ path: String, _ bytes: [UInt8]) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }

        return [UInt8](data) == bytes
    }
}
