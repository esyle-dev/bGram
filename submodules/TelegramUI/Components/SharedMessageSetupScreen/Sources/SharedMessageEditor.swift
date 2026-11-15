import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import AccountContext
import TelegramUIPreferences
import AppBundle
import AvatarNode
import ContextUI
import UndoUI
import TextFormat
import TelegramStringFormatting
import RichTextEditorCore
import RichTextAttachmentScreen
import ChatRichTextEditorComposer
import RichTextEditorMessageConversion

/// The editor palette: one colour per editor, by order of first participation.
private let sharedEditorColors: [UInt32] = [0xf09a37, 0x4fb256, 0x8b5cf6, 0xe5533d, 0x3b82f6, 0x14b8a6, 0xec4899]

/// Opens a shared message in the rich-text editor as a shared editor: everyone's changes arrive while
/// it is open, the account's own changes are saved as typed, and Done just leaves.
public func openSharedMessageEditor(
    context: AccountContext,
    navigationController: NavigationController,
    message: EngineMessage,
    presentAttachmentMenu: ((_ request: RichTextAttachmentScreen.MediaRequest, @escaping ([RichTextAttachmentScreen.RichTextAttachment]) -> Void) -> Void)?,
    presentFormulaEditor: ((_ initialValue: String?, _ completion: @escaping (String) -> Void) -> Void)?,
    replyInChat: ((_ messageId: EngineMessage.Id, _ text: String) -> Void)? = nil
) {
    guard let shared = message.attributes.first(where: { $0 is SharedMessageAttribute }) as? SharedMessageAttribute else {
        return
    }
    let accountPeerId = context.account.peerId

    // Everyone who may edit, the author first, in order of first participation.
    var editorIds: [EnginePeer.Id] = []
    if let author = message.author {
        editorIds.append(author.id)
    }
    for peerId in shared.activity.editorPeerIds where !editorIds.contains(peerId) {
        editorIds.append(peerId)
    }
    for peerId in shared.peerIds where !editorIds.contains(peerId) {
        editorIds.append(peerId)
    }
    if !editorIds.contains(accountPeerId) {
        editorIds.append(accountPeerId)
    }

    let content = sharedMessageEditorContent(message: message)

    // The real room when the message has one and the account can get in; the local simulation otherwise.
    let membership: Signal<Bool, NoError>
    // Debug Settings ▸ "Shared Messages: simulated co-editors": stay out of the hidden room so the
    // scripted group members below edit instead (promo recordings without other devices on this build).
    let forceSimulatedCoEditors = context.sharedContext.immediateExperimentalUISettings.sharedMessageSimulatedCoEditors
    if let link = shared.link, !forceSimulatedCoEditors {
        membership = SharedMessageRoom.ensureMembership(context: context, link: link)
    } else {
        membership = .single(false)
    }
    let _ = (membership
    |> deliverOnMainQueue).startStandalone(next: { [weak navigationController] isInRoom in
        guard let navigationController else {
            return
        }
        // The message text and its rich page stand in for a content version: a changed message re-seeds the simulation.
        let richBlockCount = (message.attributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute)?.instantPage.blocks.count ?? 0
        let contentKey = "\(message.text.hashValue):\(richBlockCount)"
        let session = SharedEditingSessionStore.shared.session(for: message.id, key: contentKey, preferringRoom: isInRoom && shared.link != nil, make: {
            if isInRoom, let link = shared.link {
                return RoomSharedEditingSession(context: context, link: link, editorPeerIds: editorIds, fallbackDocument: content.document)
            }
            return SimulatedSharedEditingSession(accountPeerId: accountPeerId, editorPeerIds: editorIds, initialDocument: content.document, sharedAt: shared.activity.sharedAt)
        })
        // Wait for the topic (briefly) so the editor opens on the shared blocks.
        let _ = (session.ready
        |> timeout(1.5, queue: .mainQueue(), alternate: .complete())
        |> deliverOnMainQueue).startStandalone(completed: { [weak navigationController] in
            guard let navigationController else {
                return
            }
            presentSharedMessageEditor(context: context, navigationController: navigationController, message: message, shared: shared, session: session, editorIds: editorIds, content: content, presentAttachmentMenu: presentAttachmentMenu, presentFormulaEditor: presentFormulaEditor, replyInChat: replyInChat)
        })
    })
}

