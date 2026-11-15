import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import UndoUI
import PresentationDataUtils
import AvatarNode
import AppBundle
import ContextUI
import ComponentFlow
import GlassControls
import BundleIconComponent
import RichTextEditorCore
import RichTextAttachmentScreen

/// The sheet a version opens in from the history popup: the same slide-up modal as Manage Editing,
/// holding a `SharedMessageVersionView`, whose close button and Restore both dismiss it.
final class SharedMessageVersionController: ViewController {
    /// The sheet's own top area: the 44pt glass controls 16pt down and 16pt below them, the editor
    /// sheet's own distance from its controls to its header block.
    private static let controlsHeight: CGFloat = 76.0

    private let versionView: SharedMessageVersionView

    init(context: AccountContext, session: SharedEditingSession, versions: [SharedEditingVersion], versionId: Int, peers: [EnginePeer.Id: EnginePeer], title: String, restored: @escaping () -> Void, replyInChat: @escaping (SharedEditingVersion) -> Void) {
        var presentMenuImpl: ((ContextController) -> Void)?
        self.versionView = SharedMessageVersionView(context: context, session: session, versions: versions, versionId: versionId, peers: peers, title: title, presentMenu: { menu in
            presentMenuImpl?(menu)
        })

        super.init(navigationBarPresentationData: nil)

        self.navigationPresentation = .modal
        // The modal container rounds a sheet at 38pt only for a glass-style controller (10pt otherwise).
        self._hasGlassStyle = true
        presentMenuImpl = { [weak self] menu in
            self?.presentInGlobalOverlay(menu)
        }
        self.versionView.onDismiss = { [weak self] in
            self?.dismiss()
        }
        self.versionView.onRestored = { [weak self] in
            self?.dismiss()
            restored()
        }
        self.versionView.presentAlert = { [weak self] alert in
            self?.present(alert, in: .window(.root))
        }
        self.versionView.onReplyInChat = { version in
            replyInChat(version)
        }
        self.versionView.onCopyText = { [weak self] version in
            UIPasteboard.general.string = sharedMessagePlainText(of: version.document)
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            self?.present(UndoOverlayController(presentationData: presentationData, content: .copy(text: presentationData.strings.Conversation_TextCopied), elevatedLayout: false, action: { _ in false }), in: .window(.root))
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.versionView.backgroundColor
        self.displayNode.view.addSubview(self.versionView)
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.versionView.frame = CGRect(origin: .zero, size: layout.size)
        self.versionView.updateLayout(size: layout.size, safeInsets: UIEdgeInsets(top: layout.statusBarHeight ?? 0.0, left: layout.safeInsets.left, bottom: layout.intrinsicInsets.bottom, right: layout.safeInsets.right), navigationHeight: SharedMessageVersionController.controlsHeight)
    }
}

/// One autosaved version of a shared message: what the session changed, by everyone or by one
/// author (the tabs), with the previous/next version a tap away and the version's actions under
/// "•••". Its top block (title, chips, line) has the editor header's exact geometry, and its
/// controls are the sheet's own glass controls. Shown in `SharedMessageVersionController`; it can
/// also be slid over the editor as a `RichTextCollaborationOverlay`.
final class SharedMessageVersionView: UIView, RichTextCollaborationOverlay {
    private static let insertedColor = UIColor(rgb: 0x008bff)
    private static let deletedColor = UIColor(rgb: 0x3c3c43).withAlphaComponent(0.3)
    // The editor header's block: 12 above the 22pt title (26 tall), 12 to the 32pt row, 12 to the line.
    private static let topInset: CGFloat = 12.0
    private static let titleHeight: CGFloat = 26.0
    private static let rowSpacing: CGFloat = 12.0
    private static let rowHeight: CGFloat = 32.0
    private static let controlTop: CGFloat = 16.0
    private static let controlSize: CGFloat = 44.0

