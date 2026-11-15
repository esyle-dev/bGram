import Foundation
import LottieSettings
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ChatMessageBubbleContentNode
import ChatMessageItemCommon

/// The Edit button under a shared message: a 40pt button in the accent colour at 12%, 6pt from the
/// bubble's sides and bottom. Its corners follow the bubble's (the bubble's radius less the 6pt
/// inset), so the button sits concentric with the bubble.
public final class ChatMessageSharedFooterBubbleContentNode: ChatMessageBubbleContentNode {
    private static let topInset: CGFloat = 2.0
    private static let bottomInset: CGFloat = 6.0
    private static let sideInset: CGFloat = 6.0
    private static let buttonHeight: CGFloat = 40.0

    private let buttonNode: ASDisplayNode
    private let labelNode: TextNode

    required public init(lottieSettings: LottieRenderingSettings) {
        self.buttonNode = ASDisplayNode()
        self.buttonNode.isLayerBacked = true

        self.labelNode = TextNode()
        self.labelNode.isUserInteractionEnabled = false
        self.labelNode.contentsScale = UIScreenScale

        super.init(lottieSettings: lottieSettings)

        self.addSubnode(self.buttonNode)
        self.addSubnode(self.labelNode)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let makeLabelLayout = TextNode.asyncLayout(self.labelNode)

        return { [weak self] item, _, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { [weak self] constrainedSize, _ in
                let incoming = item.message.effectivelyIncoming(item.context.account.peerId)
                let messageTheme = incoming ? item.presentationData.theme.theme.chat.message.incoming : item.presentationData.theme.theme.chat.message.outgoing
                let strings = item.presentationData.strings

                var shared: SharedMessageAttribute?
                for attribute in item.message.attributes {
                    if let attribute = attribute as? SharedMessageAttribute {
                        shared = attribute
                        break
                    }
                }
                let isClosed = shared?.footerState(now: Int32(Date().timeIntervalSince1970)) == .closed

                let labelColor = isClosed ? messageTheme.secondaryTextColor : messageTheme.accentTextColor
                let labelText = isClosed ? strings.SharedMessage_Header_Closed : strings.SharedMessage_Footer_Edit
                let sideInset = ChatMessageSharedFooterBubbleContentNode.sideInset
                let (labelLayout, labelApply) = makeLabelLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: labelText, font: Font.medium(16.0), textColor: labelColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(1.0, constrainedSize.width - sideInset * 2.0 - 16.0), height: CGFloat.greatestFiniteMagnitude), alignment: .natural, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))

                let suggestedWidth = labelLayout.size.width + 16.0 + sideInset * 2.0

                return (suggestedWidth, { [weak self] boundingWidth in
                    let buttonHeight = ChatMessageSharedFooterBubbleContentNode.buttonHeight
                    let size = CGSize(width: boundingWidth, height: ChatMessageSharedFooterBubbleContentNode.topInset + buttonHeight + ChatMessageSharedFooterBubbleContentNode.bottomInset)

                    return (size, { [weak self] _, _, _ in
                        guard let self else {
                            return
                        }
                        self.item = item

                        let _ = labelApply()

                        let buttonFrame = CGRect(x: sideInset, y: ChatMessageSharedFooterBubbleContentNode.topInset, width: max(0.0, boundingWidth - sideInset * 2.0), height: buttonHeight)
                        self.buttonNode.frame = buttonFrame
                        self.buttonNode.backgroundColor = labelColor.withAlphaComponent(0.12)
                        self.buttonNode.cornerRadius = max(4.0, min(buttonHeight / 2.0, item.presentationData.chatBubbleCorners.mainRadius - ChatMessageSharedFooterBubbleContentNode.bottomInset))
                        self.labelNode.frame = CGRect(origin: CGPoint(x: buttonFrame.minX + floor((buttonFrame.width - labelLayout.size.width) / 2.0), y: buttonFrame.minY + floor((buttonFrame.height - labelLayout.size.height) / 2.0)), size: labelLayout.size)
                    })
                })
            })
        }
    }

    override public func animateInsertion(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override public func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override public func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
    }

    override public func animateInsertionIntoBubble(_ duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        // The bubble asks every content node about a gesture wherever it landed. Only a plain tap on the
        // button is the footer's: claiming anything else (a long press on the text above) took the
        // message's context menu away.
        guard case .tap = gesture, self.buttonNode.frame.insetBy(dx: 0.0, dy: -4.0).contains(point) else {
            return ChatMessageBubbleContentTapAction(content: .none)
        }
        return ChatMessageBubbleContentTapAction(content: .custom({ [weak self] in
            guard let item = self?.item else {
                return
            }
            item.controllerInteraction.openSharedMessageEditor?(item.message.id)
        }))
    }
}
