import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ContextUI
import TelegramCore
import SwiftSignalKit
import AccountContext
import Postbox
import PhotoResources
import ChatMessageBubbleItemNode

/// The photo of an album that a long press is about. A move of the finger changes it, and everything that acts on "the photo" (the menu,
/// the reactions, the reply) reads it from here.
final class AlbumPhotoSelection {
    let photoMessages: [EngineRawMessage]
    /// Every message of the album, not only the photos, for the actions of the album as a whole.
    let allMessages: [EngineRawMessage]
    private(set) var index: Int
    /// Whether the actions of the whole album are shown instead of the menu of the photo; no photo is picked out then.
    private(set) var isAlbumActionsOpen = false
    weak var bubbleNode: ChatMessageBubbleItemNode?
    
    var message: EngineRawMessage {
        return self.photoMessages[self.index]
    }
    
    init?(photoMessages: [EngineRawMessage], allMessages: [EngineRawMessage], message: EngineRawMessage) {
        guard let index = photoMessages.firstIndex(where: { $0.id == message.id }) else {
            return nil
        }
        self.photoMessages = photoMessages
        self.allMessages = allMessages
        self.index = index
    }
    
    /// Called when the actions of the whole album are opened or closed.
    var albumActionsToggled: ((Bool) -> Void)?
    
    func setAlbumActionsOpen(_ open: Bool) {
        self.isAlbumActionsOpen = open
        self.albumActionsToggled?(open)
        self.bubbleNode?.setAlbumPhotosAllActive(open)
    }
    
    /// Makes another photo of the album the one that is open. Returns false when it already is, or is not a photo of the album.
    func select(_ message: EngineRawMessage) -> Bool {
        guard let index = self.photoMessages.firstIndex(where: { $0.id == message.id }), index != self.index else {
            return false
        }
        self.index = index
        return true
    }
    
    /// Moves to the next (positive) or the previous (negative) photo of the album. Returns false at either end of the album.
    func move(by delta: Int) -> Bool {
        let updated = self.index + delta
        if updated < 0 || updated >= self.photoMessages.count {
            return false
        }
        self.index = updated
        return true
    }
}

/// The content of the context menu of one photo of an album: that photo, on a card of one size for every photo, lifted with the reactions
/// above it and the menu under it. The card is made for the photo, because the photos of an album share one bubble in the chat. The
/// photo on it can be replaced while the menu is open (`switchTo`), and the card does not change size when it is.
final class AlbumPhotoContextExtractedContentSource: ContextExtractedContentSource {
    let keepInPlace: Bool = false
    let ignoreContentTouches: Bool = false
    let blurBackground: Bool = true
    // Not centred: the menu mirrors centred content to the other side of the screen, and the content then returns from the wrong side.
    let centerVertically: Bool = false
    
    private weak var chatNode: ChatControllerNode?
    private let context: AccountContext
    private let selection: AlbumPhotoSelection
    private let sourceView: () -> (UIView, CGRect)?
    
    private var containerNode: ContextExtractedContentContainingNode?
    private var cardSize = CGSize()
    private var cardNode: AlbumPhotoCardNode?
    
    var shouldBeDismissed: Signal<Bool, NoError> {
        return .single(false)
    }
    
    init(context: AccountContext, chatNode: ChatControllerNode, selection: AlbumPhotoSelection, sourceView: @escaping () -> (UIView, CGRect)?) {
        self.context = context
        self.chatNode = chatNode
        self.selection = selection
        self.sourceView = sourceView
    }
    
    private func cardOrigin(center: CGPoint, cardSize: CGSize, chatNode: ChatControllerNode) -> CGPoint {
        return CGPoint(x: max(0.0, min(chatNode.bounds.width - cardSize.width, floor(center.x - cardSize.width / 2.0))), y: floor(center.y - cardSize.height / 2.0))
    }
    
    func takeView() -> ContextControllerTakeViewInfo? {
        guard let chatNode = self.chatNode else {
            return nil
        }
        
        let width = min(floor(chatNode.bounds.width * 0.78), 320.0)
        let cardSize = CGSize(width: width, height: floor(width * 1.1))
        
        // The card starts over the photo it was made from, so the lift begins there.
        var center = CGPoint(x: chatNode.bounds.midX, y: chatNode.bounds.midY)
        if let (view, rect) = self.sourceView() {
            center = view.convert(rect, to: chatNode.view).center
        }
        let origin = self.cardOrigin(center: center, cardSize: cardSize, chatNode: chatNode)
        
        let cardNode = AlbumPhotoCardNode(context: self.context, message: self.selection.message, size: cardSize)
        let containerNode = ContextExtractedContentContainingNode()
        containerNode.frame = CGRect(origin: origin, size: cardSize)
        containerNode.contentNode.frame = CGRect(origin: CGPoint(), size: cardSize)
        containerNode.contentRect = CGRect(origin: CGPoint(), size: cardSize)
        cardNode.frame = CGRect(origin: CGPoint(), size: cardSize)
        containerNode.contentNode.addSubnode(cardNode)
        chatNode.addSubnode(containerNode)
        
        self.containerNode = containerNode
        self.cardNode = cardNode
        self.cardSize = cardSize
        
        return ContextControllerTakeViewInfo(containingItem: .node(containerNode), contentAreaInScreenSpace: chatNode.convert(chatNode.frameForVisibleArea(), to: nil))
    }
    
    private var cardOffset: CGFloat = 0.0
    
