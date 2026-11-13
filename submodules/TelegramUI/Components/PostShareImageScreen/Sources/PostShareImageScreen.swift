import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import ViewControllerComponent
import SheetComponent
import ButtonComponent
import GlassBarButtonComponent
import BundleIconComponent
import MultilineTextComponent
import LottieComponent
import WallpaperBackgroundNode
import InvisibleInkDustNode
import ChatMessageBubbleItemNode
import ChatMessageTextBubbleContentNode

/// What the screenshot editor starts from: the bubbles that were on screen, oldest first.
/// An album is one item of several messages.
public struct PostShareScreenshotContent {
    public let items: [[EngineMessage]]
    /// Called after the share sheet has sent the screenshots and the editor has closed: the chats they went to and
    /// how many screenshots there were.
    public let sent: (([EnginePeer.Id], Int) -> Void)?

    public init(items: [[EngineMessage]], sent: (([EnginePeer.Id], Int) -> Void)? = nil) {
        self.items = items
        self.sent = sent
    }
}

/// A look for the screenshot: the user's own chat look first, then Telegram's chat themes (the ones a chat can be
/// switched to), each with its bubble colours and its wallpaper.
private struct PostShareThemeOption {
    let id: String
    let theme: PresentationTheme
    let wallpaper: TelegramWallpaper
    /// The colours of the picker's circle.
    let previewColors: [UIColor]

    init(id: String, theme: PresentationTheme, wallpaper: TelegramWallpaper) {
        self.id = id
        self.theme = theme
        self.wallpaper = wallpaper

        var colors: [UInt32] = []
        switch wallpaper {
        case let .color(color):
            colors = [color]
        case let .gradient(gradient):
            colors = gradient.colors
        case let .file(file):
            colors = file.settings.colors
        default:
            break
        }
        if colors.isEmpty {
            self.previewColors = theme.chat.message.outgoing.bubble.withoutWallpaper.fill
        } else {
            self.previewColors = colors.map { UIColor(rgb: $0) }
        }
    }
}

/// The image as JPEG, scaled down (never up) so that its longer side is at most `maxPixelSide` pixels.
private func postShareJpegData(image: UIImage, maxPixelSide: CGFloat, quality: CGFloat) -> (Data, CGSize)? {
    let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    let factor = min(1.0, maxPixelSide / max(pixelSize.width, pixelSize.height))
    let targetSize = CGSize(width: floor(pixelSize.width * factor), height: floor(pixelSize.height * factor))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.opaque = true
    let scaledImage = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
        image.draw(in: CGRect(origin: CGPoint(), size: targetSize))
    }
    guard let data = scaledImage.jpegData(compressionQuality: quality) else {
        return nil
    }
    return (data, targetSize)
}

/// The footer's logo: the 19x15 artwork one point taller, at the same proportions.
private let postShareFooterLogoSize: CGSize = {
    let artwork = PostShareIcons.telegramLogoSize
    let height = artwork.height + 1.0
    return CGSize(width: artwork.width * height / artwork.height, height: height)
}()

private func postShareTelegramLogo(color: UIColor) -> UIImage {
    let size = postShareFooterLogoSize
    return UIGraphicsImageRenderer(size: size).image { rendererContext in
        PostShareIcons.drawTelegramLogo(in: rendererContext.cgContext, frame: CGRect(origin: CGPoint(), size: size), color: color)
    }
}

/// SF Pro Expanded Bold; plain bold before iOS 16.
private func postShareExpandedFont(size: CGFloat) -> UIFont {
    if #available(iOS 16.0, *) {
        return UIFont.systemFont(ofSize: size, weight: .bold, width: .expanded)
    } else {
        return UIFont.systemFont(ofSize: size, weight: .bold)
    }
}

/// The block with the captured messages, drawn by the chat's own bubble nodes on the chosen chat wallpaper, under
/// a "Today" date header, with the "Telegram" footer and fades at the edges. Inside the block is a canvas as wide
/// as the phone's screen, laid out like the chat itself (its text size, its wallpaper scale) and shown scaled down
/// to the block: the shared images are cut from that canvas unscaled, so they look like real screenshots.
/// A swipe to the left (the chat's reply swipe, with a crossed-out eye) removes a message; a text selection offers
/// "Cut from screenshot", which hides the fragment under a spoiler, or shows it again if it is already cut.
private final class PostShareMessagesView: UIView, UIScrollViewDelegate {
    private struct Entry {
        var messages: [EngineMessage]
        var isHidden: Bool
    }

    /// The block is this much taller than it is wide.
    static let extraHeight: CGFloat = 40.0
    private static let topPadding: CGFloat = 8.0
    private static let footerBottomInset: CGFloat = 12.0
    private static let footerHeight: CGFloat = 20.0
    private static let footerSideInset: CGFloat = 20.0
    private static let footerSpacing: CGFloat = 12.0
    private static let fadeHeight: CGFloat = 50.0
    /// The bottom fade reaches full strength once the content has scrolled this far from the bottom.
    private static let bottomFadeDistance: CGFloat = 24.0

    private static var bottomPadding: CGFloat {
        return PostShareMessagesView.footerBottomInset + PostShareMessagesView.footerHeight + PostShareMessagesView.footerSpacing
    }

    private let context: AccountContext
    private let presentationData: PresentationData
    private var themeOption: PostShareThemeOption
    /// Newest first, as the chat list orders its items: index 0 is the bottom bubble.
    private var entries: [Entry]
    /// Cut ranges per message, in UTF-16 offsets of `message.text`.
    private var cuts: [EngineMessage.Id: [Range<Int>]] = [:]
    /// Reaction icons resolve through this list; without it a bubble's reactions draw as empty pills.
    private var availableReactions: AvailableReactions?

    /// The screen-wide canvas everything is laid out in; the block shows it scaled down.
    private let canvasView = UIView()
    private var wallpaperNode: WallpaperBackgroundNode
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    /// Chat item nodes are built for the chat's upside-down list (each is turned by 180°); this container turns
    /// them back the same way the list does, so their own gestures (the reply swipe) move the right way.
    private let containerNode = ASDisplayNode()
    private var dateHeaderNode: ListViewItemHeaderNode?
    private var dateHeaderHeight: CGFloat = 0.0
    private var dateHeaderTimestamp: Int32?
    private let topFadeLayer = CAGradientLayer()
    private let bottomFadeLayer = CAGradientLayer()
    /// Rounds the block: 32 pt corners with 100% corner smoothing, as in the design.
    private let cornerMaskLayer = CAShapeLayer()
    private var cornerMaskSize: CGSize?
    private let footerTitleLabel = UILabel()
    private let footerLogoView = UIImageView()
    /// The view the text selection menu positions itself against.
    private let menuRootNode = ASDisplayNode()
    private var itemNodes: [ListViewItemNode] = []
    private var layoutWidth: CGFloat?

