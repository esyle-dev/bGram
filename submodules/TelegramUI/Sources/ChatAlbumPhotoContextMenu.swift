import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass
import LegacyComponents
import LegacyMediaPickerUI
import MediaPickerUI
import MediaPasteboardUI
import AttachmentUI
import Photos
import TelegramStringFormatting
import Postbox
import TextFormat
import TelegramCore
import Display
import SwiftSignalKit
import AccountContext
import ContextUI
import AppBundle
import PresentationDataUtils
import ImageCompression
import TelegramPresentationData
import UndoUI
import ChatPresentationInterfaceState
import ChatControllerInteraction
import ChatMessageItemCommon
import ChatMessageBubbleItemNode
import BetaFeatures

/// Whether a press on `message` is a press on one photo of an album: the message is one of several that make up the album, and it holds a
/// photo. Such a press gets the menu of that photo alone (see `albumPhotoContextMenuItems`), not the menu of the whole album.
func isAlbumPhotoMessage(_ message: EngineRawMessage, in messages: [EngineRawMessage]) -> Bool {
    if messages.count < 2 || message.groupingKey == nil {
        return false
    }
    return message.effectiveMedia.contains(where: { $0 is TelegramMediaImage })
}

private func renamedContextMenuAction(_ item: ContextMenuActionItem, text: String) -> ContextMenuActionItem {
    return ContextMenuActionItem(
        id: item.id,
        text: text,
        textColor: item.textColor,
        textLayout: item.textLayout,
        textFont: item.textFont,
        icon: item.icon,
        iconSource: item.iconSource,
        iconPosition: item.iconPosition,
        action: item.action
    )
}

/// The menu of one photo of an album: Reply, Save to Photos, Forward, Delete, Select, Album Actions. Every item acts on this
/// photo only. The items that need the rules of the regular message menu (who can reply, forward or delete, copy protection) are taken
/// from the regular menu of this one message, so those rules stay in one place; the rest is added or renamed here.
func albumPhotoContextMenuItems(
    chatPresentationInterfaceState: ChatPresentationInterfaceState,
    context: AccountContext,
    message: EngineRawMessage,
    controllerInteraction: ChatControllerInteraction?,
    interfaceInteraction: ChatPanelInterfaceInteraction?,
    photoIndex: Int,
    photoCount: Int,
    albumMessages: [EngineRawMessage],
    showsAlbumActions: Bool,
    albumReactions: AlbumReactionsBox? = nil,
    albumActionsToggled: ((Bool) -> Void)?,
    editPhoto: ((EngineMessage.Id) -> Void)?,
    editAlbum: (() -> Void)?
) -> Signal<ContextController.Items, NoError> {
    let strings = chatPresentationInterfaceState.strings
    let regularMenu = contextMenuForChatPresentationInterfaceState(
        chatPresentationInterfaceState: chatPresentationInterfaceState,
        context: context,
        messages: [message],
        controllerInteraction: controllerInteraction,
        selectAll: false,
        interfaceInteraction: interfaceInteraction,
        messageNode: nil
    )
    return combineLatest(
        regularMenu,
        context.engine.data.get(TelegramEngine.EngineData.Item.Configuration.Limits())
    )
    |> map { items, limits -> ContextController.Items in
        guard case let .list(regularItems) = items.content else {
            return items
        }

        var reply: ContextMenuItem?
        var forward: ContextMenuItem?
        var delete: ContextMenuItem?
        var select: ContextMenuItem?
        for item in regularItems {
            switch item {
            case let .action(action):
                if action.text == strings.Conversation_ContextMenuReply {
                    reply = item
                } else if action.text == strings.Conversation_ContextMenuForward {
                    forward = item
                } else if action.textColor == .destructive {
                    delete = item
                } else if action.text == strings.Conversation_ContextMenuSelect {
                    select = item
                }
            case .custom:
                // The delete item that shows a countdown of a message that disappears.
                if delete == nil {
                    delete = item
                }
            case .separator:
                break
            }
        }

        // Reply to the photo: the reply panel says which photo it is ("Reply to photo 4"), so the number is kept for it.
        if case let .action(replyAction)? = reply, BetaFeatures.isEnabled(.albumReply) {
            let replyMessageId = message.id
            reply = .action(ContextMenuActionItem(
                id: replyAction.id,
                text: replyAction.text,
                textColor: replyAction.textColor,
                textLayout: replyAction.textLayout,
                textFont: replyAction.textFont,
                icon: replyAction.icon,
                iconSource: replyAction.iconSource,
                iconPosition: replyAction.iconPosition,
                action: { action in
                    AlbumPhotoReplyStore.shared.setText(strings.Conversation_ContextMenuPhotoIndex("\(photoIndex + 1)", "\(photoCount)").string, for: replyMessageId)
                    replyAction.action?(action)
                }
            ))
        }

        var result: [ContextMenuItem] = []
        // Which photo of the album this is ("Photo 3 of 6"), small, like the line of the read time, with a line under it.
        let noAction: ((ContextMenuActionItem.Action) -> Void)? = nil
        result.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuPhotoIndex("\(photoIndex + 1)", "\(photoCount)").string, textColor: .primary, textLayout: .singleLine, textFont: .small, icon: { _ in
            return nil
        }, action: noAction)))
        result.append(.separator)
        if let reply {
            result.append(reply)
        }
        
        // Edit Photo: the ordinary edit of the message of this photo.
        if let editPhoto, canEditMessage(accountPeerId: context.account.peerId, limitsConfiguration: limits, message: message) {
            let messageId = message.id
            result.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuEditPhoto, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                AlbumPhotoReplyStore.shared.setText(strings.Conversation_ContextMenuPhotoIndex("\(photoIndex + 1)", "\(photoCount)").string, for: messageId)
                editPhoto(messageId)
            })))
        }

        // Add to Saved: the photo alone, with no text, goes to Saved Messages, and the usual notice says so.
        if forward != nil {
            let messageId = message.id
            let accountPeerId = context.account.peerId
            result.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuAddToSaved, icon: { theme in
                // The picture is 30 pt, the other pictures of the menu are 24 pt.
                guard let bookmark = generateTintedImage(image: UIImage(bundleImageName: "Instant View/Bookmark"), color: theme.contextMenu.primaryColor) else {
                    return nil
                }
                let iconSize = CGSize(width: 24.0, height: 24.0)
                return generateImage(iconSize, contextGenerator: { size, context in
                    context.clear(CGRect(origin: CGPoint(), size: size))
                    if let cgImage = bookmark.cgImage {
                        context.draw(cgImage, in: CGRect(origin: CGPoint(), size: size))
                    }
                })
            }, action: { _, f in
                f(.default)
                let attributes: [MessageAttribute] = [ForwardOptionsMessageAttribute(hideNames: false, hideCaptions: true)]
                let _ = enqueueMessages(account: context.account, peerId: accountPeerId, messages: [.forward(source: messageId, threadId: nil, grouping: .none, attributes: attributes, correlationId: nil)]).startStandalone()
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                controllerInteraction?.presentController(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: true, text: presentationData.strings.Conversation_ForwardTooltip_SavedMessages_One), elevatedLayout: false, position: .bottom, animateInAsReplacement: false, action: { _ in
                    return false
                }), nil)
            })))
        }
        if let forward {
            result.append(forward)
        }
        if let delete {
            result.append(delete)
        }
        if let select {
            result.append(.separator)
            result.append(select)
        }
        
        // Album actions: the menu of the album as a whole, which opens in place of this one (and goes back to it).
        if showsAlbumActions, albumMessages.count > 1 {
            let albumMenu = contextMenuForChatPresentationInterfaceState(
                chatPresentationInterfaceState: chatPresentationInterfaceState,
                context: context,
                messages: albumMessages,
                controllerInteraction: controllerInteraction,
                selectAll: true,
                interfaceInteraction: interfaceInteraction,
                messageNode: nil
            )
            |> map { albumItems -> ContextController.Items in
                var updated = albumPhotoEditItemRenamed(albumItems, strings: strings, openEditor: editAlbum)
                // The list is longer than this menu: it is not kept at the top it started at, so that all of it is on the screen.
                updated.disablePositionLock = true
                // The reactions are of the album as a whole, so they are over this menu and not over the menu of one photo.
                albumReactions?.apply?(&updated)
                if case let .list(albumList) = updated.content {
                    var list: [ContextMenuItem] = []
                    list.append(.action(ContextMenuActionItem(text: strings.Common_Back, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
                    }, iconPosition: .left, action: { c, _ in
                        albumActionsToggled?(false)
                        c?.popItems()
                    })))
                    list.append(.separator)
                    list.append(contentsOf: albumList)
                    updated.content = .list(list)
                }
                return updated
            }
            result.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuAlbumActions, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/List"), color: theme.contextMenu.primaryColor)
            }, additionalLeftIcon: { theme in
                // Shown at the right edge of the item: the menu goes on from here.
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Arrow"), color: theme.contextMenu.secondaryColor)
            }, action: { c, _ in
                albumActionsToggled?(true)
                c?.pushItems(items: albumMenu)
            })))
        }

        var updated = items
        updated.content = .list(result)
        return updated
    }
}

