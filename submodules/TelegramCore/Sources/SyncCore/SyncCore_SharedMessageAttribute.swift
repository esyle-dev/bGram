import Foundation
import Postbox

/// Marks a message as a shared message: one that several members of a group can edit together.
///
/// The record is local, but it travels in the message itself: the author's client puts the title in
/// front of the text as a bold line linked to `tg://sharedmsg?…` (`markerURL`), which names the room
/// (a hidden forum supergroup) and the topic the editing happens in. A client that receives such a
/// message strips that line back out (`sharedMessageStrippingMarker`) and keeps this attribute instead.
public final class SharedMessageAttribute: MessageAttribute {
    /// Where the editing happens: a topic in the group's hidden room, and the invite that lets an
    /// editor in when adding them directly was not possible.
    public struct Link: Equatable {
        public let roomPeerId: PeerId
        public let topicId: Int64
        public let inviteHash: String?

        public init(roomPeerId: PeerId, topicId: Int64, inviteHash: String?) {
            self.roomPeerId = roomPeerId
            self.topicId = topicId
            self.inviteHash = inviteHash
        }
    }

    public static let markerScheme = "tg://sharedmsg"
    /// A room's title starts with this (an invisible separator), which is how clients hide the room.
    public static let roomTitleMarker = "\u{2063}"

    public enum Access: Int32 {
        /// Only the admins of the group (and the author) can edit.
        case admins = 0
        /// Every member can edit, except `peerIds`.
        case allMembers = 1
        /// Only `peerIds` (plus the author and admins) can edit.
        case selectedMembers = 2
    }

    public enum CloseEditing: Int32 {
        case never = 0
        case inOneDay = 1
        case inOneWeek = 2
        case inOneMonth = 3
    }

    /// What a shared message has been through. Local and simulated for now.
    public struct Activity: Equatable {
        public enum FooterState {
            case untouched
            case edited
            case hasNewEdits
            case someoneEditing
            case closed
        }

        public var sharedAt: Int32
        public var editsCount: Int32
        public var unreadEdits: Int32
        public var lastEditAt: Int32
        public var editingPeerId: PeerId?
        /// In order of first participation, which is also the order of their colours.
        public var editorPeerIds: [PeerId]
        public var commentsCount: Int32
        public var isClosedManually: Bool

        public init(sharedAt: Int32 = 0, editsCount: Int32 = 0, unreadEdits: Int32 = 0, lastEditAt: Int32 = 0, editingPeerId: PeerId? = nil, editorPeerIds: [PeerId] = [], commentsCount: Int32 = 0, isClosedManually: Bool = false) {
            self.sharedAt = sharedAt
            self.editsCount = editsCount
            self.unreadEdits = unreadEdits
            self.lastEditAt = lastEditAt
            self.editingPeerId = editingPeerId
            self.editorPeerIds = editorPeerIds
            self.commentsCount = commentsCount
            self.isClosedManually = isClosedManually
        }
    }

    public static let maxTitleLength: Int = 32

    public let title: String
    public let access: Access
    /// Selected members for `.selectedMembers`, excluded members for `.allMembers`.
    public let peerIds: [PeerId]
    public let closeEditing: CloseEditing
    public let commentsEnabled: Bool
    /// When on, every client posts a short local service message ("Ron updated «Plan»") once the
    /// message itself takes a new version.
    public let notifyChanges: Bool
    /// The generation of the message's content: the author's client moves it on every save of a
    /// new document, and a client that sees it move tells the chat (when `notifyChanges` is on).
    public let version: Int32
    /// Who made the changes the current `version` carries, in the order they last edited.
    public let versionEditorIds: [PeerId]
    public let activity: Activity
    public let link: Link?

    public var associatedPeerIds: [PeerId] {
        var result = self.activity.editorPeerIds
        if let editingPeerId = self.activity.editingPeerId, !result.contains(editingPeerId) {
            result.append(editingPeerId)
        }
        return result
    }

