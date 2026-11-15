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
    case topicSwipe
    case giftArchive
    case makeOffer

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
            return isRussian ? "Капсула времени (недоступно)" : "Time Capsule (unavailable)"
        case .unmuteSimilar:
            return isRussian ? "Умный звук" : "Unmute Similar"
        case .annotations:
            return isRussian ? "Аннотации" : "Annotations"
        case .topicSwipe:
            return isRussian ? "Свайп к непрочитанным" : "Swipe to Unread"
        case .giftArchive:
            return isRussian ? "Архив подарков" : "Gift Archive"
        case .makeOffer:
            return isRussian ? "Предложить цену" : "Make an Offer"
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
                ? "Не работает и выключена: в MTProto нет поля, которым сообщение можно «запечатать» до выбранного времени, — сервер отдал бы его сразу. Раньше это была лишь имитация отложенной отправки. Включим, когда появится серверная поддержка."
                : "Off and not working: MTProto has no field to seal a message until a chosen moment, so the server would deliver it at once. What shipped was only a stand-in for scheduled delivery. It comes back when the API supports it."
        case .unmuteSimilar:
            return isRussian
                ? "Уведомления о важных постах в беззвучных каналах — по ключевым словам или типу поста."
                : "Notifications for important posts in muted channels, matched by keyword or by post type."
        case .annotations:
            return isRussian
                ? "Выделите слово в сообщении и прикрепите к нему пояснение — текст, фото или ссылку. Читатель откроет его тапом по слову с точечным подчёркиванием."
                : "Select a word in your message and attach a note — text, a photo or a link. The reader taps the dotted word to see it."
        case .topicSwipe:
            return isRussian
                ? "Потяните чат вверх у нижнего края: появится ряд непрочитанных чатов текущей папки и превью выбранного — можно листать, не выходя из чата."
                : "Pull the chat up from the bottom edge: a row of unread chats of the current folder appears with a live preview, so you can switch without leaving."
        case .giftArchive:
            return isRussian
                ? "Вкладка «Архив» в списке подарков профиля: убранные подарки лежат отдельно, их можно вернуть."
                : "An Archive tab in the profile's gifts: hidden gifts live there and can be brought back."
        case .makeOffer:
            return isRussian
                ? "Предложить свою цену за подарок на чужом профиле: сумма держится в эскроу до ответа владельца."
                : "Offer your own price for a gift on someone's profile: the amount is held in escrow until the owner answers."
        }
    }
}

public final class BetaFeatures {
    public static let didChangeNotification = Notification.Name("BetaFeaturesDidChangeNotification")

    private static let defaults = UserDefaults.standard

    /// Features that cannot work in this build: the switch is shown but stays off and disabled.
    public static func isAvailable(_ feature: BetaFeature) -> Bool {
        switch feature {
        case .timeCapsule:
            // MTProto has no "sealed until" field, so a capsule would be delivered at once.
            return false
        default:
            return true
        }
    }

    /// Every β-feature is on out of the box; the switch in the settings screen turns it off.
    public static func isEnabled(_ feature: BetaFeature) -> Bool {
        guard self.isAvailable(feature) else {
            return false
        }
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

/// Telegram's own translations arrive from server langpacks, which know nothing about the β-features,
/// so their text is translated here and picked by the device language: Russian at least, English otherwise.
public func bgramIsRussian() -> Bool {
    return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru")
}

public func bgramText(_ ru: String, _ en: String) -> String {
    return bgramIsRussian() ? ru : en
}

public func bgramPlural(_ value: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod100 = value % 100
    let mod10 = value % 10
    if mod100 >= 11 && mod100 <= 14 {
        return many
    }
    if mod10 == 1 {
        return one
    }
    if mod10 >= 2 && mod10 <= 4 {
        return few
    }
    return many
}