    var present: ((ViewController, Any?) -> Void)?
    /// Called when the split into screenshots may have changed: a message was removed, or the bubbles were laid
    /// out again.
    var screenshotsUpdated: (() -> Void)?

    init(context: AccountContext, content: PostShareScreenshotContent, themeOption: PostShareThemeOption) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.themeOption = themeOption
        self.entries = content.items.reversed().map { Entry(messages: $0, isHidden: false) }
        self.wallpaperNode = createWallpaperBackgroundNode(context: context, forChatDisplay: true)

        super.init(frame: CGRect())

        self.clipsToBounds = true
        self.layer.mask = self.cornerMaskLayer

        self.addSubview(self.canvasView)
        self.canvasView.addSubview(self.wallpaperNode.view)

        self.menuRootNode.isUserInteractionEnabled = false
        self.canvasView.addSubview(self.menuRootNode.view)

        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.alwaysBounceVertical = true
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.scrollView.delegate = self
        self.canvasView.addSubview(self.scrollView)
        self.scrollView.addSubview(self.contentView)

        self.containerNode.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
        self.contentView.addSubview(self.containerNode.view)

        self.topFadeLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        self.topFadeLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        self.canvasView.layer.addSublayer(self.topFadeLayer)
        self.bottomFadeLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        self.bottomFadeLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        self.bottomFadeLayer.opacity = 0.0
        self.topFadeLayer.opacity = 0.0
        self.canvasView.layer.addSublayer(self.bottomFadeLayer)

        self.footerTitleLabel.isUserInteractionEnabled = false
        self.canvasView.addSubview(self.footerTitleLabel)
        self.footerLogoView.isUserInteractionEnabled = false
        self.canvasView.addSubview(self.footerLogoView)

        self.applyThemeAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyThemeAppearance() {
        let theme = self.themeOption.theme
        self.wallpaperNode.update(wallpaper: self.themeOption.wallpaper, animated: false)
        self.wallpaperNode.updateBubbleTheme(bubbleTheme: theme, bubbleCorners: self.presentationData.chatBubbleCorners)

        // The footer takes the colour of the theme's incoming bubbles, the fades that of the user's own (outgoing)
        // ones, all as drawn over a wallpaper.
        let bubbleColor = theme.chat.message.incoming.bubble.withWallpaper.fill.first ?? .white
        let fadeColor = (theme.chat.message.outgoing.bubble.withWallpaper.fill.first ?? bubbleColor).withAlphaComponent(1.0)
        let fadeColors = [fadeColor.withAlphaComponent(0.6).cgColor, fadeColor.withAlphaComponent(0.0).cgColor]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.topFadeLayer.colors = fadeColors
        self.bottomFadeLayer.colors = fadeColors
        CATransaction.commit()

        let footerColor = bubbleColor
        self.footerTitleLabel.attributedText = NSAttributedString(string: "Telegram", attributes: [
            .font: postShareExpandedFont(size: 13.0),
            .kern: -0.6 as NSNumber,
            .foregroundColor: footerColor
        ])
        self.footerLogoView.image = postShareTelegramLogo(color: footerColor)
    }

    func updateThemeOption(_ themeOption: PostShareThemeOption) {
        guard self.themeOption.id != themeOption.id else {
            return
        }
        self.themeOption = themeOption

        // A fresh wallpaper node: one reused across themes kept the previous theme's gradient (bubble backdrops
        // and pattern) when switching between day and night.
        let previousWallpaperNode = self.wallpaperNode
        let wallpaperNode = createWallpaperBackgroundNode(context: self.context, forChatDisplay: true)
        wallpaperNode.frame = CGRect(origin: CGPoint(), size: PostShareMessagesView.wallpaperSize)
        wallpaperNode.updateLayout(size: PostShareMessagesView.wallpaperSize, displayMode: .aspectFill, transition: .immediate)
        self.canvasView.insertSubview(wallpaperNode.view, aboveSubview: previousWallpaperNode.view)
        previousWallpaperNode.view.removeFromSuperview()
        self.wallpaperNode = wallpaperNode

        // A text bubble's selection layer takes its colours once, when it is made: drop it, so the relayout's
        // `activateTextSelection()` makes it again in the new theme's selection colours.
        self.forEachTextContentNode { $0.updateIsExtractedToContextPreview(false) }

        self.applyThemeAppearance()
        self.relayoutItems()
    }

    func updateAvailableReactions(_ availableReactions: AvailableReactions?) {
        self.availableReactions = availableReactions
        self.relayoutItems()
    }

    private func relayoutItems() {
        guard let width = self.layoutWidth else {
            return
        }
        self.updateItemNodes(width: width)
        self.layoutContent(visibleIndices: nil, distanceFromBottom: self.currentDistanceFromBottom)
        self.screenshotsUpdated?()
    }

    // MARK: - Items

    /// The chat's own text size: the canvas is a screen, and the block's scaling makes the text a little smaller.
    private var fontSize: PresentationFontSize {
        return self.presentationData.chatFontSize
    }

    /// The longer side of the largest photo Telegram sends.
    fileprivate static let maxPhotoPixelSide: CGFloat = 2560.0

    /// The wallpaper is a portrait screen in size; the canvas, never taller, crops it from the top.
    fileprivate static var wallpaperSize: CGSize {
        return PostShareMessagesView.screenSize
    }

    /// The canvas is as wide as the screen in portrait, and an image is at most as tall as the screen.
    private static var screenSize: CGSize {
        let size = UIScreen.main.bounds.size
        return CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
    }