    /// The moment editing closes by itself, if it does.
    public var closeDate: Int32? {
        switch self.closeEditing {
        case .never:
            return nil
        case .inOneDay:
            return self.activity.sharedAt + 24 * 60 * 60
        case .inOneWeek:
            return self.activity.sharedAt + 7 * 24 * 60 * 60
        case .inOneMonth:
            return self.activity.sharedAt + 30 * 24 * 60 * 60
        }
    }

    public func footerState(now: Int32) -> Activity.FooterState {
        if self.activity.isClosedManually || (self.closeDate.flatMap { now >= $0 } ?? false) {
            return .closed
        } else if self.activity.editingPeerId != nil {
            return .someoneEditing
        } else if self.activity.unreadEdits > 0 {
            return .hasNewEdits
        } else if self.activity.editsCount > 0 {
            return .edited
        } else {
            return .untouched
        }
    }

    public func withUpdatedActivity(_ activity: Activity) -> SharedMessageAttribute {
        return SharedMessageAttribute(title: self.title, access: self.access, peerIds: self.peerIds, closeEditing: self.closeEditing, commentsEnabled: self.commentsEnabled, notifyChanges: self.notifyChanges, version: self.version, versionEditorIds: self.versionEditorIds, activity: activity, link: self.link)
    }

    public func withUpdatedLink(_ link: Link?) -> SharedMessageAttribute {
        return SharedMessageAttribute(title: self.title, access: self.access, peerIds: self.peerIds, closeEditing: self.closeEditing, commentsEnabled: self.commentsEnabled, notifyChanges: self.notifyChanges, version: self.version, versionEditorIds: self.versionEditorIds, activity: self.activity, link: link)
    }

    /// The same settings carrying a new content version made by `editorIds`.
    public func withNextVersion(editorIds: [PeerId]) -> SharedMessageAttribute {
        return SharedMessageAttribute(title: self.title, access: self.access, peerIds: self.peerIds, closeEditing: self.closeEditing, commentsEnabled: self.commentsEnabled, notifyChanges: self.notifyChanges, version: self.version + 1, versionEditorIds: editorIds, activity: self.activity, link: self.link)
    }

    public init(title: String, access: Access, peerIds: [PeerId], closeEditing: CloseEditing, commentsEnabled: Bool, notifyChanges: Bool = false, version: Int32 = 0, versionEditorIds: [PeerId] = [], activity: Activity = Activity(), link: Link? = nil) {
        self.title = title
        self.access = access
        self.peerIds = peerIds
        self.closeEditing = closeEditing
        self.commentsEnabled = commentsEnabled
        self.notifyChanges = notifyChanges
        self.version = version
        self.versionEditorIds = versionEditorIds
        self.activity = activity
        self.link = link
    }

    /// The marker other clients read the settings and the room from. Nil until the message has a room.
    public var markerURL: String? {
        guard let link = self.link else {
            return nil
        }
        var components = URLComponents()
        var items: [URLQueryItem] = [
            URLQueryItem(name: "room", value: "\(link.roomPeerId.toInt64())"),
            URLQueryItem(name: "topic", value: "\(link.topicId)"),
            URLQueryItem(name: "a", value: "\(self.access.rawValue)"),
            URLQueryItem(name: "c", value: "\(self.closeEditing.rawValue)"),
            URLQueryItem(name: "m", value: self.commentsEnabled ? "1" : "0"),
        ]
        if !self.peerIds.isEmpty {
            items.append(URLQueryItem(name: "p", value: self.peerIds.map { "\($0.toInt64())" }.joined(separator: ",")))
        }
        if let inviteHash = link.inviteHash, !inviteHash.isEmpty {
            items.append(URLQueryItem(name: "i", value: inviteHash))
        }
        if self.notifyChanges {
            items.append(URLQueryItem(name: "n", value: "1"))
        }
        if self.version > 0 {
            items.append(URLQueryItem(name: "v", value: "\(self.version)"))
            if !self.versionEditorIds.isEmpty {
                items.append(URLQueryItem(name: "e", value: self.versionEditorIds.map { "\($0.toInt64())" }.joined(separator: ",")))
            }
        }
        // Closed by hand: the only piece of activity other clients must see.
        if self.activity.isClosedManually {
            items.append(URLQueryItem(name: "x", value: "1"))
        }
        components.queryItems = items
        return SharedMessageAttribute.markerScheme + "?" + (components.percentEncodedQuery ?? "")
    }

