import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import ChatPresentationInterfaceState
import TelegramPresentationData
import AppBundle
import ChatInputPanelNode
import GlassBackgroundComponent
import ComponentFlow
import ComponentDisplayAdapters
import LottieComponent

/// Three pictures that lie on one another, each a little to the right of and under the one before. Each has a gap round it where it lies
/// on another one, which is cut out of that one, so the gap is the colour of what is behind the whole collage.
///
/// It starts level, every picture at the same height in the middle of the block, and half a second later settles into the staggered arrangement.
private final class AlbumEditCollageView: UIView {
    private final class DisplayLinkTarget {
        var action: (() -> Void)?
        @objc func fire() {
            self.action?()
        }
    }
    
    private static let settleDelay: Double = 0.5
    private static let settleDuration: Double = 0.4
    
    private var imageViews: [UIImageView] = []
    private var images: [UIImage] = []
    /// 0 is level, 1 is the final arrangement.
    private var spread: CGFloat = 0.0
    private var didScheduleSettle = false
    private var displayLink: CADisplayLink?
    private var settleStartTime: CFTimeInterval = 0.0
    
    deinit {
        self.displayLink?.invalidate()
    }
    
    func update(images: [UIImage]) {
        self.images = images
        self.layoutImages()
        
        if !self.didScheduleSettle && min(3, images.count) > 1 {
            self.didScheduleSettle = true
            DispatchQueue.main.asyncAfter(deadline: .now() + AlbumEditCollageView.settleDelay) { [weak self] in
                self?.startSettling()
            }
        }
    }
    
    private func startSettling() {
        let target = DisplayLinkTarget()
        target.action = { [weak self] in
            self?.settleStep()
        }
        let displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.fire))
        self.settleStartTime = CACurrentMediaTime()
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }
    
    private func settleStep() {
        let progress = min(1.0, (CACurrentMediaTime() - self.settleStartTime) / AlbumEditCollageView.settleDuration)
        // Ease in and out.
        self.spread = CGFloat(progress * progress * (3.0 - 2.0 * progress))
        self.layoutImages()
        if progress >= 1.0 {
            self.displayLink?.invalidate()
            self.displayLink = nil
        }
    }
    
    private func layoutImages() {
        let images = self.images
        let count = min(3, images.count)
        while self.imageViews.count < count {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 8.0
            imageView.layer.cornerCurve = .continuous
            self.addSubview(imageView)
            self.imageViews.append(imageView)
        }
        while self.imageViews.count > count {
            self.imageViews.removeLast().removeFromSuperview()
        }
        
        let side: CGFloat = 28.0
        let gap: CGFloat = 1.2
        // Level, the pictures lie at the middle of the final arrangement (y = 4); the first one then rises and the last one sinks.
        let offsets: [CGPoint] = [CGPoint(x: 0.0, y: 4.0 - 4.0 * self.spread), CGPoint(x: 6.0, y: 4.0), CGPoint(x: 12.0, y: 4.0 + 4.0 * self.spread)]
        for index in 0 ..< count {
            let imageView = self.imageViews[index]
            imageView.image = images[index]
            imageView.frame = CGRect(origin: offsets[index], size: CGSize(width: side, height: side))
            
            // The gaps are cut out with the same smoothed corners (continuous) the pictures have: a path with circular corners would not
            // fit them. The corners are drawn by a layer, which is the one that knows that curve.
            if index + 1 < count {
                let bounds = imageView.bounds
                let renderer = UIGraphicsImageRenderer(size: bounds.size)
                let maskImage = renderer.image { rendererContext in
                    let context = rendererContext.cgContext
                    context.setFillColor(UIColor.black.cgColor)
                    context.fill(bounds)
                    context.setBlendMode(.destinationOut)
                    for front in (index + 1) ..< count {
                        let frontRect = CGRect(origin: CGPoint(x: offsets[front].x - offsets[index].x, y: offsets[front].y - offsets[index].y), size: CGSize(width: side, height: side)).insetBy(dx: -gap, dy: -gap)
                        let cutout = CALayer()
                        cutout.frame = CGRect(origin: CGPoint(), size: frontRect.size)
                        cutout.backgroundColor = UIColor.black.cgColor
                        cutout.cornerRadius = 8.0 + gap
                        cutout.cornerCurve = .continuous
                        context.saveGState()
                        context.translateBy(x: frontRect.minX, y: frontRect.minY)
                        cutout.render(in: context)
                        context.restoreGState()
                    }
                }
                let mask = CALayer()
                mask.frame = bounds
                mask.contents = maskImage.cgImage
                mask.contentsScale = maskImage.scale
                imageView.layer.mask = mask
            } else {
                imageView.layer.mask = nil
            }
        }
    }
}

