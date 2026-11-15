import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import RichTextEditorCore

/// The real transport: the shared message's topic in the group's hidden room. Every change is a
/// message in the topic (`SharedMessageRoomPayload`), everyone replays the topic in the server's
/// order, so the server is the sequencer. The account's own changes are applied at once and kept on
/// top until the server echoes them back.
final class RoomSharedEditingSession: SharedEditingSession {
    private struct RemotePresence {
        var caret: BlockID?
        var caretAt: Double
        var lastOpAt: Double
    }

    private struct Entry {
        let messageId: Int32
        let isCloud: Bool
        let authorId: EnginePeer.Id?
        let timestamp: Int32
        let payload: SharedMessageRoomPayload
    }

    /// A hold message goes out only when the caret moves to another paragraph, at most this often;
    /// between holds the typing status (not a message) keeps the lock alive.
    private static let holdInterval: Double = 5.0
    private static let holdExpiry: Double = 30.0
    private static let editingWindow: Double = 6.0
    private static let sessionIdleTimeout: Double = 120.0
    /// How many topic messages the view holds. The base must stay inside it, which compaction keeps true.
    private static let viewWindow = 1000
    /// Past this many messages after the base, a compaction snapshot is posted so a reader's window
    /// (and a cold start) never has to reach back further.
    private static let compactionThreshold = 150

    private let context: AccountContext
    private let accountPeerId: EnginePeer.Id
    private let roomId: EnginePeer.Id
    private let topicId: Int64
    private var colorIndices: [EnginePeer.Id: Int]
    private let fallbackDocument: Document

    /// The document as the topic says it is.
    private var viewDocument: Document
    /// `viewDocument` with the account's own not-yet-echoed changes on top; what the editor shows.
    private var document: Document
    private var revision: Int = 0
    private var pendingOps: [SharedMessageRoomPayload] = []

    private var localCaret: BlockID?
    private var lastHoldSentAt: Double = 0
    private var holdDirty = false
    private var remote: [EnginePeer.Id: RemotePresence] = [:]
    private var typingPeers = Set<EnginePeer.Id>()

    private var decodedPayloads: [UInt32: SharedMessageRoomPayload] = [:]
    private var fetchingFiles = Set<EngineMessage.Id>()
    private var lastMessages: [EngineMessage] = []
    private var lastCloudMessageCount: Int = 0
    /// Once the topic has given a base (setup or snapshot), a view without one is a partial reload.
    private var hasSeenBase = false
    private var viewChangedSinceRead = false
    private var lastReadMarkAt: Double = 0

    /// The ops of the open document session (since the last snapshot), in the server's order.
    private var sessionOps: [Entry] = []
    private var lastSnapshotLastOpId: Int32 = 0
    private var messagesSinceBase: Int = 0
    private var lastCloudMessageId: Int32 = 0
    private var snapshotInFlight: Int32?
    private var versionsValue: [SharedEditingVersion] = []

    private let statePromise: ValuePromise<SharedEditingState>
    private let versionsPromise: ValuePromise<[SharedEditingVersion]>
    private let readyPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let historyDisposable = MetaDisposable()
    private let pollingDisposable = MetaDisposable()
    private let activitiesDisposable = MetaDisposable()
    private let fetchDisposables = DisposableSet()
    private var timer: SwiftSignalKit.Timer?

    var state: Signal<SharedEditingState, NoError> {
        return self.statePromise.get()
    }

    var versions: Signal<[SharedEditingVersion], NoError> {
        return self.versionsPromise.get()
    }

    var currentDocument: Document {
        return self.document
    }

    var ready: Signal<Never, NoError> {
        return self.readyPromise.get()
        |> filter { $0 }
        |> take(1)
        |> ignoreValues
    }

    var hasUnsavedChanges: Bool {
        return !self.sessionOps.isEmpty || !self.pendingOps.isEmpty
    }

