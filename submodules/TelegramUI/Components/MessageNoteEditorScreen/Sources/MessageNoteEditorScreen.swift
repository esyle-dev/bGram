import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import TextFormat

/// The annotation editor: a popover above the selected text of the message input field, with a tail pointing at it.
/// The keyboard stays up; focus moves to the annotation's text field.
public final class MessageNoteEditorScreen: ViewController {
    public enum Result {
        case save(MessageNoteContent)
        case remove
        case cancel
    }

    public struct Actions {
        /// Asks for a link URL (the host's link alert); the completion gets nil on cancel and an empty string to
        /// remove the link.
        public var requestLink: (_ currentUrl: String?, _ completion: @escaping (String?) -> Void) -> Void
        /// Opens the host's media picker for one photo; the completion gets nil on cancel.
        public var requestPhoto: (_ completion: @escaping (UIImage?) -> Void) -> Void
        /// Fetches the link preview card of a URL-only annotation.
        public var loadLinkCard: (String, @escaping (MessageNoteLinkCard?) -> Void) -> Void
        /// Asks to confirm a destructive step (the host's alert); the completion gets whether it was confirmed.
        public var confirm: (_ text: String, _ actionTitle: String, _ completion: @escaping (Bool) -> Void) -> Void

        public init(requestLink: @escaping (_ currentUrl: String?, _ completion: @escaping (String?) -> Void) -> Void, requestPhoto: @escaping (_ completion: @escaping (UIImage?) -> Void) -> Void, loadLinkCard: @escaping (String, @escaping (MessageNoteLinkCard?) -> Void) -> Void, confirm: @escaping (_ text: String, _ actionTitle: String, _ completion: @escaping (Bool) -> Void) -> Void) {
            self.requestLink = requestLink
            self.requestPhoto = requestPhoto
            self.loadLinkCard = loadLinkCard
            self.confirm = confirm
        }
    }

    /// What the AI search gets: the annotated text, the whole message for context and the app's language.
    public struct AIContext {
        public var anchor: String
        public var messageText: String
        public var language: String

        public init(anchor: String, messageText: String, language: String) {
            self.anchor = anchor
            self.messageText = messageText
            self.language = language
        }
    }

    private let presentationData: PresentationData
    private let initialNote: MessageNoteContent?
    private let anchorRect: CGRect
    private let actions: Actions
    private let aiContext: AIContext
    private let aiService: NoteAIService
    private let completion: (Result) -> Void

    private var isDismissed = false

    private var controllerNode: MessageNoteEditorNode {
        return self.displayNode as! MessageNoteEditorNode
    }

    /// - Parameters:
    ///   - anchorRect: the annotated text's rect in window coordinates.
    public init(presentationData: PresentationData, initialNote: MessageNoteContent?, anchorRect: CGRect, aiContext: AIContext, aiService: NoteAIService = NoteAIStubService(), actions: Actions, completion: @escaping (Result) -> Void) {
        self.presentationData = presentationData
        self.initialNote = initialNote
        self.anchorRect = anchorRect
        self.aiContext = aiContext
        self.aiService = aiService
        self.actions = actions
        self.completion = completion

        super.init(navigationBarPresentationData: nil)

        self.statusBar.statusBarStyle = .Ignore
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func loadDisplayNode() {
        self.displayNode = MessageNoteEditorNode(presentationData: self.presentationData, initialNote: self.initialNote, anchorRect: self.anchorRect, aiContext: self.aiContext, aiService: self.aiService, actions: self.actions, finish: { [weak self] result in
            self?.finish(result)
        })
        self.displayNodeDidLoad()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.controllerNode.animateIn()
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.updateLayout(layout: layout, transition: transition)
    }

    private func finish(_ result: Result) {
        if self.isDismissed {
            return
        }
        self.isDismissed = true
        self.completion(result)
        self.controllerNode.animateOut(completion: { [weak self] in
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
        })
    }

    override public func dismiss(completion: (() -> Void)? = nil) {
        self.finish(.cancel)
        completion?()
    }
}

/// A flat capsule toolbar button, the size of the chat's send button.
private final class RoundButton: UIButton {
    init(image: UIImage?, tintColor: UIColor, fillColor: UIColor, accessibilityLabel: String) {
        super.init(frame: CGRect())
        self.setImage(image, for: .normal)
        self.tintColor = tintColor
        self.backgroundColor = fillColor
        self.accessibilityLabel = accessibilityLabel
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var progressLayer: CAShapeLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layer.cornerRadius = self.bounds.height / 2.0
        if let progressLayer = self.progressLayer {
            progressLayer.frame = self.bounds
            progressLayer.path = UIBezierPath(ovalIn: self.bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath
        }
    }

    /// A short arc in the tint colour running around the button's edge, as on the system's stop-loading controls.
    func setSpinning(_ isSpinning: Bool) {
        if isSpinning {
            guard self.progressLayer == nil else {
                return
            }
            let progressLayer = CAShapeLayer()
            progressLayer.fillColor = nil
            progressLayer.strokeColor = self.tintColor.cgColor
            progressLayer.lineWidth = 2.0
            progressLayer.lineCap = .round
            progressLayer.strokeStart = 0.0
            progressLayer.strokeEnd = 0.26
            self.layer.addSublayer(progressLayer)
            self.progressLayer = progressLayer
            self.setNeedsLayout()
            self.layoutIfNeeded()

            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0.0
            rotation.toValue = Double.pi * 2.0
            rotation.duration = 1.0
            rotation.repeatCount = .infinity
            progressLayer.add(rotation, forKey: "rotation")
            // The arc breathes while it runs.
            let length = CABasicAnimation(keyPath: "strokeEnd")
            length.fromValue = 0.12
            length.toValue = 0.42
            length.duration = 0.9
            length.autoreverses = true
            length.repeatCount = .infinity
            length.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            progressLayer.add(length, forKey: "length")
            progressLayer.add({
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.0
                fade.toValue = 1.0
                fade.duration = 0.2
                return fade
            }(), forKey: "appear")
        } else if let progressLayer = self.progressLayer {
            self.progressLayer = nil
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                progressLayer.removeFromSuperlayer()
            }
            progressLayer.opacity = 0.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = 0.2
            progressLayer.add(fade, forKey: "disappear")
            CATransaction.commit()
        }
    }

    /// Swaps the icon with a short pop.
    func setImageAnimated(_ image: UIImage?) {
        self.setImage(image, for: .normal)
        guard let imageLayer = self.imageView?.layer else {
            return
        }
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.0
        scale.damping = 12.0
        scale.stiffness = 260.0
        scale.mass = 1.0
        scale.duration = scale.settlingDuration
        imageLayer.add(scale, forKey: "pop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.15
        imageLayer.add(fade, forKey: "fade")
    }
}

/// A source: the site's round icon and its domain.
private final class SourceChipView: UIView {
    private let iconView = UIImageView()
    private let label = UILabel()