    /// Moves the card up or down with the finger: the way the finger went from where it was (`distance`) is followed, a little less
    /// the farther it goes, so the card never leaves the screen. With `animated` the card goes to the new place on a spring.
    func setCardOffset(_ distance: CGFloat, animated: Bool = false) {
        guard let cardNode = self.cardNode else {
            return
        }
        let limit: CGFloat = 120.0
        let offset: CGFloat = distance == 0.0 ? 0.0 : (distance < 0.0 ? -1.0 : 1.0) * limit * (1.0 - exp(-abs(distance) / limit))
        let previous = self.cardOffset
        if previous == offset {
            return
        }
        self.cardOffset = offset
        cardNode.layer.transform = offset == 0.0 ? CATransform3DIdentity : CATransform3DMakeTranslation(0.0, offset, 0.0)
        if animated {
            cardNode.layer.animateSpring(from: (previous - offset) as NSNumber, to: 0.0 as NSNumber, keyPath: "transform.translation.y", duration: 0.5, additive: true)
        }
    }
    
    /// The finger is lifted: the card settles back where it was.
    func releaseCard() {
        self.setCardOffset(0.0, animated: true)
    }
    
    /// Shows another photo on the card, with the pop of a sticker that is replaced by the next one.
    func switchTo(message: EngineRawMessage) {
        self.cardNode?.show(message: message)
    }
    
    func putBack() -> ContextControllerPutBackViewInfo? {
        guard let chatNode = self.chatNode else {
            return nil
        }
        if let containerNode = self.containerNode {
            self.containerNode = nil
            self.cardNode?.layer.removeAllAnimations()
            self.cardNode?.layer.transform = CATransform3DIdentity
            self.cardOffset = 0.0
            let cardNode = self.cardNode
            self.cardNode = nil
            // The card goes back to the photo that is open now (which may not be the one it came from), and shrinks to its size on the
            // way. The place it returns to is read after this, so it is moved here.
            if let (view, rect) = self.sourceView() {
                let tileRect = view.convert(rect, to: chatNode.view)
                let newOrigin = self.cardOrigin(center: tileRect.center, cardSize: self.cardSize, chatNode: chatNode)
                let offsetX = newOrigin.x - containerNode.frame.origin.x
                // The menu moves the content back up and down to where the container is, and not sideways: it assumes that the place the
                // content came from does not move to one side. So only the height of the container is changed here, and the card
                // moves sideways by itself, to the photo, over the same time.
                containerNode.frame.origin.y = newOrigin.y
                if let cardNode, abs(offsetX) > 0.0 {
                    cardNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: offsetX, y: 0.0), duration: 0.4, removeOnCompletion: false, additive: true)
                }
                if let cardNode, self.cardSize.width > 0.0, self.cardSize.height > 0.0 {
                    let scale = max(tileRect.width / self.cardSize.width, tileRect.height / self.cardSize.height)
                    cardNode.layer.animateScale(from: 1.0, to: scale, duration: 0.4, removeOnCompletion: false)
                }
            }
            // The card the content returns to goes away once the content has arrived, without a jump.
            Queue.mainQueue().after(0.4, {
                ContainedViewLayoutTransition.animated(duration: 0.2, curve: .easeInOut).updateAlpha(node: containerNode, alpha: 0.0, completion: { _ in
                    containerNode.removeFromSupernode()
                })
            })
        }
        return ContextControllerPutBackViewInfo(contentAreaInScreenSpace: chatNode.convert(chatNode.frameForVisibleArea(), to: nil))
    }
}

/// A photo with rounded corners, filling a card of a fixed size.
private final class AlbumPhotoCardNode: ASDisplayNode {
    private let context: AccountContext
    private let cardSize: CGSize
    private var imageNode: TransformImageNode
    private let fetchDisposable = MetaDisposable()
    
    init(context: AccountContext, message: EngineRawMessage, size: CGSize) {
        self.context = context
        self.cardSize = size
        self.imageNode = TransformImageNode()
        
        super.init()
        
        self.isUserInteractionEnabled = false
        self.imageNode = self.makeImageNode(message: message)
        self.addSubnode(self.imageNode)
    }
    
    deinit {
        self.fetchDisposable.dispose()
    }
    
    private func makeImageNode(message: EngineRawMessage) -> TransformImageNode {
        let node = TransformImageNode()
        node.displaysAsynchronously = false
        node.frame = CGRect(origin: CGPoint(), size: self.cardSize)
        
        guard let image = message.effectiveMedia.compactMap({ $0 as? TelegramMediaImage }).first else {
            return node
        }
        let largest = largestImageRepresentation(image.representations)
        let dimensions = largest?.dimensions.cgSize ?? self.cardSize
        let arguments = TransformImageArguments(corners: ImageCorners(radius: 16.0), imageSize: dimensions.aspectFilled(self.cardSize), boundingSize: self.cardSize, intrinsicInsets: UIEdgeInsets())
        let apply = node.asyncLayout()(arguments)
        let photoReference: ImageMediaReference = .message(message: MessageReference(message), media: image)
        node.setSignal(chatMessagePhoto(postbox: self.context.account.postbox, userLocation: .peer(message.id.peerId), photoReference: photoReference, synchronousLoad: true, highQuality: true))
        apply()
        
        if let largest {
            self.fetchDisposable.set(fetchedMediaResource(mediaBox: self.context.account.postbox.mediaBox, userLocation: .peer(message.id.peerId), userContentType: .image, reference: photoReference.abstract.resourceReference(largest.resource)).startStrict())
        }
        return node
    }
    
    func show(message: EngineRawMessage) {
        let previousNode = self.imageNode
        previousNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false, completion: { [weak previousNode] _ in
            previousNode?.removeFromSupernode()
        })
        previousNode.layer.animateScale(from: 1.0, to: 0.2, duration: 0.15, removeOnCompletion: false)
        
        self.imageNode = self.makeImageNode(message: message)
        self.addSubnode(self.imageNode)
        self.imageNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
        self.imageNode.layer.animateSpring(from: 0.35 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5)
    }
}
