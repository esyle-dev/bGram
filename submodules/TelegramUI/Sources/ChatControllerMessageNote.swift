import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import AccountContext
import TextFormat
import ChatMessageItemView
import ChatMessageBubbleItemNode
import ChatMessageBubbleContentNode
import ChatMessageTextBubbleContentNode
import ChatTextLinkEditUI
import ChatPresentationInterfaceState
import MessageNoteEditorScreen
import Photos
import SwiftSignalKit
import AttachmentUI
import PresentationDataUtils

extension ChatControllerImpl {
    /// Shows the tooltip of a message note whose anchor was tapped. `sourceNode`/`sourceRect` is the anchor's rect on the
    /// tapped line.
    func displayMessageNote(messageId: EngineMessage.Id, noteUrl: String, sourceNode: ASDisplayNode, sourceRect: CGRect?) {
        guard let note = MessageNoteContent(url: noteUrl) else {
            return
        }

        if let current = self.messageNoteTooltipController {
            self.messageNoteTooltipController = nil
            current.dismiss()
        }

        var anchorRect = sourceNode.view.convert(sourceNode.view.bounds, to: nil)
        if let sourceRect {
            anchorRect = sourceNode.view.convert(sourceRect, to: nil)
        }

        // The tooltip flips below the anchor when it does not fit under the navigation bar.
        var topLimit: CGFloat = 8.0
        if let navigationBar = self.navigationBar {
            topLimit = navigationBar.view.convert(navigationBar.view.bounds, to: nil).maxY + 4.0
        }

        let tooltipScreen = MessageNoteTooltipScreen(presentationData: self.presentationData, note: note, anchorRect: anchorRect, topLimit: topLimit, actions: MessageNoteTooltipScreen.Actions(
            loadLinkCard: { [weak self] url, completion in
                self?.loadMessageNoteLinkCard(url: url, completion: completion)
            },
            openUrl: { [weak self] url in
                self?.openUrl(url, concealed: false)
            },
            passesTouchThrough: { [weak self] point in
                // A tap on another annotation's anchor goes through, so that one opens at once; a tap on this one
                // only closes the tooltip.
                guard let self, let tappedUrl = self.messageNoteUrlAtWindowPoint(point) else {
                    return false
                }
                return tappedUrl != noteUrl
            }
        ))
        tooltipScreen.becameDismissed = { [weak self, weak tooltipScreen] in
            if let self, let tooltipScreen, self.messageNoteTooltipController === tooltipScreen {
                self.messageNoteTooltipController = nil
            }
        }
        self.messageNoteTooltipController = tooltipScreen
        self.present(tooltipScreen, in: .current)
    }

    /// The link preview card of a URL, from Telegram's webpage preview.
    func loadMessageNoteLinkCard(url: String, completion: @escaping (MessageNoteLinkCard?) -> Void) {
        let _ = (webpagePreview(account: self.context.account, urls: [url])
        |> filter { result in
            if case .progress = result {
                return false
            }
            return true
        }
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { result in
            guard case let .result(value) = result, let value, case let .Loaded(content) = value.webpage.content else {
                completion(nil)
                return
            }
            let domain = URL(string: content.url)?.host ?? content.displayUrl
            completion(MessageNoteLinkCard(url: url, domain: domain, title: content.title ?? content.websiteName, text: content.text))
        })
    }

    /// The note URL of the anchor under a point in window coordinates, if a visible message has one there.
    private func messageNoteUrlAtWindowPoint(_ point: CGPoint) -> String? {
        var result: String?
        self.chatDisplayNode.historyNode.forEachVisibleItemNode { itemNode in
            guard result == nil, let itemNode = itemNode as? ChatMessageBubbleItemNode else {
                return
            }
            for contentNode in itemNode.contentNodes {
                guard let contentNode = contentNode as? ChatMessageTextBubbleContentNode else {
                    continue
                }
                let localPoint = contentNode.view.convert(point, from: nil)
                guard contentNode.bounds.contains(localPoint) else {
                    continue
                }
                let action = contentNode.tapActionAtPoint(localPoint, gesture: .tap, isEstimating: true)
                if case let .tooltip(text, _, _) = action.content, MessageNoteContent.isNoteUrl(text) {
                    result = text
                    return
                }
            }
        }
        return result
    }