    private func applyingCuts(_ message: EngineMessage) -> EngineMessage {
        guard let ranges = self.cuts[message.id], !ranges.isEmpty else {
            return message
        }
        var entities: [MessageTextEntity] = []
        for attribute in message.attributes {
            if let attribute = attribute as? TextEntitiesMessageAttribute {
                entities = attribute.entities
            }
        }
        for range in ranges {
            entities.append(MessageTextEntity(range: range, type: .Spoiler))
        }
        var attributes = message.attributes.filter { !($0 is TextEntitiesMessageAttribute) }
        attributes.append(TextEntitiesMessageAttribute(entities: entities))
        return EngineMessage(message._asMessage().withUpdatedAttributes(attributes))
    }

    private func makeItems() -> [ListViewItem] {
        let presentationData = self.presentationData
        let fontSize = self.fontSize
        let hooks = ChatScreenshotMessageItemHooks(
            rootNode: { [weak self] in
                return self?.menuRootNode
            },
            present: { [weak self] controller, arguments in
                self?.present?(controller, arguments)
            },
            cutText: { [weak self] messageId, range in
                self?.cut(messageId: messageId, range: range)
            },
            toggleHidden: { [weak self] messageId in
                self?.hide(messageId: messageId)
            }
        )
        return self.entries.map { entry in
            return self.context.sharedContext.makeChatScreenshotMessageItem(
                context: self.context,
                messages: entry.messages.map(self.applyingCuts),
                theme: self.themeOption.theme,
                strings: presentationData.strings,
                wallpaper: self.themeOption.wallpaper,
                fontSize: fontSize,
                chatBubbleCorners: presentationData.chatBubbleCorners,
                dateTimeFormat: presentationData.dateTimeFormat,
                nameOrder: presentationData.nameDisplayOrder,
                // Gradient and wallpaper-tinted bubbles take their fill from the wallpaper node, as in the chat.
                backgroundNode: self.wallpaperNode,
                availableReactions: self.availableReactions,
                accountPeer: nil,
                hooks: hooks
            )
        }
    }

    private func updateItemNodes(width: CGFloat) {
        let items = self.makeItems()
        let params = ListViewItemLayoutParams(width: width, leftInset: 0.0, rightInset: 0.0, availableHeight: 1000.0)
        for i in 0 ..< items.count {
            let neighbors = ListViewItemNeighbors(previous: i == 0 ? nil : items[i - 1].neighborDescriptor, next: i == items.count - 1 ? nil : items[i + 1].neighborDescriptor)
            if i < self.itemNodes.count {
                let itemNode = self.itemNodes[i]
                items[i].updateNode(async: { $0() }, node: {
                    return itemNode
                }, params: params, neighbors: neighbors, animation: .None, completion: { layout, apply in
                    itemNode.contentSize = layout.contentSize
                    itemNode.insets = layout.insets
                    itemNode.frame = CGRect(origin: itemNode.frame.origin, size: CGSize(width: width, height: layout.size.height))
                    apply(ListViewItemApply())
                })
            } else {
                var createdNode: ListViewItemNode?
                items[i].nodeConfiguredForParams(async: { $0() }, params: params, synchronousLoads: true, neighbors: neighbors, completion: { node, apply in
                    createdNode = node
                    apply().1(ListViewItemApply())
                })
                if let itemNode = createdNode {
                    self.containerNode.addSubnode(itemNode)
                    self.itemNodes.append(itemNode)
                }
            }
        }
        self.updateDateHeader(timestamp: self.oldestTimestamp(indices: nil))
        self.activateTextSelection()
    }

    /// The timestamp of the oldest shown message, for the date header ("Today" for today's).
    private func oldestTimestamp(indices: [Int]?) -> Int32? {
        let candidates = indices ?? Array(self.entries.indices)
        var result: Int32?
        for index in candidates where index < self.entries.count && !self.entries[index].isHidden {
            for message in self.entries[index].messages {
                result = min(result ?? message.timestamp, message.timestamp)
            }
        }
        return result
    }

    /// The chat's date header ("Today"), above the oldest message.
    private func updateDateHeader(timestamp: Int32?) {
        guard let timestamp, let width = self.layoutWidth else {
            self.dateHeaderNode?.isHidden = true
            self.dateHeaderHeight = 0.0
            return
        }
        let presentationData = self.presentationData
        let headerItem = self.context.sharedContext.makeChatMessageDateHeaderItem(context: self.context, timestamp: timestamp, theme: self.themeOption.theme, strings: presentationData.strings, wallpaper: self.themeOption.wallpaper, fontSize: self.fontSize, chatBubbleCorners: presentationData.chatBubbleCorners, dateTimeFormat: presentationData.dateTimeFormat, nameOrder: presentationData.nameDisplayOrder)
        let headerNode: ListViewItemHeaderNode
        if let current = self.dateHeaderNode {
            headerNode = current
            headerItem.updateNode(headerNode, previous: nil, next: headerItem)
        } else {
            headerNode = headerItem.node(synchronousLoad: true)
            self.containerNode.addSubnode(headerNode)
            self.dateHeaderNode = headerNode
        }
        headerNode.isHidden = false
        self.dateHeaderTimestamp = timestamp
        self.dateHeaderHeight = headerItem.height
        headerNode.frame = CGRect(origin: headerNode.frame.origin, size: CGSize(width: width, height: headerItem.height))
        headerNode.updateLayout(size: headerNode.bounds.size, leftInset: 0.0, rightInset: 0.0, transition: .immediate)
    }

    /// Text bubbles create their selection layer only while "extracted" to a context preview, as in the chat's
    /// message menu; here it is on for good, so a long press on any text starts a selection.
    private func activateTextSelection() {
        self.forEachTextContentNode { $0.updateIsExtractedToContextPreview(true) }
    }

    private func forEachTextContentNode(_ f: (ChatMessageTextBubbleContentNode) -> Void) {
        for itemNode in self.itemNodes {
            guard let bubbleNode = itemNode as? ChatMessageBubbleItemNode else {
                continue
            }
            for contentNode in bubbleNode.contentNodes {
                if let textNode = contentNode as? ChatMessageTextBubbleContentNode {
                    f(textNode)
                }
            }
        }
    }

    // MARK: - Layout

