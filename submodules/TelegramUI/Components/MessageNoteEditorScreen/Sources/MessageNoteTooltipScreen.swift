import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import TextFormat
import BetaFeatures

/// The tooltip of an annotation: a dark bubble above (or below) the tapped anchor line, with the annotation's media,
/// text, link preview card and AI footer.
public final class MessageNoteTooltipScreen: ViewController {
    public enum Style {
        /// A dark blurred bubble with a straight arrow (the first design).
        case dark
        /// The look of the annotation editor: a light card with a smooth tail and a soft shadow.
        case card
        /// The editor's shape, tail, shadow and type, in the first design's dark colours.
        case darkCard
    }

    /// The tooltip's look: `.dark` is the first design, `.card` the editor's look, `.darkCard` the two mixed.
    public static var style: Style = .darkCard

    public struct Actions {
        /// Fetches the link preview card of a URL-only annotation.
        public var loadLinkCard: (String, @escaping (MessageNoteLinkCard?) -> Void) -> Void
        public var openUrl: (String) -> Void
        /// Whether a tap outside the tooltip lands on another annotation's anchor, which then opens at once.
        public var passesTouchThrough: (CGPoint) -> Bool

        public init(loadLinkCard: @escaping (String, @escaping (MessageNoteLinkCard?) -> Void) -> Void, openUrl: @escaping (String) -> Void, passesTouchThrough: @escaping (CGPoint) -> Bool) {
            self.loadLinkCard = loadLinkCard
            self.openUrl = openUrl
            self.passesTouchThrough = passesTouchThrough
        }
    }

    private let presentationData: PresentationData
    private let note: MessageNoteContent
    private let anchorRect: CGRect
    private let topLimit: CGFloat
    private let actions: Actions

    private var isDismissed = false
    public var becameDismissed: (() -> Void)?

    private var controllerNode: MessageNoteTooltipNode {
        return self.displayNode as! MessageNoteTooltipNode
    }

    /// - Parameters:
    ///   - anchorRect: the anchor's rect on the tapped line, in window coordinates.
    ///   - topLimit: the lowest y the tooltip may reach above the anchor (under the navigation bar); below it, the
    ///     tooltip flips under the anchor.
    public init(presentationData: PresentationData, note: MessageNoteContent, anchorRect: CGRect, topLimit: CGFloat, actions: Actions) {
        self.presentationData = presentationData
        self.note = note
        self.anchorRect = anchorRect
        self.topLimit = topLimit
        self.actions = actions

        super.init(navigationBarPresentationData: nil)

        self.statusBar.statusBarStyle = .Ignore
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func loadDisplayNode() {
        self.displayNode = MessageNoteTooltipNode(presentationData: self.presentationData, note: self.note, anchorRect: self.anchorRect, topLimit: self.topLimit, actions: self.actions, requestDismiss: { [weak self] in
            self?.dismiss()
        })
        self.displayNodeDidLoad()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.controllerNode.animateIn()
        UIAccessibility.post(notification: .layoutChanged, argument: self.controllerNode.accessibilityFocusView)
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.controllerNode.updateLayout(layout: layout)
    }

    override public func dismiss(completion: (() -> Void)? = nil) {
        if self.isDismissed {
            completion?()
            return
        }
        self.isDismissed = true
        self.controllerNode.animateOut(completion: { [weak self] in
            guard let self else {
                return
            }
            self.presentingViewController?.dismiss(animated: false, completion: nil)
            self.becameDismissed?()
            completion?()
        })
    }
}

private final class MessageNoteTooltipNode: ASDisplayNode {
    private let note: MessageNoteContent
    private let anchorRect: CGRect
    private let topLimit: CGFloat
    private let actions: Actions
    private let requestDismiss: () -> Void

    private typealias Actions = MessageNoteTooltipScreen.Actions

    private let bubbleView: UIView
    private let blurView: UIVisualEffectView
    private let tintView: UIView
    private let maskLayer: CAShapeLayer
    private let scrollView: UIScrollView
    private let imageView: UIImageView
    private let imagePlaceholderLabel: UILabel
    private let textView: UITextView
    private let linkCardView: MessageNoteLinkCardView
    private let footerView: UITextView

