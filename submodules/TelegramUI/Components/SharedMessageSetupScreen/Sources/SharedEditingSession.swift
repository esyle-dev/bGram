import Foundation
import SwiftSignalKit
import TelegramCore
import RichTextEditorCore

/// Someone else in the document: where they are and whether they are typing right now.
public struct SharedEditingParticipant: Equatable {
    public let peerId: EnginePeer.Id
    /// Index into the message's editor palette, by order of first participation.
    public let colorIndex: Int
    /// The block they hold; others cannot enter it while it is held.
    public let blockId: BlockID?
    public let isEditing: Bool

    public init(peerId: EnginePeer.Id, colorIndex: Int, blockId: BlockID?, isEditing: Bool) {
        self.peerId = peerId
        self.colorIndex = colorIndex
        self.blockId = blockId
        self.isEditing = isEditing
    }
}

/// One autosaved version: a snapshot of the document at the end of a document session.
public struct SharedEditingVersion: Equatable {
    public let id: Int
    public let timestamp: Int32
    /// Everyone who edited during the session, in order of first edit.
    public let authorIds: [EnginePeer.Id]
    public let changeCount: Int
    /// The session consisted of restoring an earlier version.
    public let isRestore: Bool
    public let document: Document
    /// The document the session started from, for showing what the session changed.
    public let previousDocument: Document?
    /// The blocks each author changed during the session.
    public let blocksByAuthor: [EnginePeer.Id: Set<BlockID>]

    public init(id: Int, timestamp: Int32, authorIds: [EnginePeer.Id], changeCount: Int, isRestore: Bool = false, document: Document, previousDocument: Document? = nil, blocksByAuthor: [EnginePeer.Id: Set<BlockID>] = [:]) {
        self.id = id
        self.timestamp = timestamp
        self.authorIds = authorIds
        self.changeCount = changeCount
        self.isRestore = isRestore
        self.document = document
        self.previousDocument = previousDocument
        self.blocksByAuthor = blocksByAuthor
    }
}

/// The latest change: when it was made and who made the changes of the session it belongs to,
/// most recent author first.
public struct SharedEditingLastEdit: Equatable {
    public let timestamp: Int32
    public let authorIds: [EnginePeer.Id]

    public init(timestamp: Int32, authorIds: [EnginePeer.Id]) {
        self.timestamp = timestamp
        self.authorIds = authorIds
    }
}

public struct SharedEditingState: Equatable {
    public let document: Document
    /// Grows with every change, local or remote. The host reports the revision its edits are based on.
    public let revision: Int
    /// The other people in the document. The account itself is never listed.
    public let participants: [SharedEditingParticipant]
    public let lastEdit: SharedEditingLastEdit?
    /// Changes of this account that are stored on the device but have not reached the server yet.
    public let hasUnsentChanges: Bool

    public init(document: Document, revision: Int, participants: [SharedEditingParticipant], lastEdit: SharedEditingLastEdit?, hasUnsentChanges: Bool = false) {
        self.document = document
        self.revision = revision
        self.participants = participants
        self.lastEdit = lastEdit
        self.hasUnsentChanges = hasUnsentChanges
    }
}

/// A shared message's editing session as the editor sees it: the current document, who is in it,
/// and its versions. The editor sends its own changes in and receives everyone's changes out.
/// The transport behind it is not the editor's concern; today it is a local simulation.
public protocol SharedEditingSession: AnyObject {
    var state: Signal<SharedEditingState, NoError> { get }
    var versions: Signal<[SharedEditingVersion], NoError> { get }
    var currentDocument: Document { get }
    var hasUnsavedChanges: Bool { get }
    /// Completes once `currentDocument` is the shared one (the topic has been read), so the editor
    /// opens on the blocks everyone else has rather than on a local copy with its own ids.
    var ready: Signal<Never, NoError> { get }

    func updateLocalDocument(_ document: Document, basedOnRevision: Int, caretBlock: BlockID?)
    func updateLocalCaret(block: BlockID?)
    func restore(versionId: Int)
    /// The account closed the editor. Ends the document session if nobody else is typing.
    func endLocalEditing()
}

/// Keeps one session per shared message alive while the app runs, so closing and reopening the
/// editor keeps the versions and the simulated collaborators' progress.
public final class SharedEditingSessionStore {
    public static let shared = SharedEditingSessionStore()

    private var sessions: [EngineMessage.Id: (key: String, session: SharedEditingSession)] = [:]