    /// Stacks the bubbles bottom-up, then the date header, and returns the content height. With `visibleIndices`
    /// only those bubbles are laid out (one exported screenshot). Removed messages never are.
    private func layoutItemNodes(width: CGFloat, visibleIndices: Set<Int>?) -> CGFloat {
        var y = PostShareMessagesView.bottomPadding
        for (index, itemNode) in self.itemNodes.enumerated() {
            let isHidden = index >= self.entries.count || self.entries[index].isHidden
            if isHidden || (visibleIndices.flatMap { !$0.contains(index) } ?? false) {
                itemNode.isHidden = true
                continue
            }
            itemNode.isHidden = false
            itemNode.alpha = 1.0
            itemNode.frame = CGRect(origin: CGPoint(x: 0.0, y: y), size: CGSize(width: width, height: itemNode.frame.height))
            y += itemNode.frame.height
        }
        if let dateHeaderNode = self.dateHeaderNode, !dateHeaderNode.isHidden {
            dateHeaderNode.frame = CGRect(origin: CGPoint(x: 0.0, y: y), size: CGSize(width: width, height: self.dateHeaderHeight))
            y += self.dateHeaderHeight
        }
        y += PostShareMessagesView.topPadding

        let contentSize = CGSize(width: width, height: y)
        self.containerNode.bounds = CGRect(origin: CGPoint(), size: contentSize)
        self.containerNode.position = CGPoint(x: contentSize.width / 2.0, y: contentSize.height / 2.0)
        return y
    }

    private var currentDistanceFromBottom: CGFloat {
        return max(0.0, self.scrollView.contentSize.height - self.scrollView.contentOffset.y - self.scrollView.bounds.height)
    }

    /// Lays the messages out in the block; short content sits at the bottom, as in a chat. The bubbles end up
    /// `distanceFromBottom` above where they would rest at the bottom.
    private func layoutContent(visibleIndices: Set<Int>?, distanceFromBottom: CGFloat) {
        let size = self.canvasView.bounds.size
        let contentHeight = self.layoutItemNodes(width: size.width, visibleIndices: visibleIndices)
        let offset = max(0.0, size.height - contentHeight)
        self.contentView.frame = CGRect(origin: CGPoint(x: 0.0, y: offset), size: CGSize(width: size.width, height: contentHeight))
        let scrollHeight = max(size.height, contentHeight)
        self.scrollView.contentSize = CGSize(width: size.width, height: scrollHeight)
        self.scrollView.contentOffset = CGPoint(x: 0.0, y: max(0.0, scrollHeight - size.height - distanceFromBottom))
        self.updateAbsoluteRects()
        self.updateBottomFade()
    }

    /// Tells each bubble where it is over the wallpaper, so a gradient bubble draws its own slice of the gradient.
    /// Bubbles take the rect as the chat's upside-down list reports it: measured from the bottom of the wallpaper.
    private func updateAbsoluteRects() {
        let blockSize = PostShareMessagesView.wallpaperSize
        let contentHeight = self.containerNode.bounds.height
        let contentTop = self.contentView.frame.minY - self.scrollView.contentOffset.y
        for itemNode in self.itemNodes where !itemNode.isHidden {
            let frame = itemNode.frame
            let visualTop = contentTop + contentHeight - frame.maxY
            let rect = CGRect(x: frame.minX, y: blockSize.height - visualTop - frame.height, width: frame.width, height: frame.height)
            itemNode.updateAbsoluteRect(rect, within: blockSize)
        }
    }

    /// The fades show only where there are messages to fade: at the top once a message is cut off above, at the
    /// bottom once the messages scroll up under the footer.
    private func updateBottomFade() {
        let distanceFromTop = self.scrollView.contentOffset.y - self.contentView.frame.minY
        let topOpacity = Float(max(0.0, min(1.0, distanceFromTop / PostShareMessagesView.bottomFadeDistance)))
        let bottomOpacity = Float(min(1.0, self.currentDistanceFromBottom / PostShareMessagesView.bottomFadeDistance))
        if self.topFadeLayer.opacity != topOpacity || self.bottomFadeLayer.opacity != bottomOpacity {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.topFadeLayer.opacity = topOpacity
            self.bottomFadeLayer.opacity = bottomOpacity
            CATransaction.commit()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateAbsoluteRects()
        self.updateBottomFade()
    }

    /// Everything on the canvas but the bubbles: wallpaper, scroll area, fades and footer, for a canvas of `size`.
    private func layoutChrome(size: CGSize) {
        let bounds = CGRect(origin: CGPoint(), size: size)
        // The wallpaper is laid out once, at the screen's size from the canvas top, as behind a real chat; the
        // canvas only crops it. Resizing it for each exported image stretched its pattern and gradient: they
        // redraw asynchronously, so the capture got the previous size's drawing scaled to the new one.
        let wallpaperFrame = CGRect(origin: CGPoint(), size: PostShareMessagesView.wallpaperSize)
        if self.wallpaperNode.frame != wallpaperFrame {
            self.wallpaperNode.frame = wallpaperFrame
            self.wallpaperNode.updateLayout(size: wallpaperFrame.size, displayMode: .aspectFill, transition: .immediate)
        }
        self.menuRootNode.frame = bounds
        self.scrollView.frame = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.topFadeLayer.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: PostShareMessagesView.fadeHeight)
        self.bottomFadeLayer.frame = CGRect(x: 0.0, y: size.height - PostShareMessagesView.fadeHeight, width: size.width, height: PostShareMessagesView.fadeHeight)
        CATransaction.commit()

        let footerY = size.height - PostShareMessagesView.footerBottomInset - PostShareMessagesView.footerHeight
        let titleSize = self.footerTitleLabel.sizeThatFits(CGSize(width: size.width, height: PostShareMessagesView.footerHeight))
        self.footerTitleLabel.frame = CGRect(x: PostShareMessagesView.footerSideInset, y: footerY + floor((PostShareMessagesView.footerHeight - titleSize.height) / 2.0), width: titleSize.width, height: titleSize.height)
        let logoSize = postShareFooterLogoSize
        self.footerLogoView.frame = CGRect(x: size.width - PostShareMessagesView.footerSideInset - logoSize.width, y: footerY + floor((PostShareMessagesView.footerHeight - logoSize.height) / 2.0), width: logoSize.width, height: logoSize.height)
    }

