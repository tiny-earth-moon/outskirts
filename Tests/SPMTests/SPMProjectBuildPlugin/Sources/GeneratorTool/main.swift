import Foundation

let source = """
func generatedEntry() {
    usedOnlyByGeneratedCode()
}

func generatedUnused() {}

"""

try source.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
