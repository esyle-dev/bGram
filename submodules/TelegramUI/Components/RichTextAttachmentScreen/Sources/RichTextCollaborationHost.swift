import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AvatarNode
import RichTextEditorCore

/// What makes the rich-text editor a shared editor: the document everyone else changes, who is in
/// it, and where the editor's own changes go. The screen draws the header and the paragraph locks
/// from it and never knows what carries the changes.
public final class RichTextCollaborationHost {
    public struct Participant: Equatable {
        public let peerId: EnginePeer.Id
        public let peer: EnginePeer?
        public let color: UIColor
        /// The block this person holds. Nobody else can enter it while it is held.
        public let blockId: BlockID?
        public let isEditing: Bool

        public init(peerId: EnginePeer.Id, peer: EnginePeer?, color: UIColor, blockId: BlockID?, isEditing: Bool) {
            self.peerId = peerId
            self.peer = peer
            self.color = color
            self.blockId = blockId
            self.isEditing = isEditing
        }
    }

    /// The line under the title, with the people it is about in front of it.
    public enum Status: Equatable {
        /// Nobody has edited yet: "You and 2 others can edit", grey, the people who may edit in front.
        case canEdit(text: String, peers: [EnginePeer])
        /// Someone else is typing now: blue, with dots that type themselves out after the text. The
        /// texts are in order of preference ("Milli and Tom are editing", then "2 users editing"); the
        /// header shows the first that fits the room it has.
        case editing(texts: [String], peers: [EnginePeer])
        /// "Last edit Nov 15 at 12:40", grey, with the people who made it in front.
        case lastEdit(text: String, peers: [EnginePeer])
    }

    /// A short line in a capsule over the toolbar about where the changes are: saved automatically,
    /// kept on the device while offline, synced again. The host decides when one shows and for how long.
    public struct Notice: Equatable {
        public enum Icon: Equatable {
            case saved
            case offline
            case synced
        }

        public let icon: Icon
        public let title: String
        /// Grey, after a " · ".
        public let subtitle: String?

        public init(icon: Icon, title: String, subtitle: String?) {
            self.icon = icon
            self.title = title
            self.subtitle = subtitle
        }
    }

    public struct Update: Equatable {
        /// The message's title as it is now; it changes when the settings are edited while the editor is open.
        public let title: String
        public let document: Document
        /// The revision the document is at. The editor reports it back with its own changes.
        public let revision: Int
        public let participants: [Participant]
        public let status: Status
        /// How many versions the history holds; shown on the history button, which is hidden at zero.
        public let versionCount: Int

        public init(title: String, document: Document, revision: Int, participants: [Participant], status: Status, versionCount: Int) {
            self.title = title
            self.document = document
            self.revision = revision
            self.participants = participants
            self.status = status
            self.versionCount = versionCount
        }
    }

    /// The title at open; `Update.title` carries later changes.
    public let title: String
    public let updates: Signal<Update, NoError>
    /// The editor's document after a pause in typing, with the revision it was based on and the block
    /// the caret is in.
    public let localDocumentChanged: (Document, Int, BlockID?) -> Void
    public let localCaretChanged: (BlockID?) -> Void
    /// The history button was tapped; the host shows the versions anchored to the button, and may
    /// put a full-screen overlay (a version) over the editor through the presenter it is given.
    public let openHistory: (ViewController, UIView, @escaping (RichTextCollaborationOverlay) -> Void) -> Void
    /// The "…" button in the sheet's top bar was tapped; the host shows its menu anchored to the
    /// button. The last closure closes the editor the way the close button does (`finished` runs).
    public let openMenu: (ViewController, UIView, @escaping () -> Void) -> Void
    /// The editor is closing, by Done or by the close button. There is no cancel: everything is saved as typed.
    public let finished: () -> Void
    /// The notice over the toolbar; nil hides it.
    public let notice: Signal<Notice?, NoError>

    public init(title: String, updates: Signal<Update, NoError>, notice: Signal<Notice?, NoError> = .single(nil), localDocumentChanged: @escaping (Document, Int, BlockID?) -> Void, localCaretChanged: @escaping (BlockID?) -> Void, openHistory: @escaping (ViewController, UIView, @escaping (RichTextCollaborationOverlay) -> Void) -> Void, openMenu: @escaping (ViewController, UIView, @escaping () -> Void) -> Void, finished: @escaping () -> Void) {
        self.title = title
        self.updates = updates
        self.notice = notice
        self.localDocumentChanged = localDocumentChanged
        self.localCaretChanged = localCaretChanged
        self.openHistory = openHistory
        self.openMenu = openMenu
        self.finished = finished
    }
}