    var onDismiss: (() -> Void)?
    /// A version was restored from the "•••" menu; the view is done. `onDismiss` is used when unset.
    var onRestored: (() -> Void)?
    /// Presents a centred alert over the screen (the restore confirmation).
    var presentAlert: ((ViewController) -> Void)?
    /// "Reply in Chat": the screens close and the chat replies to the message about this version.
    var onReplyInChat: ((SharedEditingVersion) -> Void)?
    /// "Copy Text": the version's whole text goes to the clipboard and a toast confirms it.
    var onCopyText: ((SharedEditingVersion) -> Void)?
    private let presentMenu: (ContextController) -> Void

    private let context: AccountContext
    private let session: SharedEditingSession
    private let versions: [SharedEditingVersion]
    private let peers: [EnginePeer.Id: EnginePeer]
    private let documentTitle: String
    private var index: Int
    private var selectedAuthor: EnginePeer.Id?
    private let presentationData: PresentationData

    private let backControl = ComponentView<Empty>()
    private let moreControl = ComponentView<Empty>()
    private let navigationControl = ComponentView<Empty>()
    private let headerTitleLabel = UILabel()
    private let headerSubtitleLabel = UILabel()
    private let titleLabel = UILabel()
    private let tabsScrollView = UIScrollView()
    private var tabs: [SharedMessageVersionTab] = []
    private var tabsAuthorIds: [EnginePeer.Id] = []
    private let tabHaptic = HapticFeedback()
    private var avatarNodes: [EnginePeer.Id: AvatarNode] = [:]
    private let separator = UIView()
    private let textView = UITextView()
    private var validLayout: (CGSize, UIEdgeInsets, CGFloat)?

    init(context: AccountContext, session: SharedEditingSession, versions: [SharedEditingVersion], versionId: Int, peers: [EnginePeer.Id: EnginePeer], title: String, presentMenu: @escaping (ContextController) -> Void) {
        self.context = context
        self.session = session
        // Oldest first; the history reads newest first, so "<" steps to the newer version.
        self.versions = versions.sorted(by: { $0.id < $1.id })
        self.index = self.versions.firstIndex(where: { $0.id == versionId }) ?? max(0, self.versions.count - 1)
        self.peers = peers
        self.documentTitle = title
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.presentMenu = presentMenu

        super.init(frame: .zero)

        self.setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var version: SharedEditingVersion? {
        guard self.index >= 0, self.index < self.versions.count else {
            return nil
        }
        return self.versions[self.index]
    }

    private func setup() {
        let theme = self.presentationData.theme
        self.backgroundColor = theme.actionSheet.opaqueItemBackgroundColor

        // The same pair the sheet's own two-line titles use: 15pt semibold over 13pt regular.
        self.headerTitleLabel.font = Font.semibold(15.0)
        self.headerTitleLabel.textColor = theme.rootController.navigationBar.primaryTextColor
        self.headerTitleLabel.textAlignment = .center
        self.headerSubtitleLabel.font = Font.regular(13.0)
        self.headerSubtitleLabel.textColor = theme.rootController.navigationBar.secondaryTextColor
        self.headerSubtitleLabel.textAlignment = .center
        self.addSubview(self.headerTitleLabel)
        self.addSubview(self.headerSubtitleLabel)

        self.titleLabel.font = Font.bold(22.0)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.titleLabel.numberOfLines = 1
        self.titleLabel.lineBreakMode = .byTruncatingTail
        self.addSubview(self.titleLabel)

        self.tabsScrollView.showsHorizontalScrollIndicator = false
        self.tabsScrollView.alwaysBounceHorizontal = true
        self.addSubview(self.tabsScrollView)

        self.separator.backgroundColor = theme.list.itemPlainSeparatorColor
        self.addSubview(self.separator)

        self.textView.isEditable = false
        self.textView.isSelectable = true
        self.textView.backgroundColor = .clear
        self.textView.textContainerInset = UIEdgeInsets(top: 12.0, left: 0.0, bottom: 120.0, right: 0.0)
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.addSubview(self.textView)

        self.reload()
    }

    func updateLayout(size: CGSize, safeInsets: UIEdgeInsets, navigationHeight: CGFloat) {
        self.validLayout = (size, safeInsets, navigationHeight)
        let theme = self.presentationData.theme
        let width = size.width
        let sideInset: CGFloat = 16.0 + safeInsets.left
        let controlSize = SharedMessageVersionView.controlSize
        let controlTop = SharedMessageVersionView.controlTop

        // Top controls: the sheet's glass buttons, at the sheet's own 16pt / 44pt.
        let backSize = self.backControl.update(
            transition: .immediate,
            component: AnyComponent(GlassControlGroupComponent(theme: theme, preferClearGlass: false, background: .panel, items: [
                GlassControlGroupComponent.Item(id: 0, content: .icon("Navigation/Close"), action: { [weak self] in
                    self?.onDismiss?()
                })
            ], minWidth: controlSize)),
            environment: {},
            containerSize: CGSize(width: width, height: controlSize)
        )
        if let view = self.backControl.view {
            if view.superview == nil {
                self.addSubview(view)
            }
            view.frame = CGRect(origin: CGPoint(x: sideInset, y: controlTop), size: backSize)
        }
        let moreSize = self.moreControl.update(
            transition: .immediate,
            component: AnyComponent(GlassControlGroupComponent(theme: theme, preferClearGlass: false, background: .panel, items: [
                GlassControlGroupComponent.Item(id: 0, content: .customIcon(id: "more", component: AnyComponent(Image(image: UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .semibold)), tintColor: theme.rootController.navigationBar.primaryTextColor, size: CGSize(width: 22.0, height: 22.0), contentMode: .scaleAspectFit)), insets: .zero), action: { [weak self] in
                    self?.morePressed()
                })
            ], minWidth: controlSize)),
            environment: {},
            containerSize: CGSize(width: width, height: controlSize)
        )
        if let view = self.moreControl.view {
            if view.superview == nil {
                self.addSubview(view)
            }
            view.frame = CGRect(origin: CGPoint(x: width - sideInset - moreSize.width, y: controlTop), size: moreSize)
        }
        let headerLeft = sideInset + backSize.width + 8.0
        let headerRight = width - sideInset - moreSize.width - 8.0
        self.headerTitleLabel.frame = CGRect(x: headerLeft, y: controlTop + 4.0, width: max(0.0, headerRight - headerLeft), height: 20.0)
        self.headerSubtitleLabel.frame = CGRect(x: headerLeft, y: controlTop + 24.0, width: max(0.0, headerRight - headerLeft), height: 16.0)

