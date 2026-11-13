import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext
import ScreenCaptureDetection
import UndoUI
import ChatMessageItem
import ChatMessageItemView
import PostShareImageScreen
import BetaFeatures

extension ChatControllerImpl {
    /// After a screenshot of a one-to-one chat, offers to share the captured messages as an edited image
    /// ("Screenshot taken" toast, "Customize" opens the editor). Only private dialogs with a person: not groups,
    /// channels, bots or Saved Messages, and not secret chats, where the screenshot is reported to the other side.
    func setupScreenshotShareIfNeeded() {
        guard BetaFeatures.isEnabled(.customizeScreenshot), self.screenshotShareDisposable == nil, case let .peer(peerId) = self.chatLocation, peerId.namespace == Namespaces.Peer.CloudUser, peerId != self.context.account.peerId else {
            return
        }
        self.screenshotShareDisposable = (screenCaptureEvents()
        |> deliverOnMainQueue).startStrict(next: { [weak self] event in
            guard let self, case .still = event, self.traceVisibility() else {
                return
            }
            if let user = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramUser, user.botInfo != nil {
                return
            }
            self.screenshotTaken()
        })
    }

    /// The bubbles on screen when the screenshot was taken, oldest first; an album is one item.
    private func capturedScreenshotItems() -> [[EngineMessage]] {
        var items: [(index: EngineMessage.Index, messages: [EngineMessage])] = []
        self.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
            guard let item = itemNode.item else {
                return
            }
            var messages: [EngineMessage] = []
            switch item.content {
            case let .message(message, _, _, _, _):
                messages.append(EngineMessage(message))
            case let .group(groupMessages):
                messages.append(contentsOf: groupMessages.map { EngineMessage($0.0) })
            }
            if !messages.isEmpty {
                items.append((item.content.index, messages))
            }
        }
        items.sort(by: { $0.index < $1.index })
        return items.map(\.messages)
    }

    private func screenshotTaken() {
        let items = self.capturedScreenshotItems()
        if items.isEmpty {
            return
        }
        // Copy-protected content must not be re-shared from the app.
        if self.presentationInterfaceState.copyProtectionEnabled || items.contains(where: { $0.contains(where: { $0._asMessage().isCopyProtected() }) }) {
            return
        }

        let presentationData = self.presentationData
        self.present(UndoOverlayController(
            presentationData: presentationData,
            content: .info(title: "Screenshot taken", text: "Hide messages or cut text", timeout: 5.0, customUndoText: "Customize"),
            elevatedLayout: false,
            appearance: UndoOverlayController.Appearance(hidesIcon: true),
            action: { [weak self] action in
                if case .undo = action {
                    self?.openScreenshotShareEditor(items: items)
                }
                return false
            }
        ), in: .current)
    }

    private func openScreenshotShareEditor(items: [[EngineMessage]]) {
        self.chatDisplayNode.dismissInput()
        self.push(PostShareImageScreen(context: self.context, content: PostShareScreenshotContent(items: items, sent: { [weak self] peerIds, count in
            self?.presentScreenshotSentToast(peerIds: peerIds, count: count)
        })))
    }

    /// "Screenshot sent to X", worded like the forward toast ("Message forwarded to X").
    private func presentScreenshotSentToast(peerIds: [EnginePeer.Id], count: Int) {
        let _ = (self.context.engine.data.get(
            EngineDataList(
                peerIds.map(TelegramEngine.EngineData.Item.Peer.RenderedPeer.init)
            )
        )
        |> deliverOnMainQueue).startStandalone(next: { [weak self] peerList in
            guard let self else {
                return
            }
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            let peers = peerList.compactMap { $0?.chatOrMonoforumMainPeer }
            func name(_ peer: EnginePeer) -> String {
                let title = peer.id == self.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                return title.replacingOccurrences(of: "**", with: "")
            }
            let subject = count == 1 ? "Screenshot" : "Screenshots"
            let savedMessages = peerIds.count == 1 && peerIds.first == self.context.account.peerId
            let text: String
            if savedMessages {
                text = "\(subject) saved to **Saved Messages**"
            } else if peers.count == 1, let peer = peers.first {
                text = "\(subject) sent to **\(name(peer))**"
            } else if peers.count == 2 {
                text = "\(subject) sent to **\(name(peers[0]))** and **\(name(peers[1]))**"
            } else if let peer = peers.first {
                text = "\(subject) sent to **\(name(peer))** and \(peers.count - 1) others"
            } else {
                return
            }
            self.present(UndoOverlayController(
                presentationData: presentationData,
                content: .forward(savedMessages: savedMessages, text: text),
                elevatedLayout: false,
                animateInAsReplacement: true,
                action: { _ in return false }
            ), in: .current)
        })
    }
}
