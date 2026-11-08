import Foundation
import Logger
import Shared
import Synchronization
import SystemPackage

public final class Xcodebuild {
    private let shell: Shell
    private let logger: Logger
    /// The directory holding the DerivedData folders, the outskirts cache when nil.
    let cacheDirectory: FilePath?
    /// The DerivedData folders of `-list` and `-showBuildSettings`, locked so that concurrent scans never evict them.
    private let cacheLease = CacheLease()

    public required init(shell: Shell, logger: Logger, cacheDirectory: FilePath? = nil) {
        self.shell = shell
        self.logger = logger
        self.cacheDirectory = cacheDirectory
    }

    private static let cachedVersion = Mutex<String?>(nil)

    func version() throws -> String {
        if let version = Self.cachedVersion.withLock({ $0 }) {
            return version
        }

        let version = try shell.exec(["xcodebuild", "-version"]).trimmed
        Self.cachedVersion.withLock { $0 = version }
        return version
    }

    public func ensureConfigured() throws {
        do {
            try logger.debug(version())
        } catch {
            throw PeripheryError.xcodebuildNotConfigured
        }
    }

    @discardableResult
    public func build(project: XcodeProjectlike, scheme: String, allSchemes: [String], additionalArguments: [String] = []) throws -> String {
        let xcodebuild = try [
            "xcodebuild",
            "-\(project.type)", project.path.lexicallyNormalized().string,
            "-scheme", scheme,
            "-parallelizeTargets",
            "-derivedDataPath", derivedDataPath(for: project, schemes: allSchemes, buildArguments: additionalArguments).string,
            "-quiet",
            "build-for-testing",
            "CODE_SIGNING_ALLOWED=NO",
            "ENABLE_BITCODE=NO",
            "DEBUG_INFORMATION_FORMAT=dwarf",
            "COMPILER_INDEX_STORE_ENABLE=YES",
            "INDEX_ENABLE_DATA_STORE=YES",
        ] + additionalArguments

        return try shell.exec(xcodebuild)
    }

    /// removes the DerivedData folder used to build the specified schemes
    public func removeDerivedData(for project: XcodeProjectlike, allSchemes: [String], buildArguments: [String] = []) throws {
        let path = try derivedDataPath(for: project, schemes: allSchemes, buildArguments: buildArguments)
        guard path.exists else { return }

        let directory = URL(fileURLWithPath: path.string)
        cacheLease.release(directory)
        if try !CacheManager.removeUnlessInUse(directory) {
            logger.warn("The DerivedData folder '\(path)' is in use by another running scan, it is not cleaned.")
        }
    }

    public func indexStorePath(
        project: XcodeProjectlike,
        schemes: [String],
        buildArguments: [String] = [],
        skipBuild: Bool = false,
        xcodeDerivedDataRoot: FilePath = Xcodebuild.defaultXcodeDerivedDataRoot
    ) throws -> FilePath {
        let derivedDataPath = try derivedDataPath(for: project, schemes: schemes, buildArguments: buildArguments)
        let relativePaths = ["Index.noindex/DataStore", "Index/DataStore"]
        let pathsToTry = relativePaths.map { derivedDataPath.appending($0) }
        if let path = pathsToTry.first(where: { $0.exists }) {
            return path
        }

        guard skipBuild else {
            throw PeripheryError.indexStoreNotFound(derivedDataPath: derivedDataPath.string)
        }

        // With --skip-build, outskirts' own DerivedData is never populated, so fall back to the one Xcode uses.
        let projectName = project.path.lexicallyNormalized().lastComponent?.stem ?? ""
        let xcodeCandidates = xcodeDerivedDataFolders(named: projectName, in: xcodeDerivedDataRoot)
            .filter { belongs($0, to: project) }
            .flatMap { folder in relativePaths.map { folder.appending($0) } }
            .filter(\.exists)
            .sorted { modificationDate($0) > modificationDate($1) }

        guard let path = xcodeCandidates.first else {
            let tried = pathsToTry.map(\.string) + [xcodeDerivedDataRoot.appending("\(projectName)-*/Index.noindex/DataStore").string]
            throw PeripheryError.indexStoreNotFoundAfterSkippedBuild(tried: tried)
        }

        logger.info("Build skipped, using the index store from Xcode's DerivedData: \(path.string)")
        return path
    }

