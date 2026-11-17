import Foundation
import UIKit
import Security

/// The "What's new" card that appears once after an install or an update.
///
/// The build number it was last shown for lives in the keychain, which survives deleting the app: reinstall
/// the same build and the card stays away, install a newer one and it comes back once.
///
/// It is a plain view added to the app window, not a presented controller: presenting anything on the root
/// controller during launch fights the launch transition (`unbalanced calls to begin/end appearance
/// transitions`) and that is what crashed the app, while an overlay cannot desync UIKit's presentation stack.
public enum BGramWhatsNew {
    private static let service = "ru.bgram.whatsnew"
    private static let account = "lastShownBuild"
    private static var overlay: BGramWhatsNewOverlay?

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

    public static func presentIfNeeded(in window: UIWindow?, isRussian: Bool) {
        guard let window else {
            return
        }
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        if readLastShownBuild() == build {
            return
        }
        // Marked right away: the card must not come back on the next launch if the app is closed on it.
        storeLastShownBuild(build)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak window] in
            guard let window, self.overlay == nil else {
                return
            }
            let overlay = BGramWhatsNewOverlay(build: build, isRussian: isRussian)
            overlay.frame = window.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(overlay)
            self.overlay = overlay
            overlay.animateIn()
        }
    }

    fileprivate static func dismiss() {
        guard let overlay = self.overlay else {
            return
        }
        self.overlay = nil
        overlay.animateOut {
            overlay.removeFromSuperview()
        }
    }
}

private final class BGramWhatsNewOverlay: UIView {
    private let card = UIView()
    private let build: String
    private let isRussian: Bool

    init(build: String, isRussian: Bool) {
        self.build = build
        self.isRussian = isRussian
        super.init(frame: .zero)
        self.buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func text(_ ru: String, _ en: String) -> String {
        return self.isRussian ? ru : en
    }

    private func buildContent() {
        self.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        self.card.backgroundColor = .secondarySystemBackground
        self.card.layer.cornerRadius = 22.0
        self.card.layer.cornerCurve = .continuous
        self.card.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.card)

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
             self.text("Выделите слово в сообщении — Format › Аннотации добавит к нему пояснение с фото, ссылкой и AI-черновиком.",
                       "Select a word — Format › Annotations attaches a note with a photo, a link or an AI draft.")),
            (self.text("Свайп с действиями", "Multi-action swipe"),
             self.text("Смахните сообщение до конца и задержите палец: сверху — пересылка, снизу — копирование или сохранение.",
                       "Swipe a message all the way and hold: forward above, copy or save below.")),
            (self.text("Мультиответ, цитата, транскрипт", "Multi-reply, quote, transcript"),
             self.text("Ответ колодой цитат, ответ на фрагмент фото и читаемый транскрипт голосовых с AI-конспектом.",
                       "Reply with a deck of quotes, reply to a part of a photo, and read voice messages with an AI summary.")),
            (self.text("Скриншот без лишнего", "Clean screenshots"),
             self.text("После скриншота чата — редактор: уберите сообщения, вырежьте текст, выберите тему.",
                       "After a chat screenshot an editor offers to drop messages, cut text and pick a theme.")),
            (self.text("Новое, но выключено", "New, but off"),
             self.text("Свайп к непрочитанным, архив подарков, «Предложить цену», ответ на фото из альбома и общие сообщения — прототипы, по умолчанию выключены: включайте свитчем сознательно.",
                       "Swipe to unread, gift archive, offers, album photo reply and shared messages are prototypes and start off: turn them on deliberately."))
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

        self.card.addSubview(scroll)
        self.card.addSubview(button)

        NSLayoutConstraint.activate([
            self.card.centerXAnchor.constraint(equalTo: self.safeAreaLayoutGuide.centerXAnchor),
            self.card.centerYAnchor.constraint(equalTo: self.safeAreaLayoutGuide.centerYAnchor),
            self.card.leadingAnchor.constraint(greaterThanOrEqualTo: self.safeAreaLayoutGuide.leadingAnchor, constant: 20.0),
            self.card.trailingAnchor.constraint(lessThanOrEqualTo: self.safeAreaLayoutGuide.trailingAnchor, constant: -20.0),
            self.card.widthAnchor.constraint(equalToConstant: 340.0),
            self.card.heightAnchor.constraint(lessThanOrEqualTo: self.safeAreaLayoutGuide.heightAnchor, multiplier: 0.9),

            scroll.topAnchor.constraint(equalTo: self.card.topAnchor, constant: 22.0),
            scroll.leadingAnchor.constraint(equalTo: self.card.leadingAnchor, constant: 20.0),
            scroll.trailingAnchor.constraint(equalTo: self.card.trailingAnchor, constant: -20.0),
            scroll.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -16.0),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            button.leadingAnchor.constraint(equalTo: self.card.leadingAnchor, constant: 20.0),
            button.trailingAnchor.constraint(equalTo: self.card.trailingAnchor, constant: -20.0),
            button.bottomAnchor.constraint(equalTo: self.card.bottomAnchor, constant: -20.0),
            button.heightAnchor.constraint(equalToConstant: 50.0)
        ])
    }

    func animateIn() {
        self.card.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        self.card.alpha = 0.0
        UIView.animate(withDuration: 0.28, delay: 0.0, options: [.curveEaseOut]) {
            self.card.transform = .identity
            self.card.alpha = 1.0
        }
    }

    func animateOut(completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.2, animations: {
            self.alpha = 0.0
            self.card.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }, completion: { _ in
            completion()
        })
    }

    @objc private func dismissSelf() {
        BGramWhatsNew.dismiss()
    }
}