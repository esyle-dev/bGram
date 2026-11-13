import Foundation
import LottieSettings
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import AccountContext
import AvatarNode

public enum ChatListFilterSettingsHeaderAnimation {
    case folders
    case newFolder
    case discussionGroupSetup
    case autoRemove
    // Локальные концепты: исключения для канала без звука.
    case notifications
}

public class ChatListFilterSettingsHeaderItem: ListViewItem, ItemListItem {
    let context: AccountContext
    let theme: PresentationTheme
    let text: String
    let animation: ChatListFilterSettingsHeaderAnimation
    // Локальные концепты: чат, к которому относится экран, — маленькая аватарка в углу анимации.
    let cornerPeer: EnginePeer?
    // Локальные концепты: крупный заголовок под анимацией (как на экранах Telegram); при прокрутке уходит в навбар.
    let headline: String?
    public let sectionId: ItemListSectionId
    
    public init(context: AccountContext, theme: PresentationTheme, text: String, animation: ChatListFilterSettingsHeaderAnimation, cornerPeer: EnginePeer? = nil, headline: String? = nil, sectionId: ItemListSectionId) {
        self.headline = headline
        self.context = context
        self.theme = theme
        self.text = text
        self.animation = animation
        self.cornerPeer = cornerPeer
        self.sectionId = sectionId
    }
    
    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = ChatListFilterSettingsHeaderItemNode(lottieSettings: self.context.lottieRenderingSettings)
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }
    
    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? ChatListFilterSettingsHeaderItemNode else {
                assertionFailure()
                return
            }
            
            let makeLayout = nodeValue.asyncLayout()
            
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                Queue.mainQueue().async {
                    completion(layout, { _ in
                        apply()
                    })
                }
            }
        }
    }
}

private let titleFont = Font.regular(13.0)

class ChatListFilterSettingsHeaderItemNode: ListViewItemNode {
    private let titleNode: TextNode
    private let headlineNode: TextNode
    private let nameNode = TextNode()
    private var animationNode: AnimatedStickerNode
    private var avatarRingNode: ASDisplayNode?
    private var avatarNode: AvatarNode?
    
    private var item: ChatListFilterSettingsHeaderItem?
    
    private let lottieSettings: LottieRenderingSettings