/// A view the shared editor shows over itself inside the same sheet (a version of the document),
/// slid in from the right; it asks to go away through `onDismiss`.
public protocol RichTextCollaborationOverlay: UIView {
    var onDismiss: (() -> Void)? { get set }
    /// `navigationHeight` is the sheet's own top area (its close/undo controls), which the overlay's
    /// content starts below, like the editor's header does.
    func updateLayout(size: CGSize, safeInsets: UIEdgeInsets, navigationHeight: CGFloat)
}

/// The header of a shared editor: the title, the last edit with its authors, and the history button.
/// 12pt above the 22pt bold title, 12pt to the status row, 12pt to the hairline; it lives at the top
/// of the editor's scroll content, and the editor's own top margin puts the text 12pt below the line.
final class RichTextCollaborationHeaderView: UIView {
    enum Status: Equatable {
        /// Nothing has arrived yet: grey placeholders stand in for the avatar and the text.
        case loading
        case loaded(RichTextCollaborationHost.Status)
    }

    /// The dots after "… is editing" type themselves out one by one and vanish: none, one, two,
    /// three, none again, a step every `dotsInterval`.
    private static let dotsInterval: Double = 0.4
    private static let dotsSteps = 4

    private static let topInset: CGFloat = 12.0
    private static let titleHeight: CGFloat = 26.0
    private static let rowSpacing: CGFloat = 12.0
    private static let rowHeight: CGFloat = 32.0
    static let height: CGFloat = topInset + titleHeight + rowSpacing + rowHeight + rowSpacing + UIScreenPixel

    private static let avatarSize: CGFloat = 28.0
    private static let avatarOverlap: CGFloat = 10.0
    private static let avatarRing: CGFloat = 1.5
    private static let avatarTextSpacing: CGFloat = 8.0
    private static let maxAvatars = 3
    // A 20pt icon with 8pt at the sides in a 32pt capsule.
    // History button: 36pt tall, 8pt at the sides, an 18pt icon in a 22pt box, 2pt, the version count.
    private static let historyButtonHeight: CGFloat = 36.0
    private static let historySidePadding: CGFloat = 8.0
    private static let historyIconBox: CGFloat = 22.0
    private static let historyIconTextSpacing: CGFloat = 2.0

    private let titleLabel: UILabel
    private var ringViews: [UIView] = []
    private var avatarNodes: [AvatarNode] = []
    private let statusLabel: UILabel
    private let avatarPlaceholder: UIView
    private let statusPlaceholder: UIView
    private let historyButton: UIButton
    private let historyIcon: UIImageView
    private let historyCountLabel: UILabel
    private let separator: UIView

    /// The text under the dots while someone is editing; nil in the other states.
    private var editingText: String?
    private var dotsStep = 0
    private var dotsTimer: SwiftSignalKit.Timer?

    var historyTapped: ((UIView) -> Void)?

    deinit {
        self.dotsTimer?.invalidate()
    }

    override init(frame: CGRect) {
        self.titleLabel = UILabel()
        self.titleLabel.font = Font.bold(22.0)
        self.titleLabel.numberOfLines = 1
        self.titleLabel.lineBreakMode = .byTruncatingTail

        self.statusLabel = UILabel()
        self.statusLabel.font = Font.regular(15.0)
        self.statusLabel.numberOfLines = 1
        self.statusLabel.lineBreakMode = .byTruncatingTail

        self.avatarPlaceholder = UIView()
        self.avatarPlaceholder.isUserInteractionEnabled = false
        self.avatarPlaceholder.layer.cornerRadius = RichTextCollaborationHeaderView.avatarSize / 2.0
        self.statusPlaceholder = UIView()
        self.statusPlaceholder.isUserInteractionEnabled = false
        self.statusPlaceholder.layer.cornerRadius = 7.0

        self.historyButton = UIButton(type: .custom)
        self.historyButton.layer.cornerRadius = RichTextCollaborationHeaderView.historyButtonHeight / 2.0
        self.historyButton.clipsToBounds = true
        self.historyIcon = UIImageView()
        self.historyIcon.image = UIImage(systemName: "clock.arrow.circlepath", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .regular))
        self.historyIcon.contentMode = .center
        self.historyIcon.isUserInteractionEnabled = false
        self.historyCountLabel = UILabel()
        self.historyCountLabel.font = Font.medium(15.0)
        self.historyCountLabel.isUserInteractionEnabled = false

