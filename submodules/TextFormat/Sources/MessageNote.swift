import Foundation
import TelegramCore

/// A note attached to a range of message text ("Note" feature, design demo).
///
/// The server knows no note entity, so a note travels as a hidden `textUrl` entity over the anchor text whose URL is
/// `tg://note?d=<base64url(JSON)>`. Clients that do not know the scheme show the anchor as a plain link.
public struct MessageNoteContent: Equatable {
    public static let maxTextLength = 200
    public static let maxNotesPerMessage = 10

    /// Formatting inside the note's text. Only these kinds are allowed.
    public struct Entity: Equatable {
        public enum Kind: Equatable {
            case bold
            case italic
            case url
            case textUrl(String)
        }

        public var kind: Kind
        /// UTF-16 offsets into `text`, as in `MessageTextEntity`.
        public var range: Range<Int>

        public init(kind: Kind, range: Range<Int>) {
            self.kind = kind
            self.range = range
        }
    }

    public var text: String
    public var entities: [Entity]
    /// A web image shown above the text; it reaches every recipient.
    public var imageUrl: String?
    /// A photo picked from the sender's gallery. Demo simulation: the image is stored on the sender's device only,
    /// so recipients do not see it.
    public var localImageId: String?
    /// The sender removed the link preview card of a URL-only annotation.
    public var suppressLinkPreview: Bool
    public var aiGenerated: Bool
    public var sources: [String]

    public init(text: String, entities: [Entity] = [], imageUrl: String? = nil, localImageId: String? = nil, suppressLinkPreview: Bool = false, aiGenerated: Bool = false, sources: [String] = []) {
        self.text = text
        self.entities = entities
        self.imageUrl = imageUrl
        self.localImageId = localImageId
        self.suppressLinkPreview = suppressLinkPreview
        self.aiGenerated = aiGenerated
        self.sources = sources
    }

    public var isEmpty: Bool {
        return self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && self.imageUrl == nil && self.localImageId == nil
    }

    /// The URL to show as a link preview card: the text is a single URL and there is no media.
    public var linkPreviewUrl: String? {
        if self.suppressLinkPreview || self.imageUrl != nil || self.localImageId != nil {
            return nil
        }
        let trimmed = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range), match.range == range else {
            return nil
        }
        return match.url?.absoluteString ?? trimmed
    }

    /// The note's text formatting as message entities, for the existing text renderers.
    public var messageTextEntities: [MessageTextEntity] {
        return self.entities.map { entity in
            let type: MessageTextEntityType
            switch entity.kind {
            case .bold:
                type = .Bold
            case .italic:
                type = .Italic
            case .url:
                type = .Url
            case let .textUrl(url):
                type = .TextUrl(url: url)
            }
            return MessageTextEntity(range: entity.range, type: type)
        }
    }

    public init(text: String, messageTextEntities: [MessageTextEntity], imageUrl: String? = nil, localImageId: String? = nil, suppressLinkPreview: Bool = false, aiGenerated: Bool = false, sources: [String] = []) {
        var entities: [Entity] = []
        for entity in messageTextEntities {
            switch entity.type {
            case .Bold:
                entities.append(Entity(kind: .bold, range: entity.range))
            case .Italic:
                entities.append(Entity(kind: .italic, range: entity.range))
            case .Url:
                entities.append(Entity(kind: .url, range: entity.range))
            case let .TextUrl(url):
                if !MessageNoteContent.isNoteUrl(url) {
                    entities.append(Entity(kind: .textUrl(url), range: entity.range))
                }
            default:
                break
            }
        }
        self.init(text: text, entities: entities, imageUrl: imageUrl, localImageId: localImageId, suppressLinkPreview: suppressLinkPreview, aiGenerated: aiGenerated, sources: sources)
    }
}

// MARK: - URL encoding

private let noteUrlPrefix = "tg://note?d="

private struct EncodedNote: Codable {
    var t: String?
    /// Each entity is `[kind, offset, length]` or `["l", offset, length, url]`.
    var e: [[EncodedValue]]?
    var i: String?
    /// Local (sender-only) image id.
    var m: String?
    /// Link preview suppressed.
    var n: Bool?
    var a: Bool?
    var s: [String]?
}

private enum EncodedValue: Codable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }

    var int: Int? {
        if case let .int(value) = self {
            return value
        }
        return nil
    }

    var string: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }
}

public extension MessageNoteContent {
    static func isNoteUrl(_ url: String) -> Bool {
        return url.hasPrefix(noteUrlPrefix)
    }

    init?(url: String) {
        guard url.hasPrefix(noteUrlPrefix) else {
            return nil
        }
        var base64 = String(url.dropFirst(noteUrlPrefix.count))
        if let decoded = base64.removingPercentEncoding {
            base64 = decoded
        }
        base64 = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64), let encoded = try? JSONDecoder().decode(EncodedNote.self, from: data) else {
            return nil
        }
        let text = encoded.t ?? ""
        let textLength = (text as NSString).length
        var entities: [Entity] = []
        for item in encoded.e ?? [] {
            guard item.count >= 3, let kindValue = item[0].string, let offset = item[1].int, let length = item[2].int, offset >= 0, length > 0, offset + length <= textLength else {
                continue
            }
            let kind: Entity.Kind
            switch kindValue {
            case "b":
                kind = .bold
            case "i":
                kind = .italic
            case "u":
                kind = .url
            case "l":
                guard item.count >= 4, let linkUrl = item[3].string else {
                    continue
                }
                kind = .textUrl(linkUrl)
            default:
                continue
            }
            entities.append(Entity(kind: kind, range: offset ..< (offset + length)))
        }
        self.init(text: text, entities: entities, imageUrl: encoded.i, localImageId: encoded.m, suppressLinkPreview: encoded.n ?? false, aiGenerated: encoded.a ?? false, sources: encoded.s ?? [])
        if self.isEmpty {
            return nil
        }
    }

    var url: String {
        var encoded = EncodedNote()
        if !self.text.isEmpty {
            encoded.t = self.text
        }
        if !self.entities.isEmpty {
            encoded.e = self.entities.map { entity in
                let offset = EncodedValue.int(entity.range.lowerBound)
                let length = EncodedValue.int(entity.range.count)
                switch entity.kind {
                case .bold:
                    return [.string("b"), offset, length]
                case .italic:
                    return [.string("i"), offset, length]
                case .url:
                    return [.string("u"), offset, length]
                case let .textUrl(linkUrl):
                    return [.string("l"), offset, length, .string(linkUrl)]
                }
            }
        }
        encoded.i = self.imageUrl
        encoded.m = self.localImageId
        if self.suppressLinkPreview {
            encoded.n = true
        }
        if self.aiGenerated {
            encoded.a = true
        }
        if !self.sources.isEmpty {
            encoded.s = self.sources
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(encoded)) ?? Data()
        let base64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return noteUrlPrefix + base64
    }
}

/// The range without leading and trailing whitespace; nil when nothing else is left.
public func messageNoteTrimmedRange(text: String, range: NSRange) -> NSRange? {
    let nsText = text as NSString
    var start = range.location
    var end = range.location + range.length
    let whitespace = CharacterSet.whitespacesAndNewlines
    while start < end, let scalar = UnicodeScalar(nsText.character(at: start)), whitespace.contains(scalar) {
        start += 1
    }
    while end > start, let scalar = UnicodeScalar(nsText.character(at: end - 1)), whitespace.contains(scalar) {
        end -= 1
    }
    if start >= end {
        return nil
    }
    return NSRange(location: start, length: end - start)
}
