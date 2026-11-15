import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import ItemListPeerItem
import PresentationDataUtils
import AccountContext

private final class SharedMessageMembersArguments {
    let context: AccountContext
    let toggle: (EnginePeer) -> Void

    init(context: AccountContext, toggle: @escaping (EnginePeer) -> Void) {
        self.context = context
        self.toggle = toggle
    }
}

private enum SharedMessageMembersEntry: ItemListNodeEntry {
    case header(PresentationTheme, String)
    case peer(Int32, PresentationTheme, PresentationStrings, PresentationDateTimeFormat, PresentationPersonNameOrder, EnginePeer, Bool)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int64 {
        switch self {
        case .header:
            return 0
        case let .peer(_, _, _, _, _, peer, _):
            return peer.id.toInt64()
        }
    }

    static func ==(lhs: SharedMessageMembersEntry, rhs: SharedMessageMembersEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(lhsTheme, lhsText), .header(rhsTheme, rhsText)):
            return lhsTheme === rhsTheme && lhsText == rhsText
        case let (.peer(lhsIndex, lhsTheme, lhsStrings, lhsDateTimeFormat, lhsOrder, lhsPeer, lhsSelected), .peer(rhsIndex, rhsTheme, rhsStrings, rhsDateTimeFormat, rhsOrder, rhsPeer, rhsSelected)):
            return lhsIndex == rhsIndex && lhsTheme === rhsTheme && lhsStrings === rhsStrings && lhsDateTimeFormat == rhsDateTimeFormat && lhsOrder == rhsOrder && lhsPeer == rhsPeer && lhsSelected == rhsSelected
        default:
            return false
        }
    }

    static func <(lhs: SharedMessageMembersEntry, rhs: SharedMessageMembersEntry) -> Bool {
        return lhs.order < rhs.order
    }

    private var order: Int32 {
        switch self {
        case .header:
            return 0
        case let .peer(index, _, _, _, _, _, _):
            return 1 + index
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SharedMessageMembersArguments
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .peer(_, _, _, dateTimeFormat, nameDisplayOrder, peer, selected):
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: dateTimeFormat, nameDisplayOrder: nameDisplayOrder, context: arguments.context, peer: peer, presence: nil, text: .none, label: .none, editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: nil), switchValue: ItemListPeerItemSwitch(value: selected, style: .check), enabled: true, selectable: true, sectionId: self.section, action: {
                arguments.toggle(peer)
            }, setPeerIdWithRevealedOptions: { _, _ in
            }, removePeer: { _ in
            })
        }
    }
}

private func sharedMessageGroupMembers(context: AccountContext, peerId: EnginePeer.Id) -> Signal<[EnginePeer], NoError> {
    if peerId.namespace == Namespaces.Peer.CloudChannel {
        return Signal { subscriber in
            let (disposable, _) = context.peerChannelMemberCategoriesContextsManager.recent(engine: context.engine, accountPeerId: context.account.peerId, peerId: peerId, searchQuery: nil, updated: { state in
                if case .ready = state.loadingState {
                    subscriber.putNext(state.list.map { $0.peer })
                }
            })
            return ActionDisposable {
                disposable.dispose()
            }
        }
        |> runOn(Queue.mainQueue())
    } else {
        return context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.LegacyGroupParticipants(id: peerId))
        |> mapToSignal { participants -> Signal<[EnginePeer], NoError> in
            guard case let .known(participants) = participants else {
                return .single([])
            }
            return context.engine.data.subscribe(EngineDataList(participants.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0.peerId) }))
            |> map { peers -> [EnginePeer] in
                return peers.compactMap { $0 }
            }
        }
    }
}

/// Lets the author pick which members of the group may edit the message.
func sharedMessageMembersController(context: AccountContext, peerId: EnginePeer.Id, selectedPeers: [EnginePeer], completion: @escaping ([EnginePeer]) -> Void) -> ViewController {
    let selectedPromise = ValuePromise<[EnginePeer.Id: EnginePeer]>(Dictionary(uniqueKeysWithValues: selectedPeers.map { ($0.id, $0) }))
    let selectedValue = Atomic<[EnginePeer.Id: EnginePeer]>(value: Dictionary(uniqueKeysWithValues: selectedPeers.map { ($0.id, $0) }))

    let arguments = SharedMessageMembersArguments(context: context, toggle: { peer in
        selectedPromise.set(selectedValue.modify { current in
            var current = current
            if current[peer.id] != nil {
                current.removeValue(forKey: peer.id)
            } else {
                current[peer.id] = peer
            }
            return current
        })
    })

    let accountPeerId = context.account.peerId
    let members = sharedMessageGroupMembers(context: context, peerId: peerId)
    |> map { peers -> [EnginePeer] in
        return peers.filter { peer in
            if peer.id == accountPeerId || peer.isDeleted {
                return false
            }
            if case let .user(user) = peer, user.botInfo != nil {
                return false
            }
            return true
        }
    }

    var saveImpl: (() -> Void)?

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, members, selectedPromise.get())
    |> map { presentationData, members, selected -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [SharedMessageMembersEntry] = []
        entries.append(.header(presentationData.theme, presentationData.strings.SharedMessage_Members_Header))
        for (index, peer) in members.enumerated() {
            entries.append(.peer(Int32(index), presentationData.theme, presentationData.strings, presentationData.dateTimeFormat, presentationData.nameDisplayOrder, peer, selected[peer.id] != nil))
        }

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(presentationData.strings.SharedMessage_Setup_SelectedMembers), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        // The choice is applied by the button at the bottom, which also returns to the settings; Back
        // and the swipe leave the previous choice as it was.
        let footerItem = SharedMessageSetupFooterItem(theme: presentationData.theme, title: presentationData.strings.Common_Save, action: {
            saveImpl?()
        })
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, footerItem: footerItem, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    saveImpl = { [weak controller] in
        completion(Array(selectedValue.with { $0 }.values))
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}