    init(url: String, textColor: UIColor, fillColor: UIColor, iconFillColor: UIColor) {
        super.init(frame: CGRect())
        self.backgroundColor = fillColor
        self.isUserInteractionEnabled = false

        let host = URL(string: url)?.host ?? url
        self.label.text = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        self.label.font = Font.medium(13.0)
        self.label.textColor = textColor

        self.iconView.backgroundColor = iconFillColor
        self.iconView.contentMode = .scaleAspectFill
        self.iconView.clipsToBounds = true
        self.iconView.layer.cornerRadius = 9.0
        self.iconView.tintColor = textColor
        self.iconView.image = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11.0, weight: .medium))
        self.iconView.contentMode = .center

        self.addSubview(self.iconView)
        self.addSubview(self.label)

        // The site's own icon, when it serves one.
        if let parsed = URL(string: url), let scheme = parsed.scheme, let host = parsed.host {
            MessageNoteMedia.loadRemoteImage(url: "\(scheme)://\(host)/favicon.ico", completion: { [weak self] image in
                guard let self, let image else {
                    return
                }
                self.iconView.image = image
                self.iconView.contentMode = .scaleAspectFill
                self.iconView.backgroundColor = .white
            })
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let labelWidth = ceil(self.label.sizeThatFits(CGSize(width: size.width, height: size.height)).width)
        return CGSize(width: 4.0 + 18.0 + 6.0 + labelWidth + 10.0, height: size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        self.layer.cornerRadius = size.height / 2.0
        self.iconView.frame = CGRect(x: 4.0, y: floor((size.height - 18.0) / 2.0), width: 18.0, height: 18.0)
        self.label.frame = CGRect(x: 4.0 + 18.0 + 6.0, y: 0.0, width: max(0.0, size.width - 28.0 - 10.0), height: size.height)
    }
}

private final class MessageNoteEditorNode: ASDisplayNode, UITextViewDelegate, UIGestureRecognizerDelegate {
    private let presentationData: PresentationData
    private let initialNote: MessageNoteContent?
    private let anchorRect: CGRect
    private let actions: MessageNoteEditorScreen.Actions
    private let aiContext: MessageNoteEditorScreen.AIContext
    private let aiService: NoteAIService
    private let finish: (MessageNoteEditorScreen.Result) -> Void

    /// The card and its tail, one shape, so the shadow follows both.
    private let containerView: UIView
    /// A tight contact shadow under the wide one on `containerView`.
    private let shadowLayer: CAShapeLayer
    private let contactShadowLayer: CAShapeLayer
    private let blurView: UIVisualEffectView
    private let blurMaskLayer: CAShapeLayer
    private let backgroundLayer: CAShapeLayer
    private let textView: UITextView
    private let placeholderLabel: UILabel
    private let aiButton: RoundButton
    private let attachButton: RoundButton
    private let counterLabel: UILabel
    private let doneButton: RoundButton
    /// The attached photo, above the text, with a remove button.
    private let mediaView: UIImageView
    private let mediaRemoveButton: UIButton
    /// The link preview card of a URL-only annotation, above the text, with a remove button.
    private let linkCardView: MessageNoteLinkCardView
    private let linkCardRemoveButton: UIButton

    private var localImageId: String?
    private var imageUrl: String?
    private var suppressLinkPreview: Bool
    private var linkCard: MessageNoteLinkCard?
    private var linkCardRequestedUrl: String?
    /// The image key (local id or URL) `mediaView` shows.
    private var displayedImageKey: String?

    // MARK: AI

    private enum AIState {
        case idle
        case loading
        case result
    }

    private struct Snapshot {
        var text: NSAttributedString
        var localImageId: String?
        var imageUrl: String?
        var suppressLinkPreview: Bool
        var aiGenerated: Bool
        var sources: [String]
        var aiText: String?
    }

    private var aiState: AIState
    private var displayedAIState: AIState?
    private var aiRequest: NoteAIRequest?
    /// Bumped by every start and stop, so that a delayed answer of an abandoned generation is dropped.
    private var aiGeneration: Int = 0
    private static let minimumAILoadingDuration: Double = 2.4
    private var aiGenerated: Bool
    private var sources: [String]
    /// The text as the AI wrote it, to tell whether the user has edited it.
    private var aiText: String?
    /// The content before a generation, restored on Stop and on errors.
    private var snapshot: Snapshot?
    private var statusText: String?
    private var showsRetry = false

    private let skeletonMediaView: UIView
    private let skeletonLineViews: [UIView]
    private let searchingLabel: UILabel
    private let statusLabel: UILabel
    private let retryButton: UIButton
    private let sourcesLabel: UILabel
    private var sourceChipViews: [SourceChipView] = []
    private let secondaryTextColor: UIColor
    private let chipFillColor: UIColor

    private var validLayout: ContainerViewLayout?
    private var tailOffset: CGFloat = 0.0

    private let baseFont: UIFont
    private let textColor: UIColor
    private let accentColor: UIColor

    init(presentationData: PresentationData, initialNote: MessageNoteContent?, anchorRect: CGRect, aiContext: MessageNoteEditorScreen.AIContext, aiService: NoteAIService, actions: MessageNoteEditorScreen.Actions, finish: @escaping (MessageNoteEditorScreen.Result) -> Void) {
        self.presentationData = presentationData
        self.initialNote = initialNote
        self.anchorRect = anchorRect
        self.aiContext = aiContext
        self.aiService = aiService
        self.actions = actions
        self.finish = finish

        let theme = presentationData.theme
        let isDark = theme.overallDarkAppearance
        self.baseFont = Font.regular(17.0)
        self.textColor = theme.list.itemPrimaryTextColor
        self.accentColor = theme.list.itemAccentColor
        // The system's tertiary fill (translucent grey), which keeps reading on the card's glass.
        let buttonFillColor = UIColor(rgb: 0x767680, alpha: isDark ? 0.24 : 0.12)

        // Shadow as in the system menus: a wide soft one plus a tight contact one. Both are masked out of the card
        // so that they do not darken its translucent glass.
        self.containerView = UIView()
        self.shadowLayer = CAShapeLayer()
        self.shadowLayer.fillColor = nil
        self.shadowLayer.shadowColor = UIColor.black.cgColor
        self.shadowLayer.shadowOpacity = isDark ? 0.45 : 0.18
        self.shadowLayer.shadowRadius = 40.0
        self.shadowLayer.shadowOffset = CGSize(width: 0.0, height: 16.0)

        self.contactShadowLayer = CAShapeLayer()
        self.contactShadowLayer.fillColor = nil
        self.contactShadowLayer.shadowColor = UIColor.black.cgColor
        self.contactShadowLayer.shadowOpacity = isDark ? 0.3 : 0.08
        self.contactShadowLayer.shadowRadius = 4.0
        self.contactShadowLayer.shadowOffset = CGSize(width: 0.0, height: 1.0)

        // Glass as in the context menus: a blur under the menu's translucent background colour.
        self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: isDark ? .dark : .light))
        self.blurMaskLayer = CAShapeLayer()
        self.blurView.layer.mask = self.blurMaskLayer
        self.backgroundLayer = CAShapeLayer()
        self.backgroundLayer.fillColor = theme.contextMenu.backgroundColor.cgColor