    func update(size: CGSize) {
        if self.cornerMaskSize != size {
            self.cornerMaskSize = size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.cornerMaskLayer.frame = CGRect(origin: CGPoint(), size: size)
            self.cornerMaskLayer.path = postShareSmoothRoundedRectPath(size: size, cornerRadius: 32.0, smoothing: 1.0).cgPath
            CATransaction.commit()
        }

        // The canvas is screen-wide; the block scales it down to its own width.
        let canvasWidth = PostShareMessagesView.screenSize.width
        let scale = size.width / canvasWidth
        let canvasSize = CGSize(width: canvasWidth, height: floor(size.height / scale))
        self.canvasView.transform = .identity
        self.canvasView.bounds = CGRect(origin: CGPoint(), size: canvasSize)
        self.canvasView.center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
        self.canvasView.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.layoutChrome(size: canvasSize)

        if self.layoutWidth != canvasWidth {
            self.layoutWidth = canvasWidth
            self.updateItemNodes(width: canvasWidth)
            self.layoutContent(visibleIndices: nil, distanceFromBottom: 0.0)
            self.screenshotsUpdated?()
        } else {
            self.layoutContent(visibleIndices: nil, distanceFromBottom: self.currentDistanceFromBottom)
        }
    }

    // MARK: - Editing

    /// A swipe to the left (the chat's reply swipe) removes the bubble from the block and from the screenshots.
    private func hide(messageId: EngineMessage.Id) {
        guard let index = self.entries.firstIndex(where: { $0.messages.contains(where: { $0.id == messageId }) }), index < self.itemNodes.count, !self.entries[index].isHidden else {
            return
        }
        self.entries[index].isHidden = true
        let itemNode = self.itemNodes[index]
        let distanceFromBottom = self.currentDistanceFromBottom
        UIView.animate(withDuration: 0.2, animations: {
            itemNode.alpha = 0.0
        }, completion: { [weak self] _ in
            guard let self else {
                return
            }
            self.updateDateHeader(timestamp: self.oldestTimestamp(indices: nil))
            UIView.animate(withDuration: 0.25, animations: {
                self.layoutContent(visibleIndices: nil, distanceFromBottom: distanceFromBottom)
            })
            self.screenshotsUpdated?()
        })
    }

    /// Cuts the selected text out (a spoiler); cutting text that is already cut shows it again.
    private func cut(messageId: EngineMessage.Id, range: Range<Int>) {
        guard !range.isEmpty, self.layoutWidth != nil else {
            return
        }
        var ranges = self.cuts[messageId] ?? []
        if ranges.contains(where: { $0.overlaps(range) }) {
            ranges.removeAll(where: { $0.overlaps(range) })
        } else {
            ranges.append(range)
        }
        self.cuts[messageId] = ranges
        self.relayoutItems()
    }

    // MARK: - Export

    /// The messages that are left, oldest first, split into screenshots: each takes as many bubbles as fit on one
    /// screen between its date header and its footer. Entry indices; a bubble taller than the screen gets one of
    /// its own.
    func screenshotGroups() -> [[Int]] {
        let availableHeight = PostShareMessagesView.screenSize.height - PostShareMessagesView.bottomPadding - PostShareMessagesView.topPadding - self.dateHeaderHeight
        var groups: [[Int]] = []
        var current: [Int] = []
        var currentHeight: CGFloat = 0.0
        for index in (0 ..< min(self.entries.count, self.itemNodes.count)).reversed() where !self.entries[index].isHidden {
            let itemHeight = self.itemNodes[index].frame.height
            if !current.isEmpty && currentHeight + itemHeight > availableHeight {
                groups.append(current)
                current = []
                currentHeight = 0.0
            }
            current.append(index)
            currentHeight += itemHeight
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    /// The images to share, one per screenshot group, cut from the canvas unscaled at the screen's scale: as wide
    /// as the screen and as tall as their messages (at most the screen), without the fades and the rounded corners.
    func renderImages() -> [UIImage] {
        let groups = self.screenshotGroups()
        guard !groups.isEmpty, let width = self.layoutWidth else {
            return []
        }
        self.forEachTextContentNode { $0.cancelTextSelection() }

        // The canvas is laid out at each image's size while it is captured; a still copy of the window hides that.
        var coverView: UIView?
        if let window = self.window, let snapshotView = window.snapshotView(afterScreenUpdates: false) {
            window.addSubview(snapshotView)
            coverView = snapshotView
        }

        let canvasBounds = self.canvasView.bounds
        let canvasTransform = self.canvasView.transform
        let distanceFromBottom = self.currentDistanceFromBottom
        let headerTimestamp = self.dateHeaderTimestamp

        // The fades are bare layers: without disabling actions their hiding would animate, and the capture would
        // still see them.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.topFadeLayer.isHidden = true
        self.bottomFadeLayer.isHidden = true
        CATransaction.commit()
        self.layer.mask = nil
        self.clipsToBounds = false
        self.canvasView.transform = .identity
        defer {
            self.canvasView.bounds = canvasBounds
            self.canvasView.transform = canvasTransform
            self.layoutChrome(size: canvasBounds.size)
            self.layer.mask = self.cornerMaskLayer
            self.clipsToBounds = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.topFadeLayer.isHidden = false
            self.bottomFadeLayer.isHidden = false
            CATransaction.commit()
            self.updateDateHeader(timestamp: headerTimestamp)
            self.layoutContent(visibleIndices: nil, distanceFromBottom: distanceFromBottom)
            coverView?.removeFromSuperview()
        }

        var images: [UIImage] = []
        for group in groups {
            self.updateDateHeader(timestamp: self.oldestTimestamp(indices: group))
            let contentHeight = self.layoutItemNodes(width: width, visibleIndices: Set(group))
            let imageSize = CGSize(width: width, height: min(PostShareMessagesView.screenSize.height, ceil(contentHeight)))
            // Up to twice the screen's resolution, within the 2560 px a Telegram photo keeps on its longer side.
            let format = UIGraphicsImageRendererFormat()
            format.scale = max(UIScreen.main.scale, min(UIScreen.main.scale * 2.0, PostShareMessagesView.maxPhotoPixelSide / max(imageSize.width, imageSize.height)))
            format.opaque = true
            self.canvasView.bounds = CGRect(origin: CGPoint(), size: imageSize)
            self.layoutChrome(size: imageSize)
            self.layoutContent(visibleIndices: Set(group), distanceFromBottom: 0.0)
            let bounds = CGRect(origin: CGPoint(), size: imageSize)
            images.append(UIGraphicsImageRenderer(bounds: bounds, format: format).image { rendererContext in
                self.canvasView.drawHierarchy(in: bounds, afterScreenUpdates: true)
                self.drawSpoilerDust(in: rendererContext.cgContext)
            })
        }
        return images
    }

    /// Spoilers animate their dust with an emitter that a snapshot does not capture; draw it still on top.
    private func drawSpoilerDust(in context: CGContext) {
        var dustNodes: [InvisibleInkDustNode] = []
        func collect(_ view: UIView) {
            if view.isHidden || view.alpha <= 0.01 {
                return
            }
            if let dustNode = view.asyncdisplaykit_node as? InvisibleInkDustNode {
                dustNodes.append(dustNode)
                return
            }
            for subview in view.subviews {
                collect(subview)
            }
        }
        collect(self.contentView)

        for dustNode in dustNodes {
            // The chat's flips cancel out along the way, so a converted rect keeps the node's orientation.
            let frame = dustNode.view.convert(dustNode.view.bounds, to: self.canvasView)
            if !frame.intersects(self.canvasView.bounds) {
                continue
            }
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            dustNode.drawStaticDust(in: context)
            context.restoreGState()
        }
    }
}

private final class PostShareColorButton: UIControl {
    private let ringLayer = CAShapeLayer()
    private let gradientLayer = CAGradientLayer()
    var action: (() -> Void)?

    static let size = CGSize(width: 40.0, height: 40.0)

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.ringLayer.fillColor = UIColor.clear.cgColor
        self.ringLayer.lineWidth = 2.0
        self.gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        self.gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        self.gradientLayer.masksToBounds = true

        self.layer.addSublayer(self.gradientLayer)
        self.layer.addSublayer(self.ringLayer)

        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func pressed() {
        self.action?()
    }

    func update(colors: [UIColor], isSelected: Bool, accentColor: UIColor) {
        let size = PostShareColorButton.size
        self.ringLayer.frame = CGRect(origin: .zero, size: size)
        self.ringLayer.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1.0, dy: 1.0)).cgPath
        self.ringLayer.strokeColor = accentColor.cgColor
        self.ringLayer.isHidden = !isSelected

        let inset: CGFloat = isSelected ? 4.0 : 2.0
        let gradientFrame = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        self.gradientLayer.frame = gradientFrame
        self.gradientLayer.cornerRadius = gradientFrame.width / 2.0
        let cgColors = colors.map { $0.cgColor }
        self.gradientLayer.colors = cgColors.count == 1 ? [cgColors[0], cgColors[0]] : cgColors
    }
}