        self.separator = UIView()

        super.init(frame: frame)

        self.addSubview(self.titleLabel)
        // Later avatars lie under earlier ones, so each ring covers the avatar to its right.
        for _ in 0 ..< RichTextCollaborationHeaderView.maxAvatars {
            let ringView = UIView()
            ringView.isUserInteractionEnabled = false
            ringView.layer.cornerRadius = (RichTextCollaborationHeaderView.avatarSize + RichTextCollaborationHeaderView.avatarRing * 2.0) / 2.0
            self.ringViews.insert(ringView, at: 0)

            let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 12.0))
            avatarNode.isUserInteractionEnabled = false
            self.avatarNodes.insert(avatarNode, at: 0)
        }
        for index in 0 ..< RichTextCollaborationHeaderView.maxAvatars {
            self.addSubview(self.ringViews[index])
            self.addSubview(self.avatarNodes[index].view)
        }
        self.addSubview(self.statusLabel)
        self.addSubview(self.avatarPlaceholder)
        self.addSubview(self.statusPlaceholder)
        self.addSubview(self.historyButton)
        self.historyButton.addSubview(self.historyIcon)
        self.historyButton.addSubview(self.historyCountLabel)
        self.addSubview(self.separator)
        self.historyButton.addTarget(self, action: #selector(self.historyPressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func historyPressed() {
        self.historyTapped?(self.historyButton)
    }

    func update(context: AccountContext, theme: PresentationTheme, backgroundColor: UIColor, title: String, status: Status, versionCount: Int, width: CGFloat, sideInset: CGFloat) {
        self.backgroundColor = backgroundColor
        self.titleLabel.text = title
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.statusLabel.textColor = theme.list.itemSecondaryTextColor
        self.historyButton.backgroundColor = theme.list.itemAccentColor
        self.historyIcon.tintColor = theme.list.itemCheckColors.foregroundColor
        self.historyCountLabel.textColor = theme.list.itemCheckColors.foregroundColor
        self.historyCountLabel.text = "\(versionCount)"
        self.separator.backgroundColor = theme.list.itemPlainSeparatorColor
        let placeholderColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.18)
        self.avatarPlaceholder.backgroundColor = placeholderColor
        self.statusPlaceholder.backgroundColor = placeholderColor

        let avatarSize = RichTextCollaborationHeaderView.avatarSize
        let countWidth = ceil(self.historyCountLabel.sizeThatFits(CGSize(width: 100.0, height: 36.0)).width)
        let buttonSize = CGSize(width: RichTextCollaborationHeaderView.historySidePadding * 2.0 + RichTextCollaborationHeaderView.historyIconBox + RichTextCollaborationHeaderView.historyIconTextSpacing + countWidth, height: RichTextCollaborationHeaderView.historyButtonHeight)
        let rowHeight = RichTextCollaborationHeaderView.rowHeight
        let contentWidth = max(1.0, width - sideInset * 2.0)
        self.titleLabel.frame = CGRect(x: sideInset, y: RichTextCollaborationHeaderView.topInset, width: contentWidth, height: RichTextCollaborationHeaderView.titleHeight)

        let rowY = RichTextCollaborationHeaderView.topInset + RichTextCollaborationHeaderView.titleHeight + RichTextCollaborationHeaderView.rowSpacing
        let avatarStep = avatarSize - RichTextCollaborationHeaderView.avatarOverlap
        let avatarY = rowY + floor((rowHeight - avatarSize) / 2.0)

        // The history button only appears once there is a version to show.
        self.historyButton.isHidden = versionCount == 0
        self.historyButton.frame = CGRect(x: width - sideInset - buttonSize.width, y: rowY + floor((rowHeight - buttonSize.height) / 2.0), width: buttonSize.width, height: buttonSize.height)
        let statusRight = versionCount == 0 ? width - sideInset : self.historyButton.frame.minX - 12.0

        var shownPeers: [EnginePeer] = []
        var statusLeft = sideInset
        var editingTexts: [String]?
        switch status {
        case .loading:
            self.statusLabel.text = ""
            self.avatarPlaceholder.isHidden = false
            self.statusPlaceholder.isHidden = false
            self.avatarPlaceholder.frame = CGRect(x: sideInset, y: avatarY, width: avatarSize, height: avatarSize)
            statusLeft += avatarSize + RichTextCollaborationHeaderView.avatarTextSpacing
            self.statusPlaceholder.frame = CGRect(x: statusLeft, y: rowY + floor((rowHeight - 14.0) / 2.0), width: 150.0, height: 14.0)
        case let .loaded(loaded):
            self.avatarPlaceholder.isHidden = true
            self.statusPlaceholder.isHidden = true
            let peers: [EnginePeer]
            switch loaded {
            case let .canEdit(text, statusPeers):
                self.statusLabel.text = text
                self.statusLabel.textColor = theme.list.itemSecondaryTextColor
                peers = statusPeers
            case let .lastEdit(text, statusPeers):
                self.statusLabel.text = text
                self.statusLabel.textColor = theme.list.itemSecondaryTextColor
                peers = statusPeers
            case let .editing(texts, statusPeers):
                self.statusLabel.textColor = theme.list.itemAccentColor
                editingTexts = texts
                peers = statusPeers
            }
            shownPeers = Array(peers.prefix(RichTextCollaborationHeaderView.maxAvatars))
            if !shownPeers.isEmpty {
                statusLeft += avatarSize + avatarStep * CGFloat(shownPeers.count - 1) + RichTextCollaborationHeaderView.avatarTextSpacing
            }
        }
        if let editingTexts {
            // The first text that fits with its three dots; the last one is the shortest and is shown whatever the room.
            let available = statusRight - statusLeft
            var chosen = editingTexts.last ?? ""
            for text in editingTexts {
                let measured = NSAttributedString(string: text + "...", font: self.statusLabel.font).boundingRect(with: CGSize(width: 10000.0, height: rowHeight), options: [.usesLineFragmentOrigin], context: nil).width
                if ceil(measured) <= available {
                    chosen = text
                    break
                }
            }
            if self.editingText != chosen {
                self.editingText = chosen
                self.dotsStep = 0
                self.applyDots()
            }
            if self.dotsTimer == nil {
                let timer = SwiftSignalKit.Timer(timeout: RichTextCollaborationHeaderView.dotsInterval, repeat: true, completion: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.dotsStep = (self.dotsStep + 1) % RichTextCollaborationHeaderView.dotsSteps
                    self.applyDots()
                }, queue: Queue.mainQueue())
                self.dotsTimer = timer
                timer.start()
            }
        } else {
            self.editingText = nil
            self.dotsTimer?.invalidate()
            self.dotsTimer = nil
        }
        for index in 0 ..< self.avatarNodes.count {
            let avatarNode = self.avatarNodes[index]
            let ringView = self.ringViews[index]
            if index < shownPeers.count {
                avatarNode.view.isHidden = false
                ringView.isHidden = false
                let avatarFrame = CGRect(x: sideInset + avatarStep * CGFloat(index), y: avatarY, width: avatarSize, height: avatarSize)
                ringView.backgroundColor = backgroundColor
                ringView.frame = avatarFrame.insetBy(dx: -RichTextCollaborationHeaderView.avatarRing, dy: -RichTextCollaborationHeaderView.avatarRing)
                avatarNode.frame = avatarFrame
                avatarNode.setPeer(context: context, theme: theme, peer: shownPeers[index], displayDimensions: avatarFrame.size)
                avatarNode.updateSize(size: avatarFrame.size)
            } else {
                avatarNode.view.isHidden = true
                ringView.isHidden = true
            }
        }

        let iconBox = RichTextCollaborationHeaderView.historyIconBox
        self.historyIcon.frame = CGRect(x: RichTextCollaborationHeaderView.historySidePadding, y: floor((buttonSize.height - iconBox) / 2.0), width: iconBox, height: iconBox)
        self.historyCountLabel.frame = CGRect(x: self.historyIcon.frame.maxX + RichTextCollaborationHeaderView.historyIconTextSpacing, y: 0.0, width: countWidth, height: buttonSize.height)
        self.statusLabel.frame = CGRect(x: statusLeft, y: rowY, width: max(1.0, statusRight - statusLeft), height: rowHeight)
        self.separator.frame = CGRect(x: sideInset, y: RichTextCollaborationHeaderView.height - UIScreenPixel, width: contentWidth, height: UIScreenPixel)
    }

    private func applyDots() {
        guard let editingText else {
            return
        }
        self.statusLabel.text = editingText + String(repeating: ".", count: self.dotsStep)
    }
}