    /// The settings a marker carries. The title is the text the marker is attached to.
    public convenience init?(markerURL: String, title: String, sharedAt: Int32, authorId: PeerId?) {
        guard markerURL.hasPrefix(SharedMessageAttribute.markerScheme + "?"), let components = URLComponents(string: markerURL) else {
            return nil
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            values[item.name] = item.value ?? ""
        }
        guard let roomValue = values["room"].flatMap(Int64.init), let topicId = values["topic"].flatMap(Int64.init) else {
            return nil
        }
        let access = values["a"].flatMap(Int32.init).flatMap(Access.init(rawValue:)) ?? .admins
        let closeEditing = values["c"].flatMap(Int32.init).flatMap(CloseEditing.init(rawValue:)) ?? .never
        let peerIds = (values["p"] ?? "").split(separator: ",").compactMap { Int64($0) }.map(PeerId.init)
        var activity = Activity()
        activity.sharedAt = sharedAt
        if let authorId {
            activity.editorPeerIds = [authorId]
        }
        activity.isClosedManually = values["x"] == "1"
        let version = values["v"].flatMap(Int32.init) ?? 0
        let versionEditorIds = (values["e"] ?? "").split(separator: ",").compactMap { Int64($0) }.map(PeerId.init)
        self.init(title: title, access: access, peerIds: peerIds, closeEditing: closeEditing, commentsEnabled: values["m"] != "0", notifyChanges: values["n"] == "1", version: version, versionEditorIds: versionEditorIds, activity: activity, link: Link(roomPeerId: PeerId(roomValue), topicId: topicId, inviteHash: values["i"].flatMap { $0.isEmpty ? nil : $0 }))
    }

    required public init(decoder: PostboxDecoder) {
        self.title = decoder.decodeStringForKey("t", orElse: "")
        self.access = Access(rawValue: decoder.decodeInt32ForKey("a", orElse: 0)) ?? .admins
        self.peerIds = decoder.decodeInt64ArrayForKey("p").map(PeerId.init)
        self.closeEditing = CloseEditing(rawValue: decoder.decodeInt32ForKey("c", orElse: 0)) ?? .never
        self.commentsEnabled = decoder.decodeBoolForKey("m", orElse: true)
        self.notifyChanges = decoder.decodeBoolForKey("n", orElse: false)
        self.version = decoder.decodeInt32ForKey("v", orElse: 0)
        self.versionEditorIds = decoder.decodeInt64ArrayForKey("ve").map(PeerId.init)
        let editingPeerId = decoder.decodeInt64ForKey("eg", orElse: 0)
        self.activity = Activity(
            sharedAt: decoder.decodeInt32ForKey("as", orElse: 0),
            editsCount: decoder.decodeInt32ForKey("ae", orElse: 0),
            unreadEdits: decoder.decodeInt32ForKey("au", orElse: 0),
            lastEditAt: decoder.decodeInt32ForKey("al", orElse: 0),
            editingPeerId: editingPeerId != 0 ? PeerId(editingPeerId) : nil,
            editorPeerIds: decoder.decodeInt64ArrayForKey("ar").map(PeerId.init),
            commentsCount: decoder.decodeInt32ForKey("ak", orElse: 0),
            isClosedManually: decoder.decodeBoolForKey("ax", orElse: false)
        )
        let roomPeerId = decoder.decodeInt64ForKey("lr", orElse: 0)
        if roomPeerId != 0 {
            let inviteHash = decoder.decodeStringForKey("li", orElse: "")
            self.link = Link(roomPeerId: PeerId(roomPeerId), topicId: decoder.decodeInt64ForKey("lt", orElse: 0), inviteHash: inviteHash.isEmpty ? nil : inviteHash)
        } else {
            self.link = nil
        }
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.title, forKey: "t")
        encoder.encodeInt32(self.access.rawValue, forKey: "a")
        encoder.encodeInt64Array(self.peerIds.map { $0.toInt64() }, forKey: "p")
        encoder.encodeInt32(self.closeEditing.rawValue, forKey: "c")
        encoder.encodeBool(self.commentsEnabled, forKey: "m")
        encoder.encodeBool(self.notifyChanges, forKey: "n")
        encoder.encodeInt32(self.version, forKey: "v")
        encoder.encodeInt64Array(self.versionEditorIds.map { $0.toInt64() }, forKey: "ve")
        encoder.encodeInt32(self.activity.sharedAt, forKey: "as")
        encoder.encodeInt32(self.activity.editsCount, forKey: "ae")
        encoder.encodeInt32(self.activity.unreadEdits, forKey: "au")
        encoder.encodeInt32(self.activity.lastEditAt, forKey: "al")
        encoder.encodeInt64(self.activity.editingPeerId?.toInt64() ?? 0, forKey: "eg")
        encoder.encodeInt64Array(self.activity.editorPeerIds.map { $0.toInt64() }, forKey: "ar")
        encoder.encodeInt32(self.activity.commentsCount, forKey: "ak")
        encoder.encodeBool(self.activity.isClosedManually, forKey: "ax")
        if let link = self.link {
            encoder.encodeInt64(link.roomPeerId.toInt64(), forKey: "lr")
            encoder.encodeInt64(link.topicId, forKey: "lt")
            encoder.encodeString(link.inviteHash ?? "", forKey: "li")
        }
    }
}