private final class PostShareSheetContentComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    let content: PostShareScreenshotContent
    let dismiss: () -> Void

    init(context: AccountContext, content: PostShareScreenshotContent, dismiss: @escaping () -> Void) {
        self.context = context
        self.content = content
        self.dismiss = dismiss
    }

    static func ==(lhs: PostShareSheetContentComponent, rhs: PostShareSheetContentComponent) -> Bool {
        return lhs.context === rhs.context
    }

    final class View: UIView {
        private let closeButton = ComponentView<Empty>()
        private let appearanceButton = ComponentView<Empty>()
        private let appearanceButtonPlayOnce = ActionSlot<Void>()
        private let title = ComponentView<Empty>()
        private var messagesView: PostShareMessagesView?
        private let colorsView = UIScrollView()
        private var colorButtons: [PostShareColorButton] = []
        private let separatorView = UIView()
        private let shareButton = ComponentView<Empty>()

        private var component: PostShareSheetContentComponent?
        private var environment: EnvironmentType?
        private weak var state: EmptyComponentState?

        private var themeOptions: [PostShareThemeOption] = []
        private var cloudThemes: [TelegramTheme] = []
        private var selectedThemeIndex: Int = 0
        /// Day or night variants of the themes, switched by the moon button; starts as the app's appearance.
        private var isDarkAppearance = false
        private var themesDisposable: Disposable?
        private var reactionsDisposable: Disposable?
        private var screenshotCount = 1
        private var screenshotMessageCount = 0
        /// True while `update` runs: cached themes arrive synchronously inside it, and requesting another update
        /// from there trips ComponentFlow's re-entrancy precondition.
        private var isUpdatingLayout = false

        override init(frame: CGRect) {
            super.init(frame: frame)

            self.colorsView.showsHorizontalScrollIndicator = false
            self.addSubview(self.colorsView)

            self.addSubview(self.separatorView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            self.themesDisposable?.dispose()
            self.reactionsDisposable?.dispose()
        }

        private func loadData(context: AccountContext) {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            self.isDarkAppearance = presentationData.theme.overallDarkAppearance
            self.rebuildThemeOptions(context: context)

            self.themesDisposable = (context.engine.themes.getChatThemes(accountManager: context.sharedContext.accountManager)
            |> take(1)
            |> deliverOnMainQueue).startStrict(next: { [weak self] themes in
                guard let self else {
                    return
                }
                self.cloudThemes = themes
                self.rebuildThemeOptions(context: context)
                if !self.isUpdatingLayout {
                    self.state?.updated(transition: .immediate)
                }
            })

            self.reactionsDisposable = (context.engine.stickers.availableReactions()
            |> take(1)
            |> deliverOnMainQueue).startStrict(next: { [weak self] availableReactions in
                self?.messagesView?.updateAvailableReactions(availableReactions)
            })
        }

        /// The user's own chat look, then the chat themes, all in the current day or night variant. In the
        /// variant opposite to the app's, the user's own look is the default theme of that variant.
        private func rebuildThemeOptions(context: AccountContext) {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let isDark = self.isDarkAppearance
            let variant = isDark ? "night" : "day"

            var options: [PostShareThemeOption] = []
            if presentationData.theme.overallDarkAppearance == isDark {
                options.append(PostShareThemeOption(id: "current-\(variant)", theme: presentationData.theme, wallpaper: presentationData.chatWallpaper))
            } else {
                let theme = isDark ? defaultDarkColorPresentationTheme : defaultPresentationTheme
                options.append(PostShareThemeOption(id: "current-\(variant)", theme: theme, wallpaper: theme.chat.defaultWallpaper))
            }
            for cloudTheme in self.cloudThemes {
                guard let theme = makePresentationTheme(cloudTheme: cloudTheme, dark: isDark) else {
                    continue
                }
                options.append(PostShareThemeOption(id: "\(cloudTheme.id)-\(variant)", theme: theme, wallpaper: theme.chat.defaultWallpaper))
            }
            self.themeOptions = options
            if self.selectedThemeIndex >= options.count {
                self.selectedThemeIndex = 0
            }
            self.messagesView?.updateThemeOption(options[self.selectedThemeIndex])
        }

        private func selectTheme(_ index: Int) {
            guard self.selectedThemeIndex != index, index < self.themeOptions.count else {
                return
            }
            self.selectedThemeIndex = index
            self.messagesView?.updateThemeOption(self.themeOptions[index])
            self.state?.updated(transition: .immediate)
        }

        private func toggleAppearance() {
            guard let component = self.component else {
                return
            }
            self.isDarkAppearance = !self.isDarkAppearance
            self.rebuildThemeOptions(context: component.context)
            self.state?.updated(transition: .immediate)
            Queue.mainQueue().justDispatch { [weak self] in
                self?.appearanceButtonPlayOnce.invoke(Void())
            }
        }

        private func updateScreenshotCounts() {
            guard let messagesView = self.messagesView else {
                return
            }
            let groups = messagesView.screenshotGroups()
            let count = max(1, groups.count)
            let messageCount = groups.reduce(0, { $0 + $1.count })
            if count != self.screenshotCount || messageCount != self.screenshotMessageCount {
                self.screenshotCount = count
                self.screenshotMessageCount = messageCount
                if !self.isUpdatingLayout {
                    self.state?.updated(transition: .immediate)
                }
            }
        }

        // MARK: - Actions

        /// Shares the screenshots through the system share sheet: one image, or several as an album.
        fileprivate func shareImages() {
            guard let component = self.component, let controller = self.environment?.controller(), let images = self.messagesView?.renderImages(), !images.isEmpty else {
                return
            }
            let dismiss = component.dismiss
            let activity = UIActivityViewController(activityItems: images, applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = controller.view
                popover.sourceRect = CGRect(origin: CGPoint(x: controller.view.bounds.midX, y: controller.view.bounds.midY), size: CGSize(width: 1.0, height: 1.0))
            }
            activity.completionWithItemsHandler = { _, _, _, _ in
                dismiss()
            }
            controller.present(activity, animated: true, completion: nil)
        }

        // MARK: - Layout

        func update(component: PostShareSheetContentComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            self.isUpdatingLayout = true
            defer {
                self.isUpdatingLayout = false
            }
            if self.component == nil {
                self.loadData(context: component.context)
            }
            self.component = component
            self.state = state
            let environment = environment[EnvironmentType.self].value
            self.environment = environment
            let theme = environment.theme

            let sideInset: CGFloat = 16.0
            var contentHeight: CGFloat = 16.0

            // Header
            let buttonSize = CGSize(width: 44.0, height: 44.0)
            let closeSize = self.closeButton.update(
                transition: .immediate,
                component: AnyComponent(GlassBarButtonComponent(
                    size: buttonSize,
                    backgroundColor: nil,
                    isDark: theme.overallDarkAppearance,
                    state: .glass,
                    component: AnyComponentWithIdentity(id: "close", component: AnyComponent(BundleIconComponent(
                        name: "Navigation/Close",
                        tintColor: theme.chat.inputPanel.panelControlColor
                    ))),
                    action: { [weak self] _ in
                        self?.component?.dismiss()
                    }
                )),
                environment: {},
                containerSize: buttonSize
            )
            if let view = self.closeButton.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                view.frame = CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: closeSize)
            }

            // Day / night variants of the themes, with the sun-and-moon icon of the chat theme screen.
            let appearanceSize = self.appearanceButton.update(
                transition: .immediate,
                component: AnyComponent(GlassBarButtonComponent(
                    size: buttonSize,
                    backgroundColor: nil,
                    isDark: theme.overallDarkAppearance,
                    state: .glass,
                    component: AnyComponentWithIdentity(id: self.isDarkAppearance ? "night" : "day", component: AnyComponent(LottieComponent(
                        content: LottieComponent.AppBundleContent(name: self.isDarkAppearance ? "anim_sun_reverse" : "anim_sun"),
                        color: theme.chat.inputPanel.panelControlColor,
                        startingPosition: .end,
                        size: CGSize(width: 28.0, height: 28.0),
                        playOnce: self.appearanceButtonPlayOnce,
                        lottieSettings: component.context.lottieRenderingSettings
                    ))),
                    action: { [weak self] _ in
                        self?.toggleAppearance()
                    }
                )),
                environment: {},
                containerSize: buttonSize
            )
            if let view = self.appearanceButton.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                view.frame = CGRect(origin: CGPoint(x: availableSize.width - sideInset - appearanceSize.width, y: contentHeight), size: appearanceSize)
            }
            let headerY = contentHeight
            contentHeight += 44.0 + 22.0

            // Messages
            let messagesView: PostShareMessagesView
            if let current = self.messagesView {
                messagesView = current
            } else {
                messagesView = PostShareMessagesView(context: component.context, content: component.content, themeOption: self.themeOptions[self.selectedThemeIndex])
                messagesView.present = { [weak self] controller, arguments in
                    self?.environment?.controller()?.presentInGlobalOverlay(controller, with: arguments)
                }
                messagesView.screenshotsUpdated = { [weak self] in
                    self?.updateScreenshotCounts()
                }
                self.messagesView = messagesView
                self.addSubview(messagesView)
            }
            let blockWidth = availableSize.width - sideInset * 2.0
            let blockSize = CGSize(width: blockWidth, height: blockWidth + PostShareMessagesView.extraHeight)
            messagesView.frame = CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: blockSize)
            messagesView.update(size: blockSize)
            contentHeight += blockSize.height + 20.0
            self.updateScreenshotCounts()

            // Title, with how the messages split into screenshots.
            let screenshotsText = self.screenshotCount == 1 ? "1 Screenshot" : "\(self.screenshotCount) Screenshots"
            let messagesText = self.screenshotMessageCount == 1 ? "1 message" : "\(self.screenshotMessageCount) messages"
            let titleString = NSMutableAttributedString(string: "Share it beautifully", font: Font.semibold(17.0), textColor: theme.list.itemPrimaryTextColor)
            titleString.append(NSAttributedString(string: "\n\(screenshotsText) with \(messagesText)", font: Font.regular(13.0), textColor: theme.list.itemSecondaryTextColor))
            let titleSize = self.title.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(
                    text: .plain(titleString),
                    horizontalAlignment: .center,
                    maximumNumberOfLines: 2
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - 120.0, height: 44.0)
            )
            if let view = self.title.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                view.frame = CGRect(origin: CGPoint(x: floor((availableSize.width - titleSize.width) / 2.0), y: headerY + floor((44.0 - titleSize.height) / 2.0)), size: titleSize)
            }

            // Themes
            while self.colorButtons.count < self.themeOptions.count {
                let index = self.colorButtons.count
                let button = PostShareColorButton()
                button.action = { [weak self] in
                    self?.selectTheme(index)
                }
                self.colorsView.addSubview(button)
                self.colorButtons.append(button)
            }
            let colorSpacing: CGFloat = 4.0
            let colorSize = PostShareColorButton.size
            self.colorsView.frame = CGRect(x: 0.0, y: contentHeight, width: availableSize.width, height: colorSize.height)
            for (index, button) in self.colorButtons.enumerated() {
                button.frame = CGRect(origin: CGPoint(x: sideInset - 2.0 + CGFloat(index) * (colorSize.width + colorSpacing), y: 0.0), size: colorSize)
                button.update(colors: self.themeOptions[index].previewColors, isSelected: index == self.selectedThemeIndex, accentColor: theme.list.itemAccentColor)
            }
            self.colorsView.contentSize = CGSize(width: sideInset * 2.0 - 4.0 + CGFloat(self.colorButtons.count) * (colorSize.width + colorSpacing) - colorSpacing, height: colorSize.height)
            contentHeight += colorSize.height + 16.0

            self.separatorView.backgroundColor = theme.list.itemPlainSeparatorColor
            self.separatorView.frame = CGRect(x: sideInset, y: contentHeight, width: availableSize.width - sideInset * 2.0, height: UIScreenPixel)
            contentHeight += 20.0

            // Share
            let buttonInsets = ContainerViewLayout.concentricInsets(bottomInset: environment.safeInsets.bottom, innerDiameter: 52.0, sideInset: 30.0)
            let shareSize = self.shareButton.update(
                transition: transition,
                component: AnyComponent(ButtonComponent(
                    background: ButtonComponent.Background(
                        style: .glass,
                        color: theme.list.itemCheckColors.fillColor,
                        foreground: theme.list.itemCheckColors.foregroundColor,
                        pressedColor: theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.8)
                    ),
                    content: AnyComponentWithIdentity(id: "share", component: AnyComponent(ButtonTextContentComponent(
                        text: self.screenshotCount == 1 ? "Share Screen" : "Share \(self.screenshotCount) Screens",
                        badge: 0,
                        textColor: theme.list.itemCheckColors.foregroundColor,
                        badgeBackground: theme.list.itemCheckColors.foregroundColor,
                        badgeForeground: theme.list.itemCheckColors.fillColor
                    ))),
                    isEnabled: self.screenshotMessageCount > 0,
                    displaysProgress: false,
                    action: { [weak self] in
                        self?.shareImages()
                    }
                )),
                environment: {},
                containerSize: CGSize(width: availableSize.width - buttonInsets.left - buttonInsets.right, height: 52.0)
            )
            if let view = self.shareButton.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: buttonInsets.left, y: contentHeight), size: shareSize))
            }
            contentHeight += shareSize.height + buttonInsets.bottom

            return CGSize(width: availableSize.width, height: contentHeight)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