private func presentSharedMessageEditor(
    context: AccountContext,
    navigationController: NavigationController,
    message: EngineMessage,
    shared: SharedMessageAttribute,
    session: SharedEditingSession,
    editorIds: [EnginePeer.Id],
    content: (document: Document, media: [String: EngineMedia], emojiFiles: [Int64: TelegramMediaFile]),
    presentAttachmentMenu: ((_ request: RichTextAttachmentScreen.MediaRequest, @escaping ([RichTextAttachmentScreen.RichTextAttachment]) -> Void) -> Void)?,
    presentFormulaEditor: ((_ initialValue: String?, _ completion: @escaping (String) -> Void) -> Void)?,
    replyInChat: ((_ messageId: EngineMessage.Id, _ text: String) -> Void)?
) {
    let accountPeerId = context.account.peerId
    let documentAtOpen = session.currentDocument

    let peers = context.engine.data.subscribe(EngineDataList(editorIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
    |> map { list -> [EnginePeer.Id: EnginePeer] in
        var result: [EnginePeer.Id: EnginePeer] = [:]
        for peer in list {
            if let peer {
                result[peer.id] = peer
            }
        }
        return result
    }
    // Editors the message did not name (they joined through the room) are looked up as they appear.
    let allPeers = combineLatest(queue: .mainQueue(), session.state, peers)
    |> mapToSignal { state, known -> Signal<[EnginePeer.Id: EnginePeer], NoError> in
        let missing = state.participants.map { $0.peerId }.filter { known[$0] == nil }
        if missing.isEmpty {
            return .single(known)
        }
        return context.engine.data.get(EngineDataList(missing.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
        |> map { list in
            var result = known
            for peer in list {
                if let peer {
                    result[peer.id] = peer
                }
            }
            return result
        }
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings
    // The title follows the message, so a change made in Manage Editing shows in the header at once.
    let currentTitle = Atomic<String>(value: shared.title)
    // Who made the changes the editor is about to save, newest first: the new version names them.
    let lastEditAuthorIds = Atomic<[EnginePeer.Id]>(value: [])
    let liveTitle = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: message.id))
    |> map { latest -> String in
        return (latest?.attributes.first(where: { $0 is SharedMessageAttribute }) as? SharedMessageAttribute)?.title ?? shared.title
    }
    |> distinctUntilChanged
    let updates = combineLatest(queue: .mainQueue(), session.state, allPeers, session.versions, liveTitle)
    |> map { state, peers, versions, title -> RichTextCollaborationHost.Update in
        let _ = currentTitle.swap(title)
        let _ = lastEditAuthorIds.swap(state.lastEdit?.authorIds ?? [])
        let participants = state.participants.map { participant in
            let peer = peers[participant.peerId]
            // The colour a person's name has in the chat; the palette stands in while the peer is unknown.
            var color = UIColor(rgb: sharedEditorColors[participant.colorIndex % sharedEditorColors.count])
            if case let .preset(nameColor)? = peer?.nameColor {
                color = context.peerNameColors.get(nameColor, dark: presentationData.theme.overallDarkAppearance).main
            }
            return RichTextCollaborationHost.Participant(
                peerId: participant.peerId,
                peer: peer,
                color: color,
                blockId: participant.blockId,
                isEditing: participant.isEditing
            )
        }
        // Others typing now come first, then the last edit, and before any edit the people who may edit.
        let status: RichTextCollaborationHost.Status
        let editingIds = state.participants.filter { $0.isEditing && $0.peerId != accountPeerId }.map { $0.peerId }
        if !editingIds.isEmpty {
            let editingPeers = editingIds.compactMap { peers[$0] }
            let texts = sharedMessageEditingStatusShapes(names: editingPeers.map { $0.compactDisplayTitle }, count: editingIds.count).map { shape -> String in
                switch shape {
                case let .one(name):
                    return strings.SharedMessage_Editor_IsEditing(name).string
                case let .two(first, second):
                    return strings.SharedMessage_Editor_AndAreEditing(first, second).string
                case let .oneAndOthers(name, others):
                    return strings.SharedMessage_Editor_AndAreEditing(name, strings.SharedMessage_Editor_Others(Int32(others))).string
                case let .count(count):
                    return strings.SharedMessage_Editor_UsersEditing(Int32(count))
                }
            }
            status = .editing(texts: texts, peers: editingPeers)
        } else if let lastEdit = state.lastEdit {
            status = .lastEdit(text: strings.SharedMessage_Editor_LastEdit(sharedMessageEditDateString(timestamp: lastEdit.timestamp, strings: strings, dateTimeFormat: presentationData.dateTimeFormat)).string, peers: lastEdit.authorIds.compactMap { peers[$0] })
        } else {
            let others = Int32(editorIds.filter { $0 != accountPeerId }.count)
            status = .canEdit(text: others == 0 ? strings.SharedMessage_Header_YouCanEdit : strings.SharedMessage_Header_YouAndOthers(others), peers: editorIds.compactMap { peers[$0] })
        }
        return RichTextCollaborationHost.Update(title: title, document: state.document, revision: state.revision, participants: participants, status: status, versionCount: versions.count)
    }

    let notices = SharedMessageEditorNotices(
        strings: strings,
        connectionStatus: context.account.network.connectionStatus,
        hasUnsentChanges: session.state |> map { $0.hasUnsentChanges } |> distinctUntilChanged
    )

    let isAuthor = (message.author?.id ?? accountPeerId) == accountPeerId
    let media = content.media
    let host = RichTextCollaborationHost(
        title: shared.title,
        updates: updates,
        notice: notices.notice,
        localDocumentChanged: { document, revision, caretBlock in
            let before = session.currentDocument
            session.updateLocalDocument(document, basedOnRevision: revision, caretBlock: caretBlock)
            // The editor reports its document after a pause in typing, so this is the first stop after an edit.
            if session.currentDocument != before {
                notices.localChangeSaved()
            }
        },
        localCaretChanged: { block in
            session.updateLocalCaret(block: block)
        },
        openHistory: { controller, sourceView, _ in
            presentSharedMessageVersions(context: context, controller: controller, sourceView: sourceView, session: session, peers: allPeers, title: currentTitle.with { $0 }, replyInChat: { [weak controller] version in
                // The version screen and the editor close (the editor saves as on its own close), then the
                // chat replies to the message, its input naming the version the reply is about.
                (controller as? RichTextAttachmentScreen)?.close()
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let date = sharedMessageVersionDateString(timestamp: version.timestamp, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat)
                replyInChat?(message.id, presentationData.strings.SharedMessage_Version_ReplyText(date).string)
            })
        },
        openMenu: { controller, sourceView, dismissEditor in
            presentSharedMessageEditorMenu(context: context, controller: controller, sourceView: sourceView, message: message, session: session, isAuthor: isAuthor, documentAtOpen: documentAtOpen, dismissEditor: dismissEditor)
        },
        finished: {
            session.endLocalEditing()
            // Only the author's client can write the real message; everyone else's changes reach it
            // through the room when the author is next in the editor. The settings may have changed
            // from the menu while the editor was open, so the marker is taken from the message as it is now.
            let document = session.currentDocument
            if isAuthor, document != documentAtOpen {
                let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: message.id))
                |> mapToSignal { latest -> Signal<Never, NoError> in
                    let latest = latest ?? message
                    let attribute = (latest.attributes.first(where: { $0 is SharedMessageAttribute }) as? SharedMessageAttribute) ?? shared
                    // A saved document is a new version; every client that sees it move tells the chat
                    // (when the message asks for that), naming who made it.
                    var editorIds = lastEditAuthorIds.with { $0 }
                    if editorIds.isEmpty {
                        editorIds = [accountPeerId]
                    }
                    return SharedMessageRoom.saveToMessage(context: context, message: latest, attribute: attribute.withNextVersion(editorIds: editorIds), document: document, media: media)
                }).startStandalone()
            }
        }
    )

    let screen = RichTextAttachmentScreen(
        context: context,
        mode: .edit(initialDocument: documentAtOpen, media: content.media, emojiFiles: content.emojiFiles),
        sendMessage: { _, _, _, _ in
        },
        syncContent: nil,
        sendContextActions: nil,
        preuploadPeerId: message.id.peerId,
        presentAttachmentMenu: presentAttachmentMenu,
        presentFormulaEditor: presentFormulaEditor,
        pastedMarkdownParser: nil,
        collaboration: host
    )
    screen.navigationPresentation = .modal
    navigationController.pushViewController(screen)
}

