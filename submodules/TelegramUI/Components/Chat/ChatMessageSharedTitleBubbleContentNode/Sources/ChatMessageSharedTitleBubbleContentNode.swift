import Foundation
import LottieSettings
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import TextFormat
import AccountContext
import MergedAvatarsNode
import ChatMessageBubbleContentNode
import ChatMessageItemCommon

/// The header of a shared message: the bold title, then the editors' avatars (drawn exactly like a
/// poll's voters) and a status line, over a hairline. The status is one of three: who can edit while
/// nobody has edited yet, who is editing right now (the room topic's typing activity), or the last edit.
public final class ChatMessageSharedTitleBubbleContentNode: ChatMessageBubbleContentNode {
    // 4pt above the title, title 17/22, a 2pt gap, an 18pt row holding the poll-sized avatars and the
    // 15pt caption 6pt after them, 8pt below, then the hairline on the text insets.
    private static let titleTopInset: CGFloat = 4.0
    private static let titleLineHeight: CGFloat = 22.0
    private static let titleGap: CGFloat = 2.0
    private static let rowHeight: CGFloat = 18.0
    private static let avatarSize: CGFloat = MergedAvatarsNode.defaultMergedImageSize
    private static let avatarSpacing: CGFloat = MergedAvatarsNode.defaultMergedImageSpacing
    private static let avatarTextSpacing: CGFloat = 6.0
    private static let bottomInset: CGFloat = 8.0
    private static let maxAvatars = 3
    /// The marker is written into the message within moments of sharing; an edit that close to
    /// `sharedAt` is that write, not a change by an editor.
    private static let markerWriteTolerance: Int32 = 60

    private let titleNode: TextNode
    private let captionNode: TextNode
    private let separatorNode: ASDisplayNode
    private let avatarsNode: MergedAvatarsNode
    private var loadedPeers: [EnginePeer.Id: EnginePeer] = [:]
    private var requestedPeerIds = Set<EnginePeer.Id>()
    private let peersDisposable = MetaDisposable()
    /// Who is typing in the message's room topic right now, which is what the editor sends while a
    /// caret is in the document.
    private var editingPeerIds: [EnginePeer.Id] = []
    private var activitiesKey: SharedMessageAttribute.Link?
    private let activitiesDisposable = MetaDisposable()