    /// A room session replaces a simulated one once the message's room becomes reachable, and a
    /// simulated one is re-seeded when the message it stands in for has changed (`key`).
    public func session(for messageId: EngineMessage.Id, key: String, preferringRoom: Bool = false, make: () -> SharedEditingSession) -> SharedEditingSession {
        if let existing = self.sessions[messageId] {
            if existing.session is SimulatedSharedEditingSession {
                if !preferringRoom && existing.key == key {
                    return existing.session
                }
            } else {
                return existing.session
            }
        }
        let session = make()
        self.sessions[messageId] = (key, session)
        return session
    }
}

/// A local stand-in for the real transport: scripted collaborators type into the document on the
/// cadence the real room will have (one change every 1–2 s), hold the paragraph they type in, and
/// the document session ends into a version when everyone has been quiet for two minutes.
public final class SimulatedSharedEditingSession: SharedEditingSession {
    private enum PeerActivity {
        case idle(until: Double)
        case typing(blockId: BlockID, words: [String], nextAt: Double)
    }

    private struct Op {
        let authorId: EnginePeer.Id
        let blockId: BlockID?
        let time: Double
        var isRestore: Bool = false
    }

    private static let tickInterval: Double = 1.5
    private static let sessionIdleTimeout: Double = 120.0
    private static let phrases: [String] = [
        "and bring spare gloves",
        "— moved to 11:30, see Fred",
        "(check with Katie first)",
        "Wood says no excuses this time",
        "see the pinned playbook",
        "meet at the changing rooms",
    ]

    private let accountPeerId: EnginePeer.Id
    private let otherPeerIds: [EnginePeer.Id]
    private let colorIndices: [EnginePeer.Id: Int]

    private var document: Document
    private var revision: Int = 0
    private var blockRevision: [BlockID: Int] = [:]
    private var localCaretBlock: BlockID?
    private var activities: [EnginePeer.Id: PeerActivity] = [:]
    private var phraseIndex = 0

    private var ops: [Op] = []
    private var sessionBaseDocument: Document
    private var versionsValue: [SharedEditingVersion] = []
    private var nextVersionId = 1

    private let statePromise: ValuePromise<SharedEditingState>
    private let versionsPromise: ValuePromise<[SharedEditingVersion]>
    private var timer: SwiftSignalKit.Timer?

    public var state: Signal<SharedEditingState, NoError> {
        return self.statePromise.get()
    }

    public var versions: Signal<[SharedEditingVersion], NoError> {
        return self.versionsPromise.get()
    }

    public var ready: Signal<Never, NoError> {
        return .complete()
    }

    public var currentDocument: Document {
        return self.document
    }

    public var hasUnsavedChanges: Bool {
        return !self.ops.isEmpty
    }

    public init(accountPeerId: EnginePeer.Id, editorPeerIds: [EnginePeer.Id], initialDocument: Document, sharedAt: Int32) {
        self.accountPeerId = accountPeerId
        self.otherPeerIds = editorPeerIds.filter { $0 != accountPeerId }
        var colorIndices: [EnginePeer.Id: Int] = [:]
        for (index, peerId) in editorPeerIds.enumerated() {
            colorIndices[peerId] = index
        }
        self.colorIndices = colorIndices
        self.document = initialDocument
        self.sessionBaseDocument = initialDocument

        let now = Date().timeIntervalSince1970
        for (index, peerId) in self.otherPeerIds.enumerated() {
            self.activities[peerId] = .idle(until: now + 4.0 + Double(index) * 7.0)
        }

        // Earlier versions, so the history has something to show before the first real session ends.
        self.versionsValue = SimulatedSharedEditingSession.seededVersions(document: initialDocument, authorIds: editorPeerIds, sharedAt: sharedAt, now: Int32(now))
        self.nextVersionId = self.versionsValue.count + 1

        let initialLastEdit = self.versionsValue.first.map { SharedEditingLastEdit(timestamp: $0.timestamp, authorIds: $0.authorIds) }
        self.statePromise = ValuePromise(SharedEditingState(document: initialDocument, revision: 0, participants: [], lastEdit: initialLastEdit), ignoreRepeated: true)
        self.versionsPromise = ValuePromise(self.versionsValue, ignoreRepeated: true)

        let timer = SwiftSignalKit.Timer(timeout: SimulatedSharedEditingSession.tickInterval, repeat: true, completion: { [weak self] in
            self?.tick()
        }, queue: Queue.mainQueue())
        self.timer = timer
        timer.start()
    }

    deinit {
        self.timer?.invalidate()
    }

    // MARK: - Local edits

