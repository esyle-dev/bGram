import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import CheckNode

/// A selectable row laid out like the category rows of the story privacy screen: a check on the
/// left, a round gradient icon, a semibold title and a one-line subtitle under it. An accent
/// subtitle is followed by a small arrow.
final class SharedMessageAccessItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let icon: UIImage?
    let title: String
    let subtitle: String
    let subtitleIsAccent: Bool
    let checked: Bool
    let sectionId: ItemListSectionId
    let action: () -> Void

    let tag: ItemListItemTag? = nil

    init(presentationData: ItemListPresentationData, icon: UIImage?, title: String, subtitle: String, subtitleIsAccent: Bool, checked: Bool, sectionId: ItemListSectionId, action: @escaping () -> Void) {
        self.presentationData = presentationData
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsAccent = subtitleIsAccent
        self.checked = checked
        self.sectionId = sectionId
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = SharedMessageAccessItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply(false) })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? SharedMessageAccessItemNode {
                let makeLayout = nodeValue.asyncLayout()

                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply(animation.isAnimated)
                        })
                    }
                }
            }
        }
    }

    var selectable: Bool = true

    func selected(listView: ListView) {
        listView.clearHighlightAnimated(true)
        self.action()
    }
}

final class SharedMessageAccessItemNode: ListViewItemNode, ItemListItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let highlightedBackgroundNode: ASDisplayNode
    private let maskNode: ASImageNode

    private let iconNode: ASImageNode
    private let arrowNode: ASImageNode
    private let titleNode: TextNode
    private let subtitleNode: TextNode
    private var checkLayer: CheckLayer?

    private let activateArea: AccessibilityAreaNode

    private var item: SharedMessageAccessItem?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true

        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true

        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true

        self.highlightedBackgroundNode = ASDisplayNode()
        self.highlightedBackgroundNode.isLayerBacked = true

        self.maskNode = ASImageNode()
        self.maskNode.isUserInteractionEnabled = false

        self.iconNode = ASImageNode()
        self.iconNode.isLayerBacked = true
        self.iconNode.displayWithoutProcessing = true
        self.iconNode.displaysAsynchronously = false

        self.arrowNode = ASImageNode()
        self.arrowNode.isLayerBacked = true
        self.arrowNode.displayWithoutProcessing = true
        self.arrowNode.displaysAsynchronously = false

        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.contentMode = .left
        self.titleNode.contentsScale = UIScreen.main.scale

        self.subtitleNode = TextNode()
        self.subtitleNode.isUserInteractionEnabled = false
        self.subtitleNode.contentMode = .left
        self.subtitleNode.contentsScale = UIScreen.main.scale

        self.activateArea = AccessibilityAreaNode()

        super.init(layerBacked: false)

        self.addSubnode(self.iconNode)
        self.addSubnode(self.arrowNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.subtitleNode)
        self.addSubnode(self.activateArea)

        self.activateArea.activate = { [weak self] in
            self?.item?.action()
            return true
        }
    }

    func asyncLayout() -> (_ item: SharedMessageAccessItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, (Bool) -> Void) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeSubtitleLayout = TextNode.asyncLayout(self.subtitleNode)

        let currentItem = self.item

        return { [weak self] item, params, neighbors in
            let theme = item.presentationData.theme
            let height: CGFloat = 64.0
            let checkSize: CGFloat = 22.0
            let iconSize: CGFloat = 40.0
            let leftInset: CGFloat = params.leftInset + 106.0
            let rightInset: CGFloat = params.rightInset + 16.0
            let titleSpacing: CGFloat = 3.0

            let baseFontSize = item.presentationData.fontSize.itemListBaseFontSize
            let titleFont = Font.semibold(baseFontSize)
            let subtitleFont = Font.regular(floor(baseFontSize * 15.0 / 17.0))

            let subtitleColor = item.subtitleIsAccent ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor

            let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.title, font: titleFont, textColor: theme.list.itemPrimaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: params.width - leftInset - rightInset, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))

            let arrowReserve: CGFloat = item.subtitleIsAccent ? 14.0 : 0.0
            let (subtitleLayout, subtitleApply) = makeSubtitleLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.subtitle, font: subtitleFont, textColor: subtitleColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: params.width - leftInset - rightInset - arrowReserve, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))

            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let contentSize = CGSize(width: params.width, height: height)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            let themeUpdated = currentItem?.presentationData.theme !== theme
            let separatorHeight = UIScreenPixel

            return (layout, { animated in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item

                strongSelf.activateArea.frame = CGRect(origin: CGPoint(x: params.leftInset, y: 0.0), size: CGSize(width: params.width - params.leftInset - params.rightInset, height: height))
                strongSelf.activateArea.accessibilityLabel = item.title
                strongSelf.activateArea.accessibilityValue = item.checked ? "Selected" : ""

                if themeUpdated {
                    strongSelf.topStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = theme.list.itemBlocksSeparatorColor
                    strongSelf.backgroundNode.backgroundColor = theme.list.itemBlocksBackgroundColor
                    strongSelf.highlightedBackgroundNode.backgroundColor = theme.list.itemHighlightedBackgroundColor
                    strongSelf.arrowNode.image = generateTintedImage(image: UIImage(bundleImageName: "Contact List/SubtitleArrow"), color: theme.list.itemAccentColor)
                }

                let _ = titleApply()
                let _ = subtitleApply()

                if strongSelf.backgroundNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                }
                if strongSelf.topStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                }
                if strongSelf.bottomStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                }
                if strongSelf.maskNode.supernode == nil {
                    strongSelf.addSubnode(strongSelf.maskNode)
                }

                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTopCorners = false
                var hasBottomCorners = false
                let topStripeIsHidden: Bool
                switch neighbors.top {
                case .sameSection(false):
                    topStripeIsHidden = true
                default:
                    hasTopCorners = true
                    topStripeIsHidden = hasCorners
                }
                let bottomStripeInset: CGFloat
                let bottomStripeIsHidden: Bool
                switch neighbors.bottom {
                case .sameSection(false):
                    bottomStripeInset = leftInset
                    bottomStripeIsHidden = false
                default:
                    bottomStripeInset = 0.0
                    hasBottomCorners = true
                    bottomStripeIsHidden = hasCorners
                }
                strongSelf.topStripeNode.isHidden = topStripeIsHidden
                strongSelf.bottomStripeNode.isHidden = bottomStripeIsHidden

                strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(theme, top: hasTopCorners, bottom: hasBottomCorners, glass: true) : nil

                strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.inset(by: UIEdgeInsets(top: 0.0, left: params.leftInset, bottom: 0.0, right: params.rightInset))
                strongSelf.highlightedBackgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -UIScreenPixel), size: CGSize(width: params.width, height: strongSelf.backgroundNode.frame.height + UIScreenPixel))
                strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: separatorHeight))
                strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: height - separatorHeight), size: CGSize(width: params.width - params.rightInset - bottomStripeInset - 16.0, height: separatorHeight))

                let checkLayer: CheckLayer
                if let current = strongSelf.checkLayer {
                    checkLayer = current
                    if themeUpdated {
                        checkLayer.theme = CheckNodeTheme(theme: theme, style: .plain)
                    }
                    checkLayer.setSelected(item.checked, animated: animated)
                } else {
                    checkLayer = CheckLayer(theme: CheckNodeTheme(theme: theme, style: .plain))
                    strongSelf.checkLayer = checkLayer
                    strongSelf.layer.addSublayer(checkLayer)
                    checkLayer.setSelected(item.checked, animated: false)
                    checkLayer.setNeedsDisplay()
                }
                checkLayer.frame = CGRect(origin: CGPoint(x: params.leftInset + floor((54.0 - checkSize) * 0.5), y: floor((height - checkSize) * 0.5)), size: CGSize(width: checkSize, height: checkSize))

                strongSelf.iconNode.image = item.icon
                strongSelf.iconNode.frame = CGRect(origin: CGPoint(x: params.leftInset + 54.0, y: floor((height - iconSize) * 0.5)), size: CGSize(width: iconSize, height: iconSize))

                let contentHeight = titleLayout.size.height + titleSpacing + subtitleLayout.size.height
                let titleOrigin = CGPoint(x: leftInset, y: floor((height - contentHeight) * 0.5))
                strongSelf.titleNode.frame = CGRect(origin: titleOrigin, size: titleLayout.size)
                strongSelf.subtitleNode.frame = CGRect(origin: CGPoint(x: leftInset, y: titleOrigin.y + titleLayout.size.height + titleSpacing), size: subtitleLayout.size)

                if item.subtitleIsAccent, let arrowImage = strongSelf.arrowNode.image {
                    strongSelf.arrowNode.isHidden = false
                    strongSelf.arrowNode.frame = CGRect(origin: CGPoint(x: strongSelf.subtitleNode.frame.maxX + 5.0, y: strongSelf.subtitleNode.frame.minY + floor((subtitleLayout.size.height - arrowImage.size.height) * 0.5) + 1.0), size: arrowImage.size)
                } else {
                    strongSelf.arrowNode.isHidden = true
                }
            })
        }
    }

    override func setHighlighted(_ highlighted: Bool, at point: CGPoint, animated: Bool) {
        super.setHighlighted(highlighted, at: point, animated: animated)

        if highlighted {
            self.highlightedBackgroundNode.alpha = 1.0
            if self.highlightedBackgroundNode.supernode == nil {
                self.insertSubnode(self.highlightedBackgroundNode, aboveSubnode: self.backgroundNode)
            }
        } else if self.highlightedBackgroundNode.supernode != nil {
            if animated {
                self.highlightedBackgroundNode.layer.animateAlpha(from: self.highlightedBackgroundNode.alpha, to: 0.0, duration: 0.4, completion: { [weak self] finished in
                    if finished {
                        self?.highlightedBackgroundNode.removeFromSupernode()
                    }
                })
                self.highlightedBackgroundNode.alpha = 0.0
            } else {
                self.highlightedBackgroundNode.removeFromSupernode()
            }
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