/// Puts the reactions of the album on the menu of the whole album. It is filled in when the reactions that are allowed are known, which
/// is after the menu of the photo is made.
final class AlbumReactionsBox {
    var apply: ((inout ContextController.Items) -> Void)?
}

/// Which photo of an album a reply is to, for the reply panel ("Photo 4 of 9"). Main thread only.
final class AlbumPhotoReplyStore {
    static let shared = AlbumPhotoReplyStore()
    
    private var texts: [EngineMessage.Id: String] = [:]
    
    private init() {
    }
    
    func setText(_ text: String, for id: EngineMessage.Id) {
        self.texts[id] = text
    }
    
    func text(for id: EngineMessage.Id) -> String? {
        return self.texts[id]
    }
}

/// A drag on the album after the finger that opened the menu was lifted: it begins only on a photo of the album, and does not take the
/// touch from anything else of the menu.
private final class AlbumPhotoPanHandler: NSObject, UIGestureRecognizerDelegate {
    private let isOverPhoto: (CGPoint) -> Bool
    private let moved: (CGPoint) -> Void
    
    init(isOverPhoto: @escaping (CGPoint) -> Bool, moved: @escaping (CGPoint) -> Void) {
        self.isOverPhoto = isOverPhoto
        self.moved = moved
        super.init()
    }
    
    @objc func handle(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            self.moved(recognizer.location(in: nil))
        default:
            break
        }
    }
    
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return self.isOverPhoto(gestureRecognizer.location(in: nil))
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

/// Watches every touch of the menu of an album, from where it starts to where it ends, without taking any of them from anything else.
/// A touch that starts on a photo is one that moves the album (`scrolled` is given the distance it went vertically); `isDriving` says
/// that there is one such touch now, which is when the usual scrolling has to be off. A touch that starts anywhere else is not
/// followed, so it scrolls as usual. Nothing here is kept after a touch has ended or was cancelled.
private final class AlbumPhotoScrollDriver: UIGestureRecognizer {
    private let isOverPhoto: (CGPoint) -> Bool
    private let scrolled: (CGFloat) -> Void
    private let menuMoved: (CGPoint?) -> Void
    private let menuFinished: (Bool) -> Void
    private var lastPoints: [ObjectIdentifier: CGPoint] = [:]
    /// The touches that have gone off the photos and are over the menu now.
    private var isOverMenu = false
    /// Called when `isDriving` may have changed, at once, before the touch has moved.
    var drivingChanged: (() -> Void)?
    
    var isDriving: Bool {
        return !self.lastPoints.isEmpty
    }
    
    init(isOverPhoto: @escaping (CGPoint) -> Bool, scrolled: @escaping (CGFloat) -> Void, menuMoved: @escaping (CGPoint?) -> Void, menuFinished: @escaping (Bool) -> Void) {
        self.isOverPhoto = isOverPhoto
        self.scrolled = scrolled
        self.menuMoved = menuMoved
        self.menuFinished = menuFinished
        super.init(target: nil, action: nil)
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        for touch in touches {
            let point = touch.location(in: nil)
            if self.isOverPhoto(point) {
                self.lastPoints[ObjectIdentifier(touch)] = point
            }
        }
        self.drivingChanged?()
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let previous = self.lastPoints[key] else {
                continue
            }
            let point = touch.location(in: nil)
            self.lastPoints[key] = point
            if point.y != previous.y {
                self.scrolled(point.y - previous.y)
            }
            // A touch that began on a photo and has gone on to the menu chooses an item of it, as the finger that opened the menu does.
            if self.isOverPhoto(point) {
                if self.isOverMenu {
                    self.isOverMenu = false
                    self.menuMoved(nil)
                }
            } else {
                self.isOverMenu = true
                self.menuMoved(point)
            }
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        for touch in touches {
            self.lastPoints[ObjectIdentifier(touch)] = nil
        }
        if self.isOverMenu {
            self.isOverMenu = false
            self.menuFinished(true)
        }
        self.drivingChanged?()
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        for touch in touches {
            self.lastPoints[ObjectIdentifier(touch)] = nil
        }
        if self.isOverMenu {
            self.isOverMenu = false
            self.menuFinished(false)
        }
        self.drivingChanged?()
    }
    
    override func reset() {
        super.reset()
        self.isOverMenu = false
        self.lastPoints.removeAll()
        self.drivingChanged?()
    }
}

/// Watches a touch on the album and tells when it has stayed on a photo for a moment. It never takes the touch: it does not recognize.
private final class AlbumPhotoPressObserver: UIGestureRecognizer {
    private let isOverPhoto: (CGPoint) -> Bool
    private let pressed: (CGPoint) -> Void
    private let released: () -> Void
    private var startPoint: CGPoint?
    private var timer: SwiftSignalKit.Timer?
    private var didPress = false
    
    init(isOverPhoto: @escaping (CGPoint) -> Bool, pressed: @escaping (CGPoint) -> Void, released: @escaping () -> Void) {
        self.isOverPhoto = isOverPhoto
        self.pressed = pressed
        self.released = released
        super.init(target: nil, action: nil)
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
    }
    
