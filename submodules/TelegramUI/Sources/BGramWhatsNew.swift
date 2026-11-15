import Foundation
import UIKit
import Security

/// The "What's new" card that appears once after an install or an update.
///
/// The build number it was last shown for lives in the keychain, which survives deleting the app: reinstall
/// the same build and the card stays away, install a newer one and it comes back once.
public enum BGramWhatsNew {
    private static let service = "ru.bgram.whatsnew"
    private static let account = "lastShownBuild"

    private static func readLastShownBuild() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func storeLastShownBuild(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public static func presentIfNeeded(from controller: UIViewController?, isRussian: Bool) {
        guard let controller else {
            return
        }
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        if readLastShownBuild() == build {
            return
        }
        // Marked right away: the card must not come back on the next launch if the user closes the app.
        storeLastShownBuild(build)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let screen = BGramWhatsNewController(build: build, isRussian: isRussian)
            screen.modalPresentationStyle = .overFullScreen
            screen.modalTransitionStyle = .crossDissolve
            controller.present(screen, animated: true, completion: nil)
        }
    }
}

private final class BGramWhatsNewController: UIViewController {
    private let build: String
    private let isRussian: Bool

    init(build: String, isRussian: Bool) {
        self.build = build
        self.isRussian = isRussian
        super.init(nibName: nil, bundle: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func text(_ ru: String, _ en: String) -> String {
        return self.isRussian ? ru : en
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = UIColor.black.withAlphaComponent(0.5)

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 22.0
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(card)

        let title = UILabel()
        title.text = self.text("Что нового в bGram", "What's new in bGram")
        title.font = .systemFont(ofSize: 24.0, weight: .bold)
        title.numberOfLines = 0
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = self.text("Версия 13.0 · сборка \(self.build)", "Version 13.0 · build \(self.build)")
        subtitle.font = .systemFont(ofSize: 13.0, weight: .regular)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center

        let rows: [(String, String)] = [
            (self.text("βeta Features", "βeta Features"),
             self.text("Новая вкладка в настройках, над «Избранным»: все фичи сборки включаются и выключаются свитчами.",
                       "A new settings tab above Saved Messages: every feature of this build is one switch away.")),
            (self.text("Аннотации", "Annotations"),
             self.text("Выделите слово в сообщении — Format › Annotations добавит к нему пояснение с фото, ссылкой и AI-черновиком.",
                       "Select a word — Format › Annotations attaches a note with a photo, a link or an AI draft.")),
            (self.text("Свайп с действиями", "Multi-action swipe"),
             self.text("Смахните сообщение до конца и задержите палец: сверху — пересылка, снизу — копирование или сохранение.",
                       "Swipe a message all the way and hold: forward above, copy or save below.")),
            (self.text("Мультиответ", "Multi-reply"),
             self.text("Выберите 2–5 сообщений и ответьте на них одной колодой цитат.",
                       "Select 2–5 messages and answer them with one deck of quotes.")),
            (self.text("Скриншот без лишнего", "Clean screenshots"),
             self.text("После скриншота чата — редактор: уберите сообщения, вырежьте текст, выберите тему.",
                       "After a chat screenshot an editor offers to drop messages, cut text and pick a theme.")),
            (self.text("Визуальная цитата, транскрипт голосовых, «Умный звук»", "Visual quote, voice transcripts, smart muting"),
             self.text("Ответ на фрагмент фото, читаемый транскрипт с AI-конспектом и уведомления о важном в беззвучных каналах.",
                       "Reply to a part of a photo, read a voice message, and hear what matters in muted channels.")),
            (self.text("Свайп к непрочитанным", "Swipe to unread"),
             self.text("Потяните чат вверх у нижнего края — лента непрочитанных с превью, не выходя из чата.",
                       "Pull the chat up from the bottom edge to walk through unread chats without leaving.")),
            (self.text("Архив подарков и «Предложить цену»", "Gift archive and offers"),
             self.text("Спрятанные подарки лежат в архиве профиля, а за подарок можно предложить свою цену.",
                       "Hidden gifts live in a profile archive, and you can offer your price for a gift."))
        ]

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14.0
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(18.0, after: subtitle)

        for (rowTitle, rowText) in rows {
            let row = UIStackView()
            row.axis = .vertical
            row.spacing = 2.0
            let name = UILabel()
            name.text = rowTitle
            name.font = .systemFont(ofSize: 15.0, weight: .semibold)
            name.numberOfLines = 0
            let detail = UILabel()
            detail.text = rowText
            detail.font = .systemFont(ofSize: 14.0, weight: .regular)
            detail.textColor = .secondaryLabel
            detail.numberOfLines = 0
            row.addArrangedSubview(name)
            row.addArrangedSubview(detail)
            stack.addArrangedSubview(row)
        }

        let button = UIButton(type: .system)
        button.setTitle(self.text("Начать", "Get started"), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17.0, weight: .semibold)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12.0
        button.layer.cornerCurve = .continuous
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(self.dismissSelf), for: .touchUpInside)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        card.addSubview(scroll)
        card.addSubview(button)
        self.view.addSubview(card)

        let safe = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 20.0),
            card.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -20.0),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420.0),
            card.heightAnchor.constraint(lessThanOrEqualTo: safe.heightAnchor, multiplier: 0.92),

            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 22.0),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20.0),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20.0),
            scroll.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -16.0),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            button.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20.0),
            button.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20.0),
            button.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20.0),
            button.heightAnchor.constraint(equalToConstant: 50.0),

            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 300.0)
        ])
    }

    @objc private func dismissSelf() {
        self.dismiss(animated: true, completion: nil)
    }
}