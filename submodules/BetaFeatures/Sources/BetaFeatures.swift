import Foundation

/// The β-features of this build. Each one is a ported concept from an open-source Telegram-iOS prototype;
/// the switch in Settings → βeta Features only controls its entry point, the code itself is always compiled in.
public enum BetaFeature: String, CaseIterable {
    case customizeScreenshot
    case multiActionSwipe
    case multiReply
    case visualQuote
    case blackHoleDelete
    case voiceTranscript
    case timeCapsule
    case unmuteSimilar
    case annotations

    public var key: String {
        return "bgram.beta." + self.rawValue
    }

    public func title(isRussian: Bool) -> String {
        switch self {
        case .customizeScreenshot:
            return isRussian ? "Кастомизация скриншота" : "Customize Screenshot"
        case .multiActionSwipe:
            return isRussian ? "Свайп с действиями" : "Multi-Action Swipe"
        case .multiReply:
            return isRussian ? "Мультиответ" : "Multi-Reply"
        case .visualQuote:
            return isRussian ? "Визуальная цитата" : "Visual Quote"
        case .blackHoleDelete:
            return isRussian ? "Чёрная дыра" : "Black Hole Delete"
        case .voiceTranscript:
            return isRussian ? "Транскрипт голосовых" : "Voice Transcript"
        case .timeCapsule:
            return isRussian ? "Капсула времени" : "Time Capsule"
        case .unmuteSimilar:
            return isRussian ? "Умный звук" : "Unmute Similar"
        case .annotations:
            return isRussian ? "Аннотации" : "Annotations"
        }
    }

    public func description(isRussian: Bool) -> String {
        switch self {
        case .customizeScreenshot:
            return isRussian
                ? "После скриншота чата предложит убрать лишние сообщения и вырезать текст — чистый снимок для отправки."
                : "After a chat screenshot, offers to drop messages and cut text before you share a clean image."
        case .multiActionSwipe:
            return isRussian
                ? "Смахните сообщение влево и, не отпуская, ведите вверх или вниз: пересылка, копирование, сохранение."
                : "Swipe a message left and keep sliding up or down to forward, copy or save it instead of only replying."
        case .multiReply:
            return isRussian
                ? "Выберите 2–5 сообщений и ответьте на них сразу — одной колодой цитат."
                : "Select 2–5 messages and reply to all of them at once, as one deck of quotes."
        case .visualQuote:
            return isRussian
                ? "Ответьте на деталь фотографии: в цитату попадает выделенный фрагмент, а не весь снимок."
                : "Reply to a detail of a photo: the quote carries the selected region, not the whole image."
        case .blackHoleDelete:
            return isRussian
                ? "Очистка истории с анимацией чёрной дыры: сообщения затягивает из Dynamic Island."
                : "Clearing the history pulls the messages into a black hole that opens from the Dynamic Island."
        case .voiceTranscript:
            return isRussian
                ? "Лист транскрипта голосового: подсветка по ходу прослушивания, переход по словам и AI-конспект."
                : "A transcript sheet for voice messages: synced highlighting, tap-to-seek and an AI summary."
        case .timeCapsule:
            return isRussian
                ? "Запечатайте сообщение до выбранного срока: до этого момента его не видит никто. Долгое нажатие на «Отправить»."
                : "Seal a message until a chosen moment: nobody sees it before it opens. Long-press Send to seal."
        case .unmuteSimilar:
            return isRussian
                ? "Уведомления о важных постах в беззвучных каналах — по ключевым словам или типу поста."
                : "Notifications for important posts in muted channels, matched by keyword or by post type."
        case .annotations:
            return isRussian
                ? "Выделите слово в сообщении и прикрепите к нему пояснение — текст, фото или ссылку. Читатель откроет его тапом по слову с точечным подчёркиванием."
                : "Select a word in your message and attach a note — text, a photo or a link. The reader taps the dotted word to see it."
        }
    }
}

public final class BetaFeatures {
    public static let didChangeNotification = Notification.Name("BetaFeaturesDidChangeNotification")

    private static let defaults = UserDefaults.standard

    /// Every β-feature is on out of the box; the switch in the settings screen turns it off.
    public static func isEnabled(_ feature: BetaFeature) -> Bool {
        if self.defaults.object(forKey: feature.key) == nil {
            return true
        }
        return self.defaults.bool(forKey: feature.key)
    }

    public static func setEnabled(_ enabled: Bool, for feature: BetaFeature) {
        self.defaults.set(enabled, forKey: feature.key)
        NotificationCenter.default.post(name: BetaFeatures.didChangeNotification, object: feature.rawValue)
    }

    public static func resetAll() {
        for feature in BetaFeature.allCases {
            self.defaults.removeObject(forKey: feature.key)
        }
        NotificationCenter.default.post(name: BetaFeatures.didChangeNotification, object: nil)
    }
}