/// A paragraph someone else holds, in their name colour: the whole paragraph on an 8% tint of it
/// that starts 4pt left of the text, a 2pt line of it before that (rounded on its left), their 18pt avatar 2pt inside the
/// tint's right edge (centred on one line, at the bottom when there are more), and the glyphs
/// darkened to the colour with 60% black over it. One line is a capsule on the right; more lines
/// round 4pt at the top right and 11pt around the avatar. Taps do not reach the text under it.
///
/// The glyphs are recoloured from a snapshot the screen takes of the editor under the tint (the
/// sheet isolates its compositing, so a blend mode over the text does not reach it): an opaque
/// page-coloured cover hides the editor's own ink and a view in the text colour, masked by the
/// snapshot's ink, draws it again.
final class RichTextCollaborationLockView: UIView {
    private static let leftInset: CGFloat = 4.0
    private static let barWidth: CGFloat = 2.0
    private static let avatarSize: CGFloat = 18.0
    private static let avatarInset: CGFloat = 2.0
    private static let topRightRadius: CGFloat = 4.0

    private let coverView: UIView
    private let backgroundView: UIView
    private let backgroundLayer: CAShapeLayer
    private let glyphView: UIView
    private let glyphMaskLayer: CALayer
    private let barView: UIView
    private let avatarNode: AvatarNode

