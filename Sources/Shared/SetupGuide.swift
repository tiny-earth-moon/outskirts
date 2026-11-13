import Foundation
import Logger

public protocol SetupGuide {
    func perform() throws -> ProjectKind
    var commandLineOptions: [String] { get }
    var projectKindName: String { get }
}

public enum SetupSelection {
    case all([String])
    case some([String])

    public var selectedValues: [String] {
        switch self {
        case let .all(values), let .some(values):
            values
        }
    }
}

open class SetupGuideHelpers {
    public let logger: Logger
    public var readInput: () -> String? = { readLine(strippingNewline: true) }

    public init(logger: Logger) {
        self.logger = logger
    }

    func display(options: [String]) {
        let maxPaddingCount = String(options.count).count

        for (index, option) in options.enumerated() {
            let paddingCount = maxPaddingCount - String(index + 1).count
            let padding = String(repeating: " ", count: paddingCount)
            print(padding + logger.colorize("\(index + 1) ", .boldGreen) + option)
        }
    }

    func readAnswer() throws -> String {
        guard let line = readInput() else {
            print("")
            throw PeripheryError.guidedSetupError(message: "Reached the end of the input before the guided setup was complete")
        }

        return line.trimmed
    }

    public func select(single options: [String]) throws -> String {
        while true {
            display(options: options)
            print(logger.colorize("?", .boldYellow) + " Type the number for the option you wish to select")
            print(logger.colorize("=> ", .bold), terminator: "")

            let strChoice = try readAnswer()

            if let choice = Int(strChoice) {
                if let option = options[safe: choice - 1] {
                    return option
                }
                print(logger.colorize("\nInvalid option: \(strChoice)\n", .boldYellow))
            }

            print(logger.colorize("\nInvalid input, expected a number.\n", .boldYellow))
        }
    }

    public func select(multiple options: [String]) throws -> SetupSelection {
        let helpMsg = " Delimit choices with a single space, e.g: 1 2 3"

        while true {
            display(options: options)
            print(logger.colorize("?", .boldYellow) + helpMsg)
            print(logger.colorize("=> ", .bold), terminator: "")

            let strChoices = try readAnswer().split(separator: " ", omittingEmptySubsequences: true)
            var selected: [String] = []
            var invalidChoice: Substring?

            for strChoice in strChoices {
                if let choice = Int(strChoice),
                   let option = options[safe: choice - 1]
                {
                    selected.append(option)
                } else {
                    invalidChoice = strChoice
                    break
                }
            }

            if let invalidChoice {
                print(logger.colorize("\nInvalid option: \(invalidChoice)\n", .boldYellow))
                continue
            }

            if !selected.isEmpty {
                return .some(selected)
            }

            print(logger.colorize("\nInvalid input, expected a number.\n", .boldYellow))
        }
    }

    public func selectBoolean(default defaultAnswer: Bool? = nil) throws -> Bool {
        while true {
            print(
                "(" + logger.colorize("Y", .boldGreen) + ")es" +
                    "/" +
                    "(" + logger.colorize("N", .boldGreen) + ")o" +
                    (defaultAnswer.map { $0 ? " [default: yes]" : " [default: no]" } ?? "") +
                    logger.colorize("\n=> ", .bold),
                terminator: ""
            )

            let answer = try readAnswer().lowercased()

            if answer.isEmpty, let defaultAnswer {
                return defaultAnswer
            }

            if ["y", "yes"].contains(answer) {
                return true
            } else if ["n", "no"].contains(answer) {
                return false
            }

            print(logger.colorize("\nInvalid input, expected 'y' or 'n'.\n", .boldYellow))
        }
    }
}
