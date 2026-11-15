import Foundation
import RichTextEditorCore

/// What one message in a shared message's topic says. JSON in the message text, or in an attached
/// JSON file when it does not fit a message.
struct SharedMessageRoomPayload: Codable {
    enum Kind: String, Codable {
        /// The first message of the topic: the message as it was when sharing started.
        case setup
        /// Blocks that changed, blocks that went, the order of blocks, and where the author's caret is.
        case op
        /// Only where the author's caret is (or that it left), so others keep that paragraph locked.
        case hold
        /// The document at the end of a session: a version.
        case snapshot
    }

    var version: Int = 1
    var kind: Kind
    /// Client-generated for an op, so a client recognises its own op once the server echoes it.
    var opId: String?
    var title: String?
    /// The base document of a setup, the whole document of a snapshot, or a whole replacement in an op.
    var document: Document?
    var blocks: [Block]?
    var deleted: [String]?
    var order: [String]?
    var caret: String?
    /// The snapshot message an op restores.
    var restoreOf: Int32?
    var authorIds: [Int64]?
    var changeCount: Int?
    /// The id of the last message a snapshot covers; two clients closing one session post equal values.
    var lastOpId: Int32?
    /// A snapshot posted only to keep the topic's replay short: a base for readers, not a version.
    var isCompaction: Bool?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind = "k"
        case opId = "id"
        case title = "t"
        case document = "d"
        case blocks = "b"
        case deleted = "x"
        case order = "o"
        case caret = "c"
        case restoreOf = "r"
        case authorIds = "a"
        case changeCount = "n"
        case lastOpId = "l"
        case isCompaction = "q"
    }

    init(kind: Kind) {
        self.kind = kind
    }

    static func encode(_ payload: SharedMessageRoomPayload) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    static func decode(_ data: Data) -> SharedMessageRoomPayload? {
        return try? JSONDecoder().decode(SharedMessageRoomPayload.self, from: data)
    }

    /// Applies an op to a document: a whole replacement, else changed blocks by id, removals, order.
    func apply(to document: Document) -> Document {
        if let replacement = self.document {
            return replacement
        }
        var result = document
        var indexById: [String: Int] = [:]
        for (index, block) in result.blocks.enumerated() {
            indexById[block.id.rawValue] = index
        }
        for block in self.blocks ?? [] {
            if let index = indexById[block.id.rawValue] {
                result.blocks[index] = block
            } else {
                indexById[block.id.rawValue] = result.blocks.count
                result.blocks.append(block)
            }
        }
        if let deleted = self.deleted, !deleted.isEmpty {
            let removed = Set(deleted)
            result.blocks.removeAll(where: { removed.contains($0.id.rawValue) })
        }
        if let order = self.order, !order.isEmpty {
            let byId = Dictionary(result.blocks.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
            var ordered: [Block] = []
            var placed = Set<String>()
            for id in order {
                if let block = byId[id], !placed.contains(id) {
                    ordered.append(block)
                    placed.insert(id)
                }
            }
            // Blocks the order does not know (added by an op this one did not see) keep their place at the end.
            for block in result.blocks where !placed.contains(block.id.rawValue) {
                ordered.append(block)
            }
            result.blocks = ordered
        }
        return result
    }

    /// The op that turns `from` into `to`, or nil when they are equal.
    static func op(from: Document, to: Document, caret: BlockID?) -> SharedMessageRoomPayload? {
        guard from != to else {
            return nil
        }
        var payload = SharedMessageRoomPayload(kind: .op)
        payload.opId = UUID().uuidString
        let previousById = Dictionary(from.blocks.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [Block] = []
        var currentIds = Set<String>()
        for block in to.blocks {
            currentIds.insert(block.id.rawValue)
            if previousById[block.id.rawValue] != block {
                changed.append(block)
            }
        }
        payload.blocks = changed.isEmpty ? nil : changed
        let deleted = from.blocks.map { $0.id.rawValue }.filter { !currentIds.contains($0) }
        payload.deleted = deleted.isEmpty ? nil : deleted
        if from.blocks.map({ $0.id }) != to.blocks.map({ $0.id }) {
            payload.order = to.blocks.map { $0.id.rawValue }
        }
        payload.caret = caret?.rawValue
        if payload.blocks == nil && payload.deleted == nil && payload.order == nil {
            // Same blocks and order but a different document-level field: replace the whole document.
            payload.document = to
        }
        return payload
    }
}