    /// Format › Annotations: opens the annotation editor for the input field's selection and applies the result as a hidden
    /// `tg://note` link over the trimmed selection.
    func openMessageNoteEditing() {
        guard let textInputPanelNode = self.chatDisplayNode.textInputPanelNode else {
            return
        }

        var anchorRect = textInputPanelNode.view.convert(textInputPanelNode.view.bounds, to: nil)
        if let caretRect = textInputPanelNode.currentCaretRect(in: self.view) {
            anchorRect = self.view.convert(caretRect, to: nil)
        }

        let actions = MessageNoteEditorScreen.Actions(
            requestLink: { [weak self] currentUrl, completion in
                guard let self else {
                    return
                }
                let controller = chatTextLinkEditController(context: self.context, updatedPresentationData: self.updatedPresentationData, text: "Add a link to the annotation.", link: currentUrl, apply: { link, _ in
                    completion(link)
                })
                self.present(controller, in: .window(.root))
            },
            requestPhoto: { [weak self] completion in
                self?.requestMessageNotePhoto(completion: completion)
            },
            loadLinkCard: { [weak self] url, completion in
                self?.loadMessageNoteLinkCard(url: url, completion: completion)
            },
            confirm: { [weak self] text, actionTitle, completion in
                guard let self else {
                    return
                }
                let strings = self.presentationData.strings
                self.present(textAlertController(context: self.context, title: nil, text: text, actions: [
                    TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {
                        completion(false)
                    }),
                    TextAlertAction(type: .defaultAction, title: actionTitle, action: {
                        completion(true)
                    })
                ]), in: .window(.root))
            }
        )
        let language = self.presentationData.strings.baseLanguageCode

        // The native rich-text editor owns its document: read and apply the link through its API.
        if let richNode = textInputPanelNode.richTextInputNode, richNode.usesNativeRichTextEngine {
            let anchorText = richNode.selectedRichText().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !anchorText.isEmpty else {
                return
            }
            let initialNote = richNode.currentRichTextLinkURL().flatMap { MessageNoteContent(url: $0) }
            let aiContext = MessageNoteEditorScreen.AIContext(anchor: anchorText, messageText: anchorText, language: language)
            let controller = MessageNoteEditorScreen(presentationData: self.presentationData, initialNote: initialNote, anchorRect: anchorRect, aiContext: aiContext, actions: actions, completion: { [weak richNode] result in
                guard let richNode else {
                    return
                }
                switch result {
                case let .save(note):
                    richNode.applyRichTextLink(note.url)
                case .remove:
                    richNode.applyRichTextLink(nil)
                case .cancel:
                    break
                }
            })
            self.present(controller, in: .window(.root))
            return
        }

        let inputState = self.presentationInterfaceState.interfaceState.effectiveInputState
        let inputText = inputState.inputText
        let selection = NSRange(location: inputState.selectionRange.lowerBound, length: inputState.selectionRange.count)
        guard selection.location + selection.length <= inputText.length, let anchorRange = messageNoteTrimmedRange(text: inputText.string, range: selection) else {
            return
        }
        var initialNote: MessageNoteContent?
        inputText.enumerateAttribute(ChatTextInputAttributes.textUrl, in: anchorRange, options: []) { value, range, _ in
            if range == anchorRange, let value = value as? ChatTextInputTextUrlAttribute {
                initialNote = MessageNoteContent(url: value.url)
            }
        }
        let selectionRange = anchorRange.location ..< (anchorRange.location + anchorRange.length)

        // The annotated words stay highlighted in the input field while the editor is open; the tail points at them.
        let highlight = MessageNoteInputHighlight(inputView: textInputPanelNode.richTextInputNode?.inputView, range: anchorRange, color: self.presentationData.theme.chat.inputPanel.panelControlAccentColor.withAlphaComponent(0.2))
        if let highlightRect = highlight.rect {
            anchorRect = highlightRect
        }