/// The notices over the shared editor's toolbar. "Changes save automatically" after the first pause
/// in typing of each open; "You're offline · Saved on this device" while the device has no network;
/// "Back online · Changes synced" once the network is back and everything typed meanwhile has been sent.
private final class SharedMessageEditorNotices {
    /// How long the network must be gone before the editor says so: short reconnects are routine.
    private static let offlineDelay: Double = 1.5
    private static let shownDuration: Double = 3.0

    private let strings: PresentationStrings
    private let noticePromise = ValuePromise<RichTextCollaborationHost.Notice?>(nil, ignoreRepeated: true)
    private let disposables = DisposableSet()
    private var offlineTimer: SwiftSignalKit.Timer?
    private var hideTimer: SwiftSignalKit.Timer?

    private var isOffline = false
    private var hasUnsentChanges = false
    /// The editor was offline; "Back online" is owed once the changes are through.
    private var awaitingSync = false
    private var didShowSaved = false

    var notice: Signal<RichTextCollaborationHost.Notice?, NoError> {
        return self.noticePromise.get()
    }

    init(strings: PresentationStrings, connectionStatus: Signal<ConnectionStatus, NoError>, hasUnsentChanges: Signal<Bool, NoError>) {
        self.strings = strings
        self.disposables.add((connectionStatus
        |> deliverOnMainQueue).startStrict(next: { [weak self] status in
            self?.updateConnection(isWaitingForNetwork: status == .waitingForNetwork)
        }))
        self.disposables.add((hasUnsentChanges
        |> deliverOnMainQueue).startStrict(next: { [weak self] value in
            guard let self else {
                return
            }
            self.hasUnsentChanges = value
            self.showSyncedIfDone()
        }))
    }