/// The panel in the place of the input panel while the window that edits an album is folded away and there is something to save: the album
/// (its first pictures and how many changes there are), its text, a button to throw the changes away and one to save them.
final class AlbumEditInputPanelNode: ChatInputPanelNode, UITextViewDelegate {
    private var session: AlbumEditSession
    private var presentationInterfaceState: ChatPresentationInterfaceState?
    
    private let closeBackground = GlassBackgroundView(frame: CGRect())
    private let closeIcon = UIImageView()
    private let closeButton = HighlightTrackingButton()
    
    private let cardBackground = GlassBackgroundView(frame: CGRect())
    private let lineView = UIImageView()
    private let collageView = AlbumEditCollageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevronView = UIImageView()
    private let headerButton = HighlightTrackingButton()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let emojiView = ComponentHostView<Empty>()
    private let applyBackground = UIView()
    private let applyIcon = UIImageView()
    private let applyButton = HighlightTrackingButton()
    
    init(session: AlbumEditSession) {
        self.session = session
        
        super.init()
        
        self.closeIcon.contentMode = .center
        self.closeBackground.contentView.addSubview(self.closeIcon)
        self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        self.view.addSubview(self.closeBackground)
        
        self.view.addSubview(self.cardBackground)
        self.lineView.image = generateImage(CGSize(width: 2.0, height: 3.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(UIColor.black.cgColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: 1.0).cgPath)
            context.fillPath()
        })?.withRenderingMode(.alwaysTemplate).stretchableImage(withLeftCapWidth: 0, topCapHeight: 1)
        self.cardBackground.contentView.addSubview(self.lineView)
        self.cardBackground.contentView.addSubview(self.collageView)
        self.titleLabel.font = Font.medium(15.0)
        self.cardBackground.contentView.addSubview(self.titleLabel)
        self.subtitleLabel.font = Font.regular(14.0)
        self.cardBackground.contentView.addSubview(self.subtitleLabel)
        self.chevronView.contentMode = .center
        self.cardBackground.contentView.addSubview(self.chevronView)
        self.headerButton.addTarget(self, action: #selector(self.headerPressed), for: .touchUpInside)
        
        self.textView.backgroundColor = .clear
        self.textView.textContainerInset = .zero
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.isScrollEnabled = false
        self.textView.font = Font.regular(17.0)
        self.textView.delegate = self
        self.textView.attributedText = AlbumEditInputPanelNode.styledCaption(session.caption)
        self.cardBackground.contentView.addSubview(self.textView)
        self.placeholderLabel.font = Font.regular(17.0)
        self.placeholderLabel.isUserInteractionEnabled = false
        self.cardBackground.contentView.addSubview(self.placeholderLabel)
        
        self.emojiView.isUserInteractionEnabled = false
        self.cardBackground.contentView.addSubview(self.emojiView)
        self.applyIcon.contentMode = .center
        self.applyBackground.addSubview(self.applyIcon)
        self.applyButton.addTarget(self, action: #selector(self.applyPressed), for: .touchUpInside)
        self.cardBackground.contentView.addSubview(self.applyBackground)
        // The buttons are over the glass, in the panel itself: the glass takes no touches that start in it.
        self.view.addSubview(self.closeButton)
        self.view.addSubview(self.headerButton)
        self.view.addSubview(self.applyButton)
        
        session.changed = { [weak self] in
            self?.updateTexts()
        }
    }
    
    func updateSession(_ session: AlbumEditSession) {
        if self.session !== session {
            self.session = session
            self.textView.attributedText = AlbumEditInputPanelNode.styledCaption(session.caption)
            session.changed = { [weak self] in
                self?.updateTexts()
            }
        }
    }
    
    /// The text of the album as it is typed: 17 pt, with a line of 22 pt.
    private static func styledCaption(_ caption: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: caption)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 20.0
        style.maximumLineHeight = 20.0
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttribute(.paragraphStyle, value: style, range: fullRange)
        result.enumerateAttribute(.font, in: fullRange, options: [], using: { value, range, _ in
            if value == nil {
                result.addAttribute(.font, value: Font.regular(17.0), range: range)
            }
        })
        return result
    }
    