    private func cancelTimer() {
        self.timer?.invalidate()
        self.timer = nil
        self.startPoint = nil
        if self.didPress {
            self.didPress = false
            self.released()
        }
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        self.cancelTimer()
        guard let touch = touches.first else {
            return
        }
        let point = touch.location(in: nil)
        let isOverPhoto = self.isOverPhoto(point)
        if !isOverPhoto {
            return
        }
        self.startPoint = point
        let timer = SwiftSignalKit.Timer(timeout: 0.2, repeat: false, completion: { [weak self] in
            guard let self, let point = self.startPoint else {
                return
            }
            self.didPress = true
            self.pressed(point)
        }, queue: Queue.mainQueue())
        self.timer = timer
        timer.start()
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if let touch = touches.first, let startPoint = self.startPoint {
            let point = touch.location(in: nil)
            if hypot(point.x - startPoint.x, point.y - startPoint.y) > 10.0 {
                self.cancelTimer()
            }
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        self.cancelTimer()
        self.state = .failed
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        self.cancelTimer()
        self.state = .failed
    }
    
    override func reset() {
        super.reset()
        self.cancelTimer()
    }
}

private var albumPhotoPanHandlerKey: UInt8 = 0

/// What moving the finger over the album needs to remember between two moves.
private final class AlbumPhotoTrackingState {
    var lastPoint: CGPoint?
    var lastScrollPoint: CGPoint?
    var latestPoint: CGPoint?
    var stillPoint: CGPoint?
    var stillSince: Double
    var isFingerDown = true
    var isOpened = false
    var isDisabled = false
    var generation: Int = 0
    var timer: SwiftSignalKit.Timer?
    var cleanup: (() -> Void)?
    
    init(now: Double) {
        self.stillSince = now
    }
    
    deinit {
        self.timer?.invalidate()
        self.cleanup?()
    }
}

extension ChatControllerImpl {
    /// Turns the menu of the album (all of it lifted, one photo active) into the menu of that one photo, on a card in the middle of the
    /// screen with the reactions above it, as a long hold on a photo does. The card is shown over the menu of the album, which fades out
    /// while the card comes in, so there is no moment when neither is there; then the menu of the album is closed.
    private func openAlbumPhotoCard(from albumController: ContextController, anyRecognizer: UIGestureRecognizer?, bubbleNode: ChatMessageBubbleItemNode, selection: AlbumPhotoSelection) {
        self.openMessageContextMenu(message: EngineMessage(selection.message), selectAll: false, node: bubbleNode, frame: bubbleNode.bounds, anyRecognizer: anyRecognizer, location: nil, albumPhotoCard: selection, albumPhotoCardPresented: { [weak albumController] _ in
            guard let albumController else {
                return
            }
            // Closing it is not to be seen, and is not to tell the chat that no menu is open any more.
            albumController.dismissed = nil
            ContainedViewLayoutTransition.animated(duration: 0.35, curve: .easeInOut).updateAlpha(layer: albumController.view.layer, alpha: 0.0, completion: { [weak albumController] _ in
                albumController?.dismiss(completion: nil)
            })
        })
    }
    
    /// While the menu of a photo of an album is open, moving a finger over another photo of the album (in any direction) moves the menu to
    /// that photo: it is highlighted, the others are a little transparent, and the menu is made again for it; the reactions stay as they
    /// were (`baseItems`). It works for the finger that opened the menu while it is still down, and, after that, for a finger that is
    /// dragged over the album. A finger that stays still on one photo for a long time makes the album show only that photo. A long press
    /// comes from one of two recognizers, depending on where on the message it started.
    func installAlbumPhotoTracking(gesture: ContextGesture?, recognizer: TapLongTapOrDoubleTapGestureRecognizer?, controller: ContextController, bubbleNode: ChatMessageBubbleItemNode, selection: AlbumPhotoSelection, baseItems: ContextController.Items) {
        let startTime = CACurrentMediaTime()
        let state = AlbumPhotoTrackingState(now: startTime)
        let haptic = HapticFeedback()
        // How far the album goes for a distance of the finger (1.0 is the same distance, the other way).
        let albumScrollFactor: CGFloat = 0.6
        
        // The photos of a tall album are out of reach of the finger, so a finger that is down on the photos moves the album the other way
        // round. The finger that opened the menu does it through `handlePoint`. Every other finger does it through the driver, which sees
        // every touch from its start to its end, so the usual scrolling of a touch that began anywhere else is never switched off, and
        // is given back at once when a touch that did switch it off is over.
        let driver = AlbumPhotoScrollDriver(isOverPhoto: { [weak bubbleNode] point in
            return !selection.isAlbumActionsOpen && bubbleNode?.albumPhotoMessage(atWindowPoint: point) != nil
        }, scrolled: { [weak controller] distance in
            controller?.scrollContent(by: distance * albumScrollFactor)
        }, menuMoved: { [weak controller] point in
            controller?.highlightMenu(atWindowPoint: point)
        }, menuFinished: { [weak controller] performAction in
            controller?.finishMenuHighlight(performAction: performAction)
        })
        // The menu is chosen from by sliding the finger over it, as in any menu, also when the content is taller than the screen (where
        // it would scroll). A touch that does not begin on an item of the menu still scrolls.
        let applyScrollMode: () -> Void = { [weak controller, weak driver] in
            controller?.setContentScrollingDriven(driver?.isDriving ?? false, menuSelection: true)
        }
        applyScrollMode()
        driver.drivingChanged = applyScrollMode
        
        let finishMenuHighlight: (Bool) -> Void = { [weak controller] performAction in
            controller?.finishMenuHighlight(performAction: performAction)
        }
        
        // Makes the photo under the point the one that is open, when it is another photo of the album.
        let moveFocus: (CGPoint) -> Void = { [weak self, weak controller, weak bubbleNode] windowPoint in
            guard let self, let controller, let bubbleNode else {
                return
            }
            if state.isDisabled || selection.isAlbumActionsOpen {
                return
            }
            let hitMessage = bubbleNode.albumPhotoMessage(atWindowPoint: windowPoint)
            guard let hit = hitMessage, selection.select(hit) else {
                return
            }
            haptic.tap()
            bubbleNode.focusAlbumPhoto(stableId: hit.stableId)
            state.stillSince = CACurrentMediaTime()
            
            state.generation += 1
            let generation = state.generation
            // An answer that comes after the finger has gone on to another photo is dropped, so the menu always shows the last photo.
            let items = albumPhotoContextMenuItems(chatPresentationInterfaceState: self.presentationInterfaceState, context: self.context, message: hit, controllerInteraction: self.controllerInteraction, interfaceInteraction: self.interfaceInteraction, photoIndex: selection.index, photoCount: selection.photoMessages.count, albumMessages: selection.allMessages, showsAlbumActions: true, albumActionsToggled: { open in selection.setAlbumActionsOpen(open) }, editPhoto: { id in self.editAlbumPhoto(messageId: id) }, editAlbum: { self.openAlbumEditor(messages: selection.allMessages) })
            |> filter { _ in
                return generation == state.generation
            }
            |> map { items -> ContextController.Items in
                var updated = baseItems
                updated.content = items.content
                return updated
            }
            controller.setItems(items, minHeight: nil, animated: false)
        }
        
        // A move of the finger: remembered, and followed at once once the album has been lifted (its photos are moving before that).
        let handlePoint: (CGPoint, Bool) -> Void = { [weak controller, weak bubbleNode] windowPoint, scrolls in
            if state.isDisabled {
                return
            }
            // The same move can reach this more than once, when the callback was wrapped more than once.
            if state.lastPoint == windowPoint {
                return
            }
            // The finger that opened the menu moves a tall album the other way round while it is over its photos: a finger that goes up
            // brings the photos above it down to it, a finger that goes down brings the ones below up. It does not go past either end of
            // the album, so a finger that goes down over the top of it does not pull the album down.
            if scrolls, let controller, CACurrentMediaTime() - startTime >= 0.45 {
                if !selection.isAlbumActionsOpen, bubbleNode?.albumPhotoMessage(atWindowPoint: windowPoint) != nil {
                    if let previous = state.lastScrollPoint {
                        controller.scrollContent(by: (windowPoint.y - previous.y) * albumScrollFactor)
                    }
                    state.lastScrollPoint = windowPoint
                    controller.highlightMenu(atWindowPoint: nil)
                } else {
                    state.lastScrollPoint = nil
                    // The finger has gone off the photos, onto the menu: the item under it is chosen, as in any menu.
                    controller.highlightMenu(atWindowPoint: windowPoint)
                }
            }
            state.lastPoint = windowPoint
            state.latestPoint = windowPoint
            if let stillPoint = state.stillPoint, hypot(stillPoint.x - windowPoint.x, stillPoint.y - windowPoint.y) <= 12.0 {
            } else {
                state.stillPoint = windowPoint
                state.stillSince = CACurrentMediaTime()
            }
            if CACurrentMediaTime() - startTime >= 0.45 {
                moveFocus(windowPoint)
            }
        }
        
        // Also followed by the clock, so that a finger that arrives on a photo while the album is still being lifted, and then stays
        // still, is not missed; and a finger that stays still on a photo for a long time opens it.
        let timer = SwiftSignalKit.Timer(timeout: 0.1, repeat: true, completion: { [weak self, weak state, weak controller, weak bubbleNode, weak gesture, weak recognizer] in
            guard let state, !state.isDisabled else {
                return
            }
            guard let controller, let bubbleNode, controller.isNodeLoaded else {
                state.timer?.invalidate()
                state.timer = nil
                state.cleanup?()
                state.cleanup = nil
                return
            }
            applyScrollMode()
            let now = CACurrentMediaTime()
            if now - startTime < 0.45 {
                return
            }
            if state.isFingerDown, let point = state.latestPoint {
                moveFocus(point)
                if !state.isOpened, !selection.isAlbumActionsOpen, now - state.stillSince > 0.8, bubbleNode.albumPhotoMessage(atWindowPoint: point) != nil, let self {
                    // A finger that stays still on one photo for a long time: the album becomes that one photo, on a card.
                    state.isOpened = true
                    state.isDisabled = true
                    state.timer?.invalidate()
                    state.timer = nil
                    self.openAlbumPhotoCard(from: controller, anyRecognizer: (gesture as UIGestureRecognizer?) ?? recognizer, bubbleNode: bubbleNode, selection: selection)
                }
            }
        }, queue: Queue.mainQueue())
        state.timer = timer
        timer.start()
        
        // The finger that opened the menu. The callbacks are set by the context menu when it is shown, so they are wrapped once that has
        // happened, and again a moment later in case it had not; the second wrapper repeats what the first did, which `lastPoint` makes
        // harmless.
        let wrap: () -> Void = { [weak gesture, weak recognizer] in
            if let gesture {
                let original = gesture.externalUpdated
                gesture.externalUpdated = { view, point in
                    original?(view, point)
                    if let view {
                        handlePoint(view.convert(point, to: nil), true)
                    }
                }
                let originalEnded = gesture.externalEnded
                gesture.externalEnded = { viewAndPoint in
                    state.isFingerDown = false
                    state.lastScrollPoint = nil
                    originalEnded?(viewAndPoint)
                    // What the menu has not done itself with the finger lifted.
                    finishMenuHighlight(viewAndPoint != nil)
                }
            }
            if let recognizer {
                let original = recognizer.externalUpdated
                recognizer.externalUpdated = { view, point in
                    original?(view, point)
                    if let view {
                        handlePoint(view.convert(point, to: nil), true)
                    }
                }
                let originalEnded = recognizer.externalEnded
                recognizer.externalEnded = { viewAndPoint in
                    state.isFingerDown = false
                    state.lastScrollPoint = nil
                    originalEnded?(viewAndPoint)
                    finishMenuHighlight(viewAndPoint != nil)
                }
            }
        }
        wrap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            wrap()
        }
        