    private var image: UIImage?
    private var isLoadingImage = false
    private var linkCard: MessageNoteLinkCard?
    private var validLayout: ContainerViewLayout?
    private var didRequestDismiss = false
    private var passesTouchThrough = false

    private static let maxWidth: CGFloat = 300.0
    private static let screenInset: CGFloat = 8.0
    private static let spacing: CGFloat = 8.0

    private struct Metrics {
        var padding: UIEdgeInsets
        /// A photo sits closer to the bubble's edges than text: its corner radius plus this inset is the bubble's.
        var mediaInset: CGFloat
        var arrowSize: CGSize
        var cornerRadius: CGFloat
        var fontSize: CGFloat

        static let dark = Metrics(padding: UIEdgeInsets(top: 10.0, left: 12.0, bottom: 10.0, right: 12.0), mediaInset: 6.0, arrowSize: CGSize(width: 18.0, height: 8.0), cornerRadius: 14.0, fontSize: 15.0)
        /// As the editor: corner 24, text inset 16 (12 + the editor's 4 pt text row inset).
        static let card = Metrics(padding: UIEdgeInsets(top: 12.0, left: 12.0, bottom: 14.0, right: 12.0), mediaInset: 4.0, arrowSize: CGSize(width: 30.0, height: 10.0), cornerRadius: 24.0, fontSize: 15.0)
    }

    private let tooltipStyle: MessageNoteTooltipScreen.Style
    private let metrics: Metrics
    /// Holds the shadows (outside the bubble's mask) and the bubble; it is what animates.
    private let containerView: UIView
    private let shadowLayer: CAShapeLayer
    private let contactShadowLayer: CAShapeLayer

    var accessibilityFocusView: UIView {
        return self.textView
    }