    required public init(lottieSettings: LottieRenderingSettings) {
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.contentMode = .topLeft
        self.titleNode.contentsScale = UIScreenScale

        self.captionNode = TextNode()
        self.captionNode.isUserInteractionEnabled = false
        self.captionNode.contentMode = .topLeft
        self.captionNode.contentsScale = UIScreenScale

        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true

        self.avatarsNode = MergedAvatarsNode()
        self.avatarsNode.isUserInteractionEnabled = false

        super.init(lottieSettings: lottieSettings)

        self.addSubnode(self.titleNode)
        self.addSubnode(self.separatorNode)
        self.addSubnode(self.avatarsNode)
        self.addSubnode(self.captionNode)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.peersDisposable.dispose()
        self.activitiesDisposable.dispose()
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeCaptionLayout = TextNode.asyncLayout(self.captionNode)
        let currentEditingPeerIds = self.editingPeerIds

        return { [weak self] item, layoutConstants, _, _, _, _ in
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { [weak self] constrainedSize, position in
                let insets = layoutConstants.text.bubbleInsets
                var topInset: CGFloat = insets.top
                if case let .linear(top, _) = position, case let .Neighbour(_, topType, _) = top, case .text = topType {
                    topInset = insets.top - 2.0
                }

                let incoming = item.message.effectivelyIncoming(item.context.account.peerId)
                let messageTheme = incoming ? item.presentationData.theme.theme.chat.message.incoming : item.presentationData.theme.theme.chat.message.outgoing
                let strings = item.presentationData.strings
                let dateTimeFormat = item.presentationData.dateTimeFormat
                let accountPeerId = item.context.account.peerId

                var shared: SharedMessageAttribute?
                for attribute in item.message.attributes {
                    if let attribute = attribute as? SharedMessageAttribute {
                        shared = attribute
                        break
                    }
                }
                let activity = shared?.activity ?? SharedMessageAttribute.Activity()
                let now = Int32(Date().timeIntervalSince1970)
                let isClosed = shared?.footerState(now: now) == .closed

                func peer(_ peerId: EnginePeer.Id) -> EnginePeer? {
                    if let peer = item.message.peers[peerId] {
                        return EnginePeer(peer)
                    }
                    if let author = item.message.author, author.id == peerId {
                        return EnginePeer(author)
                    }
                    return self?.loadedPeers[peerId]
                }

                // Everyone who may edit, the author first, in order of first participation.
                var editorIds: [EnginePeer.Id] = []
                if let author = item.message.author {
                    editorIds.append(author.id)
                }
                for peerId in activity.editorPeerIds where !editorIds.contains(peerId) {
                    editorIds.append(peerId)
                }
                for peerId in shared?.peerIds ?? [] where !editorIds.contains(peerId) {
                    editorIds.append(peerId)
                }

                // Editing now: the room's typing peers, plus the debug cycle's one.
                var editingIds = currentEditingPeerIds.filter { $0 != accountPeerId }
                if let editingPeerId = activity.editingPeerId, !editingIds.contains(editingPeerId) {
                    editingIds.append(editingPeerId)
                }
                for peerId in editingIds where !editorIds.contains(peerId) {
                    editorIds.append(peerId)
                }

                // The last edit: what the activity records, else the message's own edit date, which the
                // author's device moves on every save; the marker write at sharing does not count.
                var lastEditAt: Int32 = activity.lastEditAt
                if lastEditAt == 0, let edited = item.message.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute, edited.date > activity.sharedAt + ChatMessageSharedTitleBubbleContentNode.markerWriteTolerance {
                    lastEditAt = edited.date
                }

                let captionText: String
                let captionColor: UIColor
                let shownIds: [EnginePeer.Id]
                if isClosed {
                    captionText = strings.SharedMessage_Header_Closed
                    captionColor = messageTheme.secondaryTextColor
                    shownIds = Array(editorIds.prefix(ChatMessageSharedTitleBubbleContentNode.maxAvatars))
                } else if !editingIds.isEmpty {
                    let names = editingIds.map { peer($0)?.compactDisplayTitle ?? "" }.filter { !$0.isEmpty }
                    if names.count == 1 {
                        captionText = strings.SharedMessage_Footer_IsEditing(names[0]).string
                    } else {
                        captionText = strings.SharedMessage_Header_AreEditing(names.joined(separator: ", ")).string
                    }
                    captionColor = messageTheme.accentTextColor
                    shownIds = Array(editingIds.prefix(ChatMessageSharedTitleBubbleContentNode.maxAvatars))
                } else if lastEditAt > 0 {
                    captionText = strings.SharedMessage_Header_LastEdit(ChatMessageSharedTitleBubbleContentNode.lastEditString(timestamp: lastEditAt, strings: strings, dateTimeFormat: dateTimeFormat)).string
                    captionColor = messageTheme.accentTextColor
                    shownIds = Array(editorIds.prefix(ChatMessageSharedTitleBubbleContentNode.maxAvatars))
                } else {
                    let others = Int32(editorIds.filter { $0 != accountPeerId }.count)
                    if editorIds.contains(accountPeerId) {
                        captionText = others == 0 ? strings.SharedMessage_Header_YouCanEdit : strings.SharedMessage_Header_YouAndOthers(others)
                    } else {
                        captionText = strings.SharedMessage_Header_OthersCanEdit(others)
                    }
                    captionColor = messageTheme.accentTextColor
                    shownIds = Array(editorIds.prefix(ChatMessageSharedTitleBubbleContentNode.maxAvatars))
                }

                let titleFont = Font.bold(17.0)
                let title = shared?.title ?? ""
                let attributedTitle = NSAttributedString(string: title.isEmpty ? " " : title, font: titleFont, textColor: messageTheme.primaryTextColor)
                let maxWidth = max(1.0, constrainedSize.width - insets.left - insets.right)
                let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: attributedTitle, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))

                let avatarSize = ChatMessageSharedTitleBubbleContentNode.avatarSize
                let avatarsWidth = shownIds.isEmpty ? 0.0 : avatarSize + ChatMessageSharedTitleBubbleContentNode.avatarSpacing * CGFloat(shownIds.count - 1)
                let captionLeft = shownIds.isEmpty ? 0.0 : avatarsWidth + ChatMessageSharedTitleBubbleContentNode.avatarTextSpacing
                let (captionLayout, captionApply) = makeCaptionLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: captionText, font: Font.regular(15.0), textColor: captionColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(1.0, maxWidth - captionLeft), height: CGFloat.greatestFiniteMagnitude), alignment: .natural, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))

                let suggestedWidth = max(titleLayout.size.width, captionLeft + captionLayout.size.width) + insets.left + insets.right

                return (suggestedWidth, { [weak self] boundingWidth in
                    let titleTop = topInset + ChatMessageSharedTitleBubbleContentNode.titleTopInset
                    let rowTop = titleTop + ChatMessageSharedTitleBubbleContentNode.titleLineHeight + ChatMessageSharedTitleBubbleContentNode.titleGap
                    let rowHeight = ChatMessageSharedTitleBubbleContentNode.rowHeight
                    let height = rowTop + rowHeight + ChatMessageSharedTitleBubbleContentNode.bottomInset + UIScreenPixel
                    let size = CGSize(width: boundingWidth, height: height)

                    return (size, { [weak self] _, synchronousLoads, _ in
                        guard let self else {
                            return
                        }
                        self.item = item

                        let missingPeerIds = (shownIds + editingIds).filter { peer($0) == nil && !self.requestedPeerIds.contains($0) }
                        if !missingPeerIds.isEmpty {
                            self.requestedPeerIds.formUnion(missingPeerIds)
                            self.peersDisposable.set((item.context.engine.data.get(EngineDataList(missingPeerIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
                            |> deliverOnMainQueue).startStrict(next: { [weak self] peers in
                                guard let self else {
                                    return
                                }
                                for peer in peers {
                                    if let peer {
                                        self.loadedPeers[peer.id] = peer
                                    }
                                }
                                self.item?.controllerInteraction.requestMessageUpdate(item.message.id, false, nil)
                            }))
                        }

                        self.watchRoomActivity(context: item.context, link: shared?.link, messageId: item.message.id)

                        let _ = titleApply()
                        let _ = captionApply()

                        self.titleNode.frame = CGRect(origin: CGPoint(x: insets.left, y: titleTop + floor((ChatMessageSharedTitleBubbleContentNode.titleLineHeight - titleLayout.size.height) / 2.0)), size: titleLayout.size)

                        let avatarsFrame = CGRect(origin: CGPoint(x: insets.left, y: rowTop + floor((rowHeight - avatarSize) / 2.0)), size: CGSize(width: avatarsWidth, height: avatarSize))
                        self.avatarsNode.frame = avatarsFrame
                        self.avatarsNode.updateLayout(size: avatarsFrame.size)
                        self.avatarsNode.update(context: item.context, peers: shownIds.compactMap { peer($0) }, synchronousLoad: synchronousLoads, imageSize: avatarSize, imageSpacing: ChatMessageSharedTitleBubbleContentNode.avatarSpacing, borderWidth: MergedAvatarsNode.defaultBorderWidth)
                        self.avatarsNode.alpha = isClosed ? 0.55 : 1.0

                        self.captionNode.frame = CGRect(origin: CGPoint(x: insets.left + captionLeft, y: rowTop + floor((rowHeight - captionLayout.size.height) / 2.0)), size: captionLayout.size)

                        self.separatorNode.backgroundColor = messageTheme.polls.separator
                        self.separatorNode.frame = CGRect(x: insets.left, y: height - UIScreenPixel, width: max(0.0, boundingWidth - insets.left - insets.right), height: UIScreenPixel)
                    })
                })
            })
        }
    }

    /// "today at 12:40", "yesterday at 12:40", else "Nov 15 at 12:40".
    private static func lastEditString(timestamp: Int32, strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> String {
        let now = Int32(Date().timeIntervalSince1970)
        var t: time_t = time_t(timestamp)
        var timeinfo = tm()
        localtime_r(&t, &timeinfo)
        var nowT: time_t = time_t(now)
        var nowInfo = tm()
        localtime_r(&nowT, &nowInfo)
        if timeinfo.tm_year == nowInfo.tm_year && abs(timeinfo.tm_yday - nowInfo.tm_yday) <= 1 {
            return humanReadableStringForTimestamp(strings: strings, dateTimeFormat: dateTimeFormat, timestamp: timestamp, alwaysShowTime: true).string
        }
        let formatter = DateFormatter()
        formatter.locale = localeWithStrings(strings)
        formatter.setLocalizedDateFormatFromTemplate(timeinfo.tm_year == nowInfo.tm_year ? "MMMd" : "MMMdyyyy")
        let dateString = formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
        let timeString = stringForShortTimestamp(hours: Int32(timeinfo.tm_hour), minutes: Int32(timeinfo.tm_min), dateTimeFormat: dateTimeFormat)
        return strings.SharedMessage_Header_DateAtTime(dateString, timeString).string
    }

    /// Follows the typing activity of the message's room topic, which the shared editor sends while a
    /// caret is in the document, and re-lays the message out when the set of editing peers changes.
    private func watchRoomActivity(context: AccountContext, link: SharedMessageAttribute.Link?, messageId: EngineMessage.Id) {
        guard self.activitiesKey != link else {
            return
        }
        self.activitiesKey = link
        guard let link else {
            self.activitiesDisposable.set(nil)
            self.editingPeerIds = []
            return
        }
        let space = PeerActivitySpace(peerId: link.roomPeerId, category: .thread(link.topicId))
        self.activitiesDisposable.set((context.account.peerInputActivities(peerId: space)
        |> map { activities -> [EnginePeer.Id] in
            var result: [EnginePeer.Id] = []
            for (peerId, activity) in activities {
                if case .typingText = activity, !result.contains(peerId) {
                    result.append(peerId)
                }
            }
            return result
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue).startStrict(next: { [weak self] peerIds in
            guard let self, self.editingPeerIds != peerIds else {
                return
            }
            self.editingPeerIds = peerIds
            self.item?.controllerInteraction.requestMessageUpdate(messageId, false, nil)
        }))
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
        return ChatMessageBubbleContentTapAction(content: .none)
    }
}
