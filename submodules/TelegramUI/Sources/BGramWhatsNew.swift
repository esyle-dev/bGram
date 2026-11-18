import Foundation
import UIKit
import Security

/// The "What's new" sheet, shown once after an install or an update.
///
/// The build number it was last shown for lives in the keychain, which survives deleting the app: reinstall
/// the same build and the sheet stays away, install a newer one and it comes back once.
///
/// It lives in its own window on `.alert + 1`. Two earlier versions were wrong: presenting a controller on the
/// root controller during launch crashed the app (the launch transition was still running), and adding a plain
/// view to the app window showed the card but swallowed its touches (Telegram's window hands touches to its own
/// presentation surfaces). An extra window is neither: nothing is presented, and it hit-tests like a system alert.
public enum BGramWhatsNew {
    private static let service = "ru.bgram.whatsnew"
    private static let account = "lastShownBuild"
    private static var overlayWindow: UIWindow?

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

    public static func presentIfNeeded(in parentWindow: UIWindow?, isRussian: Bool) {
        guard let parentWindow else {
            return
        }
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        if readLastShownBuild() == build {
            return
        }
        // Marked right away: the sheet must not come back on the next launch if the app is closed on it.
        storeLastShownBuild(build)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak parentWindow] in
            guard let parentWindow, self.overlayWindow == nil else {
                return
            }
            let controller = BGramWhatsNewController(build: build, isRussian: isRussian, dismiss: {
                BGramWhatsNew.dismiss()
            })
            let window: UIWindow
            if let scene = parentWindow.windowScene {
                window = UIWindow(windowScene: scene)
            } else {
                window = UIWindow(frame: parentWindow.bounds)
            }
            window.windowLevel = .alert + 1
            window.backgroundColor = .clear
            window.rootViewController = controller
            window.isHidden = false
            self.overlayWindow = window
            controller.animateIn()
        }
    }

    fileprivate static func dismiss() {
        guard let window = self.overlayWindow else {
            return
        }
        self.overlayWindow = nil
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// The sheet itself: a dimmed backdrop and a near-fullscreen white card, built the way Telegram's
/// "How it works" screen is — hero icon, centred title, a list of items with blue icons, a pill button at the
/// bottom and a small caption under it.
private final class BGramWhatsNewController: UIViewController {
    private let build: String
    private let isRussian: Bool
    private let dismissHandler: () -> Void

    private let backdrop = UIView()
    private let card = UIView()
    private let content = UIStackView()

    init(build: String, isRussian: Bool, dismiss: @escaping () -> Void) {
        self.build = build
        self.isRussian = isRussian
        self.dismissHandler = dismiss
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func text(_ ru: String, _ en: String) -> String {
        return self.isRussian ? ru : en
    }

    private var accent: UIColor {
        return UIColor(rgb: 0x2f7bff)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .clear

        self.backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        self.backdrop.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.backdrop)
        self.backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapOutside)))

        self.card.backgroundColor = .systemBackground
        self.card.layer.cornerRadius = 24.0
        self.card.layer.cornerCurve = .continuous
        self.card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        self.card.translatesAutoresizingMaskIntoConstraints = false
        self.card.clipsToBounds = true
        self.view.addSubview(self.card)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)), for: .normal)
        closeButton.tintColor = .label
        closeButton.backgroundColor = .secondarySystemBackground
        closeButton.layer.cornerRadius = 16.0
        closeButton.layer.borderWidth = 0.5
        closeButton.layer.borderColor = UIColor.separator.cgColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(self.closeTapped), for: .touchUpInside)
        self.card.addSubview(closeButton)

        // Hero: a blue crystal with a few sparks around it, like the wallet screen's diamond.
        let hero = UIView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        let diamond = UIImageView(image: UIImage(systemName: "diamond.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 84.0, weight: .regular)))
        diamond.tintColor = self.accent
        diamond.contentMode = .scaleAspectFit
        diamond.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(diamond)
        for (symbol, size, dx, dy) in [("sparkle", 18.0, -58.0, -34.0), ("sparkle", 12.0, 54.0, -46.0), ("sparkle", 9.0, 62.0, 18.0), ("sparkle", 13.0, -52.0, 26.0)] {
            let spark = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: CGFloat(size), weight: .regular)))
            spark.tintColor = self.accent.withAlphaComponent(0.45)
            spark.translatesAutoresizingMaskIntoConstraints = false
            hero.addSubview(spark)
            NSLayoutConstraint.activate([
                spark.centerXAnchor.constraint(equalTo: hero.centerXAnchor, constant: CGFloat(dx)),
                spark.centerYAnchor.constraint(equalTo: hero.centerYAnchor, constant: CGFloat(dy))
            ])
        }
        NSLayoutConstraint.activate([
            diamond.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
            diamond.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            diamond.widthAnchor.constraint(equalToConstant: 96.0),
            diamond.heightAnchor.constraint(equalToConstant: 96.0),
            hero.heightAnchor.constraint(equalToConstant: 132.0)
        ])

        let title = UILabel()
        title.text = self.text("Что нового", "What's new")
        title.font = .systemFont(ofSize: 26.0, weight: .bold)
        title.textColor = .label
        title.textAlignment = .center
        title.numberOfLines = 0

        let subtitle = UILabel()
        subtitle.text = self.text("bGram 13.0 · сборка \(self.build). Ниже — что появилось и как это включить.",
                                  "bGram 13.0 · build \(self.build). Here is what is new and how to turn it on.")
        subtitle.font = .systemFont(ofSize: 15.0, weight: .regular)
        subtitle.textColor = .secondaryLabel
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        self.content.axis = .vertical
        self.content.spacing = 18.0
        self.content.translatesAutoresizingMaskIntoConstraints = false
        self.content.addArrangedSubview(hero)
        self.content.addArrangedSubview(title)
        self.content.setCustomSpacing(6.0, after: title)
        self.content.addArrangedSubview(subtitle)
        self.content.setCustomSpacing(24.0, after: subtitle)

        let items: [(String, String, String)] = [
            ("text.bubble", self.text("Аннотации", "Annotations"),
             self.text("Выделите слово в сообщении и прикрепите к нему пояснение — текст, фото или ссылку. AI-черновик теперь пишет по-русски.",
                       "Select a word and attach a note — text, a photo or a link. The AI draft now answers in your language.")),
            ("hand.draw", self.text("Свайп с действиями", "Multi-action swipe"),
             self.text("Смахните сообщение до конца и задержите палец на секунду: сверху пересылка, снизу копирование и сохранение.",
                       "Swipe a message all the way and hold for a second: forward above, copy and save below.")),
            ("quote.bubble", self.text("Мультиответ и цитата", "Multi-reply and quotes"),
             self.text("Ответ сразу на несколько сообщений одной колодой и ответ на фрагмент фотографии.",
                       "Reply to several messages with one deck of quotes, or to a part of a photo.")),
            ("waveform", self.text("Транскрипт голосовых", "Voice transcripts"),
             self.text("Читаемый текст голосового с AI-конспектом: главное, задачи и вопросы по таймкодам.",
                       "Read a voice message with an AI summary: key points, tasks and questions by timecode.")),
            ("photo.on.rectangle", self.text("Скриншот без лишнего", "Clean screenshots"),
             self.text("После скриншота чата — редактор: уберите сообщения, вырежьте текст, смените тему.",
                       "After a chat screenshot an editor drops messages, cuts text and picks a theme.")),
            ("switch.2", self.text("βeta Features", "βeta Features"),
             self.text("Новая вкладка в настройках, сразу над «Избранным»: каждая фича включается своим свитчем.",
                       "A new settings tab right above Saved Messages: every feature has its own switch.")),
            ("exclamationmark.triangle", self.text("Новое, но пока выключено", "New, but off for now"),
             self.text("Свайп к непрочитанным, архив подарков, «Предложить цену», ответ на фото из альбома и общие сообщения — прототипы. Включайте свитчем сознательно.",
                       "Swipe to unread, gift archive, offers, album photo reply and shared messages are prototypes. Turn them on deliberately."))
        ]

        for (symbol, itemTitle, itemText) in items {
            let iconView = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22.0, weight: .regular)))
            iconView.tintColor = self.accent
            iconView.contentMode = .scaleAspectFit
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 30.0).isActive = true
            iconView.setContentHuggingPriority(.required, for: .horizontal)

            let name = UILabel()
            name.text = itemTitle
            name.font = .systemFont(ofSize: 16.0, weight: .semibold)
            name.textColor = .label
            name.numberOfLines = 0

            let detail = UILabel()
            detail.text = itemText
            detail.font = .systemFont(ofSize: 14.0, weight: .regular)
            detail.textColor = .secondaryLabel
            detail.numberOfLines = 0

            let textStack = UIStackView(arrangedSubviews: [name, detail])
            textStack.axis = .vertical
            textStack.spacing = 3.0

            let row = UIStackView(arrangedSubviews: [iconView, textStack])
            row.axis = .horizontal
            row.alignment = .top
            row.spacing = 12.0
            self.content.addArrangedSubview(row)
        }

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(self.content)

        let ok = UIButton(type: .system)
        ok.setTitle(self.text("ОК", "OK"), for: .normal)
        ok.titleLabel?.font = .systemFont(ofSize: 17.0, weight: .semibold)
        ok.setTitleColor(.white, for: .normal)
        ok.backgroundColor = self.accent
        ok.layer.cornerRadius = 25.0
        ok.layer.cornerCurve = .continuous
        ok.translatesAutoresizingMaskIntoConstraints = false
        ok.addTarget(self, action: #selector(self.closeTapped), for: .touchUpInside)

        let caption = UILabel()
        caption.text = self.text("Настройки → βeta Features — там всё это можно выключить.", "Settings → βeta Features turns any of it off.")
        caption.font = .systemFont(ofSize: 12.0, weight: .regular)
        caption.textColor = .tertiaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 0
        caption.translatesAutoresizingMaskIntoConstraints = false

        self.card.addSubview(scroll)
        self.card.addSubview(ok)
        self.card.addSubview(caption)

        let guide = self.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            self.backdrop.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.backdrop.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            self.backdrop.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.backdrop.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),

            self.card.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8.0),
            self.card.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8.0),
            self.card.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8.0),
            self.card.topAnchor.constraint(equalTo: guide.topAnchor, constant: 44.0),

            closeButton.topAnchor.constraint(equalTo: self.card.topAnchor, constant: 14.0),
            closeButton.leadingAnchor.constraint(equalTo: self.card.leadingAnchor, constant: 14.0),
            closeButton.widthAnchor.constraint(equalToConstant: 32.0),
            closeButton.heightAnchor.constraint(equalToConstant: 32.0),

            scroll.topAnchor.constraint(equalTo: self.card.topAnchor, constant: 16.0),
            scroll.leadingAnchor.constraint(equalTo: self.card.leadingAnchor, constant: 22.0),
            scroll.trailingAnchor.constraint(equalTo: self.card.trailingAnchor, constant: -22.0),
            scroll.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -16.0),

            self.content.topAnchor.constraint(equalTo: scroll.topAnchor),
            self.content.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            self.content.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            self.content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            self.content.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            ok.leadingAnchor.constraint(equalTo: self.card.leadingAnchor, constant: 22.0),
            ok.trailingAnchor.constraint(equalTo: self.card.trailingAnchor, constant: -22.0),
            ok.heightAnchor.constraint(equalToConstant: 50.0),

            caption.topAnchor.constraint(equalTo: ok.bottomAnchor, constant: 10.0),
            caption.leadingAnchor.constraint(equalTo: self.card.leadingAnchor, constant: 22.0),
            caption.trailingAnchor.constraint(equalTo: self.card.trailingAnchor, constant: -22.0),
            caption.bottomAnchor.constraint(equalTo: self.card.bottomAnchor, constant: -14.0)
        ])
    }

    func animateIn() {
        self.card.transform = CGAffineTransform(translationX: 0.0, y: 40.0)
        self.card.alpha = 0.0
        self.backdrop.alpha = 0.0
        UIView.animate(withDuration: 0.32, delay: 0.0, options: [.curveEaseOut]) {
            self.card.transform = .identity
            self.card.alpha = 1.0
            self.backdrop.alpha = 1.0
        }
    }

    @objc private func tapOutside() {
        self.dismissHandler()
    }

    @objc private func closeTapped() {
        self.dismissHandler()
    }
}