    init(presentationData: PresentationData, note: MessageNoteContent, anchorRect: CGRect, topLimit: CGFloat, actions: MessageNoteTooltipScreen.Actions, requestDismiss: @escaping () -> Void) {
        self.note = note
        self.anchorRect = anchorRect
        self.topLimit = topLimit
        self.actions = actions
        self.requestDismiss = requestDismiss

        let style = MessageNoteTooltipScreen.style
        self.tooltipStyle = style
        self.metrics = style == .dark ? .dark : .card
        let theme = presentationData.theme
        let isDark = theme.overallDarkAppearance

        let textColor: UIColor
        let secondaryTextColor: UIColor
        let linkColor: UIColor
        let fillColor: UIColor
        switch style {
        case .dark, .darkCard:
            textColor = UIColor.white
            secondaryTextColor = UIColor(white: 1.0, alpha: 0.6)
            linkColor = textColor
            fillColor = UIColor(white: 1.0, alpha: 0.1)
        case .card:
            textColor = theme.list.itemPrimaryTextColor
            secondaryTextColor = theme.list.itemSecondaryTextColor
            linkColor = theme.list.itemAccentColor
            fillColor = isDark ? theme.list.itemBlocksBackgroundColor.withMultipliedBrightnessBy(1.6) : UIColor(rgb: 0xf2f2f7)
        }
        let underlineLinks = style != .card

        self.containerView = UIView()
        self.shadowLayer = CAShapeLayer()
        self.contactShadowLayer = CAShapeLayer()
        self.bubbleView = UIView()
        self.blurView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        self.tintView = UIView()
        self.tintView.backgroundColor = UIColor(rgb: 0x252525, alpha: 0.6)
        self.maskLayer = CAShapeLayer()
        if style != .dark {
            // The editor's two shadows: a wide soft one and a tight contact one. They are drawn from their paths, so a
            // translucent (dark) bubble does not show a fill under it.
            if style == .card {
                let cardColor = theme.list.itemBlocksBackgroundColor
                self.blurView.isHidden = true
                self.tintView.backgroundColor = cardColor
            }
            for layer in [self.shadowLayer, self.contactShadowLayer] {
                layer.fillColor = nil
                layer.shadowColor = UIColor.black.cgColor
            }
            self.shadowLayer.shadowOpacity = isDark ? 0.45 : 0.18
            self.shadowLayer.shadowRadius = 40.0
            self.shadowLayer.shadowOffset = CGSize(width: 0.0, height: 16.0)
            self.contactShadowLayer.shadowOpacity = isDark ? 0.3 : 0.08
            self.contactShadowLayer.shadowRadius = 4.0
            self.contactShadowLayer.shadowOffset = CGSize(width: 0.0, height: 1.0)
        }

        self.scrollView = UIScrollView()
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.alwaysBounceVertical = false

        self.imageView = UIImageView()
        self.imageView.contentMode = .scaleAspectFill
        self.imageView.clipsToBounds = true
        self.imageView.backgroundColor = fillColor

        self.imagePlaceholderLabel = UILabel()
        self.imagePlaceholderLabel.font = Font.regular(13.0)
        self.imagePlaceholderLabel.textColor = secondaryTextColor
        self.imagePlaceholderLabel.textAlignment = .center
        self.imagePlaceholderLabel.numberOfLines = 2

        self.textView = UITextView()
        self.textView.backgroundColor = .clear
        self.textView.isEditable = false
        self.textView.isSelectable = false
        self.textView.isScrollEnabled = false
        self.textView.textContainerInset = UIEdgeInsets()
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.linkTextAttributes = underlineLinks ? [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue] : [.foregroundColor: linkColor]

        self.linkCardView = MessageNoteLinkCardView(textColor: textColor, secondaryTextColor: secondaryTextColor, accentColor: style == .card ? linkColor : UIColor(rgb: 0x5ac8fa), fillColor: fillColor)

        self.footerView = UITextView()
        self.footerView.backgroundColor = .clear
        self.footerView.isEditable = false
        self.footerView.isSelectable = false
        self.footerView.isScrollEnabled = false
        self.footerView.textContainerInset = UIEdgeInsets()
        self.footerView.textContainer.lineFragmentPadding = 0.0
        self.footerView.linkTextAttributes = underlineLinks ? [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue] : [.foregroundColor: linkColor]

        // The node's own view (not a custom view block), so that `hitTest` below is consulted.
        super.init()

        let baseFont = Font.regular(self.metrics.fontSize)
        self.textView.attributedText = messageNoteAttributedText(note: note, font: baseFont, textColor: textColor, linkColor: linkColor, underlineLinks: underlineLinks)
        self.textView.accessibilityLabel = note.text

        if note.aiGenerated {
            let footer = NSMutableAttributedString(string: "✦ AI", attributes: [.font: Font.medium(12.0), .foregroundColor: secondaryTextColor])
            if !note.sources.isEmpty {
                footer.append(NSAttributedString(string: bgramText(" · Источники: ", " · Sources: "), attributes: [.font: Font.regular(12.0), .foregroundColor: secondaryTextColor]))
                for (index, source) in note.sources.enumerated() {
                    if index != 0 {
                        footer.append(NSAttributedString(string: ", ", attributes: [.font: Font.regular(12.0), .foregroundColor: secondaryTextColor]))
                    }
                    let domain = URL(string: source)?.host ?? source
                    var attributes: [NSAttributedString.Key: Any] = [.font: Font.regular(12.0), .foregroundColor: linkColor, .link: source]
                    if underlineLinks {
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    footer.append(NSAttributedString(string: domain, attributes: attributes))
                }
            }
            self.footerView.attributedText = footer
        }
    }

    override func didLoad() {
        super.didLoad()

        self.view.addSubview(self.containerView)
        self.containerView.layer.addSublayer(self.shadowLayer)
        self.containerView.layer.addSublayer(self.contactShadowLayer)
        self.containerView.addSubview(self.bubbleView)
        self.bubbleView.addSubview(self.blurView)
        self.bubbleView.addSubview(self.tintView)
        self.bubbleView.layer.mask = self.maskLayer
        self.bubbleView.addSubview(self.scrollView)
        self.scrollView.addSubview(self.imageView)
        self.scrollView.addSubview(self.imagePlaceholderLabel)
        self.scrollView.addSubview(self.textView)
        self.scrollView.addSubview(self.linkCardView)
        self.scrollView.addSubview(self.footerView)

        self.textView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.textTapped(_:))))
        self.textView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.textLongPressed(_:))))
        self.footerView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.footerTapped(_:))))
        self.linkCardView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.linkCardTapped)))

        if let localImageId = self.note.localImageId {
            if let image = MessageNoteMedia.localImage(id: localImageId) {
                self.image = image
            } else {
                self.imagePlaceholderLabel.text = bgramText("Фото есть только на устройстве отправителя", "The photo is only on the sender's device")
            }
        } else if let imageUrl = self.note.imageUrl {
            self.isLoadingImage = true
            MessageNoteMedia.loadRemoteImage(url: imageUrl, completion: { [weak self] image in
                guard let self else {
                    return
                }
                self.isLoadingImage = false
                self.image = image
                if image == nil {
                    self.imagePlaceholderLabel.text = bgramText("Не удалось загрузить фото", "The photo could not be loaded")
                }
                self.relayout()
            })
        }
        self.imageView.image = self.image

        if let url = self.note.linkPreviewUrl {
            self.linkCard = MessageNoteLinkCard(url: url, domain: URL(string: url)?.host ?? url, title: nil, text: nil)
            self.actions.loadLinkCard(url, { [weak self] card in
                guard let self, let card else {
                    return
                }
                self.linkCard = card
                self.relayout()
            })
        }
    }

    private func relayout() {
        self.imageView.image = self.image
        if let layout = self.validLayout {
            self.updateLayout(layout: layout)
        }
    }

    // MARK: - Layout

    func updateLayout(layout: ContainerViewLayout) {
        self.validLayout = layout

        let padding = self.metrics.padding
        let spacing = MessageNoteTooltipNode.spacing
        let arrowSize = self.metrics.arrowSize
        let screenInset = MessageNoteTooltipNode.screenInset

        let maxBubbleWidth = min(MessageNoteTooltipNode.maxWidth, layout.size.width - screenInset * 2.0)
        let maxContentWidth = maxBubbleWidth - padding.left - padding.right

        let hasText = self.note.linkPreviewUrl == nil && !self.note.text.isEmpty
        let hasMedia = self.note.localImageId != nil || self.note.imageUrl != nil
        let hasCard = self.linkCard != nil
        let hasFooter = self.note.aiGenerated

        // A text-only tooltip hugs its text; media and cards take the full width.
        var contentWidth = maxContentWidth
        if hasText && !hasMedia && !hasCard {
            let fitted = self.textView.sizeThatFits(CGSize(width: maxContentWidth, height: .greatestFiniteMagnitude))
            var width = ceil(fitted.width)
            if hasFooter {
                width = max(width, ceil(self.footerView.sizeThatFits(CGSize(width: maxContentWidth, height: .greatestFiniteMagnitude)).width))
            }
            contentWidth = min(maxContentWidth, max(width, 40.0))
        }

        var y: CGFloat = padding.top
        var blocks: [(UIView, CGRect)] = []

        if hasMedia {
            let mediaInset = self.metrics.mediaInset
            // The photo is followed by 4 pt more than the other blocks.
            let mediaWidth = contentWidth + padding.left + padding.right - mediaInset * 2.0
            if let image = self.image, image.size.width > 0.0 {
                let height = min(180.0, floor(mediaWidth * image.size.height / image.size.width))
                blocks.append((self.imageView, CGRect(x: mediaInset, y: mediaInset, width: mediaWidth, height: height)))
                self.imagePlaceholderLabel.isHidden = true
                self.imageView.isHidden = false
                y = mediaInset + height + spacing + 4.0
            } else if self.isLoadingImage {
                blocks.append((self.imageView, CGRect(x: mediaInset, y: mediaInset, width: mediaWidth, height: 120.0)))
                self.imagePlaceholderLabel.isHidden = true
                self.imageView.isHidden = false
                y = mediaInset + 120.0 + spacing + 4.0
            } else {
                blocks.append((self.imagePlaceholderLabel, CGRect(x: padding.left, y: y, width: contentWidth, height: 36.0)))
                self.imagePlaceholderLabel.isHidden = false
                self.imageView.isHidden = true
                y += 36.0 + spacing
            }
        } else {
            self.imageView.isHidden = true
            self.imagePlaceholderLabel.isHidden = true
        }

        self.textView.isHidden = !hasText
        if hasText {
            let height = ceil(self.textView.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
            blocks.append((self.textView, CGRect(x: padding.left, y: y, width: contentWidth, height: height)))
            y += height + spacing
        }

        self.linkCardView.isHidden = !hasCard
        if hasCard {
            self.linkCardView.card = self.linkCard
            let height = self.linkCardView.heightThatFits(width: contentWidth)
            blocks.append((self.linkCardView, CGRect(x: padding.left, y: y, width: contentWidth, height: height)))
            y += height + spacing
        }

        self.footerView.isHidden = !hasFooter
        if hasFooter {
            let height = ceil(self.footerView.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height)
            blocks.append((self.footerView, CGRect(x: padding.left, y: y, width: contentWidth, height: height)))
            y += height + spacing
        }
        // A photo alone keeps the same small inset below it.
        let endsWithMedia = hasMedia && !self.imageView.isHidden && !hasText && !hasCard && !hasFooter
        let contentHeight = y - spacing + (endsWithMedia ? self.metrics.mediaInset : padding.bottom)

        for (view, frame) in blocks {
            view.frame = frame
        }
        // The photo's top corners follow the bubble's; the bottom ones are half as round.
        let photoTopRadius = self.metrics.cornerRadius - self.metrics.mediaInset
        applyMessageNotePhotoCorners(self.imageView, top: photoTopRadius, bottom: floor(photoTopRadius / 2.0))

        // Above the anchor by default; below when it does not fit under the navigation bar.
        let bubbleWidth = contentWidth + padding.left + padding.right
        let spaceAbove = self.anchorRect.minY - arrowSize.height - 2.0 - self.topLimit
        let spaceBelow = layout.size.height - layout.intrinsicInsets.bottom - (layout.inputHeight ?? 0.0) - self.anchorRect.maxY - arrowSize.height - 2.0 - screenInset
        let isAbove = contentHeight <= spaceAbove || spaceAbove >= spaceBelow
        let bubbleHeight = min(contentHeight, max(60.0, isAbove ? spaceAbove : spaceBelow))

        var bubbleX = self.anchorRect.midX - bubbleWidth / 2.0
        bubbleX = max(screenInset, min(layout.size.width - screenInset - bubbleWidth, bubbleX))
        let bubbleY = isAbove ? self.anchorRect.minY - arrowSize.height - 2.0 - bubbleHeight : self.anchorRect.maxY + arrowSize.height + 2.0
        let bubbleFrame = CGRect(x: bubbleX, y: isAbove ? bubbleY : bubbleY - arrowSize.height, width: bubbleWidth, height: bubbleHeight + arrowSize.height)
        self.containerView.frame = bubbleFrame
        self.bubbleView.frame = CGRect(origin: CGPoint(), size: bubbleFrame.size)

        let bodyY: CGFloat = isAbove ? 0.0 : arrowSize.height
        let bodyRect = CGRect(x: 0.0, y: bodyY, width: bubbleWidth, height: bubbleHeight)
        self.blurView.frame = CGRect(origin: CGPoint(), size: bubbleFrame.size)
        self.tintView.frame = self.blurView.frame
        self.scrollView.frame = bodyRect
        self.scrollView.contentSize = CGSize(width: bubbleWidth, height: contentHeight)

        // The arrow stays on the anchor even when the bubble is clamped to the screen. The full radius is kept for a
        // card that starts with a photo (concentric with the photo's corners); a card that starts with text is
        // rounded less, and a short one keeps its corners within half its height.
        let startsWithPhoto = hasMedia && !self.imageView.isHidden
        let baseCornerRadius = startsWithPhoto ? self.metrics.cornerRadius : min(self.metrics.cornerRadius, 16.0)
        let cornerRadius = min(baseCornerRadius, floor(bodyRect.height / 2.0))
        let arrowLimit = cornerRadius + arrowSize.width / 2.0
        let arrowX = max(arrowLimit, min(bubbleWidth - arrowLimit, self.anchorRect.midX - bubbleX))
        let path = UIBezierPath(roundedRect: bodyRect, cornerRadius: cornerRadius)
        let arrow = self.tooltipStyle != .dark ? smoothTail(bodyRect: bodyRect, x: arrowX, size: arrowSize, pointsDown: isAbove) : UIBezierPath()
        if self.tooltipStyle != .dark {
        } else if isAbove {
            arrow.move(to: CGPoint(x: arrowX - arrowSize.width / 2.0, y: bodyRect.maxY - 1.0))
            arrow.addLine(to: CGPoint(x: arrowX, y: bodyRect.maxY + arrowSize.height))
            arrow.addLine(to: CGPoint(x: arrowX + arrowSize.width / 2.0, y: bodyRect.maxY - 1.0))
        } else {
            arrow.move(to: CGPoint(x: arrowX + arrowSize.width / 2.0, y: bodyRect.minY + 1.0))
            arrow.addLine(to: CGPoint(x: arrowX, y: bodyRect.minY - arrowSize.height))
            arrow.addLine(to: CGPoint(x: arrowX - arrowSize.width / 2.0, y: bodyRect.minY + 1.0))
        }
        arrow.close()
        // The arrow must wind like the rounded rect, or their 1 pt overlap cancels out and shows as a line.
        path.append(arrow.reversing())
        self.maskLayer.path = path.cgPath
        if self.tooltipStyle != .dark {
            for layer in [self.shadowLayer, self.contactShadowLayer] {
                layer.path = path.cgPath
                layer.shadowPath = path.cgPath
            }
        }
        // Scale animations grow from the arrow's tip.
        self.containerView.layer.anchorPoint = CGPoint(x: arrowX / bubbleWidth, y: isAbove ? 1.0 : 0.0)
        self.containerView.frame = bubbleFrame
    }

    func animateIn() {
        self.containerView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        if !UIAccessibility.isReduceMotionEnabled {
            self.containerView.layer.animateSpring(from: 0.6 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.4)
        }
    }

    func animateOut(completion: @escaping () -> Void) {
        self.containerView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false, completion: { _ in
            completion()
        })
        if !UIAccessibility.isReduceMotionEnabled {
            self.containerView.layer.animateScale(from: 1.0, to: 0.85, duration: 0.15, removeOnCompletion: false)
        }
    }

    // MARK: - Touches

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.containerView.frame.contains(point) {
            return super.hitTest(point, with: event)
        }
        guard let event, event.type == .touches else {
            return nil
        }
        // UIKit hit-tests one touch more than once: decide once, then repeat that decision.
        if self.didRequestDismiss {
            return self.passesTouchThrough ? nil : self.view
        }
        // A tap outside closes the tooltip and is not passed on, unless it lands on another annotation.
        self.didRequestDismiss = true
        self.passesTouchThrough = self.actions.passesTouchThrough(point)
        self.requestDismiss()
        return self.passesTouchThrough ? nil : self.view
    }

    private func linkUrl(in textView: UITextView, at point: CGPoint) -> String? {
        let layoutManager = textView.layoutManager
        let location = CGPoint(x: point.x - textView.textContainerInset.left, y: point.y - textView.textContainerInset.top)
        var fraction: CGFloat = 0.0
        let index = layoutManager.characterIndex(for: location, in: textView.textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < textView.attributedText.length else {
            return nil
        }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil), in: textView.textContainer)
        guard glyphRect.insetBy(dx: -4.0, dy: -4.0).contains(location) else {
            return nil
        }
        let value = textView.attributedText.attribute(.link, at: index, effectiveRange: nil)
        if let url = value as? URL {
            return url.absoluteString
        }
        return value as? String
    }

    @objc private func textTapped(_ recognizer: UITapGestureRecognizer) {
        if let url = self.linkUrl(in: self.textView, at: recognizer.location(in: self.textView)) {
            self.requestDismiss()
            self.actions.openUrl(url)
        }
    }

    @objc private func textLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard case .began = recognizer.state else {
            return
        }
        UIPasteboard.general.string = self.note.text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func footerTapped(_ recognizer: UITapGestureRecognizer) {
        if let url = self.linkUrl(in: self.footerView, at: recognizer.location(in: self.footerView)) {
            self.requestDismiss()
            self.actions.openUrl(url)
        }
    }

    @objc private func linkCardTapped() {
        if let url = self.linkCard?.url {
            self.requestDismiss()
            self.actions.openUrl(url)
        }
    }
}