        // The editor header's block, below the sheet's top area.
        let titleTop = navigationHeight + SharedMessageVersionView.topInset
        self.titleLabel.frame = CGRect(x: sideInset, y: titleTop, width: width - sideInset * 2.0, height: SharedMessageVersionView.titleHeight)
        let rowTop = titleTop + SharedMessageVersionView.titleHeight + SharedMessageVersionView.rowSpacing
        // One point above and below the chips, so a selected chip's outside border is not clipped.
        self.tabsScrollView.frame = CGRect(x: 0.0, y: rowTop - 1.0, width: width, height: SharedMessageVersionView.rowHeight + 2.0)
        self.layoutTabs(sideInset: sideInset)
        let lineTop = rowTop + SharedMessageVersionView.rowHeight + SharedMessageVersionView.rowSpacing
        self.separator.frame = CGRect(x: sideInset, y: lineTop, width: width - sideInset * 2.0, height: UIScreenPixel)
        self.textView.frame = CGRect(x: sideInset, y: lineTop + UIScreenPixel, width: width - sideInset * 2.0, height: max(0.0, size.height - lineTop))

        // Previous/next, the sheet's undo/redo pill: two 44pt items, greyed at either end.
        let canOlder = self.index > 0
        let canNewer = self.index < self.versions.count - 1
        let navigationSize = self.navigationControl.update(
            transition: .immediate,
            component: AnyComponent(GlassControlGroupComponent(theme: theme, preferClearGlass: false, background: .panel, items: [
                GlassControlGroupComponent.Item(id: 0, content: .icon("Navigation/Back"), action: canNewer ? { [weak self] in
                    self?.step(by: 1)
                } : nil),
                GlassControlGroupComponent.Item(id: 1, content: .customIcon(id: "next", component: AnyComponent(BundleIconComponent(name: "Navigation/Back", tintColor: theme.rootController.navigationBar.primaryTextColor, flipHorizontally: true)), insets: .zero), action: canOlder ? { [weak self] in
                    self?.step(by: -1)
                } : nil)
            ], minWidth: controlSize)),
            environment: {},
            containerSize: CGSize(width: width, height: controlSize)
        )
        if let view = self.navigationControl.view {
            if view.superview == nil {
                self.addSubview(view)
            }
            view.frame = CGRect(origin: CGPoint(x: width - sideInset - navigationSize.width, y: size.height - safeInsets.bottom - 16.0 - navigationSize.height), size: navigationSize)
        }
    }