        // A finger dragged over the album after the first one was lifted.
        let handler = AlbumPhotoPanHandler(isOverPhoto: { [weak bubbleNode] point in
            return bubbleNode?.albumPhotoMessage(atWindowPoint: point) != nil
        }, moved: { point in
            handlePoint(point, false)
            moveFocus(point)
        })
        let pan = UIPanGestureRecognizer(target: handler, action: #selector(AlbumPhotoPanHandler.handle(_:)))
        pan.delegate = handler
        pan.cancelsTouchesInView = false
        pan.maximumNumberOfTouches = 1
        controller.view.addGestureRecognizer(pan)
        objc_setAssociatedObject(pan, &albumPhotoPanHandlerKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        // A new press on a photo, after the first finger was lifted, makes that photo the open one too. It only watches the touches, so
        // that nothing else that wants the same touch (the photo itself has recognizers of its own) can take it from it.
        let press = AlbumPhotoPressObserver(isOverPhoto: { [weak bubbleNode] point in
            return bubbleNode?.albumPhotoMessage(atWindowPoint: point) != nil
        }, pressed: { point in
            // A new finger is down on a photo (the first one was lifted): it picks that photo, and keeping it there opens the photo on a
            // card, as keeping the first finger there does.
            state.isFingerDown = true
            // The way from where the first finger was is not a move of this one.
            state.lastPoint = nil
            state.stillPoint = point
            state.stillSince = CACurrentMediaTime()
            handlePoint(point, false)
            moveFocus(point)
        }, released: {
            state.isFingerDown = false
        })
        press.delegate = handler
        controller.view.addGestureRecognizer(press)
        controller.view.addGestureRecognizer(driver)
    }
}

/// What a move of the finger needs to remember between two moves.
private final class AlbumPhotoSwipeState {
    var anchorX: CGFloat?
    var anchorY: CGFloat?
    var lastPoint: CGPoint?
    var generation: Int = 0
}

extension ChatControllerImpl {
    /// While the menu of one photo of an album is open and the finger is still down, a gentle move to the right goes on to the next photo
    /// of the album and a move to the left goes back to the one before it. The photo, the menu and its title change; the reactions stay
    /// as they were (`baseItems`). A long press comes from one of two recognizers, depending on where on the message it started.
    func installAlbumPhotoSwiping(gesture: ContextGesture?, recognizer: TapLongTapOrDoubleTapGestureRecognizer?, controller: ContextController, source: AlbumPhotoContextExtractedContentSource, selection: AlbumPhotoSelection, baseItems: ContextController.Items) {
        let state = AlbumPhotoSwipeState()
        let haptic = HapticFeedback()
        let step: CGFloat = 40.0
        let verticalStep: CGFloat = 70.0
        
        let handle: (UIView?, CGPoint) -> Void = { [weak self, weak controller] view, point in
            guard let self, let controller, let view else {
                return
            }
            let windowPoint = view.convert(point, to: nil)
            // The same move can reach this more than once, when the callback was wrapped more than once.
            if state.lastPoint == windowPoint {
                return
            }
            state.lastPoint = windowPoint
            
            guard let anchorX = state.anchorX, let anchorY = state.anchorY else {
                state.anchorX = windowPoint.x
                state.anchorY = windowPoint.y
                return
            }
            // The card goes up and down with the finger.
            source.setCardOffset(windowPoint.y - anchorY)
            let delta: Int
            if windowPoint.x - anchorX > step {
                delta = 1
            } else if windowPoint.x - anchorX < -step {
                delta = -1
            } else if windowPoint.y - anchorY < -verticalStep {
                // Up goes on to the next photo, down goes back to the one before it.
                delta = 1
            } else if windowPoint.y - anchorY > verticalStep {
                delta = -1
            } else {
                return
            }
            state.anchorX = windowPoint.x
            state.anchorY = windowPoint.y
            guard selection.move(by: delta) else {
                // At either end of the album the card stays where the finger has taken it, and the anchor stays put.
                return
            }
            haptic.tap()
            
            let message = selection.message
            source.switchTo(message: message)
            // The new photo comes to the place the card is in, and the card settles there.
            source.setCardOffset(0.0, animated: true)
            
            state.generation += 1
            let generation = state.generation
            // An answer that comes after the finger has gone on to another photo is dropped, so the menu always shows the last photo.
            let items = albumPhotoContextMenuItems(chatPresentationInterfaceState: self.presentationInterfaceState, context: self.context, message: message, controllerInteraction: self.controllerInteraction, interfaceInteraction: self.interfaceInteraction, photoIndex: selection.index, photoCount: selection.photoMessages.count, albumMessages: selection.allMessages, showsAlbumActions: false, albumActionsToggled: nil, editPhoto: { id in self.editAlbumPhoto(messageId: id) }, editAlbum: { self.openAlbumEditor(messages: selection.allMessages) })
            |> filter { _ in
                return generation == state.generation
            }
            |> map { items -> ContextController.Items in
                var updated = baseItems
                updated.content = items.content
                return updated
            }
            controller.setItems(items, minHeight: nil, animated: false)
        }
        
        // The callback is set by the context menu when it is shown, so it is wrapped once that has happened, and again a moment later in
        // case it had not; the second wrapper repeats what the first one did, which `lastPoint` makes harmless.
        let wrap: () -> Void = { [weak gesture, weak recognizer] in
            if let gesture {
                let original = gesture.externalUpdated
                gesture.externalUpdated = { view, point in
                    original?(view, point)
                    handle(view, point)
                }
                let originalEnded = gesture.externalEnded
                gesture.externalEnded = { value in
                    originalEnded?(value)
                    source.releaseCard()
                }
            }
            if let recognizer {
                let original = recognizer.externalUpdated
                recognizer.externalUpdated = { view, point in
                    original?(view, point)
                    handle(view, point)
                }
                let originalEnded = recognizer.externalEnded
                recognizer.externalEnded = { value in
                    originalEnded?(value)
                    source.releaseCard()
                }
            }
        }
        wrap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            wrap()
        }
    }
}

extension ChatControllerImpl {
    /// The ordinary edit of a message, as the "Edit" of the menu of a message does it: the panel with "Edit Message" and the photo, with
    /// the button that replaces the photo.
    func editAlbumPhoto(messageId: EngineMessage.Id) {
        self.interfaceInteraction?.setupEditMessage(messageId, { _ in })
    }
}

/// The "Edit" of the menu of an album, which is the editing of the text of the message, is "Edit Album" and opens the editor of the photos
/// of the album.
func albumPhotoEditItemRenamed(_ items: ContextController.Items, strings: PresentationStrings, openEditor: (() -> Void)?) -> ContextController.Items {
    guard let openEditor, case let .list(list) = items.content else {
        return items
    }
    var updated = items
    var renamed = list.map { item -> ContextMenuItem in
        if case let .action(action) = item, action.text == strings.Conversation_MessageDialogEdit {
            return .action(ContextMenuActionItem(
                id: action.id,
                text: strings.Conversation_ContextMenuEditAlbum,
                textColor: action.textColor,
                textLayout: action.textLayout,
                textFont: action.textFont,
                icon: action.icon,
                iconSource: action.iconSource,
                iconPosition: action.iconPosition,
                action: { action in
                    action.dismissWithResult(.default)
                    openEditor()
                }
            ))
        }
        return item
    }
    // Reply comes first, Edit Album after it.
    let isReply: (ContextMenuItem) -> Bool = { item in
        if case let .action(action) = item {
            return action.text == strings.Conversation_ContextMenuReply
        }
        return false
    }
    let isEdit: (ContextMenuItem) -> Bool = { item in
        if case let .action(action) = item {
            return action.text == strings.Conversation_ContextMenuEditAlbum
        }
        return false
    }
    if let replyIndex = renamed.firstIndex(where: isReply), let editIndex = renamed.firstIndex(where: isEdit), replyIndex > editIndex {
        let reply = renamed.remove(at: replyIndex)
        renamed.insert(reply, at: editIndex)
    }
    updated.content = .list(renamed)
    return updated
}

extension ChatControllerImpl {
    /// Opens the window in which the photos of an album are looked at and edited: the one that opens when pictures are pasted, with the
    /// list of the chosen pictures ("Message Preview"). The photos of the album are its pictures.
    func openAlbumEditor(messages: [EngineRawMessage]) {
        let photoMessages = messages.filter { $0.effectiveMedia.contains(where: { $0 is TelegramMediaImage }) }.sorted(by: { $0.index < $1.index })
        if photoMessages.isEmpty {
            return
        }
        self.chatDisplayNode.dismissInput()
        
        // The edit of this album is already going on (the window was folded away): it is opened as it was left.
        if let session = self.controllerInteraction?.albumEditSession as? AlbumEditSession, session.messages.map({ $0.id }) == photoMessages.map({ $0.id }) {
            self.presentAlbumEditor(session: session)
            return
        }
        
        // The whole picture of every photo, from the storage when it is there and from the network when it is not.
        var signals: [Signal<(UIImage, String)?, NoError>] = []
        // Which message of the album each picture is of.
        var signalMessageIndices: [Int] = []
        for (messageIndex, message) in photoMessages.enumerated() {
            guard let image = message.effectiveMedia.compactMap({ $0 as? TelegramMediaImage }).first, let largest = largestImageRepresentation(image.representations) else {
                continue
            }
            let mediaBox = self.context.account.postbox.mediaBox
            let fetch = fetchedMediaResource(mediaBox: mediaBox, userLocation: .peer(message.id.peerId), userContentType: .image, reference: AnyMediaReference.message(message: MessageReference(message), media: image).resourceReference(largest.resource))
            |> ignoreValues
            |> `catch` { _ -> Signal<Never, NoError> in
                return .complete()
            }
            let data = mediaBox.resourceData(largest.resource, option: .complete(waitUntilFetchStatus: false))
            |> filter { $0.complete }
            |> take(1)
            |> map { data -> (UIImage, String)? in
                guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: data.path)), let image = UIImage(data: imageData) else {
                    return nil
                }
                return (image, data.path)
            }
            signals.append(data |> runOn(Queue.concurrentDefaultQueue()) |> deliverOnMainQueue)
            signalMessageIndices.append(messageIndex)
            let _ = fetch.startStandalone()
        }
        
