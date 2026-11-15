import Foundation
import Postbox

/// The text of the short update a shared message with "Notify About Changes" leaves in the chat
/// when it takes a new version: "Ron updated «Plan»", "Ron and Tom updated «Plan»",
/// "Ron and 2 others updated «Plan»". The names are bold. Like the other local service messages
/// of shared messages, it is stored as written, in English.
public func sharedMessageVersionNoticeText(editorNames: [String], title: String) -> (text: String, entities: [MessageTextEntity]) {
    let names = editorNames.filter { !$0.isEmpty }
    var text = ""
    var entities: [MessageTextEntity] = []
    func appendBold(_ part: String) {
        let start = (text as NSString).length
        text += part
        entities.append(MessageTextEntity(range: start ..< (text as NSString).length, type: .Bold))
    }
    switch names.count {
    case 0:
        text += "Someone"
    case 1:
        appendBold(names[0])
    case 2:
        appendBold(names[0])
        text += " and "
        appendBold(names[1])
    default:
        appendBold(names[0])
        text += " and "
        appendBold("\(names.count - 1) others")
    }
    text += " updated \u{00AB}\(title)\u{00BB}"
    return (text, entities)
}

/// Called with every server copy of an edited message before it is stored. A shared message whose
/// marker carries a newer content version than the stored one, and asks to notify, gets a local
/// service message under it in the chat. The author's own save reaches here first through the edit
/// request's result, so the replay of the same edit finds the version already stored and adds nothing.
func addSharedMessageVersionNoticeIfNeeded(transaction: Transaction, accountPeerId: PeerId, id: MessageId, updated: StoreMessage) {
    guard let incoming = updated.attributes.first(where: { $0 is SharedMessageAttribute }) as? SharedMessageAttribute, incoming.notifyChanges, incoming.version > 0 else {
        return
    }
    guard let previous = transaction.getMessage(id), let current = previous.attributes.first(where: { $0 is SharedMessageAttribute }) as? SharedMessageAttribute, incoming.version > current.version else {
        return
    }
    let names = incoming.versionEditorIds.map { peerId -> String in
        if peerId == accountPeerId {
            return "You"
        }
        guard let peer = transaction.getPeer(peerId) else {
            return ""
        }
        if let user = peer as? TelegramUser {
            return user.firstName ?? user.lastName ?? user.nameOrPhone
        }
        return peer.debugDisplayTitle
    }
    let notice = sharedMessageVersionNoticeText(editorNames: names, title: incoming.title)
    let now = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
    let _ = transaction.addMessages([StoreMessage(peerId: id.peerId, namespace: Namespaces.Message.Local, customStableId: nil, globallyUniqueId: Int64.random(in: Int64.min ... Int64.max), groupingKey: nil, threadId: previous.threadId, timestamp: max(now, previous.timestamp), flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: accountPeerId, text: "", attributes: [], media: [TelegramMediaAction(action: .customText(text: notice.text, entities: notice.entities, additionalAttributes: nil))])], location: .UpperHistoryBlock)
}