    deinit {
        self.disposables.dispose()
        self.offlineTimer?.invalidate()
        self.hideTimer?.invalidate()
    }

    func localChangeSaved() {
        // Shown on every open for now, once per open; later only the first time ever.
        if self.didShowSaved {
            return
        }
        self.didShowSaved = true
        if !self.isOffline && !self.awaitingSync {
            self.show(RichTextCollaborationHost.Notice(icon: .saved, title: self.strings.SharedMessage_Editor_Notice_Saved, subtitle: nil), hideAfter: SharedMessageEditorNotices.shownDuration)
        }
    }

    private func updateConnection(isWaitingForNetwork: Bool) {
        if isWaitingForNetwork {
            if !self.isOffline && self.offlineTimer == nil {
                let timer = SwiftSignalKit.Timer(timeout: SharedMessageEditorNotices.offlineDelay, repeat: false, completion: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.offlineTimer = nil
                    self.isOffline = true
                    self.awaitingSync = true
                    self.show(RichTextCollaborationHost.Notice(icon: .offline, title: self.strings.SharedMessage_Editor_Notice_Offline, subtitle: self.strings.SharedMessage_Editor_Notice_OfflineSaved), hideAfter: nil)
                }, queue: .mainQueue())
                self.offlineTimer = timer
                timer.start()
            }
        } else {
            self.offlineTimer?.invalidate()
            self.offlineTimer = nil
            if self.isOffline {
                self.isOffline = false
                // Nothing is said while the changes typed offline are still going out.
                self.show(nil, hideAfter: nil)
                self.showSyncedIfDone()
            }
        }
    }

    private func showSyncedIfDone() {
        guard self.awaitingSync, !self.isOffline, !self.hasUnsentChanges else {
            return
        }
        self.awaitingSync = false
        self.show(RichTextCollaborationHost.Notice(icon: .synced, title: self.strings.SharedMessage_Editor_Notice_Online, subtitle: self.strings.SharedMessage_Editor_Notice_Synced), hideAfter: SharedMessageEditorNotices.shownDuration)
    }

    private func show(_ notice: RichTextCollaborationHost.Notice?, hideAfter: Double?) {
        self.hideTimer?.invalidate()
        self.hideTimer = nil
        self.noticePromise.set(notice)
        if let hideAfter {
            let timer = SwiftSignalKit.Timer(timeout: hideAfter, repeat: false, completion: { [weak self] in
                self?.hideTimer = nil
                self?.noticePromise.set(nil)
            }, queue: .mainQueue())
            self.hideTimer = timer
            timer.start()
        }
    }
}

/// The message as an editor document: a rich message through its page, a plain one through its text and entities.
func sharedMessageEditorContent(message: EngineMessage) -> (document: Document, media: [String: EngineMedia], emojiFiles: [Int64: TelegramMediaFile]) {
    let content: ChatInputContent
    if let richText = message.attributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute {
        content = chatInputContent(fromInstantPage: richText.instantPage)
    } else {
        let entities = (message.attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute)?.entities ?? []
        content = ChatTextInputState(inputText: chatInputStateStringWithAppliedEntities(message.text, entities: entities)).content
    }
    return documentMediaAndEmoji(fromChatInputContent: content)
}

final class SharedMessageVersionsReferenceSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds)
    }
}