        let _ = (combineLatest(signals)
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] images in
            guard let self else {
                return
            }
            var media: [MediaPickerScreenImpl.Subject.Media] = []
            var messageIndexByIdentifier: [String: Int] = [:]
            var imageFiles: [Int: String] = [:]
            for (index, loaded) in images.enumerated() {
                if let (image, path) = loaded, index < signalMessageIndices.count {
                    let item: MediaPickerScreenImpl.Subject.Media = .image(image)
                    media.append(item)
                    messageIndexByIdentifier[item.albumEditIdentifier] = signalMessageIndices[index]
                    imageFiles[signalMessageIndices[index]] = path
                }
            }
            if media.isEmpty {
                return
            }
            // The text of the album and where it is.
            var caption = NSAttributedString()
            var isCaptionAbove = false
            if let captionMessage = photoMessages.first(where: { !$0.text.isEmpty }) {
                caption = chatInputStateStringWithAppliedEntities(captionMessage.text, entities: captionMessage.textEntitiesAttribute?.entities ?? [])
                isCaptionAbove = captionMessage.attributes.contains(where: { $0 is InvertMediaMessageAttribute })
            }
            let session = AlbumEditSession(messages: photoMessages, media: media, caption: caption, isCaptionAbove: isCaptionAbove)
            session.messageIndexByIdentifier = messageIndexByIdentifier
            session.imageFiles = imageFiles
            self.setupAlbumEditSession(session)
            self.presentAlbumEditor(session: session)
        })
    }
    
    /// The session of the edit is kept while the window is open and after it is folded away; the panel in the place of the input panel
    /// asks the session to open the window, to save the changes, or to throw them away.
    private func setupAlbumEditSession(_ session: AlbumEditSession) {
        self.controllerInteraction?.albumEditSession = session
        session.openRequested = { [weak self, weak session] in
            guard let self, let session else {
                return
            }
            self.openAlbumEditor(messages: session.messages)
        }
        session.applyRequested = { [weak self, weak session] in
            guard let self, let session else {
                return
            }
            session.isFinishing = true
            session.isBarVisible = false
            self.applyAlbumEdit(session: session)
            self.finishAlbumEditSession()
        }
        session.discardRequested = { [weak self, weak session] in
            session?.isBarVisible = false
            session?.isFinishing = true
            self?.finishAlbumEditSession()
        }
    }
    
    /// The edit is over: the input panel is in its place again.
    fileprivate func finishAlbumEditSession() {
        self.controllerInteraction?.albumEditSession = nil
        self.refreshAlbumEditPanel(transition: .animated(duration: 0.25, curve: .easeInOut))
    }
    
    /// The window is folded away: the changes that were made wait in the place of the input panel, or, when there are none, there is
    /// nothing to wait for.
    private func foldAlbumEditSession(_ session: AlbumEditSession) {
        session.isBarVisible = session.changeCount > 0
        if !session.isBarVisible {
            self.controllerInteraction?.albumEditSession = nil
        }
        // At once, at the moment the window starts to fold away.
        self.refreshAlbumEditPanel(transition: .immediate)
    }
    
    fileprivate func refreshAlbumEditPanel(transition: ContainedViewLayoutTransition = .animated(duration: 0.4, curve: .spring)) {
        self.updateChatPresentationInterfaceState(transition: transition, interactive: false, force: true, { $0 })
    }
    
    /// Opens the window of the edit with what the session has: the pictures in their order, the text, and the audio file.
    private func presentAlbumEditor(session: AlbumEditSession) {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
            return
        }
        session.isFinishing = false
        let media = session.order.compactMap { session.mediaById[$0] }
        if media.isEmpty {
            return
        }
        let pickerBox = AlbumEditorPickerBox()
        pickerBox.session = session
        let controller = mediaPasteboardScreen(
            context: self.context,
            updatedPresentationData: self.updatedPresentationData,
            peer: EnginePeer(peer),
            subjects: media,
            isAlbumEditing: true,
            presentMediaPicker: { [weak self] subject, _, _, _, present in
                guard let self else {
                    return
                }
                let title = self.presentationData.strings.Conversation_ContextMenuEditAlbum
                self.presentMediaPicker(subject: subject, saveEditedPhotos: false, bannedSendPhotos: nil, bannedSendVideos: nil, enableMultiselection: true, isEditingMessage: true, title: title, present: { controller, mediaPickerContext in
                    pickerBox.picker = controller
                    session.setBaseline(controller.albumEditIdentifiers())
                    // An album cannot take more pictures than it has messages: the places are what it had, and a picture can be added only
                    // in the place of one that was taken away.
                    controller.albumEditSlotCount = session.originalIdentifiers.count
                    // What the picker has is copied into the session at every change, so that it is there when the window goes.
                    controller.albumEditChanged = { [weak controller] in
                        guard let controller, !session.isFinishing else {
                            return
                        }
                        let state = controller.albumCaptionState
                        session.caption = state.text
                        session.isCaptionAbove = state.isAbove
                        session.audio = controller.albumAudioState
                        let order = controller.albumEditIdentifiers()
                        if !order.isEmpty {
                            session.order = order
                        }
                    }
                    // A picture was ticked or unticked: the attachment button is there while the album has a free place.
                    controller.albumEditSelectionChanged = { [weak controller] in
                        guard let controller, !session.isFinishing else {
                            return
                        }
                        let order = controller.albumEditIdentifiers()
                        if !order.isEmpty {
                            session.order = order
                        }
                        pickerBox.attachmentController?.isAlbumAttachVisible = session.originalIdentifiers.count > order.count
                    }
                    // The close button at the top asks whether to throw the changes away: yes, and they are gone and the window closes; no, and
                    // the window stays as it is. (Pulling the window down is not this: it folds the window away, and the changes wait in the
                    // place of the input panel.)
                    controller.albumEditCloseRequested = { [weak controller] in
                        guard let controller else {
                            return
                        }
                        let state = controller.albumCaptionState
                        session.caption = state.text
                        session.isCaptionAbove = state.isAbove
                        let order = controller.albumEditIdentifiers()
                        if !order.isEmpty {
                            session.order = order
                        }
                        let discard = {
                            session.discardRequested?()
                            pickerBox.attachmentController?.dismiss(animated: true)
                        }
                        if session.changeCount == 0 {
                            discard()
                            return
                        }
                        let strings = self.presentationData.strings
                        self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: nil, text: strings.Conversation_AlbumEdit_DiscardAlertText, actions: [
                            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                            TextAlertAction(type: .destructiveAction, title: strings.Conversation_AlbumEdit_DiscardAlertDiscard, action: {
                                discard()
                            })
                        ]), in: .window(.root))
                    }
                    // The blue button at the top saves the changes, and closes the window.
                    controller.albumEditApplied = { [weak controller] in
                        if let controller {
                            let state = controller.albumCaptionState
                            session.caption = state.text
                            session.isCaptionAbove = state.isAbove
                            let order = controller.albumEditIdentifiers()
                            if !order.isEmpty {
                                session.order = order
                            }
                        }
                        session.isFinishing = true
                        self.applyAlbumEdit(session: session)
                        self.finishAlbumEditSession()
                        pickerBox.attachmentController?.dismiss(animated: true)
                    }
                    // The text of the album and its place, and the audio file, as the session has them.
                    if session.caption.length != 0 {
                        mediaPickerContext?.setCaption(session.caption)
                    }
                    if session.isCaptionAbove {
                        mediaPickerContext?.setCaptionIsAboveMedia(true)
                    }
                    if let audio = session.audio {
                        controller.setAlbumAudio(title: audio.title, subtitle: audio.subtitle)
                    }
                    present(controller, mediaPickerContext)
                }, updateMediaPickerContext: { _ in }, completion: { _, _, _, _, _, _, completion in
                    completion()
                })
            },
            getSourceRect: nil,
            customEmojiAvailable: self.presentationInterfaceState.customEmojiAvailable
        )
        controller.navigationPresentation = .flatModal
        if let attachmentController = controller as? AttachmentController {
            pickerBox.attachmentController = attachmentController
            attachmentController.isAlbumAttachVisible = session.originalIdentifiers.count > session.order.count
            attachmentController.albumAttachPressed = { _ in
                self.presentAlbumAttachmentMenu(pickerBox: pickerBox)
            }
            // The window is folded away (by a swipe down, or by its close button): the changes that were made wait in the place of the
            // input panel, or, when there are none, the window just goes.
            attachmentController.willDismiss = { [weak pickerBox] in
                guard !session.isFinishing else {
                    return
                }
                if let picker = pickerBox?.picker {
                    let order = picker.albumEditIdentifiers()
                    if !order.isEmpty {
                        session.order = order
                    }
                    let state = picker.albumCaptionState
                    session.caption = state.text
                    session.isCaptionAbove = state.isAbove
                    session.audio = picker.albumAudioState
                }
                self.foldAlbumEditSession(session)
            }
            // If the window went without telling beforehand, the panel is brought here, with what the session has.
            attachmentController.didDismiss = {
                if !session.isFinishing && !session.isBarVisible {
                    self.foldAlbumEditSession(session)
                }
            }
        }
        self.push(controller)
    }
}