/// The editor's smooth tail under (or over) `bodyRect` at `x`, wound like the straight arrows.
private func smoothTail(bodyRect: CGRect, x: CGFloat, size: CGSize, pointsDown: Bool) -> UIBezierPath {
    let halfWidth = size.width / 2.0
    let tail = UIBezierPath()
    // Built pointing down from y = 0, then flipped and moved into place.
    tail.move(to: CGPoint(x: -halfWidth, y: -1.0))
    tail.addCurve(to: CGPoint(x: -3.0, y: size.height - 1.5), controlPoint1: CGPoint(x: -halfWidth + 8.0, y: -1.0), controlPoint2: CGPoint(x: -6.0, y: size.height - 4.5))
    tail.addQuadCurve(to: CGPoint(x: 3.0, y: size.height - 1.5), controlPoint: CGPoint(x: 0.0, y: size.height + 1.0))
    tail.addCurve(to: CGPoint(x: halfWidth, y: -1.0), controlPoint1: CGPoint(x: 6.0, y: size.height - 4.5), controlPoint2: CGPoint(x: halfWidth - 8.0, y: -1.0))
    tail.close()
    if pointsDown {
        tail.apply(CGAffineTransform(translationX: x, y: bodyRect.maxY))
    } else {
        tail.apply(CGAffineTransform(scaleX: 1.0, y: -1.0).concatenating(CGAffineTransform(translationX: x, y: bodyRect.minY)))
        // The mirror flips the winding; flip it back so both tails wind the same way (the caller reverses them).
        return tail.reversing()
    }
    return tail
}