/// The versions popup under the history button: one row per autosaved version with the icon of its
/// kind on the left and its authors on the right, tap to open it in a sheet; "Show all" at the end.
private func presentSharedMessageVersions(context: AccountContext, controller: ViewController, sourceView: UIView, session: SharedEditingSession, peers: Signal<[EnginePeer.Id: EnginePeer], NoError>, title: String, replyInChat: @escaping (SharedEditingVersion) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings
    let menuBackgroundColor = presentationData.theme.contextMenu.backgroundColor
    let shownVersionCount = 4

    let versionsAndPeers = combineLatest(session.versions, peers)
    |> take(1)
    // The avatars are drawn into the rows' right icons, which are plain images, so they are loaded first.
    |> mapToSignal { versions, peers -> Signal<([SharedEditingVersion], [EnginePeer.Id: EnginePeer], [EnginePeer.Id: UIImage]), NoError> in
        var authorIds: [EnginePeer.Id] = []
        // Every version's authors, not just the menu's: "Show all" draws the same avatars.
        for version in versions where !version.isRestore {
            for authorId in version.authorIds where !authorIds.contains(authorId) {
                authorIds.append(authorId)
            }
        }
        let avatarSignals = authorIds.compactMap { authorId -> Signal<(EnginePeer.Id, UIImage?), NoError>? in
            guard let peer = peers[authorId] else {
                return nil
            }
            return peerAvatarCompleteImage(account: context.account, peer: peer, size: CGSize(width: 22.0, height: 22.0), font: avatarPlaceholderFont(size: 9.0))
            |> take(1)
            |> timeout(0.4, queue: .mainQueue(), alternate: .single(nil))
            |> map { (authorId, $0) }
        }
        return combineLatest(avatarSignals)
        |> map { avatars in
            var images: [EnginePeer.Id: UIImage] = [:]
            for (authorId, image) in avatars {
                if let image {
                    images[authorId] = image
                }
            }
            return (versions, peers, images)
        }
    }

    let _ = (versionsAndPeers
    |> deliverOnMainQueue).startStandalone(next: { [weak controller] versions, peersById, avatars in
        guard let controller else {
            return
        }
        let openVersion: (SharedEditingVersion) -> Void = { [weak controller] version in
            guard let controller else {
                return
            }
            // The paragraph is let go while someone reads history, as the editor does for its own overlay.
            session.updateLocalCaret(block: nil)
            var dismissViewer: (() -> Void)?
            let viewer = SharedMessageVersionController(context: context, session: session, versions: versions, versionId: version.id, peers: peersById, title: title, restored: { [weak controller] in
                controller?.present(UndoOverlayController(presentationData: presentationData, content: .succeed(text: strings.SharedMessage_Version_Restored, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in false }), in: .window(.root))
            }, replyInChat: { version in
                dismissViewer?()
                replyInChat(version)
            })
            dismissViewer = { [weak viewer] in
                viewer?.dismiss()
            }
            (controller.navigationController as? NavigationController)?.pushViewController(viewer)
        }
        let noAction: ((ContextMenuActionItem.Action) -> Void)? = nil
        var items: [ContextMenuItem] = []
        let headerText = versions.isEmpty ? strings.SharedMessage_Editor_NoVersions : strings.SharedMessage_Editor_VersionsTitle(Int32(versions.count))
        items.append(.action(ContextMenuActionItem(text: headerText, textColor: .primary, textFont: .small, icon: { _ in nil }, action: noAction)))
        items.append(.separator)
        for version in versions.prefix(shownVersionCount) {
            let subtitle = sharedMessageVersionDateString(timestamp: version.timestamp, strings: strings, dateTimeFormat: presentationData.dateTimeFormat)
            let text = version.isRestore ? strings.SharedMessage_Editor_RestoredVersion : strings.SharedMessage_Editor_Changes(Int32(version.changeCount))
            let authorImages = version.isRestore ? [] : version.authorIds.compactMap { avatars[$0] }
            items.append(.action(ContextMenuActionItem(text: text, textLayout: .secondLineWithValue(subtitle), icon: { theme in
                if version.isRestore {
                    return sharedMessageMenuSymbol("arrow.uturn.backward", color: theme.contextMenu.primaryColor)
                }
                return sharedMessageMenuSymbol("pencil.and.outline", color: theme.contextMenu.primaryColor)
            }, additionalLeftIcon: authorImages.isEmpty ? nil : { _ in
                return sharedMessageAvatarGroupImage(authorImages, borderColor: menuBackgroundColor)
            }, action: { _, f in
                f(.default)
                openVersion(version)
            })))
        }
        items.append(.separator)
        items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Editor_ShowAll, icon: { theme in
            return sharedMessageMenuSymbol("list.bullet", color: theme.contextMenu.primaryColor)
        }, action: { [weak controller] _, f in
            f(.default)
            guard let controller else {
                return
            }
            let sheet = SharedMessageVersionsSheet(context: context, title: headerText, sections: sharedMessageVersionsSheetSections(versions: versions, avatars: avatars, presentationData: presentationData), select: { versionId in
                if let version = versions.first(where: { $0.id == versionId }) {
                    openVersion(version)
                }
            })
            (controller.navigationController as? NavigationController)?.pushViewController(sheet)
        })))
        let contextController = makeContextController(
            presentationData: presentationData,
            source: .reference(SharedMessageVersionsReferenceSource(sourceView: sourceView)),
            items: .single(ContextController.Items(content: .list(items)))
        )
        controller.presentInGlobalOverlay(contextController)
    })
}