    @objc private func closePressed() {
        self.textView.resignFirstResponder()
        self.session.discardRequested?()
    }
    
    @objc private func headerPressed() {
        self.textView.resignFirstResponder()
        self.session.openRequested?()
    }
    
    @objc private func applyPressed() {
        self.textView.resignFirstResponder()
        self.session.applyRequested?()
    }
    
    func textViewDidChange(_ textView: UITextView) {
        self.session.caption = textView.attributedText ?? NSAttributedString()
        self.placeholderLabel.alpha = textView.text.isEmpty ? 1.0 : 0.0
        self.updateTexts()
    }
    
    /// The text typed in the window that was folded away is the text of the field. What is typed in the field itself is already in the session.
    private func syncCaptionFromSession() {
        if !self.textView.isFirstResponder && self.textView.attributedText?.string != self.session.caption.string {
            self.textView.attributedText = AlbumEditInputPanelNode.styledCaption(self.session.caption)
        }
        self.placeholderLabel.alpha = self.textView.text.isEmpty ? 1.0 : 0.0
    }
    
    /// The line under the name: how many changes there are.
    private func updateTexts() {
        guard let interfaceState = self.presentationInterfaceState else {
            return
        }
        self.titleLabel.text = interfaceState.strings.Conversation_ContextMenuEditAlbum
        self.subtitleLabel.text = interfaceState.strings.Conversation_AlbumEdit_UnsavedChanges(Int32(self.session.changeCount))
    }
    