/// The picture window of the editing of an album, which is held without being kept alive.
private final class AlbumEditorPickerBox {
    weak var picker: MediaPickerScreenImpl?
    weak var attachmentController: AttachmentController?
    var session: AlbumEditSession?
}

extension ChatControllerImpl {
    /// The attachment button in the window that edits an album opens the attachment window of the chat, with the things that can be
    /// added to an album: for now more pictures, which join the album, and an audio file, which is attached under its pictures.
    fileprivate func presentAlbumAttachmentMenu(pickerBox: AlbumEditorPickerBox) {
        // The free places of the album: the pictures it had, less the ones it has now.
        let capacity = max(0, (pickerBox.session?.originalIdentifiers.count ?? 0) - (pickerBox.picker?.albumEditIdentifiers().count ?? 0))
        let addImages: ([UIImage], Bool) -> Void = { images, highQuality in
            // Only as many pictures as there are free places.
            let media: [MediaPickerScreenImpl.Subject.Media] = images.prefix(capacity).map { .image($0) }
            for item in media {
                pickerBox.session?.mediaById[item.albumEditIdentifier] = item
                if highQuality {
                    pickerBox.session?.highQualityIdentifiers.insert(item.albumEditIdentifier)
                }
            }
            pickerBox.picker?.addMedia(media)
            // When the album has all its places again, the attachment button goes away.
            if let session = pickerBox.session, let picker = pickerBox.picker {
                pickerBox.attachmentController?.isAlbumAttachVisible = session.originalIdentifiers.count > picker.albumEditIdentifiers().count
            }
        }
        self.presentAttachmentMenu(subject: .albumAdd(capacity: capacity, added: { [weak self] addition in
            guard let self else {
                return
            }
            switch addition {
            case let .photos(assets, highQuality):
                self.loadAlbumImages(assets, completion: { images in
                    addImages(images, highQuality)
                })
            case let .images(images):
                addImages(images, false)
            case let .audio(mediaReferences):
                guard let file = mediaReferences.first?.media as? TelegramMediaFile else {
                    return
                }
                var title = file.fileName ?? ""
                for attribute in file.attributes {
                    if case let .Audio(_, _, audioTitle, performer, _) = attribute {
                        if let audioTitle, !audioTitle.isEmpty {
                            title = performer.flatMap { $0.isEmpty ? audioTitle : "\($0) - \(audioTitle)" } ?? audioTitle
                        }
                    }
                }
                let subtitle = dataSizeString(Int64(file.size ?? 0), formatting: DataSizeStringFormatting(presentationData: self.presentationData))
                pickerBox.picker?.setAlbumAudio(title: title, subtitle: subtitle)
            }
        }))
    }
    
