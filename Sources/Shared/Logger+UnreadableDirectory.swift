import Extensions
import Logger
import SystemPackage

public extension Logger {
    func warnUnreadableDirectory(_ path: FilePath, _ error: any Error) {
        warn(FilePath.unreadableDirectoryMessage(path, error))
    }
}