        let aiContext = MessageNoteEditorScreen.AIContext(anchor: (inputText.string as NSString).substring(with: anchorRange), messageText: inputText.string, language: language)
        let controller = MessageNoteEditorScreen(presentationData: self.presentationData, initialNote: initialNote, anchorRect: anchorRect, aiContext: aiContext, actions: actions, completion: { [weak self] result in
            highlight.remove()
            guard let self else {
                return
            }
            switch result {
            case let .save(note):
                self.interfaceInteraction?.updateTextInputStateAndMode { current, inputMode in
                    return (chatTextInputAddLinkAttribute(current, selectionRange: selectionRange, url: note.url), inputMode)
                }
            case .remove:
                self.interfaceInteraction?.updateTextInputStateAndMode { current, inputMode in
                    return (chatTextInputRemoveLinkAttribute(current, selectionRange: selectionRange), inputMode)
                }
            case .cancel:
                break
            }
            // Back to the message, the caret after the anchor.
            self.updateChatPresentationInterfaceState(animated: false, interactive: true, {
                return $0.updatedInterfaceState({
                    $0.withUpdatedEffectiveInputState(ChatTextInputState(inputText: $0.effectiveInputState.inputText, selectionRange: selectionRange.upperBound ..< selectionRange.upperBound))
                })
            })
            self.chatDisplayNode.textInputPanelNode?.ensureFocused()
        })
        self.present(controller, in: .window(.root))
    }
}

extension ChatControllerImpl {
    /// Telegram's media picker for one photo (gallery or web search); the completion gets nil on cancel.
    func requestMessageNotePhoto(completion: @escaping (UIImage?) -> Void) {
        var didComplete = false
        let complete: (UIImage?) -> Void = { image in
            if !didComplete {
                didComplete = true
                completion(image)
            }
        }
        let controller = self.context.sharedContext.makeMediaPickerScreen(context: self.context, hasSearch: true, completion: { result in
            if let asset = result as? PHAsset {
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                options.isSynchronous = false
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1280.0, height: 1280.0), contentMode: .aspectFit, options: options, resultHandler: { image, _ in
                    Queue.mainQueue().async {
                        complete(image)
                    }
                })
            } else if let image = result as? UIImage {
                complete(image)
            } else {
                complete(nil)
            }
        })
        if let attachmentController = controller as? AttachmentController {
            let previousDidDismiss = attachmentController.didDismiss
            attachmentController.didDismiss = {
                previousDidDismiss()
                // Cancelled: nothing was picked. A pick completes first, so this is then a no-op.
                Queue.mainQueue().after(0.5) {
                    complete(nil)
                }
            }
        }
        self.push(controller)
    }
}

/// A temporary highlight over a range of the legacy input field (the text view itself is untouched).
private final class MessageNoteInputHighlight {
    private var views: [UIView] = []
    /// The highlighted text's rect on its first line, in window coordinates.
    private(set) var rect: CGRect?

    init(inputView: UIView?, range: NSRange, color: UIColor) {
        guard let textView = inputView.flatMap(findTextView), let start = textView.position(from: textView.beginningOfDocument, offset: range.location), let end = textView.position(from: start, offset: range.length), let textRange = textView.textRange(from: start, to: end) else {
            return
        }
        let rects = textView.selectionRects(for: textRange).map(\.rect).filter { $0.width > 0.0 && $0.height > 0.0 }
        for rect in rects {
            let view = UIView(frame: rect.insetBy(dx: -2.0, dy: 0.0))
            view.backgroundColor = color
            view.layer.cornerRadius = 4.0
            view.isUserInteractionEnabled = false
            textView.insertSubview(view, at: 0)
            self.views.append(view)
        }
        if let first = rects.first {
            self.rect = textView.convert(first, to: nil)
        }
    }

    func remove() {
        for view in self.views {
            view.removeFromSuperview()
        }
        self.views.removeAll()
    }
}

private func findTextView(_ view: UIView) -> UITextView? {
    if let textView = view as? UITextView {
        return textView
    }
    for subview in view.subviews {
        if let result = findTextView(subview) {
            return result
        }
    }
    return nil
}