    private func layoutTabs(sideInset: CGFloat) {
        var x = sideInset
        for tab in self.tabs {
            let width = tab.preferredWidth
            tab.frame = CGRect(x: x, y: 1.0, width: width, height: SharedMessageVersionView.rowHeight)
            x += width + 8.0
        }
        self.tabsScrollView.contentSize = CGSize(width: x - 8.0 + sideInset, height: SharedMessageVersionView.rowHeight + 2.0)
    }

    // MARK: - Content

    private func reload() {
        guard let version = self.version else {
            return
        }
        let strings = self.presentationData.strings
        let theme = self.presentationData.theme
        self.headerTitleLabel.text = strings.SharedMessage_Editor_Changes(Int32(version.changeCount))
        self.headerSubtitleLabel.text = sharedMessageVersionDateString(timestamp: version.timestamp, strings: strings, dateTimeFormat: self.presentationData.dateTimeFormat)
        self.titleLabel.text = self.documentTitle

        if let selected = self.selectedAuthor, !version.authorIds.contains(selected) {
            self.selectedAuthor = nil
        }
        self.updateTabs(version: version)

        let onlyBlocks = self.selectedAuthor.flatMap { version.blocksByAuthor[$0] }
        let lines = SharedMessageVersionDiff.lines(from: version.previousDocument, to: version.document, onlyBlocks: onlyBlocks)
        self.textView.attributedText = self.attributedText(for: lines, theme: theme)
        if let (size, safeInsets, navigationHeight) = self.validLayout {
            self.updateLayout(size: size, safeInsets: safeInsets, navigationHeight: navigationHeight)
        }
    }