    public static var defaultXcodeDerivedDataRoot: FilePath {
        FilePath(NSHomeDirectory()).appending("Library/Developer/Xcode/DerivedData")
    }

    private func xcodeDerivedDataFolders(named projectName: String, in root: FilePath) -> [FilePath] {
        guard !projectName.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.string) else { return [] }

        // Xcode names folders `<ProjectName>-<hash>`; require the dash so `Foo` does not match `FooBar-<hash>`.
        return names.filter { $0.hasPrefix(projectName + "-") }.map { root.appending($0) }
    }

    /// Xcode records the opened project or workspace under `WorkspacePath` in the `info.plist` of each DerivedData
    /// folder; worktrees, clones and other projects with the same name share the folder name prefix.
    private func belongs(_ folder: FilePath, to project: XcodeProjectlike) -> Bool {
        let plistPath = folder.appending("info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath.string) else {
            logger.debug("Ignoring Xcode DerivedData without info.plist: \(folder.string)")
            return false
        }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            logger.debug("Ignoring Xcode DerivedData with an unreadable info.plist: \(folder.string)")
            return false
        }

        guard let workspacePath = (plist as? [String: Any])?["WorkspacePath"] as? String else { return false }

        let matches = resolvedPath(workspacePath) == resolvedPath(project.path.lexicallyNormalized().string)
        if !matches {
            logger.debug("Ignoring Xcode DerivedData of another workspace (\(workspacePath)): \(folder.string)")
        }
        return matches
    }

    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func modificationDate(_ path: FilePath) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.string)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    func schemes(project: XcodeProjectlike, additionalArguments: [String]) throws -> Set<String> {
        try schemes(
            type: project.type,
            path: project.path.lexicallyNormalized().string,
            additionalArguments: additionalArguments
        )
    }

    func schemes(type: String, path: String, additionalArguments: [String]) throws -> Set<String> {
        let xcodebuild = try [
            "xcodebuild",
            "-\(type)", path,
            "-list",
            "-json",
            // since `xcodebuild -list` performs package resolution (meaning that it needs a DerivedData folder),
            // but doesn't support `-derivedDataPath`, we instead use `-IDECustomDerivedDataLocation=<path>`.
            // the difference between the two is that the former points to the specific folder xcodebuild will use
            // for its build output, whereas the latter points to the parent folder.
            // i.e., `-IDECustomDerivedDataLocation=<path>` is effectively identical to
            // `-derivedDataPath <path>/<xcode-default-hashed-folder-name>`.
            // this is not a problem, since we still can scope the folders on a per-project
            // and per-xcode-version level; the actual contents just happen to be one level deeper.
            "-IDECustomDerivedDataLocation=\(holdListDerivedData(projectIdentifier: path).string)",
        ] + additionalArguments

        let lines = try shell.exec(xcodebuild).split(separator: "\n").map { String($0).trimmed }

        // xcodebuild may output unrelated warnings, we need to strip them out otherwise
        // JSON parsing will fail.
        let startIndex = lines.firstIndex { $0 == "{" } ?? 0
        var jsonLines = lines.suffix(from: startIndex)

        if let lastIndex = jsonLines.lastIndex(where: { $0 == "}" }) {
            jsonLines = jsonLines.prefix(upTo: lastIndex + 1)
        }

        let jsonString = jsonLines.joined(separator: "\n")

        guard let json = try deserialize(jsonString),
              let details = json[type] as? [String: Any],
              let schemes = details["schemes"] as? [String] else { return [] }

        return Set(schemes)
    }

    /// The `SUPPORTED_PLATFORMS` of the targets the schemes build, from `xcodebuild -showBuildSettings`, in the order read.
    public func supportedPlatforms(project: XcodeProjectlike, schemes: [String], additionalArguments: [String]) throws -> [String] {
        var platforms: [String] = []
        for scheme in schemes.sorted() {
            let xcodebuild = try [
                "xcodebuild",
                "-\(project.type)", project.path.lexicallyNormalized().string,
                "-scheme", scheme,
                "-showBuildSettings",
                "-json",
                "-IDECustomDerivedDataLocation=\(holdListDerivedData(projectIdentifier: project.path.lexicallyNormalized().string).string)",
            ] + additionalArguments

            for platform in try Self.supportedPlatforms(fromBuildSettings: shell.exec(xcodebuild)) where !platforms.contains(platform) {
                platforms.append(platform)
            }
        }
        return platforms
    }

    /// The name `supportedPlatforms` gives to Mac Catalyst, which `SUPPORTS_MACCATALYST` enables.
    static let macCatalystPlatform = "maccatalyst"

    /// The `SUPPORTED_PLATFORMS` of the JSON printed by `xcodebuild -showBuildSettings -json`, warnings around it
    /// ignored, and `maccatalyst` for a target with `SUPPORTS_MACCATALYST`.
    static func supportedPlatforms(fromBuildSettings output: String) throws -> [String] {
        guard let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]"), start < end else {
            throw PeripheryError.jsonDeserializationError(error: CocoaError(.propertyListReadCorrupt), json: output)
        }

        let json = String(output[start ... end])
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        } catch {
            throw PeripheryError.jsonDeserializationError(error: error, json: json)
        }

        let targets = (object as? [[String: Any]]) ?? []
        var platforms: [String] = []
        for target in targets {
            let settings = target["buildSettings"] as? [String: Any]
            var supported = ((settings?["SUPPORTED_PLATFORMS"] as? String) ?? "").split(separator: " ").map(String.init)
            // Mac Catalyst is not a platform of its own: the iOS targets that support it say so in another setting.
            if (settings?["SUPPORTS_MACCATALYST"] as? String) == "YES" {
                supported.append(Self.macCatalystPlatform)
            }
            for platform in supported where !platforms.contains(platform) {
                platforms.append(platform)
            }
        }
        return platforms
    }

    // MARK: - Private

    private func deserialize(_ jsonString: String) throws -> [String: Any]? {
        do {
            guard let jsonData = jsonString.data(using: .utf8) else { return nil }

            return try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
        } catch {
            throw PeripheryError.jsonDeserializationError(error: error, json: jsonString)
        }
    }

    func derivedDataPath(for project: XcodeProjectlike, schemes: [String], buildArguments: [String] = []) throws -> FilePath {
        try derivedDataPath(
            projectIdentifier: project.path.lexicallyNormalized().string,
            schemes: schemes,
            buildArguments: buildArguments
        )
    }

    /// The DerivedData folder of `-list` and `-showBuildSettings`, held for the rest of the scan. A failure to hold it is
    /// a warning: the cache housekeeping never fails the scan.
    private func holdListDerivedData(projectIdentifier: String) throws -> FilePath {
        let path = try derivedDataPath(projectIdentifier: projectIdentifier, schemes: [])
        do {
            try cacheLease.hold(URL(fileURLWithPath: path.string))
        } catch {
            logger.warn("Could not lock the build cache folder '\(path)': \(error.localizedDescription)")
        }
        return path
    }

    private func derivedDataPath(projectIdentifier: String, schemes: [String], buildArguments: [String] = []) throws -> FilePath {
        // Given a project with two schemes: A and B, a scenario can arise where the index store contains conflicting
        // data. If scheme A is built, then the source file modified and then scheme B built, the index store will
        // contain two records for that source file. One reflects the state of the file when scheme A was built, and the
        // other when B was built. We must therefore key the DerivedData path with the full list of schemes being built.
        // The build arguments (destination, configuration, flags…) change what is compiled and indexed, so they are part
        // of the key too, in the order given. Output and report options are deliberately not inputs: scans that differ
        // only by those share the same incremental build.
        var name = "DerivedData"
        name += "-\(try version().djb2Hex)"
        name += "-\(projectIdentifier.djb2Hex)"
        if !schemes.isEmpty {
            name += "-\(schemes.sorted().joined().djb2Hex)"
        }
        if !buildArguments.isEmpty {
            name += "-\(buildArguments.joined(separator: "\n").djb2Hex)"
        }
        return try (cacheDirectory ?? Constants.cachePath()).appending(name)
    }
}
