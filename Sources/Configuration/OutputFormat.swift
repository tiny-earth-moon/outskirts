import Foundation

public enum OutputFormat: String, CaseIterable, Sendable {
    case xcode
    case csv
    case csvV2 = "csv-v2"
    case json
    case jsonV2 = "json-v2"
    case checkstyle
    case checkstyleV2 = "checkstyle-v2"
    case codeclimate
    case codeclimateV2 = "codeclimate-v2"
    case githubActions = "github-actions"
    case githubMarkdown = "github-markdown"
    case gitlabCodeQuality = "gitlab-codequality"
    case gitlabCodeQualityV2 = "gitlab-codequality-v2"
    case sarif
    case agent

    public static let `default` = OutputFormat.xcode

    @inlinable public var supportsAuxiliaryOutput: Bool {
        self == .xcode
    }

    @inlinable public var supportsColoredOutput: Bool {
        self == .xcode
    }
}
