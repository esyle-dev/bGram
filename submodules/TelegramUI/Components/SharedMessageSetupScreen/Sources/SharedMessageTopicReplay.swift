import Foundation
import TelegramCore
import RichTextEditorCore

/// The pure half of reading a shared message's topic: given its messages in the server's order,
/// the document everyone agrees on, the open session's ops, the versions, and who holds what.
/// Kept free of accounts and signals so it can be tested on hand-made entries.
struct SharedMessageTopicReplay {
    struct Entry {
        let messageId: Int32
        let isCloud: Bool
        let authorId: EnginePeer.Id?
        let timestamp: Int32
        let payload: SharedMessageRoomPayload
    }

    struct Presence: Equatable {
        var caret: BlockID?
        var caretAt: Double
        var lastOpAt: Double
    }

    struct Result {
        /// Nil when the topic holds neither a setup nor a snapshot yet.
        var document: Document?
        /// The ops since the last snapshot, in order.
        var sessionOps: [Entry]
        var versions: [SharedEditingVersion]
        var lastSnapshotLastOpId: Int32
        /// Op ids of the account's own ops that the server has echoed.
        var acknowledgedOpIds: Set<String>
        var remote: [EnginePeer.Id: Presence]
        /// Messages of any kind after the last base (setup or snapshot): how long a fresh replay is.
        var messagesSinceBase: Int
        /// The id of the newest server message, whatever its kind.
        var lastCloudMessageId: Int32
    }

    static func replay(_ entries: [Entry], accountPeerId: EnginePeer.Id, fallback: Document) -> Result {
        var result = Result(document: nil, sessionOps: [], versions: [], lastSnapshotLastOpId: 0, acknowledgedOpIds: [], remote: [:], messagesSinceBase: 0, lastCloudMessageId: 0)
        var seenSnapshotOps = Set<Int32>()
        // What the open session started from and which blocks each author has touched in it.
        var sessionBase: Document?
        var blocksByAuthor: [EnginePeer.Id: Set<BlockID>] = [:]

        func noteRemote(_ entry: Entry, isOp: Bool) {
            guard let authorId = entry.authorId, authorId != accountPeerId else {
                return
            }
            let time = Double(entry.timestamp)
            var presence = result.remote[authorId] ?? Presence(caret: nil, caretAt: 0, lastOpAt: 0)
            presence.caret = entry.payload.caret.map(BlockID.init)
            presence.caretAt = time
            if isOp {
                presence.lastOpAt = time
            }
            result.remote[authorId] = presence
        }

        for entry in entries {
            let payload = entry.payload
            if entry.isCloud {
                result.lastCloudMessageId = max(result.lastCloudMessageId, entry.messageId)
            }
            result.messagesSinceBase += 1
            switch payload.kind {
            case .setup:
                if result.document == nil, let base = payload.document {
                    result.document = base
                    result.messagesSinceBase = 0
                    sessionBase = base
                }
            case .op:
                if entry.authorId == accountPeerId, let opId = payload.opId {
                    result.acknowledgedOpIds.insert(opId)
                }
                let before = result.document ?? fallback
                result.document = payload.apply(to: before)
                result.sessionOps.append(entry)
                noteRemote(entry, isOp: true)
                if let authorId = entry.authorId {
                    var touched = Set<BlockID>()
                    if payload.document != nil {
                        touched.formUnion(before.blocks.map { $0.id })
                        touched.formUnion(result.document?.blocks.map { $0.id } ?? [])
                    } else {
                        touched.formUnion((payload.blocks ?? []).map { $0.id })
                        touched.formUnion((payload.deleted ?? []).map(BlockID.init))
                    }
                    blocksByAuthor[authorId, default: []].formUnion(touched)
                }
            case .hold:
                noteRemote(entry, isOp: false)
            case .snapshot:
                guard let snapshotDocument = payload.document, let lastOpId = payload.lastOpId else {
                    continue
                }
                if seenSnapshotOps.contains(lastOpId) {
                    // Two clients closed the same session; the first snapshot is the version.
                    continue
                }
                seenSnapshotOps.insert(lastOpId)
                result.messagesSinceBase = 0
                if payload.isCompaction != true {
                    let authorIds = (payload.authorIds ?? []).map(EnginePeer.Id.init)
                    result.versions.append(SharedEditingVersion(id: Int(entry.messageId), timestamp: entry.timestamp, authorIds: authorIds, changeCount: payload.changeCount ?? result.sessionOps.count, isRestore: payload.restoreOf != nil, document: snapshotDocument, previousDocument: sessionBase, blocksByAuthor: blocksByAuthor))
                    sessionBase = snapshotDocument
                    blocksByAuthor = [:]
                }
                // Ops that landed after the snapshot's last op but before the snapshot itself stay applied.
                let later = result.sessionOps.filter { $0.isCloud && $0.messageId > lastOpId }
                var rebuilt = snapshotDocument
                for op in later {
                    rebuilt = op.payload.apply(to: rebuilt)
                }
                result.document = rebuilt
                result.sessionOps = later
                result.lastSnapshotLastOpId = max(result.lastSnapshotLastOpId, lastOpId)
            }
        }
        result.versions.sort(by: { $0.id > $1.id })
        return result
    }
}