    public func updateLocalDocument(_ newDocument: Document, basedOnRevision: Int, caretBlock: BlockID?) {
        self.localCaretBlock = caretBlock

        // Keep the blocks someone else changed after the revision this edit was based on: the editor
        // had not seen those changes yet, so its copy of them is stale.
        var merged = newDocument
        for (index, block) in self.document.blocks.enumerated() {
            guard let changedAt = self.blockRevision[block.id], changedAt > basedOnRevision else {
                continue
            }
            if let position = merged.blocks.firstIndex(where: { $0.id == block.id }) {
                merged.blocks[position] = block
            } else {
                merged.blocks.insert(block, at: min(index, merged.blocks.count))
            }
        }

        guard merged != self.document else {
            self.publishState()
            return
        }
        let now = Date().timeIntervalSince1970
        let previousById = Dictionary(self.document.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var touched = false
        for block in merged.blocks where previousById[block.id] != block {
            self.ops.append(Op(authorId: self.accountPeerId, blockId: block.id, time: now))
            touched = true
        }
        if !touched {
            self.ops.append(Op(authorId: self.accountPeerId, blockId: nil, time: now))
        }
        self.document = merged
        self.revision += 1
        self.publishState()
    }

    public func updateLocalCaret(block: BlockID?) {
        self.localCaretBlock = block
    }

    public func restore(versionId: Int) {
        guard let version = self.versionsValue.first(where: { $0.id == versionId }) else {
            return
        }
        self.document = version.document
        self.revision += 1
        for block in self.document.blocks {
            self.blockRevision[block.id] = self.revision
        }
        self.ops.append(Op(authorId: self.accountPeerId, blockId: nil, time: Date().timeIntervalSince1970, isRestore: true))
        self.publishState()
    }

    public func endLocalEditing() {
        self.localCaretBlock = nil
        let anyoneTyping = self.activities.values.contains { activity in
            if case .typing = activity {
                return true
            }
            return false
        }
        if !anyoneTyping {
            self.closeDocumentSession()
        }
    }

    // MARK: - Simulation

    private func tick() {
        let now = Date().timeIntervalSince1970
        var changed = false

        for peerId in self.otherPeerIds {
            guard let activity = self.activities[peerId] else {
                continue
            }
            switch activity {
            case let .idle(until):
                guard now >= until, let blockId = self.pickBlockToEdit(for: peerId) else {
                    continue
                }
                let phrase = SimulatedSharedEditingSession.phrases[self.phraseIndex % SimulatedSharedEditingSession.phrases.count]
                self.phraseIndex += 1
                self.activities[peerId] = .typing(blockId: blockId, words: phrase.split(separator: " ").map(String.init), nextAt: now)
                changed = true
            case let .typing(blockId, words, nextAt):
                guard now >= nextAt else {
                    continue
                }
                guard let word = words.first, self.append(word: word, toBlock: blockId) else {
                    self.activities[peerId] = .idle(until: now + Double.random(in: 8.0 ... 16.0))
                    changed = true
                    continue
                }
                self.ops.append(Op(authorId: peerId, blockId: blockId, time: now))
                self.revision += 1
                self.blockRevision[blockId] = self.revision
                let remaining = Array(words.dropFirst())
                if remaining.isEmpty {
                    self.activities[peerId] = .idle(until: now + Double.random(in: 8.0 ... 16.0))
                } else {
                    self.activities[peerId] = .typing(blockId: blockId, words: remaining, nextAt: now + Double.random(in: 1.0 ... 2.0))
                }
                changed = true
            }
        }

        if let lastOp = self.ops.last, now - lastOp.time > SimulatedSharedEditingSession.sessionIdleTimeout {
            self.closeDocumentSession()
        }
        if changed {
            self.publishState()
        }
    }

    /// A paragraph with text that nobody holds, preferring the later ones.
    private func pickBlockToEdit(for peerId: EnginePeer.Id) -> BlockID? {
        var held = Set<BlockID>()
        if let localCaretBlock = self.localCaretBlock {
            held.insert(localCaretBlock)
        }
        for (otherId, activity) in self.activities where otherId != peerId {
            if case let .typing(blockId, _, _) = activity {
                held.insert(blockId)
            }
        }
        let candidates = self.document.blocks.compactMap { block -> BlockID? in
            guard case let .paragraph(paragraph) = block, paragraph.utf16Count > 0, !held.contains(paragraph.id) else {
                return nil
            }
            return paragraph.id
        }
        guard !candidates.isEmpty else {
            return nil
        }
        let fromEnd = min(candidates.count - 1, Int.random(in: 0 ... 2))
        return candidates[candidates.count - 1 - fromEnd]
    }

    private func append(word: String, toBlock blockId: BlockID) -> Bool {
        guard let index = self.document.blocks.firstIndex(where: { $0.id == blockId }), case var .paragraph(paragraph) = self.document.blocks[index] else {
            return false
        }
        if self.localCaretBlock == blockId {
            return false
        }
        let needsSpace = !(paragraph.text.last?.isWhitespace ?? true)
        let insertion = (needsSpace ? " " : "") + word
        if paragraph.runs.isEmpty {
            paragraph.runs = [TextRun(text: insertion)]
        } else {
            paragraph.runs[paragraph.runs.count - 1].text += insertion
        }
        self.document.blocks[index] = .paragraph(paragraph)
        return true
    }

    private func closeDocumentSession() {
        guard !self.ops.isEmpty else {
            return
        }
        var authorIds: [EnginePeer.Id] = []
        for op in self.ops where !authorIds.contains(op.authorId) {
            authorIds.append(op.authorId)
        }
        let isRestore = self.ops.allSatisfy { $0.isRestore }
        var blocksByAuthor: [EnginePeer.Id: Set<BlockID>] = [:]
        for op in self.ops {
            if let blockId = op.blockId {
                blocksByAuthor[op.authorId, default: []].insert(blockId)
            }
        }
        let version = SharedEditingVersion(id: self.nextVersionId, timestamp: Int32(Date().timeIntervalSince1970), authorIds: authorIds, changeCount: self.ops.count, isRestore: isRestore, document: self.document, previousDocument: self.sessionBaseDocument, blocksByAuthor: blocksByAuthor)
        self.sessionBaseDocument = self.document
        self.nextVersionId += 1
        self.versionsValue.insert(version, at: 0)
        self.ops.removeAll()
        self.versionsPromise.set(self.versionsValue)
    }

    private func publishState() {
        let now = Date().timeIntervalSince1970
        var participants: [SharedEditingParticipant] = []
        for peerId in self.otherPeerIds {
            var blockId: BlockID?
            var isEditing = false
            if case let .typing(heldBlock, _, _)? = self.activities[peerId] {
                blockId = heldBlock
                isEditing = true
            }
            let recentlyTyped = self.ops.last(where: { $0.authorId == peerId }).map { now - $0.time < 5.0 } ?? false
            participants.append(SharedEditingParticipant(peerId: peerId, colorIndex: self.colorIndices[peerId] ?? 0, blockId: blockId, isEditing: isEditing || recentlyTyped))
        }
        self.statePromise.set(SharedEditingState(document: self.document, revision: self.revision, participants: participants, lastEdit: self.lastEdit()))
    }

    /// The open session's latest change with its authors, most recent first; the last closed version when nothing is open.
    private func lastEdit() -> SharedEditingLastEdit? {
        if let lastOp = self.ops.last {
            var authorIds: [EnginePeer.Id] = []
            for op in self.ops.reversed() where !authorIds.contains(op.authorId) {
                authorIds.append(op.authorId)
            }
            return SharedEditingLastEdit(timestamp: Int32(lastOp.time), authorIds: authorIds)
        }
        if let version = self.versionsValue.first {
            return SharedEditingLastEdit(timestamp: version.timestamp, authorIds: version.authorIds)
        }
        return nil
    }

    private static func seededVersions(document: Document, authorIds: [EnginePeer.Id], sharedAt: Int32, now: Int32) -> [SharedEditingVersion] {
        guard document.blocks.count > 1 else {
            return []
        }
        var result: [SharedEditingVersion] = []
        let baseTime = sharedAt > 0 ? sharedAt : now - 3 * 24 * 60 * 60
        let steps = min(3, document.blocks.count - 1)
        for step in 0 ..< steps {
            var older = document
            older.blocks.removeLast(step + 1)
            var evenOlder = older
            evenOlder.blocks.removeLast()
            let timestamp = max(baseTime, now - Int32(step + 1) * 26 * 60 * 60)
            let authors = Array(authorIds.prefix(step % 2 == 0 ? 2 : 1))
            var blocksByAuthor: [EnginePeer.Id: Set<BlockID>] = [:]
            if let last = older.blocks.last, let author = authors.first {
                blocksByAuthor[author] = [last.id]
            }
            result.append(SharedEditingVersion(id: steps - step, timestamp: timestamp, authorIds: authors, changeCount: 2 + step * 3, document: older, previousDocument: evenOlder, blocksByAuthor: blocksByAuthor))
        }
        return result
    }
}