    /// The pictures that the camera returned as legacy signals (photos only: a video does not go into an album).
    func albumImages(fromLegacySignals signals: [Any], completion: @escaping ([UIImage]) -> Void) {
        let _ = (legacyAssetPickerEnqueueMessages(context: self.context, account: self.context.account, signals: signals)
        |> deliverOnMainQueue).startStandalone(next: { messages in
            var images: [UIImage] = []
            for message in messages {
                guard case let .message(_, _, _, mediaReference, _, _, _, _, _, _) = message.message,
                      let image = mediaReference?.media as? TelegramMediaImage,
                      let resource = largestImageRepresentation(image.representations)?.resource as? LocalFileReferenceMediaResource,
                      let picture = UIImage(contentsOfFile: resource.localFilePath) else {
                    continue
                }
                images.append(picture)
            }
            if !images.isEmpty {
                completion(images)
            }
        })
    }
    
    /// The pictures of the photos that were chosen in the gallery, as they are on the phone.
    private func loadAlbumImages(_ assets: [PHAsset], completion: @escaping ([UIImage]) -> Void) {
        final class Result {
            var images: [Int: UIImage] = [:]
        }
        let result = Result()
        let group = DispatchGroup()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        for (index, asset) in assets.enumerated() where asset.mediaType == .image {
            group.enter()
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 2560.0, height: 2560.0), contentMode: .aspectFit, options: options, resultHandler: { image, _ in
                DispatchQueue.main.async {
                    if let image {
                        result.images[index] = image
                    }
                    group.leave()
                }
            })
        }
        group.notify(queue: .main) {
            completion(assets.indices.compactMap { result.images[$0] })
        }
    }
}

/// One place of the album as the user left it: a picture the album already has (by the place it had), or a picture that was added.
private enum AlbumEditItem {
    case existing(Int)
    case new(UIImage, highQuality: Bool)
    
    func isExisting(_ index: Int) -> Bool {
        if case let .existing(value) = self {
            return value == index
        }
        return false
    }
}