    /// The chips are built once per author list and only restyled on selection, so their avatars
    /// are not loaded again on every tap.
    private func updateTabs(version: SharedEditingVersion) {
        if self.tabsAuthorIds != version.authorIds || self.tabs.isEmpty {
            for tab in self.tabs {
                tab.removeFromSuperview()
            }
            self.tabs = []
            self.tabsAuthorIds = version.authorIds
            let allTab = SharedMessageVersionTab()
            allTab.label.text = self.presentationData.strings.SharedMessage_Version_AllChanges
            allTab.tag = -1
            self.tabs.append(allTab)
            for (position, authorId) in version.authorIds.enumerated() {
                let tab = SharedMessageVersionTab()
                let peer = self.peers[authorId]
                tab.label.text = peer?.compactDisplayTitle ?? ""
                tab.tag = position
                if let peer {
                    let avatar: AvatarNode
                    if let existing = self.avatarNodes[authorId] {
                        avatar = existing
                    } else {
                        avatar = AvatarNode(font: avatarPlaceholderFont(size: 10.0))
                        avatar.setPeer(context: self.context, theme: self.presentationData.theme, peer: peer, displayDimensions: CGSize(width: 24.0, height: 24.0))
                        avatar.updateSize(size: CGSize(width: 24.0, height: 24.0))
                        self.avatarNodes[authorId] = avatar
                    }
                    tab.avatarView = avatar.view
                }
                self.tabs.append(tab)
            }
            for tab in self.tabs {
                tab.addTarget(self, action: #selector(self.tabPressed(_:)), for: .touchUpInside)
                self.tabsScrollView.addSubview(tab)
            }
        }
        let theme = self.presentationData.theme
        for tab in self.tabs {
            if tab.tag < 0 {
                tab.apply(color: nil, selected: self.selectedAuthor == nil, theme: theme)
            } else if tab.tag < version.authorIds.count {
                let authorId = version.authorIds[tab.tag]
                var color = theme.list.itemAccentColor
                if case let .preset(nameColor)? = self.peers[authorId]?.nameColor {
                    color = self.context.peerNameColors.get(nameColor, dark: theme.overallDarkAppearance).main
                }
                tab.apply(color: color, selected: self.selectedAuthor == authorId, theme: theme)
            }
        }
    }

    private func attributedText(for lines: [SharedMessageVersionDiff.Line], theme: PresentationTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 2.0
        for (index, line) in lines.enumerated() {
            let font: UIFont
            switch line.style {
            case .heading1:
                font = Font.bold(22.0)
            case .heading2:
                font = Font.bold(20.0)
            case .heading3, .heading4, .heading5, .heading6:
                font = Font.bold(17.0)
            default:
                font = Font.regular(17.0)
            }
            var prefix = ""
            if let list = line.list {
                let indent = String(repeating: "    ", count: max(0, list.level))
                switch list.marker {
                case .bullet, .ordered:
                    prefix = indent + "\u{2022} "
                case .checklist:
                    prefix = indent + (list.checked == true ? "\u{2611} " : "\u{2610} ")
                }
            }
            let prefixKind: SharedMessageVersionDiff.RunKind = line.isWhollyInserted ? .inserted : (line.isWhollyDeleted ? .deleted : .equal)
            if !prefix.isEmpty {
                result.append(NSAttributedString(string: prefix, attributes: self.attributes(for: prefixKind, font: font, theme: theme, paragraphStyle: paragraphStyle)))
            }
            for run in line.runs {
                result.append(NSAttributedString(string: run.text, attributes: self.attributes(for: run.kind, font: font, theme: theme, paragraphStyle: paragraphStyle)))
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraphStyle]))
            }
        }
        return result
    }

    private func attributes(for kind: SharedMessageVersionDiff.RunKind, font: UIFont, theme: PresentationTheme, paragraphStyle: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle]
        switch kind {
        case .equal:
            attributes[.foregroundColor] = theme.list.itemPrimaryTextColor
        case .inserted:
            attributes[.foregroundColor] = SharedMessageVersionView.insertedColor
            attributes[.backgroundColor] = SharedMessageVersionView.insertedColor.withAlphaComponent(0.12)
        case .deleted:
            attributes[.foregroundColor] = SharedMessageVersionView.deletedColor
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = SharedMessageVersionView.deletedColor
        }
        return attributes
    }

    // MARK: - Actions

    private func step(by delta: Int) {
        let target = self.index + delta
        guard target >= 0, target < self.versions.count else {
            return
        }
        self.index = target
        self.reload()
    }

    @objc private func tabPressed(_ sender: SharedMessageVersionTab) {
        guard let version = self.version else {
            return
        }
        // The same light click a picker or segmented control gives on a change.
        self.tabHaptic.tap()
        if sender.tag < 0 || sender.tag >= version.authorIds.count {
            self.selectedAuthor = nil
        } else {
            self.selectedAuthor = version.authorIds[sender.tag]
        }
        self.reload()
    }

    private func morePressed() {
        guard let version = self.version, let sourceView = self.moreControl.view else {
            return
        }
        let strings = self.presentationData.strings
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Editor_RestoredVersion, icon: { theme in
            return sharedMessageMenuSymbol("arrow.uturn.backward", color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.default)
            guard let self else {
                return
            }
            // Restoring replaces everyone's current text, so it is confirmed first.
            let alert = textAlertController(context: self.context, title: strings.SharedMessage_Version_RestoreConfirmTitle, text: strings.SharedMessage_Version_RestoreConfirmText, actions: [
                TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultAction, title: strings.SharedMessage_Version_RestoreConfirmAction, action: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.session.restore(versionId: version.id)
                    if let onRestored = self.onRestored {
                        onRestored()
                    } else {
                        self.onDismiss?()
                    }
                })
            ])
            self.presentAlert?(alert)
        })))
        items.append(.separator)
        // Compare with Current is hidden until its flow exists (it only closed the menu).
        /*items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Version_CompareWithCurrent, icon: { theme in
            return sharedMessageMenuSymbol("rectangle.lefthalf.inset.filled", color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            f(.default)
        })))*/
        // Reply and Copy use the chat menu's own icons, at the size every other menu shows them.
        items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Version_ReplyInChat, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Reply"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.default)
            self?.onReplyInChat?(version)
        })))
        items.append(.action(ContextMenuActionItem(text: strings.SharedMessage_Version_CopyText, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.default)
            self?.onCopyText?(version)
        })))
        let contextController = makeContextController(
            presentationData: self.presentationData,
            source: .reference(SharedMessageVersionsReferenceSource(sourceView: sourceView)),
            items: .single(ContextController.Items(content: .list(items)))
        )
        self.presentMenu(contextController)
    }
}

