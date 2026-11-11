import Configuration
import Foundation
import Logger
import Shared
import Synchronization

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class UpdateChecker: Sendable {
    private let logger: Logger
    private let debugLogger: ContextualLogger
    /// Only the xcode format performs the update check, because it may interfere with parsing json and csv.
    private let isEnabled: Bool
    private let urlSession: URLSession
    private let latestReleaseURL: URL
    private let semaphore: DispatchSemaphore
    /// Written on the URLSession callback queue, read on the caller's thread.
    private let state = Mutex<(latestVersion: String?, error: Error?)>((nil, nil))

    required init(logger: Logger, configuration: Configuration) {
        self.logger = logger
        debugLogger = logger.contextualized(with: "update-check")
        isEnabled = !configuration.disableUpdateCheck && configuration.outputFormat.supportsAuxiliaryOutput
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = Self.requestTimeout
        urlSession = URLSession(configuration: config)
        latestReleaseURL = UpdateNotice.latestReleaseURL
        semaphore = DispatchSemaphore(value: 0)
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    func run() {
        guard isEnabled else { return }

        var urlRequest = URLRequest(url: latestReleaseURL)
        urlRequest.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let task = urlSession.dataTask(with: urlRequest) { [weak self] data, _, error in
            guard let self else { return }

            if let error {
                debugLogger.debug("error: \(error.localizedDescription)")
                state.withLock { $0.error = error }
                semaphore.signal()
                return
            }

            switch Self.latestVersion(fromResponse: data) {
            case let .success(tagName):
                state.withLock { $0.latestVersion = tagName }
            case let .failure(error):
                debugLogger.debug(error.description)
                state.withLock { $0.error = error }
            }
            semaphore.signal()
        }

        task.resume()
    }

    static let requestTimeout: TimeInterval = 30
    static let maximumResponseSize = 64 * 1024

    /// Extracts the release tag from a latest-release response, accepting only a plain version made of digits and dots.
    static func latestVersion(fromResponse data: Data?) -> Result<String, PeripheryError> {
        guard let data else {
            return .failure(.updateCheckError(message: "Empty latest release response."))
        }
        guard data.count <= maximumResponseSize else {
            return .failure(.updateCheckError(message: "Latest release response is \(data.count) bytes, larger than the \(maximumResponseSize) bytes limit."))
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(.updateCheckError(message: "Latest release response is not valid JSON: \(error.localizedDescription)"))
        }

        guard let tagName = (jsonObject as? [AnyHashable: Any])?["tag_name"] as? String else {
            return .failure(.updateCheckError(message: "Failed to identify latest release tag."))
        }
        guard isPlainVersion(tagName) else {
            return .failure(.updateCheckError(message: "Ignoring latest release tag that is not a plain version."))
        }

        return .success(tagName)
    }

    static func isPlainVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count <= 4 && components.allSatisfy { component in
            !component.isEmpty && component.count <= 9 && component.allSatisfy { ("0" ... "9").contains($0) }
        }
    }

    func notifyIfAvailable() {
        guard let latestVersion = state.withLock({ $0.latestVersion }) else { return }

        debugLogger.debug("latest: \(latestVersion)")

        guard latestVersion.isVersion(greaterThan: PeripheryVersion) else { return }

        let lines = UpdateNotice.lines(latestVersion: latestVersion, localVersion: PeripheryVersion) { text, style in
            switch style {
            case .bold: logger.colorize(text, .bold)
            case .boldGreen: logger.colorize(text, .boldGreen)
            }
        }
        for line in lines {
            logger.info(line)
        }
    }

    func wait() -> Result<String, PeripheryError> {
        let waitResult = semaphore.wait(timeout: .now() + 60)
        let (latestVersion, error) = state.withLock { ($0.latestVersion, $0.error) }

        if let error {
            return .failure(.underlyingError(error))
        }

        if waitResult == .timedOut {
            return .failure(PeripheryError.updateCheckError(message: "Timed out while checking for update."))
        }

        if let latestVersion {
            return .success(latestVersion)
        }

        return .failure(PeripheryError.updateCheckError(message: "Failed to determine latest version."))
    }
}
