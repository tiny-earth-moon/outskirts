import Foundation
import SystemPackage
@testable import TestShared

var SPMProjectPath: FilePath {
    ProjectRootPath.appending("Tests/SPMTests/SPMProject")
}

var SPMProjectBuildPluginPath: FilePath {
    ProjectRootPath.appending("Tests/SPMTests/SPMProjectBuildPlugin")
}

#if os(macOS)
    var SPMProjectMacOSPath: FilePath {
        ProjectRootPath.appending("Tests/SPMTests/SPMProjectMacOS")
    }

    var SPMProjectMultiVariantPath: FilePath {
        ProjectRootPath.appending("Tests/SPMTests/SPMProjectMultiVariant")
    }
#endif