/// The annotation's text with its formatting: bold and italic fonts, links as `.link`.
func messageNoteAttributedText(note: MessageNoteContent, font: UIFont, textColor: UIColor, linkColor: UIColor, underlineLinks: Bool) -> NSAttributedString {
    let result = NSMutableAttributedString(string: note.text, attributes: [.font: font, .foregroundColor: textColor])
    let length = result.length
    for entity in note.entities {
        let range = NSRange(location: entity.range.lowerBound, length: entity.range.count)
        guard range.location + range.length <= length else {
            continue
        }
        switch entity.kind {
        case .bold, .italic:
            let trait: UIFontDescriptor.SymbolicTraits = entity.kind == .bold ? .traitBold : .traitItalic
            result.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let current = (value as? UIFont) ?? font
                if let descriptor = current.fontDescriptor.withSymbolicTraits(current.fontDescriptor.symbolicTraits.union(trait)) {
                    result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: current.pointSize), range: subrange)
                }
            }
        case .url:
            let url = (note.text as NSString).substring(with: range)
            result.addAttribute(.link, value: url.contains("://") ? url : "https://" + url, range: range)
        case let .textUrl(url):
            result.addAttribute(.link, value: url, range: range)
        }
        if case .bold = entity.kind {
        } else if case .italic = entity.kind {
        } else {
            result.addAttribute(.foregroundColor, value: linkColor, range: range)
            if underlineLinks {
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }
    return result
}