/// A picture of the phone as a picture that can be sent.
private func albumEditLocalImage(_ image: UIImage, highQuality: Bool) -> TelegramMediaImage? {
    var randomId: Int64 = 0
    arc4random_buf(&randomId, 8)
    let maxSide: CGFloat = highQuality ? 2560.0 : 1280.0
    let scaledSize = image.size.aspectFittedOrSmaller(CGSize(width: maxSide, height: maxSide))
    guard let scaledImage = TGScaleImageToPixelSize(image, scaledSize) else {
        return nil
    }
    let tempFile = EngineTempBox.shared.tempFile(fileName: "file")
    defer {
        EngineTempBox.shared.dispose(tempFile)
    }
    guard let data = compressImageToJPEG(scaledImage, quality: 0.6, tempFilePath: tempFile.path) else {
        return nil
    }
    let path = NSTemporaryDirectory() + "\(randomId).jpeg"
    guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else {
        return nil
    }
    let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: randomId)
    let representation = TelegramMediaImageRepresentation(dimensions: PixelDimensions(scaledSize), resource: resource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
    return TelegramMediaImage(imageId: EngineMedia.Id(namespace: Namespaces.Media.LocalImage, id: randomId), representations: [representation], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
}

/// A picture that is already on the phone as a file (the file of a picture of the album), as a picture that can be sent: the same bytes,
/// without being compressed again.
private func albumEditLocalImage(copyOfFileAt sourcePath: String, dimensions: PixelDimensions) -> TelegramMediaImage? {
    var randomId: Int64 = 0
    arc4random_buf(&randomId, 8)
    let path = NSTemporaryDirectory() + "\(randomId).jpeg"
    guard (try? FileManager.default.copyItem(atPath: sourcePath, toPath: path)) != nil else {
        return nil
    }
    let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: randomId)
    let representation = TelegramMediaImageRepresentation(dimensions: dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
    return TelegramMediaImage(imageId: EngineMedia.Id(namespace: Namespaces.Media.LocalImage, id: randomId), representations: [representation], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
}

extension ChatControllerImpl {
    /// Saves the changes that were made to an album in the window that edits it. Telegram has no way to put a message into an album that
    /// is sent, or to move one inside it: the places of an album are its messages, in the order they were sent. So the album keeps the
    /// places it had (the window lets a picture be added only in the place of one that was taken away), and its messages are kept:
    /// a message whose picture is not wanted any more is deleted, and a message that is to show another picture (the picture of another
    /// place, or a picture that was added) is edited, once. The choice of the messages to delete is the one that needs the fewest edits.
    /// The text and its place are saved too. Nothing is sent when nothing changed. An audio file that was added is not saved.
    func applyAlbumEdit(session: AlbumEditSession) {
        let messages = session.messages.sorted(by: { $0.index < $1.index })
        guard !messages.isEmpty else {
            return
        }
        
        // The pictures as they are to be.
        var items: [AlbumEditItem] = []
        for identifier in session.order {
            if let index = session.messageIndexByIdentifier[identifier], index < messages.count {
                items.append(.existing(index))
            } else if let media = session.mediaById[identifier], case let .image(image) = media {
                items.append(.new(image, highQuality: session.highQualityIdentifiers.contains(identifier)))
            }
        }
        // An album cannot be left without its pictures.
        guard !items.isEmpty else {
            return
        }
        
        // The text.
        let text = session.caption.string
        let entities = generateTextEntities(text, enabledTypes: .all, currentEntities: generateChatInputTextEntities(session.caption))
        let originalCaptionIndex = messages.lastIndex(where: { !$0.text.isEmpty })
        
        // An album cannot take more pictures than it has messages (the window does not let it), so the extra ones, if there are any, are left.
        if items.count > messages.count {
            items = Array(items.prefix(messages.count))
        }
        
        // The messages that are not needed any more are the ones whose pictures are not wanted. When there are more of them than the
        // album loses places, the others show the pictures that were added.
        var wantedIndices = Set<Int>()
        for item in items {
            if case let .existing(index) = item {
                wantedIndices.insert(index)
            }
        }
        let removable = messages.indices.filter { !wantedIndices.contains($0) }
        let deleteCount = messages.count - items.count
        
        func cost(of deleted: Set<Int>) -> Double {
            let survivors = messages.indices.filter { !deleted.contains($0) }
            var result = 0.0
            for (slot, survivor) in survivors.enumerated() where slot < items.count {
                if !items[slot].isExisting(survivor) {
                    result += 1.0
                }
            }
            // The message that has the text is kept when it can be, and the later ones go first.
            if let originalCaptionIndex, deleted.contains(originalCaptionIndex) {
                result += 0.5
            }
            for index in deleted {
                result -= Double(index) * 0.001
            }
            return result
        }
        var best: (deleted: Set<Int>, cost: Double)?
        func choose(from position: Int, picked: [Int]) {
            if picked.count == deleteCount {
                let deleted = Set(picked)
                let value = cost(of: deleted)
                if best == nil || value < best!.cost {
                    best = (deleted, value)
                }
                return
            }
            if position >= removable.count || removable.count - position < deleteCount - picked.count {
                return
            }
            choose(from: position + 1, picked: picked + [removable[position]])
            choose(from: position + 1, picked: picked)
        }
        choose(from: 0, picked: [])
        let deleted = best?.deleted ?? Set()
        let survivors = messages.indices.filter { !deleted.contains($0) }
        guard survivors.count == items.count else {
            return
        }
        
        // The message that carries the text: the one that had it, when it is still there.
        let holderIndex: Int
        if let originalCaptionIndex, survivors.contains(originalCaptionIndex) {
            holderIndex = originalCaptionIndex
        } else {
            holderIndex = survivors[survivors.count - 1]
        }
        
        var editCount = 0
        for (slot, survivor) in survivors.enumerated() {
            let message = messages[survivor]
            let isHolder = survivor == holderIndex
            
            var mediaReference: AnyMediaReference?
            switch items[slot] {
            case let .existing(source):
                // The picture of another message is sent as a copy of its file, not by its reference: the other message may be edited at
                // the same moment (two pictures that change places), and a reference to a picture that is no longer there cannot be used.
                if source != survivor, let image = messages[source].effectiveMedia.compactMap({ $0 as? TelegramMediaImage }).first {
                    if let path = session.imageFiles[source], let dimensions = largestImageRepresentation(image.representations)?.dimensions, let media = albumEditLocalImage(copyOfFileAt: path, dimensions: dimensions) {
                        mediaReference = .standalone(media: media)
                    } else {
                        mediaReference = .message(message: MessageReference(messages[source]), media: image)
                    }
                }
            case let .new(image, highQuality):
                if let media = albumEditLocalImage(image, highQuality: highQuality) {
                    mediaReference = .standalone(media: media)
                }
            }
            
            let messageText = isHolder ? text : ""
            let previousEntities = message.textEntitiesAttribute?.entities ?? []
            let textChanged = isHolder ? (text != message.text || entities != previousEntities) : !message.text.isEmpty
            let wasCaptionAbove = message.attributes.contains(where: { $0 is InvertMediaMessageAttribute })
            let positionChanged = session.isCaptionAbove != wasCaptionAbove
            if mediaReference == nil && !textChanged && !positionChanged {
                continue
            }
            editCount += 1
            let media: RequestEditMessageMedia
            if let mediaReference {
                media = .update(mediaReference)
            } else {
                media = .keep
            }
            let _ = (self.context.engine.messages.requestEditMessage(
                messageId: message.id,
                text: messageText,
                media: media,
                entities: isHolder && !entities.isEmpty ? TextEntitiesMessageAttribute(entities: entities) : nil,
                richText: nil,
                inlineStickers: [:],
                webpagePreviewAttribute: nil,
                invertMediaAttribute: session.isCaptionAbove ? InvertMediaMessageAttribute() : nil,
                disableUrlPreview: false
            )
            |> deliverOnMainQueue).startStandalone()
        }
        
        if !deleted.isEmpty {
            let ids = deleted.sorted().map { messages[$0].id }
            let _ = self.context.engine.messages.deleteMessagesInteractively(messageIds: ids, type: .forEveryone).startStandalone()
        }
    }
}
