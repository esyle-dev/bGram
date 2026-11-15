import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import RichTextEditorCore
import RichTextEditorMessageConversion
import ChatRichTextEditorComposer

/// `then` needs both sides to carry the same value type; this runs `next` after a value-less signal completes.
private func afterCompletion<T, E>(_ signal: Signal<Never, E>, _ next: Signal<T, E>) -> Signal<T, E> {
    return Signal { subscriber in
        let disposable = MetaDisposable()
        disposable.set(signal.start(error: { error in
            subscriber.putError(error)
        }, completed: {
            disposable.set(next.start(next: { value in
                subscriber.putNext(value)
            }, error: { error in
                subscriber.putError(error)
            }, completed: {
                subscriber.putCompletion()
            }))
        }))
        return disposable
    }
}

/// The hidden forum supergroup a group's shared messages are edited in: one room per source group,
/// one topic per shared message. Rooms are muted and archived for everyone, and clients hide a peer
/// whose title starts with `SharedMessageAttribute.roomTitleMarker` from the chat list.
public enum SharedMessageRoom {
    public enum ShareError {
        case generic
    }

    /// The room created for a source group, remembered per account so the next shared message of the
    /// group reuses it. Local only: another device of the same account makes its own room.
    private static func storedRoomKey(accountPeerId: EnginePeer.Id) -> String {
        return "SharedMessageRooms.\(accountPeerId.toInt64())"
    }

    static func storedRoomId(accountPeerId: EnginePeer.Id, groupId: EnginePeer.Id) -> EnginePeer.Id? {
        let map = UserDefaults.standard.dictionary(forKey: storedRoomKey(accountPeerId: accountPeerId)) as? [String: NSNumber]
        guard let value = map?["\(groupId.toInt64())"] else {
            return nil
        }
        return EnginePeer.Id(value.int64Value)
    }