/// The "…" menu of the shared editor, drawn with the app's own context-menu assets so its icons match
/// every other menu. Manage Editing and Close editing are the author's: only the author's client can
/// write the message. Show Highlights only closes the menu until its flow exists.
private func presentSharedMessageEditorMenu(context: AccountContext, controller: ViewController, sourceView: UIView, message: EngineMessage, session: SharedEditingSession, isAuthor: Bool, documentAtOpen: Document, dismissEditor: @escaping () -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings
    let messageId = message.id
    let showToast: (UndoOverlayContent) -> Void = { [weak controller] content in
        controller?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, action: { _ in false }), in: .window(.root))
    }

    var items: [ContextMenuItem] = []
    if isAuthor {
        items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Editor_ManageEditing, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Customize"), color: theme.contextMenu.primaryColor)
        }, action: { [weak controller] _, f in
            f(.default)
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
            |> deliverOnMainQueue).startStandalone(next: { [weak controller] latest in
                guard let controller, let latest, let shared = latest.attributes.first(where: { $0 is SharedMessageAttribute }) as? SharedMessageAttribute else {
                    return
                }
                let settings = SharedMessageSetupResult(title: shared.title, access: shared.access, peerIds: shared.peerIds, closeEditing: shared.closeEditing, commentsEnabled: shared.commentsEnabled, notifyChanges: shared.notifyChanges)
                // A rich message carries its text in the page, not in `text`: the generator reads the document.
                var messageText = sharedMessagePlainText(of: session.currentDocument)
                if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messageText = latest.text
                }
                let setupController = sharedMessageSetupController(context: context, peerId: messageId.peerId, initialTitle: shared.title, messageText: messageText, initialSettings: settings, completion: { result in
                    let _ = SharedMessageRoom.updateSettings(context: context, messageId: messageId, result: result).startStandalone()
                    // The sheet is closing; the toast confirms the save over the editor.
                    showToast(.succeed(text: strings.SharedMessage_Editor_SettingsSaved, timeout: nil, customUndoText: nil))
                })
                (controller.navigationController as? NavigationController)?.pushViewController(setupController)
            })
        })))
        items.append(.separator)
    }
    items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Editor_CopyText, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor)
    }, action: { _, f in
        f(.default)
        UIPasteboard.general.string = sharedMessagePlainText(of: session.currentDocument)
        showToast(.copy(text: strings.Conversation_TextCopied))
    })))
    items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Editor_CopyLink, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Link"), color: theme.contextMenu.primaryColor)
    }, action: { _, f in
        f(.default)
        let _ = (context.engine.messages.exportMessageLink(peerId: messageId.peerId, messageId: messageId)
        |> deliverOnMainQueue).startStandalone(next: { link in
            guard let link else {
                return
            }
            UIPasteboard.general.string = link
            showToast(.linkCopied(title: nil, text: strings.Conversation_LinkCopied))
        })
    })))
    items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Editor_ShowHighlights, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Tag"), color: theme.contextMenu.primaryColor)
    }, action: { _, f in
        f(.default)
    })))
    if isAuthor {
        items.append(.separator)
        items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Editor_CloseEditing, textColor: .destructive, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Lock"), color: theme.contextMenu.destructiveColor)
        }, action: { [weak controller] _, f in
            f(.default)
            guard let controller else {
                return
            }
            // Closing ends everyone's editing, so it is confirmed first.
            let alert = textAlertController(context: context, title: strings.SharedMessage_Editor_CloseEditingConfirmTitle, text: strings.SharedMessage_Editor_CloseEditingConfirmText, actions: [
                TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                TextAlertAction(type: .destructiveAction, title: strings.SharedMessage_Editor_CloseEditingConfirmAction, action: {
                    // The closing editor saves a changed document with the marker; an unchanged one needs the marker written here.
                    let rewriteMarker = session.currentDocument == documentAtOpen
                    let _ = (SharedMessageRoom.closeEditing(context: context, messageId: messageId, rewriteMarker: rewriteMarker)
                    |> deliverOnMainQueue).startStandalone(completed: {
                        dismissEditor()
                    })
                })
            ])
            controller.present(alert, in: .window(.root))
        })))
    }
    let contextController = makeContextController(
        presentationData: presentationData,
        source: .reference(SharedMessageVersionsReferenceSource(sourceView: sourceView)),
        items: .single(ContextController.Items(content: .list(items)))
    )
    controller.presentInGlobalOverlay(contextController)
}