    /// The tinted area in the superview's space, which is what the screen snapshots for the glyphs.
    private(set) var inkRect: CGRect = .zero

    override init(frame: CGRect) {
        self.coverView = UIView()
        self.coverView.isUserInteractionEnabled = false
        self.backgroundView = UIView()
        self.backgroundView.isUserInteractionEnabled = false
        self.backgroundLayer = CAShapeLayer()
        self.backgroundView.layer.addSublayer(self.backgroundLayer)
        self.glyphView = UIView()
        self.glyphView.isUserInteractionEnabled = false
        self.glyphMaskLayer = CALayer()
        self.glyphMaskLayer.contentsGravity = .resize
        self.glyphView.layer.mask = self.glyphMaskLayer
        self.glyphView.isHidden = true
        self.barView = UIView()
        self.barView.isUserInteractionEnabled = false
        self.barView.layer.cornerRadius = RichTextCollaborationLockView.barWidth / 2.0
        self.barView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        self.avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 8.0))
        self.avatarNode.isUserInteractionEnabled = false

        super.init(frame: frame)

        self.addSubview(self.coverView)
        self.addSubview(self.backgroundView)
        self.addSubview(self.glyphView)
        self.addSubview(self.barView)
        self.addSubview(self.avatarNode.view)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func backgroundPath(in rect: CGRect, topRight: CGFloat, bottomRight: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(withCenter: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight), radius: topRight, startAngle: -.pi / 2.0, endAngle: 0.0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(withCenter: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight), radius: bottomRight, startAngle: 0.0, endAngle: .pi / 2.0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }

    /// `blockFrame` is the paragraph's whole box and `lineRects` its text lines, both in the
    /// superview's space; the view sizes itself around them. Returns false when there is nothing to show.
    @discardableResult
    func update(context: AccountContext, theme: PresentationTheme, peer: EnginePeer?, color: UIColor, pageColor: UIColor, blockFrame: CGRect?, lineRects: [CGRect], hitRange: ClosedRange<CGFloat>) -> Bool {
        guard let first = lineRects.first, let last = lineRects.last else {
            return false
        }
        let leftInset = RichTextCollaborationLockView.leftInset
        let barWidth = RichTextCollaborationLockView.barWidth
        let avatarSize = RichTextCollaborationLockView.avatarSize
        let avatarInset = RichTextCollaborationLockView.avatarInset

        let textLeft = blockFrame?.minX ?? lineRects.map { $0.minX }.min()!
        let textRight = blockFrame?.maxX ?? lineRects.map { $0.maxX }.max()!
        let span = first.union(last)
        let background = CGRect(x: textLeft - leftInset, y: span.minY, width: max(1.0, textRight - textLeft + leftInset), height: span.height)
        let barFrame = CGRect(x: background.minX - barWidth, y: background.minY, width: barWidth, height: background.height)
        let isSingleLine = lineRects.count == 1
        let avatarFrame: CGRect
        if isSingleLine {
            avatarFrame = CGRect(x: background.maxX - avatarInset - avatarSize, y: background.midY - avatarSize / 2.0, width: avatarSize, height: avatarSize)
        } else {
            avatarFrame = CGRect(x: background.maxX - avatarInset - avatarSize, y: background.maxY - avatarInset - avatarSize, width: avatarSize, height: avatarSize)
        }

        // The hit area spans the editor's width over the lines, so a tap in the margin beside a held
        // paragraph cannot place the caret in it either.
        var bounds = background.union(barFrame).union(avatarFrame)
        bounds = bounds.union(CGRect(x: hitRange.lowerBound, y: span.minY, width: hitRange.upperBound - hitRange.lowerBound, height: span.height))
        self.frame = bounds
        self.inkRect = background

        let local = background.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let bottomRightRadius = min(local.height / 2.0, avatarInset + avatarSize / 2.0)
        let topRightRadius = isSingleLine ? bottomRightRadius : min(RichTextCollaborationLockView.topRightRadius, bottomRightRadius)
        self.coverView.backgroundColor = pageColor
        self.coverView.frame = local
        self.backgroundView.frame = local
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.backgroundLayer.frame = CGRect(origin: .zero, size: local.size)
        self.backgroundLayer.path = RichTextCollaborationLockView.backgroundPath(in: CGRect(origin: .zero, size: local.size), topRight: topRightRadius, bottomRight: bottomRightRadius).cgPath
        self.backgroundLayer.fillColor = color.withAlphaComponent(0.08).cgColor
        self.glyphView.frame = local
        self.glyphMaskLayer.frame = CGRect(origin: .zero, size: local.size)
        CATransaction.commit()
        // The colour with 60% black over it; on a dark page, with 40% white instead.
        self.glyphView.backgroundColor = pageColor.lightness > 0.5 ? color.mixedWith(.black, alpha: 0.6) : color.mixedWith(.white, alpha: 0.4)

        self.barView.backgroundColor = color
        self.barView.frame = barFrame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)

        if let peer {
            self.avatarNode.view.isHidden = false
            self.avatarNode.frame = avatarFrame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            self.avatarNode.setPeer(context: context, theme: theme, peer: peer, displayDimensions: avatarFrame.size)
            self.avatarNode.updateSize(size: avatarFrame.size)
        } else {
            self.avatarNode.view.isHidden = true
        }
        return true
    }

    /// The ink of `inkRect` as a mask (opaque where the editor drew ink); nil shows the editor's own
    /// ink through, which is what the cover hides, so the cover goes with it.
    func setGlyphMask(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.glyphMaskLayer.contents = image
        CATransaction.commit()
        self.glyphView.isHidden = image == nil
        self.coverView.isHidden = image == nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return self.bounds.contains(point)
    }
}