    static func storeRoomId(_ roomId: EnginePeer.Id, accountPeerId: EnginePeer.Id, groupId: EnginePeer.Id) {
        let key = storedRoomKey(accountPeerId: accountPeerId)
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: NSNumber]) ?? [:]
        map["\(groupId.toInt64())"] = NSNumber(value: roomId.toInt64())
        UserDefaults.standard.set(map, forKey: key)
    }

    public static func isRoom(_ peer: EnginePeer) -> Bool {
        if case let .channel(channel) = peer {
            return channel.title.hasPrefix(SharedMessageAttribute.roomTitleMarker)
        }
        return false
    }

    /// Mutes and archives the room, which is all the server lets a client do to keep it out of the way.
    static func quieten(context: AccountContext, roomId: EnginePeer.Id) -> Signal<Never, NoError> {
        return context.engine.peers.updatePeerMuteSetting(peerId: roomId, threadId: nil, muteInterval: Int32.max)
        |> ignoreValues
        |> then(context.engine.peers.updatePeersGroupIdInteractively(peerIds: [roomId], groupId: .archive))
    }

    /// The room of a source group: the remembered one if the account is still in it, else a new one.
    static func roomId(context: AccountContext, groupId: EnginePeer.Id, groupTitle: String) -> Signal<EnginePeer.Id, ShareError> {
        let accountPeerId = context.account.peerId
        let existing: Signal<EnginePeer.Id?, NoError>
        if let storedId = storedRoomId(accountPeerId: accountPeerId, groupId: groupId) {
            existing = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: storedId))
            |> map { peer -> EnginePeer.Id? in
                if case let .channel(channel)? = peer, channel.participationStatus == .member {
                    return storedId
                }
                return nil
            }
        } else {
            existing = .single(nil)
        }
        return existing
        |> castError(ShareError.self)
        |> mapToSignal { roomId -> Signal<EnginePeer.Id, ShareError> in
            if let roomId {
                return .single(roomId)
            }
            let title = SharedMessageAttribute.roomTitleMarker + groupTitle
            return context.engine.peers.createSupergroup(title: title, description: "Shared messages of \(groupTitle)", isForum: true)
            |> mapError { _ -> ShareError in
                return .generic
            }
            |> mapToSignal { roomId -> Signal<EnginePeer.Id, ShareError> in
                storeRoomId(roomId, accountPeerId: accountPeerId, groupId: groupId)
                return afterCompletion(quieten(context: context, roomId: roomId) |> castError(ShareError.self), .single(roomId))
            }
        }
    }

    /// The hash of the room's primary invite link, for editors who could not be added directly.
    private static func inviteHash(context: AccountContext, roomId: EnginePeer.Id) -> Signal<String?, NoError> {
        return context.engine.peers.createPeerExportedInvitation(peerId: roomId, title: nil, expireDate: nil, usageLimit: nil, requestNeeded: nil, subscriptionPricing: nil)
        |> map { invitation -> String? in
            guard case let .link(link, _, _, _, _, _, _, _, _, _, _, _, _)? = invitation else {
                return nil
            }
            // "https://t.me/+HASH" or "https://t.me/joinchat/HASH"
            guard let last = link.split(separator: "/").last else {
                return nil
            }
            var hash = String(last)
            if hash.hasPrefix("+") {
                hash.removeFirst()
            }
            return hash.isEmpty ? nil : hash
        }
        |> `catch` { _ -> Signal<String?, NoError> in
            return .single(nil)
        }
    }

    /// Makes a message shared for real: finds or creates the group's room, opens the message's topic,
    /// posts the base document, lets the editors in, writes the marker into the message, and records
    /// the settings locally. The local record is written first so the bubble changes at once; the
    /// link lands when the room is ready.
    public static func shareMessage(context: AccountContext, message: EngineMessage, result: SharedMessageSetupResult) -> Signal<Never, ShareError> {
        let messageId = message.id
        let groupId = message.id.peerId
        let groupTitle = message.peers[groupId].map { EnginePeer($0).compactDisplayTitle } ?? ""
        let content = sharedMessageEditorContent(message: message)

        let recordLocally = context.engine.messages.makeMessageShared(messageId: messageId, title: result.title, access: result.access, peerIds: result.peerIds, closeEditing: result.closeEditing, commentsEnabled: result.commentsEnabled, notifyChanges: result.notifyChanges)
        |> castError(ShareError.self)

        return afterCompletion(recordLocally, roomId(context: context, groupId: groupId, groupTitle: groupTitle))
        |> mapToSignal { roomId -> Signal<Never, ShareError> in
            return context.engine.peers.createForumChannelTopic(id: roomId, title: "\(messageId.id)", iconColor: 0x6FB9F0, iconFileId: nil)
            |> mapError { _ -> ShareError in
                return .generic
            }
            |> mapToSignal { topicId -> Signal<Never, ShareError> in
                var setup = SharedMessageRoomPayload(kind: .setup)
                setup.title = result.title
                setup.document = content.document
                let postSetup = sendPayload(context: context, roomId: roomId, topicId: topicId, payload: setup)

                let members = result.peerIds.filter { $0 != context.account.peerId }
                let addMembers: Signal<Never, NoError>
                if members.isEmpty {
                    addMembers = .complete()
                } else {
                    addMembers = context.engine.peers.addChannelMembers(peerId: roomId, memberIds: members)
                    |> ignoreValues
                    |> `catch` { _ -> Signal<Never, NoError> in
                        // Privacy settings or limits: those editors join through the invite in the marker.
                        return .complete()
                    }
                }

                return postSetup
                |> then(addMembers)
                |> then(inviteHash(context: context, roomId: roomId) |> mapToSignal { hash -> Signal<Never, NoError> in
                    let link = SharedMessageAttribute.Link(roomPeerId: roomId, topicId: topicId, inviteHash: hash)
                    let attribute = SharedMessageAttribute(title: result.title, access: result.access, peerIds: result.peerIds, closeEditing: result.closeEditing, commentsEnabled: result.commentsEnabled, notifyChanges: result.notifyChanges, link: link)
                    return writeMarker(context: context, message: message, attribute: attribute)
                    |> then(context.engine.messages.makeMessageShared(messageId: messageId, title: result.title, access: result.access, peerIds: result.peerIds, closeEditing: result.closeEditing, commentsEnabled: result.commentsEnabled, notifyChanges: result.notifyChanges, link: link))
                })
                |> castError(ShareError.self)
            }
        }
    }

    /// The message as it is now: the editor may have saved it since it was opened.
    private static func latestMessage(context: AccountContext, id: EngineMessage.Id) -> Signal<EngineMessage?, NoError> {
        return context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: id))
    }

    /// Changes the settings of a shared message (Manage Editing): the local record first, then the
    /// editors the new selection added are let into the room, then the marker is rewritten. Saving
    /// the settings again reopens a message closed by hand. Only the author can.
    static func updateSettings(context: AccountContext, messageId: EngineMessage.Id, result: SharedMessageSetupResult) -> Signal<Never, NoError> {
        return latestMessage(context: context, id: messageId)
        |> mapToSignal { message -> Signal<Never, NoError> in
            guard let message, let shared = message.attributes.first(where: { $0 is SharedMessageAttribute }) as? SharedMessageAttribute else {
                return .complete()
            }
            let recordLocally = context.engine.messages.makeMessageShared(messageId: messageId, title: result.title, access: result.access, peerIds: result.peerIds, closeEditing: result.closeEditing, commentsEnabled: result.commentsEnabled, notifyChanges: result.notifyChanges, link: shared.link)

            var addMembers: Signal<Never, NoError> = .complete()
            let newMembers = result.peerIds.filter { $0 != context.account.peerId && !shared.peerIds.contains($0) }
            if let link = shared.link, result.access == .selectedMembers, !newMembers.isEmpty {
                addMembers = context.engine.peers.addChannelMembers(peerId: link.roomPeerId, memberIds: newMembers)
                |> ignoreValues
                |> `catch` { _ -> Signal<Never, NoError> in
                    return .complete()
                }
            }

            var activity = shared.activity
            activity.isClosedManually = false
            let updated = SharedMessageAttribute(title: result.title, access: result.access, peerIds: result.peerIds, closeEditing: result.closeEditing, commentsEnabled: result.commentsEnabled, notifyChanges: result.notifyChanges, version: shared.version, versionEditorIds: shared.versionEditorIds, activity: activity, link: shared.link)
            return recordLocally
            |> then(addMembers)
            |> then(writeMarker(context: context, message: message, attribute: updated))
        }
    }

    /// Closes editing by hand: the footer turns grey everywhere once the marker carries the flag.
    /// The marker is rewritten only when asked: an author who is about to save the document writes
    /// it with the document instead. Only the author can.
    static func closeEditing(context: AccountContext, messageId: EngineMessage.Id, rewriteMarker: Bool) -> Signal<Never, NoError> {
        let close = context.engine.messages.updateSharedMessageActivity(messageId: messageId, { activity in
            var activity = activity
            activity.isClosedManually = true
            return activity
        })
        guard rewriteMarker else {
            return close
        }
        return close
        |> then(latestMessage(context: context, id: messageId)
        |> mapToSignal { message -> Signal<Never, NoError> in
            guard let message, let shared = message.attributes.first(where: { $0 is SharedMessageAttribute }) as? SharedMessageAttribute else {
                return .complete()
            }
            return writeMarker(context: context, message: message, attribute: shared)
        })
    }

    /// Edits the real message so that its text starts with the marker line. Only the author can.
    private static func writeMarker(context: AccountContext, message: EngineMessage, attribute: SharedMessageAttribute) -> Signal<Never, NoError> {
        guard let markerURL = attribute.markerURL else {
            return .complete()
        }
        let entities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        let richText = message.attributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute
        let marked = sharedMessageTextWithMarker(title: attribute.title, markerURL: markerURL, text: message.text, entities: entities)
        return context.engine.messages.requestEditMessage(messageId: message.id, text: marked.text, media: .keep, entities: TextEntitiesMessageAttribute(entities: marked.entities), richText: richText, inlineStickers: [:], disableUrlPreview: true)
        |> ignoreValues
        |> `catch` { _ -> Signal<Never, NoError> in
            return .complete()
        }
    }

    /// Writes the current document into the real message, keeping the marker line. Only the author can.
    static func saveToMessage(context: AccountContext, message: EngineMessage, attribute: SharedMessageAttribute, document: Document, media: [String: EngineMedia]) -> Signal<Never, NoError> {
        let markerURL = attribute.markerURL
        let request: Signal<RequestEditMessageResult, RequestEditMessageError>
        switch composeRichMessage(from: document, media: media, forSendPreview: true) {
        case let .rich(instantPage):
            let marked: (text: String, entities: [MessageTextEntity]) = markerURL.map { sharedMessageTextWithMarker(title: attribute.title, markerURL: $0, text: "", entities: []) } ?? (text: "", entities: [])
            request = context.engine.messages.requestEditMessage(messageId: message.id, text: marked.text, media: .keep, entities: marked.entities.isEmpty ? nil : TextEntitiesMessageAttribute(entities: marked.entities), richText: RichTextMessageAttribute(instantPage: instantPage, fullInstantPage: nil), inlineStickers: [:], disableUrlPreview: true)
        case let .plain(text, entities):
            let marked: (text: String, entities: [MessageTextEntity]) = markerURL.map { sharedMessageTextWithMarker(title: attribute.title, markerURL: $0, text: text, entities: entities) } ?? (text: text, entities: entities)
            request = context.engine.messages.requestEditMessage(messageId: message.id, text: marked.text, media: .keep, entities: marked.entities.isEmpty ? nil : TextEntitiesMessageAttribute(entities: marked.entities), richText: nil, inlineStickers: [:], disableUrlPreview: true)
        case .empty:
            return .complete()
        }
        return request
        |> ignoreValues
        |> `catch` { _ -> Signal<Never, NoError> in
            return .complete()
        }
    }

    /// Makes sure the account is in the room before the editor opens: joins through the invite if not.
    static func ensureMembership(context: AccountContext, link: SharedMessageAttribute.Link) -> Signal<Bool, NoError> {
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: link.roomPeerId))
        |> mapToSignal { peer -> Signal<Bool, NoError> in
            if case let .channel(channel)? = peer, channel.participationStatus == .member {
                // An editor the author added directly has never quietened the room on this device.
                let quietenedKey = "SharedMessageRoomsQuietened.\(context.account.peerId.toInt64())"
                var quietened = UserDefaults.standard.stringArray(forKey: quietenedKey) ?? []
                if !quietened.contains("\(link.roomPeerId.toInt64())") {
                    quietened.append("\(link.roomPeerId.toInt64())")
                    UserDefaults.standard.set(quietened, forKey: quietenedKey)
                    return afterCompletion(quieten(context: context, roomId: link.roomPeerId), .single(true))
                }
                return .single(true)
            }
            guard let inviteHash = link.inviteHash else {
                return .single(false)
            }
            return context.engine.peers.joinChatInteractively(with: inviteHash)
            |> map { _ -> Bool in
                return true
            }
            |> `catch` { _ -> Signal<Bool, NoError> in
                return .single(false)
            }
            |> mapToSignal { joined -> Signal<Bool, NoError> in
                guard joined else {
                    return .single(false)
                }
                return afterCompletion(quieten(context: context, roomId: link.roomPeerId), .single(true))
            }
        }
    }

    private static let maxTextPayloadLength = 3800

    /// Posts a payload into the topic: as text when it fits a message, else as a JSON file.
    static func sendPayload(context: AccountContext, roomId: EnginePeer.Id, topicId: Int64, payload: SharedMessageRoomPayload) -> Signal<Never, NoError> {
        guard let data = SharedMessageRoomPayload.encode(payload) else {
            return .complete()
        }
        // A forum topic is addressed by replying to its root message (whose id is the topic id), the
        // way the chat does; a bare `threadId` only places the message locally and the server files
        // it under General.
        let topicRoot = EngineMessageReplySubject(messageId: EngineMessage.Id(peerId: roomId, namespace: Namespaces.Message.Cloud, id: Int32(clamping: topicId)), quote: nil, innerSubject: nil)
        if let text = String(data: data, encoding: .utf8), (text as NSString).length <= maxTextPayloadLength {
            return context.engine.messages.enqueueOutgoingMessage(to: roomId, replyTo: topicRoot, threadId: topicId, content: .text(text, []))
            |> ignoreValues
        }
        let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max), size: Int64(data.count))
        context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data, synchronous: true)
        let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64.random(in: Int64.min ... Int64.max)), partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil, mimeType: "application/json", size: Int64(data.count), attributes: [.FileName(fileName: "\(payload.kind.rawValue).json")], alternativeRepresentations: [])
        return context.engine.messages.enqueueOutgoingMessage(to: roomId, replyTo: topicRoot, threadId: topicId, content: .file(.standalone(media: file)))
        |> ignoreValues
    }
}
