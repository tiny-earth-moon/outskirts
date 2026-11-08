import SwiftSyntax

/// A parsed source file and the byte ranges that removing a piece of it takes along.
struct ParsedSource {
    let bytes: [UInt8]
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter

    init(path: String, bytes: [UInt8], tree: SourceFileSyntax) {
        self.bytes = bytes
        self.tree = tree
        converter = SourceLocationConverter(fileName: path, tree: tree)
    }

    /// The token that starts exactly at the line and column a result reports, columns counting UTF-8 bytes.
    func token(atLine line: Int, column: Int) -> TokenSyntax? {
        guard line >= 1, column >= 1 else { return nil }

        let position = converter.position(ofLine: line, column: column)
        guard position.utf8Offset < bytes.count,
              converter.location(for: position).line == line,
              converter.location(for: position).column == column,
              let token = tree.token(at: position),
              token.positionAfterSkippingLeadingTrivia == position
        else { return nil }

        return token
    }

    /// The range that removes a node or a comment, from `start` to `end`. When the removed text is alone on its lines,
    /// the range takes the indentation and one trailing newline, and one of two blank lines that would end up next to
    /// each other; otherwise it takes the spaces that separate it from the rest of the line.
    func removalRange(from start: Int, to end: Int) -> Range<Int> {
        var lineStart = start
        while lineStart > 0, isHorizontalSpace(bytes[lineStart - 1]) {
            lineStart -= 1
        }
        var lineEnd = end
        while lineEnd < bytes.count, isHorizontalSpace(bytes[lineEnd]) {
            lineEnd += 1
        }

        let startsLine = lineStart == 0 || bytes[lineStart - 1] == newline
        let endsLine = lineEnd == bytes.count || bytes[lineEnd] == newline || bytes[lineEnd] == carriageReturn

        switch (startsLine, endsLine) {
        case (true, true):
            var upperBound = lineEnd
            if upperBound < bytes.count, bytes[upperBound] == carriageReturn {
                upperBound += 1
            }
            if upperBound < bytes.count, bytes[upperBound] == newline {
                upperBound += 1
            }
            return bytes.wholeLineRemoval(lineStart ..< upperBound)
        case (false, true):
            return lineStart ..< lineEnd
        case (_, false):
            return start ..< lineEnd
        }
    }

    /// The range that removes a whole statement or declaration with its attached doc comment, its attached comment
    /// commands, and its trailing comment. Comments separated from it by a blank line, other comments, and
    /// `ignore:all` commands, which apply to the whole file, stay.
    func statementRemovalRange(_ node: some SyntaxProtocol) -> Range<Int> {
        var start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        if let firstToken = node.firstToken(viewMode: .sourceAccurate) {
            start = attachedCommentStart(of: firstToken) ?? start
        }
        return removalRange(from: start, to: node.endPosition.utf8Offset)
    }

    // MARK: - Private

    private let newline = UInt8(ascii: "\n")
    private let carriageReturn = UInt8(ascii: "\r")

    private func isHorizontalSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }

    /// The offset of the first doc comment or comment command that is attached to the token, line after line without
    /// a blank line. A comment command left behind would apply to the next declaration.
    private func attachedCommentStart(of token: TokenSyntax) -> Int? {
        let pieces = token.leadingTrivia.offsetPieces(startingAt: token.position.utf8Offset)
        var index = pieces.count - 1
        var start: Int?

        func skipHorizontalSpace() {
            while index >= 0, pieces[index].piece.isHorizontalSpace {
                index -= 1
            }
        }

        skipHorizontalSpace()
        while index >= 0, pieces[index].piece.isSingleNewline {
            var commentIndex = index - 1
            while commentIndex >= 0, pieces[commentIndex].piece.isHorizontalSpace {
                commentIndex -= 1
            }
            guard commentIndex >= 0, pieces[commentIndex].piece.isDocComment || pieces[commentIndex].piece.isDeclarationCommentCommand else { break }

            start = pieces[commentIndex].offset
            index = commentIndex - 1
            skipHorizontalSpace()
        }
        return start
    }
}

extension [UInt8] {
    /// The length of the `\n` or `\r\n` line break that starts at the offset, 0 when there is none.
    func lineBreakLength(startingAt offset: Int) -> Int {
        if offset < count, self[offset] == UInt8(ascii: "\n") {
            return 1
        }
        if offset + 1 < count, self[offset] == UInt8(ascii: "\r"), self[offset + 1] == UInt8(ascii: "\n") {
            return 2
        }
        return 0
    }

    /// The length of the `\n` or `\r\n` line break that ends at the offset, 0 when there is none.
    func lineBreakLength(endingAt offset: Int) -> Int {
        guard offset >= 1, offset <= count, self[offset - 1] == UInt8(ascii: "\n") else { return 0 }

        return offset >= 2 && self[offset - 2] == UInt8(ascii: "\r") ? 2 : 1
    }

    /// A removal of whole lines, which takes along one of the two blank lines that would end up next to each other,
    /// or the blank line that would end the file, whatever the line breaks.
    func wholeLineRemoval(_ range: Range<Int>) -> Range<Int> {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound
        let previousBreak = lineBreakLength(endingAt: lowerBound)
        let followsBlankLine = lowerBound == 0 || (previousBreak > 0 && lineBreakLength(endingAt: lowerBound - previousBreak) > 0)
        if followsBlankLine, lineBreakLength(startingAt: upperBound) > 0 {
            upperBound += lineBreakLength(startingAt: upperBound)
        } else if upperBound == count, lowerBound > 0, followsBlankLine {
            lowerBound -= previousBreak
        }
        return lowerBound ..< upperBound
    }
}

struct OffsetTriviaPiece {
    let piece: TriviaPiece
    let offset: Int

    var range: Range<Int> {
        offset ..< offset + piece.sourceLength.utf8Length
    }
}

extension Trivia {
    func offsetPieces(startingAt start: Int) -> [OffsetTriviaPiece] {
        var offset = start
        return pieces.map { piece in
            defer { offset += piece.sourceLength.utf8Length }
            return OffsetTriviaPiece(piece: piece, offset: offset)
        }
    }
}

extension TriviaPiece {
    var isHorizontalSpace: Bool {
        switch self {
        case .spaces, .tabs: true
        default: false
        }
    }

    var isSingleNewline: Bool {
        switch self {
        case .newlines(1), .carriageReturnLineFeeds(1), .carriageReturns(1): true
        default: false
        }
    }

    var isDocComment: Bool {
        switch self {
        case .docLineComment, .docBlockComment: true
        default: false
        }
    }

    /// Whether the piece is an `outskirts:` or `periphery:` comment command that applies to the declaration below it,
    /// that is any command but `ignore:all`.
    var isDeclarationCommentCommand: Bool {
        guard let (text, markerLength) = commentText else { return false }

        let body = text.dropFirst(markerLength).replacingOccurrences(of: "*/", with: "").trimmingCharacters(in: .whitespaces)
        guard let prefix = ["outskirts:", "periphery:"].first(where: { body.hasPrefix($0) }) else { return false }

        let command = body.dropFirst(prefix.count).split(separator: "-").first.map(String.init) ?? ""
        return command.trimmingCharacters(in: .whitespaces) != "ignore:all"
    }

    /// The text of a comment, nil for any other piece.
    var commentText: (text: String, markerLength: Int)? {
        switch self {
        case let .lineComment(text), let .blockComment(text): (text, 2)
        case let .docLineComment(text), let .docBlockComment(text): (text, 3)
        default: nil
        }
    }
}