private final class PostShareSheetComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    let content: PostShareScreenshotContent

    init(context: AccountContext, content: PostShareScreenshotContent) {
        self.context = context
        self.content = content
    }

    static func ==(lhs: PostShareSheetComponent, rhs: PostShareSheetComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        return true
    }

    final class View: UIView {
        private let sheet = ComponentView<(ViewControllerComponentContainer.Environment, SheetComponentEnvironment)>()
        private let sheetAnimateOut = ActionSlot<Action<Void>>()

        private var environment: EnvironmentType?

        override init(frame: CGRect) {
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func dismissAnimated() {
            guard let environment = self.environment else {
                return
            }
            self.sheetAnimateOut.invoke(Action { _ in
                environment.controller()?.dismiss(completion: nil)
            })
        }

        func update(component: PostShareSheetComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            let environment = environment[EnvironmentType.self].value
            self.environment = environment

            let sheetEnvironment = SheetComponentEnvironment(
                metrics: environment.metrics,
                deviceMetrics: environment.deviceMetrics,
                isDisplaying: environment.isVisible,
                isCentered: false,
                hasInputHeight: !environment.inputHeight.isZero,
                regularMetricsSize: CGSize(width: 430.0, height: 900.0),
                dismiss: { [weak self] _ in
                    self?.dismissAnimated()
                }
            )
            let _ = self.sheet.update(
                transition: transition,
                component: AnyComponent(SheetComponent(
                    content: AnyComponent(PostShareSheetContentComponent(
                        context: component.context,
                        content: component.content,
                        dismiss: { [weak self] in
                            self?.dismissAnimated()
                        }
                    )),
                    style: .glass,
                    backgroundColor: .color(environment.theme.actionSheet.opaqueItemBackgroundColor),
                    animateOut: self.sheetAnimateOut
                )),
                environment: {
                    environment
                    sheetEnvironment
                },
                containerSize: availableSize
            )
            if let sheetView = self.sheet.view {
                if sheetView.superview == nil {
                    self.addSubview(sheetView)
                }
                transition.setFrame(view: sheetView, frame: CGRect(origin: CGPoint(), size: availableSize))
            }

            return availableSize
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

/// "Share it beautifully": the screenshot editor. Dim messages, cut text, pick a background, share the image.
public final class PostShareImageScreen: ViewControllerComponentContainer {
    public init(context: AccountContext, content: PostShareScreenshotContent) {
        super.init(context: context, component: PostShareSheetComponent(
            context: context,
            content: content
        ), navigationBarAppearance: .none)

        self.statusBar.statusBarStyle = .Ignore
        self.navigationPresentation = .flatModal
        self.blocksBackgroundWhenInOverlay = true
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.view.disablesInteractiveModalDismiss = true
    }
}