/// One block's part in a sent change: how it was in the host's document and how it was sent. A
/// block the change added has no `before`; one it removed has no `after`.
struct RichTextCollaborationBlockChange {
    let id: BlockID
    let before: Block?
    let after: Block?
    /// Where the block stood in the host's document, for putting a removed block back.
    let index: Int
}

/// The chat composer's flat axis: top-level paragraphs joined by "\n", other blocks contribute nothing.
/// The screen uses it to put the caret back after the document is replaced under it.
enum RichTextCollaborationFlatAxis {
    static func blockAndLocalOffset(forFlat offset: Int, in document: Document) -> (BlockID, Int)? {
        var position = 0
        for block in document.blocks {
            guard case let .paragraph(paragraph) = block else {
                continue
            }
            let length = paragraph.utf16Count
            if offset <= position + length {
                return (paragraph.id, max(0, offset - position))
            }
            position += length + 1
        }
        return nil
    }

    static func flatOffset(ofBlock id: BlockID, localOffset: Int, in document: Document) -> Int? {
        var position = 0
        for block in document.blocks {
            guard case let .paragraph(paragraph) = block else {
                continue
            }
            if paragraph.id == id {
                return position + min(localOffset, paragraph.utf16Count)
            }
            position += paragraph.utf16Count + 1
        }
        return nil
    }

    /// The end of the nearest paragraph before `id` that nobody holds, else the start of the document.
    static func escapeOffset(from id: BlockID, held: Set<BlockID>, in document: Document) -> Int {
        var position = 0
        var lastFreeEnd = 0
        for block in document.blocks {
            guard case let .paragraph(paragraph) = block else {
                continue
            }
            if paragraph.id == id {
                return lastFreeEnd
            }
            if !held.contains(paragraph.id) {
                lastFreeEnd = position + paragraph.utf16Count
            }
            position += paragraph.utf16Count + 1
        }
        return lastFreeEnd
    }
}
