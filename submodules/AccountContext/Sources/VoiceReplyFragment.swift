import Foundation
import TelegramCore

/// The part of a voice message a reply is about, chosen in the voice transcript sheet: the time (or time range) it covers as it
/// reads there, and the text of the chosen words. It only affects how the reply is shown in the chat's input panel; it is
/// not sent anywhere.
public struct VoiceReplyFragment: Codable, Equatable {
    public var timeText: String
    public var text: String
    
    public init(timeText: String, text: String) {
        self.timeText = timeText
        self.text = text
    }
}

/// Holds a chosen fragment for the moment between pressing Reply in the transcript sheet and the chat setting the reply up:
/// the chat opens asynchronously and sets the reply by message id alone, so this is how the fragment reaches it. It is read
/// once, and goes stale after a few seconds. Main thread only.
public final class VoiceReplyFragmentStore {
    public static let shared = VoiceReplyFragmentStore()
    
    private var pending: (id: EngineMessage.Id, fragment: VoiceReplyFragment, date: Double)?
    
    private init() {
    }
    
    public func set(_ fragment: VoiceReplyFragment, for id: EngineMessage.Id) {
        self.pending = (id, fragment, CFAbsoluteTimeGetCurrent())
    }
    
    public func take(for id: EngineMessage.Id) -> VoiceReplyFragment? {
        guard let pending = self.pending else {
            return nil
        }
        if pending.id != id {
            return nil
        }
        self.pending = nil
        if CFAbsoluteTimeGetCurrent() - pending.date > 15.0 {
            return nil
        }
        return pending.fragment
    }
}