        self.textView = UITextView()
        self.textView.backgroundColor = .clear
        self.textView.font = self.baseFont
        self.textView.textColor = self.textColor
        self.textView.tintColor = self.accentColor
        self.textView.textContainerInset = UIEdgeInsets()
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.allowsEditingTextAttributes = true
        self.textView.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
        self.textView.linkTextAttributes = [.foregroundColor: self.accentColor]
        self.textView.typingAttributes = [.font: self.baseFont, .foregroundColor: self.textColor]

        self.placeholderLabel = UILabel()
        self.placeholderLabel.font = self.baseFont
        self.placeholderLabel.textColor = theme.list.itemPlaceholderTextColor
        self.placeholderLabel.text = "Add an annotation…"
        self.placeholderLabel.isUserInteractionEnabled = false

        self.aiButton = RoundButton(image: UIImage(bundleImageName: "Chat/Input/Text/InputAIIcon")?.withRenderingMode(.alwaysTemplate), tintColor: self.accentColor, fillColor: self.accentColor.withAlphaComponent(isDark ? 0.2 : 0.12), accessibilityLabel: "Generate with AI")

        // A bare glyph in the text colour at 70%, without a fill.
        self.attachButton = RoundButton(image: generateScaledIcon(UIImage(bundleImageName: "Chat/Attach Menu/Image"), size: CGSize(width: 28.0, height: 28.0)), tintColor: theme.list.itemPrimaryTextColor.withMultipliedAlpha(0.7), fillColor: .clear, accessibilityLabel: "Add photo")

        self.counterLabel = UILabel()
        self.counterLabel.font = Font.with(size: 13.0, traits: .monospacedNumbers)
        self.counterLabel.textColor = theme.list.itemSecondaryTextColor
        self.counterLabel.textAlignment = .right

        self.localImageId = initialNote?.localImageId
        self.imageUrl = initialNote?.imageUrl
        self.suppressLinkPreview = initialNote?.suppressLinkPreview ?? false

        self.mediaView = UIImageView()
        self.mediaView.contentMode = .scaleAspectFill
        self.mediaView.clipsToBounds = true
        // 4 pt from the card's edges; its corners are set in layout (top: the card's minus 4, bottom: half that).
        self.mediaView.layer.cornerCurve = .continuous
        self.mediaView.backgroundColor = buttonFillColor
        self.mediaView.isUserInteractionEnabled = true