    init(context: AccountContext, link: SharedMessageAttribute.Link, editorPeerIds: [EnginePeer.Id], fallbackDocument: Document) {
        self.context = context
        self.accountPeerId = context.account.peerId
        self.roomId = link.roomPeerId
        self.topicId = link.topicId
        var colorIndices: [EnginePeer.Id: Int] = [:]
        for (index, peerId) in editorPeerIds.enumerated() {
            colorIndices[peerId] = index
        }
        self.colorIndices = colorIndices
        self.fallbackDocument = fallbackDocument
        self.viewDocument = fallbackDocument
        self.document = fallbackDocument

        self.statePromise = ValuePromise(SharedEditingState(document: fallbackDocument, revision: 0, participants: [], lastEdit: nil), ignoreRepeated: true)
        self.versionsPromise = ValuePromise([], ignoreRepeated: true)

        // Anchored at the newest message, so the later hole of the topic is filled as messages arrive;
        // a view around the "message of interest" stops at the first unread and never fills below it.
        self.historyDisposable.set((context.account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: self.roomId, threadId: self.topicId), index: .upperBound, anchorIndex: .upperBound, count: RoomSharedEditingSession.viewWindow, fixedCombinedReadStates: nil)
        |> deliverOnMainQueue).startStrict(next: { [weak self] view, _, _ in
            guard let self else {
                return
            }
            // Sending into the topic makes the view reload, and the reload arrives in pieces. A view
            // that is still loading, or that holds fewer server messages than the last one (nothing
            // is ever deleted from the topic), is not the topic's state: replaying it would roll the
            // document back and the editor would lose what was typed.
            let messages = view.entries.map { EngineMessage($0.message) }
            let cloudCount = messages.filter { $0.id.namespace == Namespaces.Message.Cloud }.count
            Logger.shared.log("SharedRoom", "view topic=\(self.topicId) entries=\(messages.count) cloud=\(cloudCount) isLoading=\(view.isLoading) holeEarlier=\(view.holeEarlier) holeLater=\(view.holeLater) previousCloud=\(self.lastCloudMessageCount)")
            if view.isLoading {
                return
            }
            self.lastCloudMessageCount = cloudCount
            self.lastMessages = messages
            self.viewChangedSinceRead = true
            self.reprocess()
        }))

        // Supergroup updates are only delivered while the channel is polled, which the chat does for
        // the chat on screen; the room is never on screen, so the session polls it itself.
        self.pollingDisposable.set(context.account.viewTracker.polledChannel(peerId: self.roomId).startStrict())

        let space = PeerActivitySpace(peerId: self.roomId, category: .thread(self.topicId))
        self.activitiesDisposable.set((context.account.peerInputActivities(peerId: space)
        |> deliverOnMainQueue).startStrict(next: { [weak self] activities in
            guard let self else {
                return
            }
            self.typingPeers = Set(activities.map { $0.0 })
            self.publishState()
        }))

        let timer = SwiftSignalKit.Timer(timeout: 2.0, repeat: true, completion: { [weak self] in
            self?.tick()
        }, queue: .mainQueue())
        self.timer = timer
        timer.start()
    }

    deinit {
        self.historyDisposable.dispose()
        self.pollingDisposable.dispose()
        self.activitiesDisposable.dispose()
        self.fetchDisposables.dispose()
        self.timer?.invalidate()
    }

    // MARK: - Reading the topic

    private func payload(for message: EngineMessage) -> SharedMessageRoomPayload? {
        if let payload = self.decodedPayloads[message.stableId] {
            return payload
        }
        var payload: SharedMessageRoomPayload?
        if message.text.hasPrefix("{"), let data = message.text.data(using: .utf8) {
            payload = SharedMessageRoomPayload.decode(data)
        } else if let file = message.media.first as? TelegramMediaFile, file.mimeType == "application/json" {
            if let path = self.context.engine.resources.completedResourcePath(id: EngineMediaResource.Id(file.resource.id)), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                payload = SharedMessageRoomPayload.decode(data)
            } else if !self.fetchingFiles.contains(message.id) {
                self.fetchingFiles.insert(message.id)
                let reference: MediaResourceReference = .media(media: .message(message: MessageReference(message._asMessage()), media: file), resource: file.resource)
                self.fetchDisposables.add(self.context.engine.resources.fetch(reference: reference, userLocation: .peer(self.roomId), userContentType: .file).startStrict())
                self.fetchDisposables.add((self.context.engine.resources.data(id: EngineMediaResource.Id(file.resource.id))
                |> filter { $0.isComplete }
                |> take(1)
                |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.fetchingFiles.remove(message.id)
                    self.reprocess()
                }))
            }
        }
        if let payload {
            self.decodedPayloads[message.stableId] = payload
        } else {
            Logger.shared.log("SharedRoom", "undecodable message \(message.id.id) textPrefix=\(String(message.text.prefix(20))) media=\(message.media.first.map { String(describing: type(of: $0)) } ?? "-")")
        }
        return payload
    }

    /// Replays the topic: the base from the setup or the last snapshot, then every op after it.
    private func reprocess() {
        let now = Date().timeIntervalSince1970
        var entries: [SharedMessageTopicReplay.Entry] = []
        for message in self.lastMessages {
            guard let payload = self.payload(for: message) else {
                continue
            }
            entries.append(SharedMessageTopicReplay.Entry(messageId: message.id.id, isCloud: message.id.namespace == Namespaces.Message.Cloud, authorId: message.author?.id, timestamp: message.timestamp, payload: payload))
        }
        let replay = SharedMessageTopicReplay.replay(entries, accountPeerId: self.accountPeerId, fallback: self.fallbackDocument)
        var kinds: [String: Int] = [:]
        for entry in entries {
            kinds[entry.payload.kind.rawValue, default: 0] += 1
        }
        Logger.shared.log("SharedRoom", "replay messages=\(self.lastMessages.count) decoded=\(entries.count) kinds=\(kinds) hasBase=\(replay.document != nil) sessionOps=\(replay.sessionOps.count) versions=\(replay.versions.count) pending=\(self.pendingOps.count) remote=\(replay.remote.count)")
        if replay.document == nil && self.hasSeenBase {
            Logger.shared.log("SharedRoom", "replay skipped: no base in this view")
            return
        }
        if replay.document != nil {
            self.hasSeenBase = true
        }

        self.pendingOps.removeAll(where: { op in
            if let opId = op.opId {
                return replay.acknowledgedOpIds.contains(opId)
            }
            return false
        })
        for peerId in replay.remote.keys where self.colorIndices[peerId] == nil {
            self.colorIndices[peerId] = self.colorIndices.count
        }
        if let inFlight = self.snapshotInFlight, inFlight <= replay.lastSnapshotLastOpId {
            self.snapshotInFlight = nil
        }

        // The first read of the topic is enough to open on: the setup, when it is in it, is applied in this pass.
        if replay.document != nil || !self.lastMessages.isEmpty {
            self.readyPromise.set(true)
        }
        self.messagesSinceBase = replay.messagesSinceBase
        self.lastCloudMessageId = replay.lastCloudMessageId
        self.remote = replay.remote.mapValues { RemotePresence(caret: $0.caret, caretAt: $0.caretAt, lastOpAt: $0.lastOpAt) }
        self.sessionOps = replay.sessionOps.map { Entry(messageId: $0.messageId, isCloud: $0.isCloud, authorId: $0.authorId, timestamp: $0.timestamp, payload: $0.payload) }
        self.lastSnapshotLastOpId = replay.lastSnapshotLastOpId
        self.viewDocument = replay.document ?? self.fallbackDocument

        var merged = self.viewDocument
        for op in self.pendingOps {
            merged = op.apply(to: merged)
        }
        if merged != self.document {
            self.document = merged
            self.revision += 1
        }

        if replay.versions != self.versionsValue {
            self.versionsValue = replay.versions
            self.versionsPromise.set(replay.versions)
        }
        self.publishState(now: now)
    }

    private func publishState(now: Double = Date().timeIntervalSince1970) {
        var participants: [SharedEditingParticipant] = []
        for (peerId, presence) in self.remote.sorted(by: { ($0.value.caretAt, $0.key.toInt64()) > ($1.value.caretAt, $1.key.toInt64()) }) {
            let holds = presence.caret != nil && (now - presence.caretAt < RoomSharedEditingSession.holdExpiry || self.typingPeers.contains(peerId))
            let isEditing = now - presence.lastOpAt < RoomSharedEditingSession.editingWindow || self.typingPeers.contains(peerId)
            participants.append(SharedEditingParticipant(peerId: peerId, colorIndex: self.colorIndices[peerId] ?? 0, blockId: holds ? presence.caret : nil, isEditing: isEditing))
        }
        for peerId in self.typingPeers where peerId != self.accountPeerId && self.remote[peerId] == nil {
            if self.colorIndices[peerId] == nil {
                self.colorIndices[peerId] = self.colorIndices.count
            }
            participants.append(SharedEditingParticipant(peerId: peerId, colorIndex: self.colorIndices[peerId] ?? 0, blockId: nil, isEditing: true))
        }
        // A payload still waiting in the room's local namespace has not been sent; it goes out by itself
        // once the connection is back.
        let accountPeerId = self.accountPeerId
        let hasUnsentChanges = self.lastMessages.contains(where: { $0.id.namespace != Namespaces.Message.Cloud && ($0.author?.id ?? accountPeerId) == accountPeerId })
        self.statePromise.set(SharedEditingState(document: self.document, revision: self.revision, participants: participants, lastEdit: self.lastEdit(), hasUnsentChanges: hasUnsentChanges))
    }

    private func lastEdit() -> SharedEditingLastEdit? {
        if let last = self.sessionOps.last {
            var authorIds: [EnginePeer.Id] = []
            for op in self.sessionOps.reversed() {
                if let authorId = op.authorId, !authorIds.contains(authorId) {
                    authorIds.append(authorId)
                }
            }
            return SharedEditingLastEdit(timestamp: last.timestamp, authorIds: authorIds)
        }
        if !self.pendingOps.isEmpty {
            return SharedEditingLastEdit(timestamp: Int32(Date().timeIntervalSince1970), authorIds: [self.accountPeerId])
        }
        if let version = self.versionsValue.first {
            return SharedEditingLastEdit(timestamp: version.timestamp, authorIds: version.authorIds)
        }
        return nil
    }

    // MARK: - Writing to the topic

    private func send(_ payload: SharedMessageRoomPayload) {
        Logger.shared.log("SharedRoom", "send \(payload.kind.rawValue) opId=\(payload.opId ?? "-") blocks=\(payload.blocks?.count ?? 0) caret=\(payload.caret ?? "-")")
        let _ = SharedMessageRoom.sendPayload(context: self.context, roomId: self.roomId, topicId: self.topicId, payload: payload).startStandalone()
    }

    private func setTyping(_ isTyping: Bool) {
        let space = PeerActivitySpace(peerId: self.roomId, category: .thread(self.topicId))
        self.context.account.updateLocalInputActivity(peerId: space, activity: .typingText, isPresent: isTyping)
    }

    func updateLocalDocument(_ document: Document, basedOnRevision: Int, caretBlock: BlockID?) {
        guard let op = SharedMessageRoomPayload.op(from: self.document, to: document, caret: caretBlock) else {
            Logger.shared.log("SharedRoom", "local document unchanged (revision \(basedOnRevision))")
            return
        }
        self.pendingOps.append(op)
        self.document = document
        self.revision += 1
        self.localCaret = caretBlock
        self.lastHoldSentAt = Date().timeIntervalSince1970
        self.holdDirty = false
        self.send(op)
        self.setTyping(true)
        self.publishState()
    }

    func updateLocalCaret(block: BlockID?) {
        guard block != self.localCaret else {
            return
        }
        self.localCaret = block
        let now = Date().timeIntervalSince1970
        if now - self.lastHoldSentAt >= RoomSharedEditingSession.holdInterval {
            self.sendHold(now: now)
        } else {
            self.holdDirty = true
        }
    }

    private func sendHold(now: Double) {
        var hold = SharedMessageRoomPayload(kind: .hold)
        hold.caret = self.localCaret?.rawValue
        self.lastHoldSentAt = now
        self.holdDirty = false
        self.send(hold)
    }

    func restore(versionId: Int) {
        guard let version = self.versionsValue.first(where: { $0.id == versionId }) else {
            return
        }
        var op = SharedMessageRoomPayload(kind: .op)
        op.opId = UUID().uuidString
        op.document = version.document
        op.restoreOf = Int32(versionId)
        op.caret = self.localCaret?.rawValue
        self.pendingOps.append(op)
        self.document = version.document
        self.revision += 1
        self.send(op)
        self.publishState()
    }

    func endLocalEditing() {
        let now = Date().timeIntervalSince1970
        if self.localCaret != nil {
            self.localCaret = nil
            self.sendHold(now: now)
        }
        self.setTyping(false)
        let othersActive = self.remote.values.contains { now - $0.caretAt < 10.0 || now - $0.lastOpAt < 10.0 } || !self.typingPeers.isEmpty
        if !othersActive {
            self.postSnapshotIfNeeded(now: now, idle: 0)
        }
    }

    // MARK: - Housekeeping

    private func tick() {
        let now = Date().timeIntervalSince1970
        if self.holdDirty && now - self.lastHoldSentAt >= RoomSharedEditingSession.holdInterval {
            self.sendHold(now: now)
        }
        // The typing status is the lock's heartbeat: cheap, not a message, shown for ~6 s a time.
        if self.localCaret != nil {
            self.setTyping(true)
        }
        self.postSnapshotIfNeeded(now: now, idle: RoomSharedEditingSession.sessionIdleTimeout)
        self.postCompactionIfNeeded()
        if self.viewChangedSinceRead && now - self.lastReadMarkAt > 3.0 {
            self.viewChangedSinceRead = false
            self.lastReadMarkAt = now
            let _ = self.context.engine.messages.markForumThreadAsRead(peerId: self.roomId, threadId: self.topicId).startStandalone()
        }
        self.publishState(now: now)
    }

    /// Keeps the replay short: a compaction snapshot after `compactionThreshold` messages of any kind
    /// since the last base. It is a base for readers but not a version; duplicates are dropped on read.
    private func postCompactionIfNeeded() {
        guard self.pendingOps.isEmpty, self.hasSeenBase, self.messagesSinceBase >= RoomSharedEditingSession.compactionThreshold else {
            return
        }
        let coveredId = self.lastCloudMessageId
        guard coveredId > self.lastSnapshotLastOpId, self.snapshotInFlight != coveredId else {
            return
        }
        var snapshot = SharedMessageRoomPayload(kind: .snapshot)
        snapshot.document = self.viewDocument
        snapshot.authorIds = []
        snapshot.changeCount = self.sessionOps.count
        snapshot.lastOpId = coveredId
        snapshot.isCompaction = true
        self.snapshotInFlight = coveredId
        Logger.shared.log("SharedRoom", "compaction after \(self.messagesSinceBase) messages, covering \(coveredId)")
        self.send(snapshot)
    }

    /// Closes the document session with a snapshot once its last op is `idle` seconds old. Any client
    /// may do it; a second snapshot of the same session is ignored on read.
    private func postSnapshotIfNeeded(now: Double, idle: Double) {
        guard self.pendingOps.isEmpty, let last = self.sessionOps.last, last.isCloud else {
            return
        }
        let lastOpId = last.messageId
        guard lastOpId > self.lastSnapshotLastOpId, self.snapshotInFlight != lastOpId else {
            return
        }
        guard now - Double(last.timestamp) >= idle else {
            return
        }
        var authorIds: [Int64] = []
        var allRestores = true
        var restoreOf: Int32?
        for op in self.sessionOps {
            if let authorId = op.authorId, !authorIds.contains(authorId.toInt64()) {
                authorIds.append(authorId.toInt64())
            }
            if let restored = op.payload.restoreOf {
                restoreOf = restored
            } else {
                allRestores = false
            }
        }
        var snapshot = SharedMessageRoomPayload(kind: .snapshot)
        snapshot.document = self.viewDocument
        snapshot.authorIds = authorIds
        snapshot.changeCount = self.sessionOps.count
        snapshot.lastOpId = lastOpId
        snapshot.restoreOf = allRestores ? restoreOf : nil
        self.snapshotInFlight = lastOpId
        self.send(snapshot)
    }
}