    override func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, additionalSideInsets: UIEdgeInsets, maxHeight: CGFloat, maxOverlayHeight: CGFloat, isSecondary: Bool, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState, metrics: LayoutMetrics, deviceMetrics: DeviceMetrics, isMediaInputExpanded: Bool) -> CGFloat {
        self.presentationInterfaceState = interfaceState
        let theme = interfaceState.theme
        let isDark = theme.overallDarkAppearance
        
        // The margins of the input of the chat: 8 pt from the sides of the screen, and 18 pt more when the panel is over the rounded corners
        // of the screen (there is no home indicator under it, which is when the keyboard is up).
        let sideInset: CGFloat = 8.0
        let compactSideInset = self.compactBottomSideInset(bottomInset: bottomInset, deviceMetrics: deviceMetrics)
        let leftInset = leftInset + compactSideInset
        let rightInset = rightInset + compactSideInset
        let buttonSize: CGFloat = 40.0
        
        self.titleLabel.textColor = theme.chat.inputPanel.panelControlAccentColor
        self.subtitleLabel.textColor = theme.chat.inputPanel.inputPlaceholderColor
        self.placeholderLabel.text = interfaceState.strings.MediaPicker_AddCaption
        self.placeholderLabel.textColor = theme.chat.inputPanel.inputPlaceholderColor
        self.textView.textColor = theme.chat.inputPanel.inputTextColor
        let typingStyle = NSMutableParagraphStyle()
        typingStyle.minimumLineHeight = 20.0
        typingStyle.maximumLineHeight = 20.0
        self.textView.typingAttributes = [
            .font: Font.regular(17.0),
            .foregroundColor: theme.chat.inputPanel.inputTextColor,
            .paragraphStyle: typingStyle
        ]
        self.syncCaptionFromSession()
        self.placeholderLabel.alpha = self.textView.text.isEmpty ? 1.0 : 0.0
        self.updateTexts()
        self.collageView.update(images: self.session.collageImages)
        
        // The card is the one of the input with a reply: 8 pt from the sides of the screen, a header of 52 pt (where the reply has its line, here
        // the first pictures of the album), and under it the row of the text, 40 pt when it is of one line, with the corners of the input.
        let cardX = leftInset + sideInset + buttonSize + 6.0
        let cardWidth = max(0.0, width - rightInset - sideInset - cardX)
        let headerHeight: CGFloat = 52.0
        let minimalRowHeight: CGFloat = 40.0
        // The button that saves is as big as the send button of the input: 44 by 36. Before it, the icon of the emoji, as big as the icon of
        // the stickers of the input (32 by 32).
        let applySize = CGSize(width: 40.0, height: 34.0)
        let emojiSize = CGSize(width: 32.0, height: 32.0)
        let textWidth = max(0.0, cardWidth - 12.0 - 11.0 - emojiSize.width - 4.0 - applySize.width - 3.0)
        let textHeight = ceil(min(110.0, max(20.0, self.textView.sizeThatFits(CGSize(width: textWidth, height: 10000.0)).height)))
        // As in the input of the chat: the field is 31 pt at least, its text is at its top (5 pt under the header, the lines of 20 pt), and
        // the row is the field and 9 pt.
        let fieldHeight = max(31.0, textHeight + 11.0)
        let rowHeight = max(minimalRowHeight, fieldHeight + 9.0)
        let cardHeight = headerHeight + rowHeight
        let cardFrame = CGRect(origin: CGPoint(x: cardX, y: 0.0), size: CGSize(width: cardWidth, height: cardHeight))
        
        transition.updateFrame(view: self.cardBackground, frame: cardFrame)
        self.cardBackground.update(size: cardFrame.size, cornerRadius: floor(minimalRowHeight * 0.5), isDark: isDark, tintColor: .init(kind: .panel), isInteractive: false, transition: ComponentTransition(transition))
        
        // As in the reply: the title is at 10 pt, the line under it 1 pt below, both 14 pt.
        // The line of the reply: 2 pt wide, 12 pt from the left, 8 pt from the top and 6 pt from the bottom of the header. The pictures
        // are 8 pt from it.
        let lineFrame = CGRect(x: 12.0, y: 8.0, width: 2.0, height: headerHeight - 8.0 - 6.0)
        self.lineView.frame = lineFrame
        self.lineView.tintColor = theme.chat.inputPanel.panelControlAccentColor
        self.collageView.frame = CGRect(origin: CGPoint(x: lineFrame.maxX + 8.0, y: 9.0), size: CGSize(width: 40.0, height: 36.0))
        let textX: CGFloat = self.collageView.frame.maxX + 8.0
        self.titleLabel.frame = CGRect(x: textX, y: 9.0, width: max(0.0, cardWidth - textX - 44.0), height: 18.0)
        self.subtitleLabel.frame = CGRect(x: textX, y: 28.0, width: max(0.0, cardWidth - textX - 44.0), height: 17.0)
        self.chevronView.image = generateImage(CGSize(width: 16.0, height: 10.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setStrokeColor(theme.chat.inputPanel.inputPlaceholderColor.cgColor)
            context.setLineWidth(2.0)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: 2.0, y: size.height - 2.0))
            context.addLine(to: CGPoint(x: size.width * 0.5, y: 2.0))
            context.addLine(to: CGPoint(x: size.width - 2.0, y: size.height - 2.0))
            context.strokePath()
        })
        // Where the close button of the reply is: 44 by 44 at the right edge.
        self.chevronView.frame = CGRect(x: cardWidth - 44.0 + 10.0, y: floor((headerHeight - 24.0) * 0.5), width: 24.0, height: 24.0)
        self.headerButton.frame = CGRect(x: cardFrame.minX, y: 0.0, width: cardWidth, height: headerHeight)
        
        let textFrame = CGRect(x: 12.0, y: headerHeight + 5.0, width: textWidth, height: textHeight)
        self.textView.frame = textFrame
        self.placeholderLabel.frame = CGRect(x: textFrame.minX, y: textFrame.minY + UIScreenPixel, width: textWidth, height: 20.0)
        
        let applyFrame = CGRect(origin: CGPoint(x: cardWidth - 3.0 - applySize.width, y: cardHeight - 3.0 - applySize.height), size: applySize)
        self.applyBackground.frame = applyFrame
        self.applyBackground.backgroundColor = theme.chat.inputPanel.panelControlAccentColor
        self.applyBackground.layer.cornerRadius = applySize.height * 0.5
        let _ = self.emojiView.update(
            transition: .immediate,
            component: AnyComponent(LottieComponent(
                content: LottieComponent.AppBundleContent(name: "input_anim_smileToKey"),
                color: theme.chat.inputPanel.inputControlColor,
                startingPosition: .begin,
                loop: false,
                lottieSettings: self.context?.lottieRenderingSettings ?? .noAccountFallback
            )),
            environment: {},
            containerSize: emojiSize
        )
        self.emojiView.frame = CGRect(origin: CGPoint(x: applyFrame.minX - 4.0 - emojiSize.width, y: headerHeight + rowHeight - minimalRowHeight + floor((minimalRowHeight - emojiSize.height) * 0.5)), size: emojiSize)
        self.applyIcon.image = UIImage(bundleImageName: "Navigation/Done")?.withRenderingMode(.alwaysTemplate)
        self.applyIcon.tintColor = theme.chat.inputPanel.actionControlForegroundColor
        self.applyIcon.frame = CGRect(origin: CGPoint(), size: applyFrame.size)
        self.applyButton.frame = applyFrame.offsetBy(dx: cardFrame.minX, dy: 0.0)
        
        // The button that throws the changes away, at the bottom of the card's left.
        let closeFrame = CGRect(x: leftInset + sideInset, y: cardHeight - buttonSize, width: buttonSize, height: buttonSize)
        transition.updateFrame(view: self.closeBackground, frame: closeFrame)
        self.closeBackground.update(size: closeFrame.size, cornerRadius: buttonSize * 0.5, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: ComponentTransition(transition))
        self.closeIcon.image = UIImage(bundleImageName: "Navigation/Close")?.withRenderingMode(.alwaysTemplate)
        self.closeIcon.tintColor = theme.chat.inputPanel.panelControlColor
        // The picture is 30 pt as it is made, and is shown 28 pt, in the middle of the button.
        self.closeIcon.contentMode = .scaleAspectFit
        let closeIconSide: CGFloat = 28.0
        self.closeIcon.frame = CGRect(x: floor((closeFrame.width - closeIconSide) * 0.5), y: floor((closeFrame.height - closeIconSide) * 0.5), width: closeIconSide, height: closeIconSide)
        self.closeButton.frame = closeFrame
        
        return cardHeight
    }
    
    override func minimalHeight(interfaceState: ChatPresentationInterfaceState, metrics: LayoutMetrics) -> CGFloat {
        return 92.0
    }
    
    override func defaultHeight(metrics: LayoutMetrics) -> CGFloat {
        return 92.0
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if result === self.view {
            return nil
        }
        return result
    }
}