/// A pill in the version screen's author row: an optional avatar and a name. 32pt tall, 15pt text,
/// the avatar 2pt from the left edge and the text 8pt from the right.
final class SharedMessageVersionTab: UIControl {
    static let height: CGFloat = 32.0
    private static let leftInset: CGFloat = 2.0
    private static let textOnlyLeftInset: CGFloat = 12.0
    private static let rightInset: CGFloat = 8.0
    private static let avatarSize: CGFloat = 24.0
    private static let avatarTextSpacing: CGFloat = 6.0
    // Text centred in the pill reads a touch low beside the avatar; it sits one point higher.
    private static let textVerticalOffset: CGFloat = -1.0

    let label = UILabel()
    var avatarView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let avatarView {
                avatarView.isUserInteractionEnabled = false
                self.addSubview(avatarView)
            }
            self.setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.layer.cornerRadius = SharedMessageVersionTab.height / 2.0
        self.label.font = Font.regular(15.0)
        self.label.isUserInteractionEnabled = false
        self.addSubview(self.label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Every pill is grey until selected; the selected one wears its colour: an 8% fill and full-colour
    /// text. `color` is an author's chat name colour, nil is "All changes", which selects in blue.
    /// The greys and blue are the design's light values; a dark theme takes the theme's equivalents.
    func apply(color: UIColor?, selected: Bool, theme: PresentationTheme) {
        let dark = theme.overallDarkAppearance
        if selected {
            let tint = color ?? (dark ? theme.list.itemAccentColor : UIColor(rgb: 0x008bff))
            self.backgroundColor = tint.withAlphaComponent(0.08)
            self.label.textColor = tint
        } else {
            self.backgroundColor = dark ? theme.list.itemInputField.backgroundColor : UIColor(rgb: 0xf2f2f7)
            self.label.textColor = dark ? theme.list.itemSecondaryTextColor : UIColor(rgb: 0x3c3c43, alpha: 0.6)
        }
    }

    private var textLeft: CGFloat {
        if self.avatarView != nil {
            return SharedMessageVersionTab.leftInset + SharedMessageVersionTab.avatarSize + SharedMessageVersionTab.avatarTextSpacing
        }
        return SharedMessageVersionTab.textOnlyLeftInset
    }

    var preferredWidth: CGFloat {
        let textWidth = ceil(self.label.sizeThatFits(CGSize(width: 300.0, height: SharedMessageVersionTab.height)).width)
        return self.textLeft + textWidth + SharedMessageVersionTab.rightInset
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let avatarView {
            let size = SharedMessageVersionTab.avatarSize
            avatarView.frame = CGRect(x: SharedMessageVersionTab.leftInset, y: floor((self.bounds.height - size) / 2.0), width: size, height: size)
        }
        self.label.frame = CGRect(x: self.textLeft, y: SharedMessageVersionTab.textVerticalOffset, width: max(0.0, self.bounds.width - self.textLeft - SharedMessageVersionTab.rightInset), height: self.bounds.height)
    }
}