/// The message text as it is sent: the title on its own first line, bold and linked to the marker,
/// then the body. Entities are UTF-16 ranges, as everywhere in the message model.
public func sharedMessageTextWithMarker(title: String, markerURL: String, text: String, entities: [MessageTextEntity]) -> (text: String, entities: [MessageTextEntity]) {
    let titleLength = (title as NSString).length
    var resultEntities: [MessageTextEntity] = [
        MessageTextEntity(range: 0 ..< titleLength, type: .Bold),
        MessageTextEntity(range: 0 ..< titleLength, type: .TextUrl(url: markerURL)),
    ]
    if text.isEmpty {
        return (title, resultEntities)
    }
    let shift = titleLength + 1
    for entity in entities {
        resultEntities.append(MessageTextEntity(range: (entity.range.lowerBound + shift) ..< (entity.range.upperBound + shift), type: entity.type))
    }
    return (title + "\n" + text, resultEntities)
}

/// Reads a marker back out of a received message: the body without the title line, the body's
/// entities, and the attribute the marker describes. Nil when the text carries no marker.
public func sharedMessageStrippingMarker(text: String, entities: [MessageTextEntity], sharedAt: Int32, authorId: PeerId?) -> (text: String, entities: [MessageTextEntity], attribute: SharedMessageAttribute)? {
    guard let marker = entities.first(where: { entity in
        if case let .TextUrl(url) = entity.type, entity.range.lowerBound == 0, url.hasPrefix(SharedMessageAttribute.markerScheme + "?") {
            return true
        }
        return false
    }), case let .TextUrl(markerURL) = marker.type else {
        return nil
    }
    let nsText = text as NSString
    guard marker.range.upperBound <= nsText.length else {
        return nil
    }
    let title = nsText.substring(with: NSRange(location: 0, length: marker.range.upperBound))
    guard let attribute = SharedMessageAttribute(markerURL: markerURL, title: title, sharedAt: sharedAt, authorId: authorId) else {
        return nil
    }
    var bodyStart = marker.range.upperBound
    if bodyStart < nsText.length, nsText.character(at: bodyStart) == 0x0A {
        bodyStart += 1
    }
    let body = nsText.substring(from: bodyStart)
    var bodyEntities: [MessageTextEntity] = []
    for entity in entities where entity.range.lowerBound >= bodyStart {
        bodyEntities.append(MessageTextEntity(range: (entity.range.lowerBound - bodyStart) ..< (entity.range.upperBound - bodyStart), type: entity.type))
    }
    return (body, bodyEntities, attribute)
}
