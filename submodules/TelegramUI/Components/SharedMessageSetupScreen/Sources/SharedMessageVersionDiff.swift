import Foundation
import RichTextEditorCore

/// What one version changed against the document its session started from, as lines of runs: a
/// word-level diff per paragraph, whole lines for paragraphs that came or went. Pure, for tests.
struct SharedMessageVersionDiff {
    enum RunKind: Equatable {
        case equal
        case inserted
        case deleted
    }

    struct Run: Equatable {
        let text: String
        let kind: RunKind
    }

    struct Line: Equatable {
        let blockId: BlockID
        let style: ParagraphStyleName
        let list: ListMembership?
        let runs: [Run]

        var isWhollyInserted: Bool {
            return !runs.isEmpty && runs.allSatisfy { $0.kind == .inserted }
        }

        var isWhollyDeleted: Bool {
            return !runs.isEmpty && runs.allSatisfy { $0.kind == .deleted }
        }
    }

    /// `onlyBlocks` limits the highlighted changes to those blocks (an author's tab); other blocks
    /// show their new text unmarked.
    static func lines(from old: Document?, to new: Document, onlyBlocks: Set<BlockID>? = nil) -> [Line] {
        let oldBlocks = old?.blocks ?? []
        let oldById = Dictionary(oldBlocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIds = Set(new.blocks.map { $0.id })

        // Deleted blocks are shown after the last surviving block that preceded them.
        var deletedAfter: [BlockID?: [Block]] = [:]
        var lastSurviving: BlockID?
        for block in oldBlocks {
            if newIds.contains(block.id) {
                lastSurviving = block.id
            } else {
                deletedAfter[lastSurviving, default: []].append(block)
            }
        }

        func highlighted(_ id: BlockID) -> Bool {
            return onlyBlocks?.contains(id) ?? true
        }

        var result: [Line] = []
        func appendDeleted(after id: BlockID?) {
            for block in deletedAfter[id] ?? [] where highlighted(block.id) {
                let text = plainText(of: block)
                result.append(Line(blockId: block.id, style: paragraphStyle(of: block), list: listMembership(of: block), runs: text.isEmpty ? [] : [Run(text: text, kind: .deleted)]))
            }
        }
        appendDeleted(after: nil)
        for block in new.blocks {
            let text = plainText(of: block)
            let style = paragraphStyle(of: block)
            let list = listMembership(of: block)
            if let oldBlock = oldById[block.id] {
                let oldText = plainText(of: oldBlock)
                if !highlighted(block.id) || oldText == text {
                    result.append(Line(blockId: block.id, style: style, list: list, runs: text.isEmpty ? [] : [Run(text: text, kind: .equal)]))
                } else {
                    result.append(Line(blockId: block.id, style: style, list: list, runs: wordDiff(old: oldText, new: text)))
                }
            } else {
                let kind: RunKind = highlighted(block.id) ? .inserted : .equal
                result.append(Line(blockId: block.id, style: style, list: list, runs: text.isEmpty ? [] : [Run(text: text, kind: kind)]))
            }
            appendDeleted(after: block.id)
        }
        return result
    }

    static func plainText(of block: Block) -> String {
        switch block {
        case let .paragraph(paragraph):
            return paragraph.text
        case let .code(code):
            return code.runs.map { $0.text }.joined()
        default:
            return "\u{2022}\u{2022}\u{2022}"
        }
    }

    static func paragraphStyle(of block: Block) -> ParagraphStyleName {
        if case let .paragraph(paragraph) = block {
            return paragraph.style
        }
        return .body
    }

    static func listMembership(of block: Block) -> ListMembership? {
        if case let .paragraph(paragraph) = block {
            return paragraph.list
        }
        return nil
    }

    /// Words and the whitespace between them are the tokens; the longest common subsequence decides
    /// what stayed, and equal runs are merged so a line reads as a few spans rather than many.
    static func wordDiff(old: String, new: String) -> [Run] {
        let oldTokens = tokens(of: old)
        let newTokens = tokens(of: new)
        let n = oldTokens.count
        let m = newTokens.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if oldTokens[i] == newTokens[j] {
                        table[i][j] = table[i + 1][j + 1] + 1
                    } else {
                        table[i][j] = max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
        }
        var runs: [Run] = []
        func append(_ text: String, _ kind: RunKind) {
            if let last = runs.last, last.kind == kind {
                runs[runs.count - 1] = Run(text: last.text + text, kind: kind)
            } else {
                runs.append(Run(text: text, kind: kind))
            }
        }
        var i = 0
        var j = 0
        while i < n && j < m {
            if oldTokens[i] == newTokens[j] {
                append(oldTokens[i], .equal)
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                append(oldTokens[i], .deleted)
                i += 1
            } else {
                append(newTokens[j], .inserted)
                j += 1
            }
        }
        while i < n {
            append(oldTokens[i], .deleted)
            i += 1
        }
        while j < m {
            append(newTokens[j], .inserted)
            j += 1
        }
        return runs
    }

    private static func tokens(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for character in text {
            let isSpace = character.isWhitespace
            if let was = currentIsSpace, was != isSpace {
                result.append(current)
                current = ""
            }
            current.append(character)
            currentIsSpace = isSpace
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
