import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI

/// A footer text under a section with an optional counter pinned to the right edge, on the first line.
final class SharedMessageSetupFooterTextItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let text: String
    let counter: String?
    let sectionId: ItemListSectionId

    let tag: ItemListItemTag? = nil
    let isAlwaysPlain: Bool = true

    init(presentationData: ItemListPresentationData, text: String, counter: String?, sectionId: ItemListSectionId) {
        self.presentationData = presentationData
        self.text = text
        self.counter = counter
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = SharedMessageSetupFooterTextItemNode()
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

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? SharedMessageSetupFooterTextItemNode {
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
}

final class SharedMessageSetupFooterTextItemNode: ListViewItemNode, ItemListItemNode {
    private let textNode: TextNode
    private let counterNode: TextNode

    private var item: SharedMessageSetupFooterTextItem?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }

    init() {
        self.textNode = TextNode()
        self.textNode.isUserInteractionEnabled = false
        self.textNode.contentMode = .left
        self.textNode.contentsScale = UIScreen.main.scale

        self.counterNode = TextNode()
        self.counterNode.isUserInteractionEnabled = false
        self.counterNode.contentMode = .left
        self.counterNode.contentsScale = UIScreen.main.scale

        super.init(layerBacked: false)

        self.addSubnode(self.textNode)
        self.addSubnode(self.counterNode)
    }

    func asyncLayout() -> (_ item: SharedMessageSetupFooterTextItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        let makeTextLayout = TextNode.asyncLayout(self.textNode)
        let makeCounterLayout = TextNode.asyncLayout(self.counterNode)

        return { [weak self] item, params, neighbors in
            let sideInset: CGFloat = 15.0
            let verticalInset: CGFloat = 7.0
            let font = Font.regular(item.presentationData.fontSize.itemListBaseHeaderFontSize)
            let color = item.presentationData.theme.list.freeTextColor

            let (counterLayout, counterApply) = makeCounterLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.counter ?? "", font: font, textColor: color), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: 100.0, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

            let counterReserve: CGFloat = item.counter != nil ? counterLayout.size.width + 8.0 : 0.0
            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.text, font: font, textColor: color), backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: params.width - sideInset * 2.0 - params.leftInset - params.rightInset - counterReserve, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))

            let contentSize = CGSize(width: params.width, height: max(textLayout.size.height, counterLayout.size.height) + verticalInset * 2.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)

            return (layout, {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item

                let _ = textApply()
                let _ = counterApply()

                strongSelf.textNode.frame = CGRect(origin: CGPoint(x: params.leftInset + sideInset, y: verticalInset), size: textLayout.size)
                strongSelf.counterNode.frame = CGRect(origin: CGPoint(x: params.width - params.rightInset - sideInset - counterLayout.size.width, y: verticalInset), size: counterLayout.size)
                strongSelf.counterNode.isHidden = item.counter == nil
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