/// The document as plain text for the clipboard: a message that has one, else the paragraphs' text.
func sharedMessagePlainText(of document: Document) -> String {
    if case let .plain(text, _) = composeRichMessage(from: document, forSendPreview: true) {
        return text
    }
    return document.blocks.map { SharedMessageVersionDiff.plainText(of: $0) }.joined(separator: "\n")
}

/// An SF Symbol tinted for a menu row, drawn like the app's own menu assets: a 24pt canvas with the
/// visible glyph fitted into 18pt (its larger side) and centred. A symbol's own image carries padding
/// that differs per glyph, so the glyph is measured from its alpha rather than taken from the image size.
func sharedMessageMenuSymbol(_ name: String, color: UIColor) -> UIImage? {
    guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 64.0, weight: .regular)), let glyph = sharedMessageGlyphBounds(of: symbol) else {
        return nil
    }
    let canvas: CGFloat = 24.0
    let box: CGFloat = 18.0
    let scale = box / max(glyph.width, glyph.height)
    let drawSize = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    let glyphSize = CGSize(width: glyph.width * scale, height: glyph.height * scale)
    let origin = CGPoint(x: (canvas - glyphSize.width) / 2.0 - glyph.minX * scale, y: (canvas - glyphSize.height) / 2.0 - glyph.minY * scale)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas))
    let image = renderer.image { _ in
        symbol.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: origin, size: drawSize))
    }
    return image.withRenderingMode(.alwaysOriginal)
}

/// The rectangle, in the image's points, that the symbol actually paints.
private func sharedMessageGlyphBounds(of symbol: UIImage) -> CGRect? {
    let width = Int(ceil(symbol.size.width))
    let height = Int(ceil(symbol.size.height))
    guard width > 0, height > 0 else {
        return nil
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
        symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 0.0, y: 0.0, width: CGFloat(width), height: CGFloat(height)))
    }
    guard let cgImage = rendered.cgImage, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else {
        return nil
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else {
        return nil
    }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0 ..< height {
        for x in 0 ..< width where bytes[y * width + x] > 25 {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return nil
    }
    return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
}

/// Up to three 22pt avatars in a row, each overlapping the next by 6pt and ringed in the menu's colour;
/// the first author is on top.
private func sharedMessageAvatarGroupImage(_ images: [UIImage], borderColor: UIColor) -> UIImage? {
    let avatarSize: CGFloat = 22.0
    let ring: CGFloat = 1.5
    let step: CGFloat = avatarSize - 6.0
    let shown = Array(images.prefix(3))
    guard !shown.isEmpty else {
        return nil
    }
    let size = CGSize(width: avatarSize + step * CGFloat(shown.count - 1) + ring * 2.0, height: avatarSize + ring * 2.0)
    return generateImage(size, rotatedContext: { size, context in
        context.clear(CGRect(origin: .zero, size: size))
        for index in stride(from: shown.count - 1, through: 0, by: -1) {
            let frame = CGRect(x: ring + step * CGFloat(index), y: ring, width: avatarSize, height: avatarSize)
            context.setFillColor(borderColor.cgColor)
            context.fillEllipse(in: frame.insetBy(dx: -ring, dy: -ring))
            UIGraphicsPushContext(context)
            shown[index].draw(in: frame)
            UIGraphicsPopContext()
        }
    })
}

private enum SharedMessageDay {
    case today
    case yesterday
    case other
}

private func sharedMessageDay(of timestamp: Int32) -> SharedMessageDay {
    var t: time_t = Int(timestamp)
    var timeinfo = tm()
    localtime_r(&t, &timeinfo)
    var now: time_t = Int(Date().timeIntervalSince1970)
    var nowInfo = tm()
    localtime_r(&now, &nowInfo)
    guard timeinfo.tm_year == nowInfo.tm_year else {
        return .other
    }
    switch nowInfo.tm_yday - timeinfo.tm_yday {
    case 0:
        return .today
    case 1:
        return .yesterday
    default:
        return .other
    }
}

private func sharedMessageTimeString(timestamp: Int32, dateTimeFormat: PresentationDateTimeFormat) -> String {
    var t: time_t = Int(timestamp)
    var timeinfo = tm()
    localtime_r(&t, &timeinfo)
    return stringForShortTimestamp(hours: Int32(timeinfo.tm_hour), minutes: Int32(timeinfo.tm_min), dateTimeFormat: dateTimeFormat)
}

private func sharedMessageMonthDayString(timestamp: Int32) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
}

