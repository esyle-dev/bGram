import Foundation
import UIKit
import TelegramCore
import MediaPickerUI

/// The edit of an album: what it was and what has been changed in the window that edits it. The window can be folded away; the session then
/// waits in the place of the input panel (`AlbumEditInputPanelNode`) until the changes are saved or thrown away.
final class AlbumEditSession {
    /// The messages of the album that have a photo, in the order of the album.
    let messages: [EngineRawMessage]
    /// The pictures of the album as they were, in order, and every picture that has been given to the window (the added ones too).
    var originalIdentifiers: [String]
    var mediaById: [String: MediaPickerScreenImpl.Subject.Media]
    /// Which message of the album (its place in the album) each picture is of.
    var messageIndexByIdentifier: [String: Int] = [:]
    /// The file of the picture of each message of the album (by its place), as it is on the phone.
    var imageFiles: [Int: String] = [:]
    /// The pictures that were added in high quality: they are scaled to a larger side when they are saved.
    var highQualityIdentifiers: Set<String> = []
    /// The pictures in the order they are in now.
    var order: [String]
    
    let originalCaption: String
    var caption: NSAttributedString
    let originalIsCaptionAbove: Bool
    var isCaptionAbove: Bool
    var audio: (title: String, subtitle: String)?
    
    /// Whether the session waits in the place of the input panel.
    var isBarVisible = false
    /// The changes are being saved or thrown away: the folding away of the window is not to bring the panel back.
    var isFinishing = false
    
    var changed: (() -> Void)?
    var openRequested: (() -> Void)?
    var applyRequested: (() -> Void)?
    var discardRequested: (() -> Void)?
    
    init(messages: [EngineRawMessage], media: [MediaPickerScreenImpl.Subject.Media], caption: NSAttributedString, isCaptionAbove: Bool) {
        self.messages = messages
        var mediaById: [String: MediaPickerScreenImpl.Subject.Media] = [:]
        var identifiers: [String] = []
        for item in media {
            let identifier = item.albumEditIdentifier
            identifiers.append(identifier)
            mediaById[identifier] = item
        }
        self.originalIdentifiers = identifiers
        self.mediaById = mediaById
        self.order = identifiers
        self.originalCaption = caption.string
        self.caption = caption
        self.originalIsCaptionAbove = isCaptionAbove
        self.isCaptionAbove = isCaptionAbove
    }
    
    /// The pictures are taken as the window has them when it is opened for the first time, so that only what the user changes counts.
    func setBaseline(_ identifiers: [String]) {
        if !self.hasBaseline && !identifiers.isEmpty {
            self.hasBaseline = true
            self.originalIdentifiers = identifiers
            self.order = identifiers
        }
    }
    private var hasBaseline = false
    
    /// How many changes there are: every place where another picture is than there was, every added picture, the text, its place and the
    /// audio file. Moving one picture to the place of another is two changes.
    var changeCount: Int {
        var count = 0
        let original = Set(self.originalIdentifiers)
        for index in 0 ..< min(self.order.count, self.originalIdentifiers.count) {
            if self.order[index] != self.originalIdentifiers[index] {
                count += 1
            }
        }
        for identifier in self.order where !original.contains(identifier) {
            count += 1
        }
        if self.caption.string != self.originalCaption {
            count += 1
        }
        if self.isCaptionAbove != self.originalIsCaptionAbove {
            count += 1
        }
        if self.audio != nil {
            count += 1
        }
        return count
    }
    
    /// The first three pictures of the album, for the small collage.
    var collageImages: [UIImage] {
        var result: [UIImage] = []
        for identifier in self.originalIdentifiers.prefix(3) {
            if let media = self.mediaById[identifier], case let .image(image) = media {
                result.append(image)
            }
        }
        return result
    }
}
