import CStdio
import Foundation

#if canImport(os)
    import os
#endif

public enum ANSIColor: String {
    case bold = "\u{001B}[0;1m"
    case red = "\u{001B}[0;31m"
    case boldRed = "\u{001B}[0;1;31m"
    case green = "\u{001B}[0;32m"
    case boldGreen = "\u{001B}[0;1;32m"
    case yellow = "\u{001B}[0;33m"
    case boldYellow = "\u{001B}[0;1;33m"
    case blue = "\u{001B}[0;34m"
    case lightBlue = "\u{001B}[1;34m"
    case magenta = "\u{001B}[0;35m"
    case boldMagenta = "\u{001B}[0;1;35m"
    case cyan = "\u{001B}[0;36m"
    case lightGray = "\u{001B}[0;37m"
    case gray = "\u{001B}[0;1;30m"
}

public enum LoggerColorMode: Sendable {
    case auto
    case always
    case never
}

public struct Logger: Sendable {
    let outputQueue: DispatchQueue
    let quiet: Bool
    let verbose: Bool
    let colorMode: LoggerColorMode
    let messagesToStderr: Bool

    #if canImport(os)
        let signposter = OSSignposter()
    #endif

    public var isColoredOutputEnabled: Bool {
        isColoredOutputEnabled(for: standardOutput)
    }

    private func isColoredOutputEnabled(for stream: UnsafeMutablePointer<FILE>) -> Bool {
        switch colorMode {
        case .auto:
            Self.isColorCapable(
                environment: ProcessInfo.processInfo.environment,
                isTerminal: isatty(fileno(stream)) != 0
            )
        case .always:
            true
        case .never:
            false
        }
    }

    /// - Parameter messagesToStderr: Sends `info` and `debug` messages to stderr instead of stdout, so that stdout
    ///   only carries what is written with ``output(_:)``.
    public init(
        quiet: Bool,
        verbose: Bool,
        colorMode: LoggerColorMode,
        messagesToStderr: Bool = false
    ) {
        self.quiet = quiet
        self.verbose = verbose
        self.colorMode = colorMode
        self.messagesToStderr = messagesToStderr
        outputQueue = DispatchQueue(label: "Logger.outputQueue")
    }

    public func colorize(_ text: String, _ color: ANSIColor) -> String {
        colorize(text, color, for: standardOutput)
    }

    private func colorize(_ text: String, _ color: ANSIColor, for stream: UnsafeMutablePointer<FILE>) -> String {
        guard isColoredOutputEnabled(for: stream) else { return text }

        return "\(color.rawValue)\(text)\u{001B}[0;0m"
    }

    public func contextualized(with context: String) -> ContextualLogger {
        .init(logger: self, context: context)
    }

    public func info(_ text: String, canQuiet: Bool = true) {
        guard !(quiet && canQuiet) else { return }

        log(text, output: messageStream)
    }

    public func debug(_ text: String) {
        guard verbose else { return }

        log(text, output: messageStream)
    }

    /// Writes the primary output of the program, e.g. the formatted results, to stdout. It is neither silenced by
    /// `quiet` nor redirected by `messagesToStderr`.
    public func output(_ text: String) {
        log(text, output: standardOutput)
    }

    /// - Parameter canQuiet: Whether `quiet` silences the warning; a mistake the user must see, such as a misspelt
    ///   configuration key, passes `false`.
    public func warn(_ text: String, newlinePrefix: Bool = false, canQuiet: Bool = true) {
        guard !(quiet && canQuiet) else { return }

        if newlinePrefix {
            log("", output: standardError)
        }
        let text = colorize("warning: ", .boldYellow, for: standardError) + text
        log(text, output: standardError)
    }

    public func error(_ text: String) {
        let text = colorize("error: ", .boldRed, for: standardError) + text
        log(text, output: standardError)
    }

    public func beginInterval(_ name: StaticString) -> SignpostInterval {
        #if canImport(os)
            let id = signposter.makeSignpostID()
            let state = signposter.beginInterval(name, id: id)
            return .init(name: name, state: state)
        #else
            return SignpostInterval()
        #endif
    }

    public func endInterval(_ interval: SignpostInterval) {
        #if canImport(os)
            signposter.endInterval(interval.name, interval.state)
        #endif
    }

    // MARK: - Private

    private var messageStream: UnsafeMutablePointer<FILE> {
        messagesToStderr ? standardError : standardOutput
    }

    func log(_ line: String, output: UnsafeMutablePointer<FILE>) {
        _ = outputQueue.sync { fputs(line + "\n", output) }
    }

    /// `auto` colors a stream only when it is a terminal, `TERM` is set and not `dumb`, and `NO_COLOR` is unset or
    /// empty (https://no-color.org).
    static func isColorCapable(environment: [String: String], isTerminal: Bool) -> Bool {
        guard isTerminal,
              let term = environment["TERM"],
              term.lowercased() != "dumb",
              environment["NO_COLOR", default: ""].isEmpty
        else {
            return false
        }

        return true
    }
}

public struct ContextualLogger: Sendable {
    let logger: Logger
    let context: String

    public func contextualized(with innerContext: String) -> ContextualLogger {
        logger.contextualized(with: "\(context):\(innerContext)")
    }

    public func debug(_ text: String) {
        logger.debug("[\(context)] \(text)")
    }

    public func warn(_ text: String) {
        logger.warn(text)
    }

    public func beginInterval(_ name: StaticString) -> SignpostInterval {
        logger.beginInterval(name)
    }

    public func endInterval(_ interval: SignpostInterval) {
        logger.endInterval(interval)
    }
}

#if canImport(os)
    public struct SignpostInterval {
        let name: StaticString
        let state: OSSignpostIntervalState
    }
#else
    public struct SignpostInterval {
        @usableFromInline
        init() {}
    }
#endif

private var standardOutput: UnsafeMutablePointer<FILE> {
    periphery_stdout()!
}

private var standardError: UnsafeMutablePointer<FILE> {
    periphery_stderr()!
}