/// "today at 12:40", "yesterday at 12:40", else "Nov 15 at 12:40".
private func sharedMessageEditDateString(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> String {
    switch sharedMessageDay(of: timestamp) {
    case .today, .yesterday:
        return humanReadableStringForTimestamp(strings: strings, dateTimeFormat: dateTimeFormat, timestamp: timestamp, alwaysShowTime: true).string
    case .other:
        return strings.Time_MediumDate(sharedMessageMonthDayString(timestamp: timestamp), sharedMessageTimeString(timestamp: timestamp, dateTimeFormat: dateTimeFormat)).string
    }
}

/// "Today, 14:39", "Yesterday, 10:12", else "Nov 10, 23:12".
/// The "Show all" sheet's sections: versions grouped by local day, newest first, each row the menu's
/// row (icon, "N changes" or "Restored version", authors) with only the time, since the day is the heading.
func sharedMessageVersionsSheetSections(versions: [SharedEditingVersion], avatars: [EnginePeer.Id: UIImage], presentationData: PresentationData) -> [SharedMessageVersionsSheetSection] {
    let strings = presentationData.strings
    let theme = presentationData.theme.withModalBlocksBackground()
    let iconColor = theme.list.itemPrimaryTextColor
    let editIcon = sharedMessageMenuSymbol("pencil.and.outline", color: iconColor)
    let restoreIcon = sharedMessageMenuSymbol("arrow.uturn.backward", color: iconColor)
    let calendar = Calendar.current
    let now = Date()

    var sections: [SharedMessageVersionsSheetSection] = []
    var currentDay: Date?
    var currentRows: [SharedMessageVersionsSheetRow] = []
    let flush: () -> Void = {
        guard let day = currentDay, !currentRows.isEmpty else {
            return
        }
        let title: String
        if calendar.isDateInToday(day) {
            title = strings.Weekday_Today
        } else if calendar.isDateInYesterday(day) {
            title = strings.Weekday_Yesterday
        } else {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(day, equalTo: now, toGranularity: .year) ? "MMMM d" : "MMMM d, yyyy")
            title = formatter.string(from: day)
        }
        sections.append(SharedMessageVersionsSheetSection(id: Int(day.timeIntervalSince1970), title: title, rows: currentRows))
    }
    for version in versions.sorted(by: { $0.timestamp > $1.timestamp }) {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(version.timestamp)))
        if day != currentDay {
            flush()
            currentDay = day
            currentRows = []
        }
        let authorImages = version.isRestore ? [] : version.authorIds.compactMap { avatars[$0] }
        currentRows.append(SharedMessageVersionsSheetRow(
            versionId: version.id,
            title: version.isRestore ? strings.SharedMessage_Editor_RestoredVersion : strings.SharedMessage_Editor_Changes(Int32(version.changeCount)),
            time: sharedMessageTimeString(timestamp: version.timestamp, dateTimeFormat: presentationData.dateTimeFormat),
            icon: version.isRestore ? restoreIcon : editIcon,
            avatars: authorImages.isEmpty ? nil : sharedMessageAvatarGroupImage(authorImages, borderColor: theme.list.itemBlocksBackgroundColor)
        ))
    }
    flush()
    return sections
}

func sharedMessageVersionDateString(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> String {
    let day: String
    switch sharedMessageDay(of: timestamp) {
    case .today:
        day = strings.Weekday_Today
    case .yesterday:
        day = strings.Weekday_Yesterday
    case .other:
        day = sharedMessageMonthDayString(timestamp: timestamp)
    }
    return day + ", " + sharedMessageTimeString(timestamp: timestamp, dateTimeFormat: dateTimeFormat)
}