    init(lottieSettings: LottieRenderingSettings) {
        self.lottieSettings = lottieSettings
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.contentMode = .left
        self.titleNode.contentsScale = UIScreen.main.scale
        
        self.headlineNode = TextNode()
        self.headlineNode.isUserInteractionEnabled = false
        self.headlineNode.contentsScale = UIScreen.main.scale
        
        self.animationNode = DefaultAnimatedStickerNodeImpl(lottieSettings: lottieSettings)
        
        super.init(layerBacked: false)
        
        self.addSubnode(self.headlineNode)
        self.nameNode.isUserInteractionEnabled = false
        self.nameNode.contentsScale = UIScreen.main.scale
        self.addSubnode(self.nameNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.animationNode)
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.animationNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.animationTapGesture(_:))))
    }
    
    @objc private func animationTapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            if !self.animationNode.isPlaying {
                self.animationNode.play(firstFrame: false, fromIndex: nil)
            }
        }
    }
    
    func asyncLayout() -> (_ item: ChatListFilterSettingsHeaderItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeHeadlineLayout = TextNode.asyncLayout(self.headlineNode)
        let makeNameLayout = TextNode.asyncLayout(self.nameNode)
        
        return { [weak self] item, params, neighbors in
            let isHidden = params.width > params.availableHeight && params.availableHeight < 400.0
            
            let animationName: String
            var size = 192
            var insetDifference = 100
            var additionalBottomInset: CGFloat = 0.0
            var playbackMode: AnimatedStickerPlaybackMode = .once
            switch item.animation {
            case .folders:
                animationName = "ChatListFolders"
            case .newFolder:
                animationName = "ChatListNewFolder"
            case .discussionGroupSetup:
                animationName = "DiscussionGroupSetup"
            case .autoRemove:
                animationName = "MessageAutoRemove"
                size = 260
                insetDifference = 120
                playbackMode = .once
                additionalBottomInset = isHidden ? 8.0 : 16.0
            case .notifications:
                // Локальные концепты: стикер из официального пака — колокольчик, без анимации (первый кадр).
                animationName = "ConceptsBellRing"
                playbackMode = .still(.start)
            }
            
            let topInset: CGFloat = CGFloat(size - insetDifference)
            
            // Локальные концепты: маленькая аватарка канала стоит в начале описания (перед названием), название — основным цветом.
            let attributedMutable: NSMutableAttributedString
            var channelName: String?
            var nameTail: String?
            if case let .channel(channel)? = item.cornerPeer {
                // Название канала и аватарка — отдельная центрированная строка над остальным текстом.
                channelName = channel.title
                var rest = item.text
                if let range = item.text.range(of: "«" + channel.title + "»") {
                    rest = String(item.text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                // Первая фраза («stays muted.») идёт в одну строку с названием канала, остальное — ниже.
                if let dot = rest.range(of: ". ") {
                    nameTail = String(rest[..<dot.lowerBound])
                    rest = String(rest[dot.upperBound...])
                }
                attributedMutable = NSMutableAttributedString(string: rest, font: titleFont, textColor: item.theme.list.freeTextColor)
            } else {
                attributedMutable = NSMutableAttributedString(string: item.text, font: titleFont, textColor: item.theme.list.freeTextColor)
            }
            let avatarSide: CGFloat = 14.0
            let avatarGap: CGFloat = 4.0
            let nameAttributed = NSMutableAttributedString(string: channelName ?? "", font: Font.semibold(14.0), textColor: item.theme.list.itemPrimaryTextColor)
            if let nameTail {
                nameAttributed.append(NSAttributedString(string: " " + nameTail, font: Font.regular(14.0), textColor: item.theme.list.itemPrimaryTextColor))
            }
            let (nameLayout, nameApply) = makeNameLayout(TextNodeLayoutArguments(attributedString: nameAttributed, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: params.width - params.leftInset - params.rightInset - 96.0, height: 40.0), alignment: .left, cutout: nil, insets: UIEdgeInsets()))
            let nameSpace: CGFloat = channelName == nil ? 0.0 : 22.0
            let attributedText: NSAttributedString = attributedMutable
            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: attributedText, backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: params.width - params.leftInset - params.rightInset - min(params.leftInset, params.rightInset) - 64.0, height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))
            
            let (headlineLayout, headlineApply) = makeHeadlineLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.headline ?? "", font: Font.bold(26.0), textColor: item.theme.list.itemPrimaryTextColor), backgroundColor: nil, maximumNumberOfLines: 2, truncationType: .end, constrainedSize: CGSize(width: params.width - params.leftInset - params.rightInset - 48.0, height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets()))
            let headlineSpace: CGFloat = item.headline == nil ? 0.0 : headlineLayout.size.height + 8.0
            
            let contentSize = CGSize(width: params.width, height: topInset + headlineSpace + nameSpace + titleLayout.size.height)
            var insets = itemListNeighborsGroupedInsets(neighbors, params)
            
            if isHidden {
                insets = UIEdgeInsets()
            }
            insets.bottom += additionalBottomInset
            
            let layout = ListViewItemNodeLayout(contentSize: isHidden ? CGSize(width: params.width, height: 0.0) : contentSize, insets: insets)
            
            return (layout, { [weak self] in
                if let strongSelf = self {
                    if strongSelf.item == nil {
                        strongSelf.animationNode.setup(source: AnimatedStickerNodeLocalFileSource(name: animationName), width: size, height: size, playbackMode: playbackMode, mode: .direct(cachePathPrefix: nil))
                        if case .notifications = item.animation {
                            // Колокольчик на экране исключений — статичный первый кадр, без воспроизведения.
                        } else {
                            strongSelf.animationNode.visibility = true
                        }

                    }
                    
                    strongSelf.item = item
                    strongSelf.accessibilityLabel = attributedText.string
                                        
                    let iconSize = CGSize(width: CGFloat(size) / 2.0, height: CGFloat(size) / 2.0)
                    strongSelf.animationNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - iconSize.width) / 2.0), y: -10.0), size: iconSize)
                    strongSelf.animationNode.updateLayout(size: iconSize)
                    
                    let _ = titleApply()
                    let _ = headlineApply()
                    strongSelf.headlineNode.frame = CGRect(origin: CGPoint(x: params.leftInset + floor((layout.size.width - params.leftInset - params.rightInset - headlineLayout.size.width) / 2.0), y: topInset + 8.0), size: headlineLayout.size)
                    strongSelf.headlineNode.alpha = isHidden || item.headline == nil ? 0.0 : 1.0
                    strongSelf.titleNode.frame = CGRect(origin: CGPoint(x: params.leftInset + floor((layout.size.width - params.leftInset - params.rightInset - titleLayout.size.width) / 2.0), y: topInset + 8.0 + headlineSpace + nameSpace), size: titleLayout.size)
                    if let cornerPeer = item.cornerPeer {
                        let avatarNode: AvatarNode
                        if let current = strongSelf.avatarNode {
                            avatarNode = current
                        } else {
                            avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 8.0))
                            strongSelf.addSubnode(avatarNode)
                            strongSelf.avatarNode = avatarNode
                        }
                        avatarNode.setPeer(context: item.context, theme: item.theme, peer: cornerPeer, displayDimensions: CGSize(width: avatarSide, height: avatarSide))
                        let _ = nameApply()
                        let groupWidth = avatarSide + avatarGap + nameLayout.size.width
                        let areaWidth = layout.size.width - params.leftInset - params.rightInset
                        let groupX = params.leftInset + floor((areaWidth - groupWidth) / 2.0)
                        let rowY = topInset + 8.0 + headlineSpace
                        let nameFrame = CGRect(origin: CGPoint(x: groupX + avatarSide + avatarGap, y: rowY + floor((nameSpace - 4.0 - nameLayout.size.height) / 2.0)), size: nameLayout.size)
                        strongSelf.nameNode.frame = nameFrame
                        // Аватарка по центру высоты строки названия.
                        avatarNode.frame = CGRect(origin: CGPoint(x: groupX, y: floorToScreenPixels(nameFrame.midY - avatarSide / 2.0)), size: CGSize(width: avatarSide, height: avatarSide))
                        strongSelf.nameNode.alpha = isHidden ? 0.0 : 1.0
                        avatarNode.alpha = isHidden ? 0.0 : 1.0
                    }
                    
                    strongSelf.animationNode.alpha = isHidden ? 0.0 : 1.0
                    strongSelf.titleNode.alpha = isHidden ? 0.0 : 1.0
                }
            })
        }
    }
    
    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }
    
    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