        func makeRemoveButton() -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11.0, weight: .bold)), for: .normal)
            button.tintColor = .white
            button.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
            button.layer.cornerRadius = 12.0
            button.accessibilityLabel = "Remove"
            return button
        }
        self.mediaRemoveButton = makeRemoveButton()

        self.linkCardView = MessageNoteLinkCardView(textColor: self.textColor, secondaryTextColor: theme.list.itemSecondaryTextColor, accentColor: self.accentColor, fillColor: buttonFillColor)
        self.linkCardRemoveButton = makeRemoveButton()

        self.aiGenerated = initialNote?.aiGenerated ?? false
        self.sources = initialNote?.sources ?? []
        self.aiText = self.aiGenerated ? initialNote?.text : nil
        self.aiState = self.aiGenerated ? .result : .idle
        self.secondaryTextColor = theme.list.itemSecondaryTextColor
        self.chipFillColor = self.accentColor.withAlphaComponent(isDark ? 0.2 : 0.12)

        self.skeletonMediaView = UIView()
        self.skeletonMediaView.backgroundColor = buttonFillColor
        self.skeletonMediaView.clipsToBounds = true
        self.skeletonMediaView.layer.cornerCurve = .continuous
        self.skeletonLineViews = (0 ..< 2).map { _ in
            let view = UIView()
            view.backgroundColor = buttonFillColor
            view.layer.cornerRadius = 6.0
            return view
        }
        self.searchingLabel = UILabel()
        self.searchingLabel.font = Font.regular(15.0)
        self.searchingLabel.textColor = theme.list.itemSecondaryTextColor
        self.searchingLabel.text = "Searching the web…"

        self.statusLabel = UILabel()
        self.statusLabel.font = Font.regular(13.0)
        self.statusLabel.textColor = theme.list.itemSecondaryTextColor
        self.statusLabel.numberOfLines = 2
        self.retryButton = UIButton(type: .system)
        self.retryButton.setTitle("Retry", for: .normal)
        self.retryButton.titleLabel?.font = Font.semibold(13.0)
        self.retryButton.tintColor = self.accentColor

        self.sourcesLabel = UILabel()
        self.sourcesLabel.font = Font.regular(13.0)
        self.sourcesLabel.textColor = theme.list.itemSecondaryTextColor
        self.sourcesLabel.text = "Sources"

        self.doneButton = RoundButton(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16.0, weight: .semibold)), tintColor: theme.list.itemCheckColors.foregroundColor, fillColor: self.accentColor, accessibilityLabel: "Done")

        super.init()

        self.setViewBlock({
            return UITracingLayerView()
        })
    }

    override func didLoad() {
        super.didLoad()

        self.view.addSubview(self.containerView)
        self.containerView.layer.addSublayer(self.shadowLayer)
        self.containerView.layer.addSublayer(self.contactShadowLayer)
        self.containerView.addSubview(self.blurView)
        self.containerView.layer.addSublayer(self.backgroundLayer)
        self.containerView.addSubview(self.textView)
        self.containerView.addSubview(self.placeholderLabel)
        self.containerView.addSubview(self.aiButton)
        self.containerView.addSubview(self.attachButton)
        self.containerView.addSubview(self.counterLabel)
        self.containerView.addSubview(self.doneButton)
        self.containerView.addSubview(self.mediaView)
        self.mediaView.addSubview(self.mediaRemoveButton)
        self.containerView.addSubview(self.linkCardView)
        self.linkCardView.addSubview(self.linkCardRemoveButton)
        self.containerView.addSubview(self.skeletonMediaView)
        for view in self.skeletonLineViews {
            self.containerView.addSubview(view)
        }
        self.containerView.addSubview(self.searchingLabel)
        self.containerView.addSubview(self.statusLabel)
        self.containerView.addSubview(self.retryButton)
        self.containerView.addSubview(self.sourcesLabel)

        if let initialNote = self.initialNote {
            self.textView.attributedText = self.attributedText(note: initialNote)
        }
        self.textView.delegate = self

        self.aiButton.addTarget(self, action: #selector(self.aiPressed), for: .touchUpInside)
        self.retryButton.addTarget(self, action: #selector(self.retryPressed), for: .touchUpInside)
        self.updateAIViews()

        self.attachButton.addTarget(self, action: #selector(self.attachPressed), for: .touchUpInside)
        self.mediaRemoveButton.addTarget(self, action: #selector(self.removeMediaPressed), for: .touchUpInside)
        self.linkCardRemoveButton.addTarget(self, action: #selector(self.removeLinkCardPressed), for: .touchUpInside)
        self.updateMedia()

        self.doneButton.addTarget(self, action: #selector(self.donePressed), for: .touchUpInside)

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.backgroundTapped(_:)))
        tapRecognizer.delegate = self
        self.view.addGestureRecognizer(tapRecognizer)

        let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(self.cardPanned(_:)))
        panRecognizer.delegate = self
        self.containerView.addGestureRecognizer(panRecognizer)

        self.updateState()
    }

    // MARK: - Layout

    private static let cornerRadius: CGFloat = 24.0
    private static let insets = UIEdgeInsets(top: 12.0, left: 8.0, bottom: 8.0, right: 8.0)
    /// The chat's send button: 40 × 34.
    private static let buttonSize = CGSize(width: 40.0, height: 34.0)
    /// The round Ai and photo buttons.
    private static let smallButtonSize = CGSize(width: 36.0, height: 36.0)
    /// The bottom row: as tall as its tallest button.
    private static var buttonRowHeight: CGFloat {
        return max(buttonSize.height, smallButtonSize.height)
    }
    private static let tailHeight: CGFloat = 10.0
    private static let tailWidth: CGFloat = 30.0

    func updateLayout(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        let isFirstLayout = self.validLayout == nil
        self.validLayout = layout

        let insets = MessageNoteEditorNode.insets
        let buttonSize = MessageNoteEditorNode.buttonSize
        let tailHeight = MessageNoteEditorNode.tailHeight

        let cardWidth = floor(layout.size.width * 0.8)
        let contentWidth = cardWidth - insets.left - insets.right

        // The text row (text and the Ai icon) is inset 4 pt more on both sides.
        let rowInset: CGFloat = 4.0
        let textWidth = contentWidth - rowInset * 2.0
        let lineHeight = ceil(self.baseFont.lineHeight)
        let fittedTextHeight = ceil(self.textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        var textHeight = max(lineHeight, min(fittedTextHeight, lineHeight * 6.0))

        let isLoading = self.aiState == .loading
        if isLoading {
            // Skeletons: the searching label and two text lines.
            textHeight = 20.0 + 10.0 + 12.0 + 8.0 + 12.0
        }

        // Above the text: the photo (or its skeleton) 4 pt from the card's edges, then the link preview card.
        let mediaInset: CGFloat = 4.0
        let mediaWidth = cardWidth - mediaInset * 2.0
        var blocksTop = insets.top
        var mediaHeight: CGFloat = 0.0
        if isLoading {
            mediaHeight = 120.0
            blocksTop = mediaInset + mediaHeight + 8.0
        } else if !self.mediaView.isHidden {
            if let image = self.mediaView.image, image.size.width > 0.0 {
                mediaHeight = min(180.0, floor(mediaWidth * image.size.height / image.size.width))
            } else {
                mediaHeight = 120.0
            }
            blocksTop = mediaInset + mediaHeight + 8.0
        }
        var linkCardHeight: CGFloat = 0.0
        var blocksHeight = blocksTop - insets.top
        if !self.linkCardView.isHidden {
            linkCardHeight = self.linkCardView.heightThatFits(width: contentWidth)
            blocksHeight += linkCardHeight + 8.0
        }

        // Under the text: an error or info line, then the AI sources.
        var rowsHeight: CGFloat = 0.0
        var statusHeight: CGFloat = 0.0
        if let statusText = self.statusText, !isLoading {
            self.statusLabel.text = statusText
            let retryWidth: CGFloat = self.showsRetry ? 56.0 : 0.0
            statusHeight = ceil(self.statusLabel.sizeThatFits(CGSize(width: contentWidth - rowInset * 2.0 - retryWidth, height: 40.0)).height)
            rowsHeight += 10.0 + statusHeight
        }
        let showsSources = self.aiGenerated && !self.sources.isEmpty && !isLoading
        let sourcesHeight: CGFloat = 26.0
        if showsSources {
            rowsHeight += 10.0 + sourcesHeight
        }

        // Text row: 4 above, 16 below; then the button row.
        let textTop = insets.top + blocksHeight + 4.0
        let buttonRowHeight = MessageNoteEditorNode.buttonRowHeight
        let fixedHeight = textTop + rowsHeight + 16.0 + buttonRowHeight + insets.bottom

        // The card sits above the anchor; it shrinks its text area rather than going under the status bar.
        let topLimit = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top) + 8.0
        let bottom = self.anchorRect.minY - tailHeight - 4.0
        textHeight = max(lineHeight, min(textHeight, bottom - topLimit - fixedHeight))
        let cardHeight = fixedHeight + textHeight

        let sideInset: CGFloat = 8.0
        var cardX = self.anchorRect.midX - cardWidth / 2.0
        cardX = max(sideInset, min(layout.size.width - sideInset - cardWidth, cardX))
        let cardFrame = CGRect(x: cardX, y: bottom - cardHeight, width: cardWidth, height: cardHeight + tailHeight)

        let tailLimit = MessageNoteEditorNode.cornerRadius + MessageNoteEditorNode.tailWidth / 2.0
        self.tailOffset = max(tailLimit, min(cardWidth - tailLimit, self.anchorRect.midX - cardX))

        transition.updateFrame(view: self.containerView, frame: cardFrame)
        let path = MessageNoteEditorNode.backgroundPath(size: CGSize(width: cardWidth, height: cardHeight), tailOffset: self.tailOffset)
        self.backgroundLayer.path = path.cgPath
        self.blurView.frame = CGRect(origin: CGPoint(), size: cardFrame.size)
        self.blurMaskLayer.path = path.cgPath
        self.shadowLayer.shadowPath = path.cgPath
        self.contactShadowLayer.shadowPath = path.cgPath
        // Everything but the card: the shadows show only outside it.
        let outside = UIBezierPath(rect: CGRect(origin: CGPoint(), size: cardFrame.size).insetBy(dx: -120.0, dy: -120.0))
        outside.append(path)
        for layer in [self.shadowLayer, self.contactShadowLayer] {
            let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.fillRule = .evenOdd
            mask.path = outside.cgPath
            layer.mask = mask
        }

        let blockY = blocksTop
        if isLoading {
            self.skeletonMediaView.frame = CGRect(x: mediaInset, y: mediaInset, width: mediaWidth, height: mediaHeight)
            applyMessageNotePhotoCorners(self.skeletonMediaView, top: MessageNoteEditorNode.cornerRadius - mediaInset, bottom: floor((MessageNoteEditorNode.cornerRadius - mediaInset) / 2.0))
        } else if !self.mediaView.isHidden {
            self.mediaView.frame = CGRect(x: mediaInset, y: mediaInset, width: mediaWidth, height: mediaHeight)
            applyMessageNotePhotoCorners(self.mediaView, top: MessageNoteEditorNode.cornerRadius - mediaInset, bottom: floor((MessageNoteEditorNode.cornerRadius - mediaInset) / 2.0))
            self.mediaRemoveButton.frame = CGRect(x: mediaWidth - 10.0 - 24.0, y: 10.0, width: 24.0, height: 24.0)
        }
        if !self.linkCardView.isHidden {
            self.linkCardView.frame = CGRect(x: insets.left, y: blockY, width: contentWidth, height: linkCardHeight)
            self.linkCardRemoveButton.frame = CGRect(x: contentWidth - 6.0 - 24.0, y: linkCardHeight - 6.0 - 24.0, width: 24.0, height: 24.0)
        }

        if isLoading {
            self.searchingLabel.frame = CGRect(x: insets.left + rowInset, y: textTop, width: textWidth, height: 20.0)
            let lineWidths: [CGFloat] = [textWidth, floor(textWidth * 0.6)]
            for (index, view) in self.skeletonLineViews.enumerated() {
                view.frame = CGRect(x: insets.left + rowInset, y: textTop + 30.0 + CGFloat(index) * 20.0, width: lineWidths[index], height: 12.0)
            }
        }
        var rowY = textTop + textHeight
        if self.statusText != nil && !isLoading {
            rowY += 10.0
            let retryWidth: CGFloat = self.showsRetry ? 56.0 : 0.0
            self.statusLabel.frame = CGRect(x: insets.left + rowInset, y: rowY, width: contentWidth - rowInset * 2.0 - retryWidth, height: statusHeight)
            self.retryButton.frame = CGRect(x: insets.left + contentWidth - rowInset - retryWidth, y: rowY + floor((statusHeight - 24.0) / 2.0), width: retryWidth, height: 24.0)
            rowY += statusHeight
        }
        if showsSources {
            rowY += 10.0
            self.sourcesLabel.sizeToFit()
            self.sourcesLabel.frame = CGRect(origin: CGPoint(x: insets.left + rowInset, y: rowY + floor((sourcesHeight - self.sourcesLabel.bounds.height) / 2.0)), size: self.sourcesLabel.bounds.size)
            var chipX = self.sourcesLabel.frame.maxX + 8.0
            for chip in self.sourceChipViews {
                let width = ceil(chip.sizeThatFits(CGSize(width: 200.0, height: sourcesHeight)).width)
                if chipX + width > insets.left + contentWidth {
                    chip.isHidden = true
                    continue
                }
                chip.isHidden = false
                chip.frame = CGRect(x: chipX, y: rowY, width: width, height: sourcesHeight)
                chipX += width + 6.0
            }
        }

        let textFrame = CGRect(x: insets.left + rowInset, y: textTop, width: textWidth, height: textHeight)
        self.textView.frame = textFrame
        self.textView.isScrollEnabled = fittedTextHeight > textHeight
        // A small gap keeps the caret off the placeholder's first letter.
        self.placeholderLabel.frame = CGRect(x: textFrame.minX + 3.0, y: textTop, width: textWidth - 3.0, height: lineHeight)
        // Bottom row: Ai and photo on the left, the counter and Done on the right, all centred vertically.
        let bottomRowY = cardHeight - insets.bottom - buttonRowHeight
        let smallButtonSize = MessageNoteEditorNode.smallButtonSize
        let smallButtonY = bottomRowY + floor((buttonRowHeight - smallButtonSize.height) / 2.0)
        self.aiButton.frame = CGRect(origin: CGPoint(x: insets.left, y: smallButtonY), size: smallButtonSize)
        self.attachButton.frame = CGRect(origin: CGPoint(x: insets.left + smallButtonSize.width + 6.0, y: smallButtonY), size: smallButtonSize)
        self.doneButton.frame = CGRect(origin: CGPoint(x: cardWidth - insets.right - buttonSize.width, y: bottomRowY + floor((buttonRowHeight - buttonSize.height) / 2.0)), size: buttonSize)
        self.counterLabel.frame = CGRect(x: self.doneButton.frame.minX - 10.0 - 80.0, y: bottomRowY, width: 80.0, height: buttonRowHeight)

        if isFirstLayout {
            self.textView.becomeFirstResponder()
        }
    }

    /// A rounded rect (continuous corners) with a smooth tail under it at `tailOffset`.
    private static func backgroundPath(size: CGSize, tailOffset: CGFloat) -> UIBezierPath {
        let path = UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: cornerRadius)
        let tail = UIBezierPath()
        let halfWidth = tailWidth / 2.0
        let baseY = size.height - 1.0
        tail.move(to: CGPoint(x: tailOffset - halfWidth, y: baseY))
        tail.addCurve(to: CGPoint(x: tailOffset - 3.0, y: size.height + tailHeight - 1.5), controlPoint1: CGPoint(x: tailOffset - halfWidth + 8.0, y: baseY), controlPoint2: CGPoint(x: tailOffset - 6.0, y: size.height + tailHeight - 4.5))
        tail.addQuadCurve(to: CGPoint(x: tailOffset + 3.0, y: size.height + tailHeight - 1.5), controlPoint: CGPoint(x: tailOffset, y: size.height + tailHeight + 1.0))
        tail.addCurve(to: CGPoint(x: tailOffset + halfWidth, y: baseY), controlPoint1: CGPoint(x: tailOffset + 6.0, y: size.height + tailHeight - 4.5), controlPoint2: CGPoint(x: tailOffset + halfWidth - 8.0, y: baseY))
        tail.close()
        path.append(tail.reversing())
        return path
    }

    func animateIn() {
        self.containerView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        if !UIAccessibility.isReduceMotionEnabled {
            let frame = self.containerView.frame
            let tailPoint = CGPoint(x: frame.minX + self.tailOffset, y: frame.maxY)
            let offset = CGPoint(x: tailPoint.x - frame.midX, y: tailPoint.y - frame.midY)
            self.containerView.layer.animateSpring(from: 0.5 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.4)
            self.containerView.layer.animatePosition(from: CGPoint(x: offset.x * 0.5, y: offset.y * 0.5), to: CGPoint(), duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
        }
    }

    func animateOut(completion: @escaping () -> Void) {
        self.aiGeneration += 1
        self.aiRequest?.cancel()
        self.aiRequest = nil
        self.textView.resignFirstResponder()
        self.containerView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
        if !UIAccessibility.isReduceMotionEnabled {
            self.containerView.layer.animateScale(from: 1.0, to: 0.9, duration: 0.15, removeOnCompletion: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: completion)
    }

    // MARK: - Content

    private func attributedText(note: MessageNoteContent) -> NSAttributedString {
        let result = NSMutableAttributedString(string: note.text, attributes: [.font: self.baseFont, .foregroundColor: self.textColor])
        let length = result.length
        for entity in note.entities {
            let range = NSRange(location: entity.range.lowerBound, length: entity.range.count)
            guard range.location + range.length <= length else {
                continue
            }
            switch entity.kind {
            case .bold:
                result.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                    let font = (value as? UIFont) ?? self.baseFont
                    result.addAttribute(.font, value: font.withTraits(.traitBold), range: subrange)
                }
            case .italic:
                result.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                    let font = (value as? UIFont) ?? self.baseFont
                    result.addAttribute(.font, value: font.withTraits(.traitItalic), range: subrange)
                }
            case .url:
                break
            case let .textUrl(url):
                result.addAttribute(.link, value: url, range: range)
            }
        }
        return result
    }

    /// The annotation as it is now: font traits become bold/italic, `.link` becomes a text link, bare URLs become url
    /// entities.
    private func currentNote() -> MessageNoteContent {
        let attributedText = self.textView.attributedText ?? NSAttributedString()
        let fullRange = NSRange(location: 0, length: attributedText.length)
        var entities: [MessageNoteContent.Entity] = []
        attributedText.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            let swiftRange = range.location ..< (range.location + range.length)
            if let font = attributes[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) {
                    entities.append(MessageNoteContent.Entity(kind: .bold, range: swiftRange))
                }
                if traits.contains(.traitItalic) {
                    entities.append(MessageNoteContent.Entity(kind: .italic, range: swiftRange))
                }
            }
            if let link = attributes[.link] {
                let url: String?
                if let value = link as? URL {
                    url = value.absoluteString
                } else {
                    url = link as? String
                }
                if let url {
                    entities.append(MessageNoteContent.Entity(kind: .textUrl(url), range: swiftRange))
                }
            }
        }
        let text = attributedText.string
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, options: [], range: fullRange) {
                let range = match.range.location ..< (match.range.location + match.range.length)
                let isInsideLink = entities.contains(where: { entity in
                    if case .textUrl = entity.kind {
                        return entity.range.overlaps(range)
                    }
                    return false
                })
                if !isInsideLink {
                    entities.append(MessageNoteContent.Entity(kind: .url, range: range))
                }
            }
        }
        return MessageNoteContent(text: text, entities: mergedEntities(entities), imageUrl: self.imageUrl, localImageId: self.localImageId, suppressLinkPreview: self.suppressLinkPreview, aiGenerated: self.aiGenerated, sources: self.aiGenerated ? self.sources : [])
    }

    private func updateState() {
        let count = self.textView.text.count
        self.counterLabel.text = "\(count)/\(MessageNoteContent.maxTextLength)"
        let isLoading = self.aiState == .loading
        self.placeholderLabel.isHidden = !self.textView.text.isEmpty || isLoading
        let isValid = (!self.currentNote().isEmpty || self.initialNote != nil) && !isLoading
        self.attachButton.isEnabled = !isLoading
        self.attachButton.alpha = isLoading ? 0.5 : 1.0
        self.doneButton.isEnabled = isValid
        self.doneButton.alpha = isValid ? 1.0 : 0.5
    }

    // MARK: - Actions

    private func editLink(range selectedRange: NSRange) {
        var currentUrl: String?
        self.textView.attributedText.enumerateAttribute(.link, in: selectedRange, options: []) { value, _, _ in
            if let value = value as? URL {
                currentUrl = value.absoluteString
            } else if let value = value as? String {
                currentUrl = value
            }
        }
        self.actions.requestLink(currentUrl, { [weak self] url in
            guard let self else {
                return
            }
            if let url {
                let text = NSMutableAttributedString(attributedString: self.textView.attributedText)
                if url.isEmpty {
                    text.removeAttribute(.link, range: selectedRange)
                } else {
                    text.addAttribute(.link, value: url, range: selectedRange)
                }
                self.textView.attributedText = text
                self.textView.selectedRange = NSRange(location: selectedRange.location + selectedRange.length, length: 0)
                self.updateState()
            }
            self.textView.becomeFirstResponder()
        })
    }

    @objc private func aiPressed() {
        switch self.aiState {
        case .loading:
            self.stopAI()
        case .idle:
            if self.currentNote().isEmpty {
                self.startAI()
            } else {
                self.actions.confirm("Replace current note?", "Replace", { [weak self] confirmed in
                    if confirmed {
                        self?.startAI()
                    }
                    self?.textView.becomeFirstResponder()
                })
            }
        case .result:
            if self.textView.text != (self.aiText ?? "") {
                self.actions.confirm("Replace your edits with a new draft?", "Regenerate", { [weak self] confirmed in
                    if confirmed {
                        self?.startAI()
                    }
                    self?.textView.becomeFirstResponder()
                })
            } else {
                self.startAI()
            }
        }
    }

    @objc private func retryPressed() {
        self.startAI()
    }

    private func startAI() {
        self.snapshot = Snapshot(text: self.textView.attributedText ?? NSAttributedString(), localImageId: self.localImageId, imageUrl: self.imageUrl, suppressLinkPreview: self.suppressLinkPreview, aiGenerated: self.aiGenerated, sources: self.sources, aiText: self.aiText)
        self.statusText = nil
        self.showsRetry = false
        self.aiState = .loading
        self.updateAIViews()

        let anchor = self.aiContext.anchor
        self.aiGeneration += 1
        let generation = self.aiGeneration
        let startTime = CACurrentMediaTime()
        self.aiRequest = self.aiService.generate(anchor: anchor, context: self.aiContext.messageText, language: self.aiContext.language, completion: { [weak self] result in
            // The skeleton stays up for a while even when the answer is quick, so that its animation is seen.
            let remaining = MessageNoteEditorNode.minimumAILoadingDuration - (CACurrentMediaTime() - startTime)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.0, remaining)) {
                guard let self, self.aiGeneration == generation else {
                    return
                }
                self.applyAIResult(result, anchor: anchor)
            }
        })
    }

    private func applyAIResult(_ result: Swift.Result<NoteAIResult, NoteAIError>, anchor: String) {
        self.aiRequest = nil
        switch result {
        case let .success(value):
            let text = String(value.text.prefix(MessageNoteContent.maxTextLength))
            self.textView.attributedText = NSAttributedString(string: text, attributes: [.font: self.baseFont, .foregroundColor: self.textColor])
            self.localImageId = nil
            self.imageUrl = value.imageUrl
            self.suppressLinkPreview = false
            self.aiGenerated = true
            self.sources = value.sources
            self.aiText = text
            self.aiState = .result
            self.snapshot = nil
        case let .failure(error):
            self.restoreSnapshot()
            switch error {
            case .nothingFound:
                self.statusText = "Couldn't find anything about \u{201C}\(anchor)\u{201D}"
                self.showsRetry = false
            case .failed:
                self.statusText = "Something went wrong"
                self.showsRetry = true
            }
        }
        self.updateAIViews()
    }

    private func stopAI() {
        self.aiGeneration += 1
        self.aiRequest?.cancel()
        self.aiRequest = nil
        self.restoreSnapshot()
        self.updateAIViews()
    }

    /// Back to the content before the generation.
    private func restoreSnapshot() {
        guard let snapshot = self.snapshot else {
            self.aiState = self.aiGenerated ? .result : .idle
            return
        }
        self.snapshot = nil
        self.textView.attributedText = snapshot.text
        self.localImageId = snapshot.localImageId
        self.imageUrl = snapshot.imageUrl
        self.suppressLinkPreview = snapshot.suppressLinkPreview
        self.aiGenerated = snapshot.aiGenerated
        self.sources = snapshot.sources
        self.aiText = snapshot.aiText
        self.aiState = snapshot.aiGenerated ? .result : .idle
    }

    /// The Ai button, skeletons, status and sources for the current AI state; relays out.
    private func updateAIViews() {
        let isLoading = self.aiState == .loading
        let aiImage: UIImage?
        switch self.aiState {
        case .idle:
            aiImage = UIImage(bundleImageName: "Chat/Input/Text/InputAIIcon")?.withRenderingMode(.alwaysTemplate)
            self.aiButton.accessibilityLabel = "Generate with AI"
        case .loading:
            aiImage = UIImage(systemName: "stop.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .regular))
            self.aiButton.accessibilityLabel = "Stop"
        case .result:
            // The regenerate icon of Telegram's own AI text tools.
            // Its 52 pt canvas has wide margins: at 40 pt the arrow is about 17 pt, like the other glyphs.
            aiImage = generateScaledIcon(UIImage(bundleImageName: "TextProcessing/RefreshButton"), size: CGSize(width: 40.0, height: 40.0))
            self.aiButton.accessibilityLabel = "Regenerate"
        }
        if self.displayedAIState != self.aiState {
            if self.displayedAIState == nil {
                self.aiButton.setImage(aiImage, for: .normal)
            } else {
                self.aiButton.setImageAnimated(aiImage)
            }
            self.displayedAIState = self.aiState
        }
        self.aiButton.setSpinning(isLoading)

        self.textView.alpha = isLoading ? 0.0 : 1.0
        self.skeletonMediaView.isHidden = !isLoading
        self.searchingLabel.isHidden = !isLoading
        for view in self.skeletonLineViews {
            view.isHidden = !isLoading
        }
        for view in [self.skeletonMediaView] + self.skeletonLineViews {
            if isLoading {
                if view.layer.animation(forKey: "pulse") == nil {
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 1.0
                    animation.toValue = 0.45
                    animation.duration = 0.8
                    animation.autoreverses = true
                    animation.repeatCount = .infinity
                    view.layer.add(animation, forKey: "pulse")
                }
            } else {
                view.layer.removeAnimation(forKey: "pulse")
            }
        }
        if isLoading {
            self.mediaView.isHidden = true
            self.linkCardView.isHidden = true
        }

        self.statusLabel.isHidden = self.statusText == nil || isLoading
        self.retryButton.isHidden = !self.showsRetry || self.statusText == nil || isLoading

        for chip in self.sourceChipViews {
            chip.removeFromSuperview()
        }
        self.sourceChipViews = []
        let showsSources = self.aiGenerated && !self.sources.isEmpty && !isLoading
        self.sourcesLabel.isHidden = !showsSources
        if showsSources {
            for source in self.sources {
                // Accent on an accent tint, like the Ai button: grey on grey washed out on the glass.
                let chip = SourceChipView(url: source, textColor: self.accentColor, fillColor: self.chipFillColor, iconFillColor: self.accentColor.withAlphaComponent(0.15))
                self.containerView.addSubview(chip)
                self.sourceChipViews.append(chip)
            }
        }

        if isLoading {
            self.updateState()
            self.relayout()
        } else {
            self.updateMedia()
        }
    }

    @objc private func attachPressed() {
        // The picker opens under this overlay: hide the editor until it closes.
        self.textView.resignFirstResponder()
        self.view.isHidden = true
        self.actions.requestPhoto({ [weak self] image in
            guard let self else {
                return
            }
            self.view.isHidden = false
            if let image, let id = MessageNoteMedia.storeLocalImage(image) {
                // A new pick replaces the current photo.
                self.localImageId = id
                self.imageUrl = nil
            }
            self.updateMedia()
            self.textView.becomeFirstResponder()
        })
    }

    @objc private func removeMediaPressed() {
        self.localImageId = nil
        self.imageUrl = nil
        self.updateMedia()
        self.resetAIIfEmpty()
    }

    /// With the text and the photo both deleted the annotation is no longer an AI draft: Ai comes back in place of
    /// Regenerate, and the sources go.
    private func resetAIIfEmpty() {
        guard self.aiGenerated, self.aiState != .loading, self.currentNote().isEmpty else {
            return
        }
        self.aiGenerated = false
        self.sources = []
        self.aiText = nil
        self.aiState = .idle
        self.updateAIViews()
    }

    @objc private func removeLinkCardPressed() {
        // The URL stays as plain text, without the card.
        self.suppressLinkPreview = true
        self.updateMedia()
    }

    /// Shows or hides the photo and the link card for the current content, and relays out.
    private func updateMedia() {
        let imageKey = self.localImageId ?? self.imageUrl
        if self.displayedImageKey != imageKey {
            self.displayedImageKey = imageKey
            self.mediaView.image = nil
        }
        if let localImageId = self.localImageId {
            self.mediaView.image = MessageNoteMedia.localImage(id: localImageId)
            self.mediaView.isHidden = false
        } else if let imageUrl = self.imageUrl {
            self.mediaView.isHidden = false
            if self.mediaView.image == nil {
                MessageNoteMedia.loadRemoteImage(url: imageUrl, completion: { [weak self] image in
                    guard let self, self.imageUrl == imageUrl else {
                        return
                    }
                    self.mediaView.image = image
                    self.relayout()
                })
            }
        } else {
            self.mediaView.image = nil
            self.mediaView.isHidden = true
        }

        let linkPreviewUrl = self.currentNote().linkPreviewUrl
        if let linkPreviewUrl {
            if self.linkCard?.url != linkPreviewUrl {
                self.linkCard = MessageNoteLinkCard(url: linkPreviewUrl, domain: URL(string: linkPreviewUrl)?.host ?? linkPreviewUrl, title: nil, text: nil)
            }
            if self.linkCardRequestedUrl != linkPreviewUrl {
                self.linkCardRequestedUrl = linkPreviewUrl
                self.actions.loadLinkCard(linkPreviewUrl, { [weak self] card in
                    guard let self, let card, self.linkCardRequestedUrl == linkPreviewUrl else {
                        return
                    }
                    self.linkCard = card
                    self.linkCardView.card = card
                    self.relayout()
                })
            }
            self.linkCardView.card = self.linkCard
            self.linkCardView.isHidden = false
        } else {
            self.linkCardView.isHidden = true
        }
        self.updateState()
        self.relayout()
    }

    private func relayout() {
        if let layout = self.validLayout {
            self.updateLayout(layout: layout, transition: .immediate)
        }
    }

    @objc private func donePressed() {
        let note = self.currentNote()
        if !note.isEmpty {
            self.finish(.save(note))
        } else if self.initialNote != nil {
            // Clearing the text of an existing annotation removes it.
            self.finish(.remove)
        }
    }

    @objc private func backgroundTapped(_ recognizer: UITapGestureRecognizer) {
        // A tap outside saves a valid annotation; otherwise a new one is dropped and an existing one keeps its version.
        let note = self.currentNote()
        if !note.isEmpty && note != self.initialNote {
            self.finish(.save(note))
        } else if note.isEmpty && self.initialNote != nil {
            self.finish(.remove)
        } else {
            self.finish(.cancel)
        }
    }

    @objc private func cardPanned(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            let offset = max(0.0, recognizer.translation(in: self.view).y)
            self.containerView.transform = CGAffineTransform(translationX: 0.0, y: offset)
        case .ended, .cancelled:
            if recognizer.translation(in: self.view).y > 60.0 || recognizer.velocity(in: self.view).y > 600.0 {
                // A swipe down discards the changes.
                self.finish(.cancel)
            } else {
                UIView.animate(withDuration: 0.25, animations: {
                    self.containerView.transform = .identity
                })
            }
        default:
            break
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer {
            let point = gestureRecognizer.location(in: self.view)
            return !self.containerView.frame.contains(point)
        }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: self.view)
            return velocity.y > abs(velocity.x)
        }
        return true
    }

    // MARK: - UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if self.aiState == .loading {
            return false
        }
        let current = textView.text as NSString
        let updated = current.replacingCharacters(in: range, with: text)
        return updated.count <= MessageNoteContent.maxTextLength
    }

    func textViewDidChange(_ textView: UITextView) {
        self.normalizePastedStyle(textView)
        if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // An emptied field gets the link preview back for the next URL.
            self.suppressLinkPreview = false
        }
        self.statusText = nil
        self.resetAIIfEmpty()
        self.updateMedia()
    }

    /// Pasted text brings its source's colours and fonts: it keeps only bold, italic and links, in the field's own
    /// colour and size.
    private func normalizePastedStyle(_ textView: UITextView) {
        guard textView.markedTextRange == nil, let text = textView.attributedText, text.length > 0 else {
            return
        }
        var needsUpdate = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attributes, _, stop in
            let font = attributes[.font] as? UIFont
            if !((attributes[.foregroundColor] as? UIColor)?.isEqual(self.textColor) ?? false) || font?.pointSize != self.baseFont.pointSize || attributes[.backgroundColor] != nil {
                needsUpdate = true
                stop.pointee = true
            }
        }
        guard needsUpdate else {
            return
        }
        let result = NSMutableAttributedString(string: text.string, attributes: [.font: self.baseFont, .foregroundColor: self.textColor])
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attributes, range, _ in
            if let font = attributes[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic])
                if !traits.isEmpty, let descriptor = self.baseFont.fontDescriptor.withSymbolicTraits(traits) {
                    result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: self.baseFont.pointSize), range: range)
                }
            }
            if let link = attributes[.link] {
                result.addAttribute(.link, value: link, range: range)
            }
        }
        let selectedRange = textView.selectedRange
        textView.attributedText = result
        textView.selectedRange = selectedRange
        textView.typingAttributes = [.font: self.baseFont, .foregroundColor: self.textColor]
    }

    /// Adds "Link" to the field's edit menu for a selection.
    @available(iOS 16.0, *)
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0 else {
            return nil
        }
        let linkAction = UIAction(title: "Link", image: nil) { [weak self] _ in
            self?.editLink(range: range)
        }
        return UIMenu(children: suggestedActions + [linkAction])
    }
}

/// The image redrawn at `size` as a template, so it takes the button's tint.
private func generateScaledIcon(_ image: UIImage?, size: CGSize) -> UIImage? {
    guard let image else {
        return nil
    }
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
        image.draw(in: CGRect(origin: CGPoint(), size: size))
    }.withRenderingMode(.alwaysTemplate)
}

/// Joins adjacent runs of the same kind (attribute enumeration splits them wherever any attribute changes).
private func mergedEntities(_ entities: [MessageNoteContent.Entity]) -> [MessageNoteContent.Entity] {
    var result: [MessageNoteContent.Entity] = []
    for entity in entities.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
        if let index = result.lastIndex(where: { $0.kind == entity.kind }), result[index].range.upperBound == entity.range.lowerBound {
            result[index].range = result[index].range.lowerBound ..< entity.range.upperBound
        } else {
            result.append(entity)
        }
    }
    return result
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = self.fontDescriptor.withSymbolicTraits(self.fontDescriptor.symbolicTraits.union(traits)) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: self.pointSize)
    }
}
