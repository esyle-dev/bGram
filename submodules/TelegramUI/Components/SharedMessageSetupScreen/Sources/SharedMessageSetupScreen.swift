import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

public struct SharedMessageSetupResult {
    public let title: String
    public let access: SharedMessageAttribute.Access
    public let peerIds: [EnginePeer.Id]
    public let closeEditing: SharedMessageAttribute.CloseEditing
    public let commentsEnabled: Bool
    public let notifyChanges: Bool
}

/// Derives a default title from the message text: its first words, cut to the title limit.
public func sharedMessageDefaultTitle(text: String) -> String {
    let limit = SharedMessageAttribute.maxTitleLength
    let normalized = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    if normalized.count <= limit {
        return normalized
    }
    var result = ""
    for word in normalized.components(separatedBy: " ") {
        let candidate = result.isEmpty ? word : result + " " + word
        if candidate.count > limit {
            break
        }
        result = candidate
    }
    if result.isEmpty {
        result = String(normalized.prefix(limit))
    }
    return result
}

private struct SharedMessageSetupArguments {
    let updateTitle: (String) -> Void
    let selectAccess: (SharedMessageAttribute.Access) -> Void
    let openMembers: () -> Void
    let generateTitle: () -> Void
    let dismissKeyboard: () -> Void
    let openCloseEditing: () -> Void
    let updateNotifyChanges: (Bool) -> Void
    let complete: () -> Void
    let cancel: () -> Void
}

private struct SharedMessageSetupState: Equatable {
    var title: String
    var access: SharedMessageAttribute.Access
    var closeEditing: SharedMessageAttribute.CloseEditing
    var commentsEnabled: Bool
    var notifyChanges: Bool
    var isGeneratingTitle: Bool
    var selectedPeers: [EnginePeer]
}

private enum SharedMessageSetupSection: Int32 {
    case title
    case access
    case closeEditing
    case notify
}

private enum SharedMessageSetupEntryId: Hashable {
    case titleHeader
    case title
    case titleFooter
    case accessHeader
    case access(Int32)
    case accessFooter
    case closeEditing
    case closeEditingFooter
    case notify
    case notifyFooter
}

private enum SharedMessageSetupEntry: ItemListNodeEntry {
    case titleHeader(PresentationTheme, String)
    case title(PresentationTheme, String, String, Bool)
    case titleFooter(PresentationTheme, String, String)
    case accessHeader(PresentationTheme, String)
    case access(PresentationTheme, SharedMessageAttribute.Access, String, String, Bool)
    case accessFooter(PresentationTheme, String)
    case closeEditing(PresentationTheme, String, String)
    case closeEditingFooter(PresentationTheme, String)
    case notify(PresentationTheme, String, Bool)
    case notifyFooter(PresentationTheme, String)

    static func ==(lhs: SharedMessageSetupEntry, rhs: SharedMessageSetupEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.titleHeader(lhsTheme, lhsText), .titleHeader(rhsTheme, rhsText)):
            return lhsTheme === rhsTheme && lhsText == rhsText
        case let (.title(lhsTheme, lhsText, lhsPlaceholder, lhsGenerating), .title(rhsTheme, rhsText, rhsPlaceholder, rhsGenerating)):
            return lhsTheme === rhsTheme && lhsText == rhsText && lhsPlaceholder == rhsPlaceholder && lhsGenerating == rhsGenerating
        case let (.titleFooter(lhsTheme, lhsText, lhsCounter), .titleFooter(rhsTheme, rhsText, rhsCounter)):
            return lhsTheme === rhsTheme && lhsText == rhsText && lhsCounter == rhsCounter
        case let (.accessHeader(lhsTheme, lhsText), .accessHeader(rhsTheme, rhsText)):
            return lhsTheme === rhsTheme && lhsText == rhsText
        case let (.access(lhsTheme, lhsAccess, lhsTitle, lhsSubtitle, lhsSelected), .access(rhsTheme, rhsAccess, rhsTitle, rhsSubtitle, rhsSelected)):
            return lhsTheme === rhsTheme && lhsAccess == rhsAccess && lhsTitle == rhsTitle && lhsSubtitle == rhsSubtitle && lhsSelected == rhsSelected
        case let (.accessFooter(lhsTheme, lhsText), .accessFooter(rhsTheme, rhsText)):
            return lhsTheme === rhsTheme && lhsText == rhsText
        case let (.closeEditing(lhsTheme, lhsTitle, lhsValue), .closeEditing(rhsTheme, rhsTitle, rhsValue)):
            return lhsTheme === rhsTheme && lhsTitle == rhsTitle && lhsValue == rhsValue
        case let (.closeEditingFooter(lhsTheme, lhsText), .closeEditingFooter(rhsTheme, rhsText)):
            return lhsTheme === rhsTheme && lhsText == rhsText
        case let (.notify(lhsTheme, lhsTitle, lhsValue), .notify(rhsTheme, rhsTitle, rhsValue)):
            return lhsTheme === rhsTheme && lhsTitle == rhsTitle && lhsValue == rhsValue
        case let (.notifyFooter(lhsTheme, lhsText), .notifyFooter(rhsTheme, rhsText)):
            return lhsTheme === rhsTheme && lhsText == rhsText
        default:
            return false
        }
    }

    var section: ItemListSectionId {
        switch self {
        case .titleHeader, .title, .titleFooter:
            return SharedMessageSetupSection.title.rawValue
        case .accessHeader, .access, .accessFooter:
            return SharedMessageSetupSection.access.rawValue
        case .closeEditing, .closeEditingFooter:
            return SharedMessageSetupSection.closeEditing.rawValue
        case .notify, .notifyFooter:
            return SharedMessageSetupSection.notify.rawValue
        }
    }

    var stableId: SharedMessageSetupEntryId {
        switch self {
        case .titleHeader:
            return .titleHeader
        case .title:
            return .title
        case .titleFooter:
            return .titleFooter
        case .accessHeader:
            return .accessHeader
        case let .access(_, access, _, _, _):
            return .access(access.rawValue)
        case .accessFooter:
            return .accessFooter
        case .closeEditing:
            return .closeEditing
        case .closeEditingFooter:
            return .closeEditingFooter
        case .notify:
            return .notify
        case .notifyFooter:
            return .notifyFooter
        }
    }

    var order: Int32 {
        switch self {
        case .titleHeader:
            return 0
        case .title:
            return 1
        case .titleFooter:
            return 2
        case .accessHeader:
            return 3
        case let .access(_, access, _, _, _):
            return 4 + access.rawValue
        case .accessFooter:
            return 10
        case .closeEditing:
            return 11
        case .closeEditingFooter:
            return 12
        case .notify:
            return 13
        case .notifyFooter:
            return 14
        }
    }

    static func <(lhs: SharedMessageSetupEntry, rhs: SharedMessageSetupEntry) -> Bool {
        return lhs.order < rhs.order
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SharedMessageSetupArguments
        switch self {
        case let .titleHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .title(_, text, placeholder, isGenerating):
            var inlineAction: ItemListMultilineInputInlineAction?
            if let icon = UIImage(bundleImageName: "Chat/Input/Text/InputAIIcon") {
                inlineAction = ItemListMultilineInputInlineAction(icon: icon, action: {
                    arguments.generateTitle()
                })
            }
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: placeholder, maxLength: ItemListMultilineInputItemTextLimit(value: SharedMessageAttribute.maxTitleLength, display: false), sectionId: self.section, style: .blocks, capitalization: true, autocorrection: true, returnKeyType: .done, textUpdated: { updatedText in
                if !isGenerating {
                    arguments.updateTitle(updatedText)
                }
            }, shouldUpdateText: { text in
                return !isGenerating && !text.contains("\n")
            }, action: {
                // The Done key: the field is a single line, so Return only closes the keyboard.
                arguments.dismissKeyboard()
            }, inlineAction: inlineAction, isLoading: isGenerating)
        case let .titleFooter(_, text, counter):
            return SharedMessageSetupFooterTextItem(presentationData: presentationData, text: text, counter: counter, sectionId: self.section)
        case let .accessHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .access(_, access, title, subtitle, selected):
            return SharedMessageAccessItem(presentationData: presentationData, icon: sharedMessageAccessIcon(access), title: title, subtitle: subtitle, subtitleIsAccent: access == .selectedMembers, checked: selected, sectionId: self.section, action: {
                arguments.selectAccess(access)
                if access == .selectedMembers {
                    arguments.openMembers()
                }
            })
        case let .accessFooter(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .closeEditing(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openCloseEditing()
            })
        case let .closeEditingFooter(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .notify(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.updateNotifyChanges(updatedValue)
            })
        case let .notifyFooter(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func sharedMessageCircleIcon(glyphName: String, colors: [UIColor]) -> UIImage? {
    return generateImage(CGSize(width: 40.0, height: 40.0), rotatedContext: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)
        context.addEllipse(in: bounds)
        context.clip()
        var locations: [CGFloat] = [0.0, 1.0]
        let cgColors = colors.map { $0.cgColor } as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: &locations) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: size.height), end: CGPoint(x: 0.0, y: 0.0), options: CGGradientDrawingOptions())
        }
        if let glyph = generateTintedImage(image: UIImage(bundleImageName: glyphName), color: .white) {
            UIGraphicsPushContext(context)
            glyph.draw(in: CGRect(origin: CGPoint(x: floor((size.width - glyph.size.width) * 0.5), y: floor((size.height - glyph.size.height) * 0.5)), size: glyph.size))
            UIGraphicsPopContext()
        }
    })
}

private let sharedMessageAdminsIcon = sharedMessageCircleIcon(glyphName: "Item List/Icons/Admin", colors: [UIColor(rgb: 0x4faaff), UIColor(rgb: 0x017aff)])
private let sharedMessageAllMembersIcon = sharedMessageCircleIcon(glyphName: "Item List/Icons/Group", colors: [UIColor(rgb: 0x87d93a), UIColor(rgb: 0x31b73b)])
private let sharedMessageSelectedMembersIcon = sharedMessageCircleIcon(glyphName: "Media Editor/Privacy/SelectedUsers", colors: [UIColor(rgb: 0xffb643), UIColor(rgb: 0xf69a36)])

private func sharedMessageAccessIcon(_ access: SharedMessageAttribute.Access) -> UIImage? {
    switch access {
    case .admins:
        return sharedMessageAdminsIcon
    case .allMembers:
        return sharedMessageAllMembersIcon
    case .selectedMembers:
        return sharedMessageSelectedMembersIcon
    }
}

private func closeEditingTitle(_ value: SharedMessageAttribute.CloseEditing, strings: PresentationStrings) -> String {
    switch value {
    case .never:
        return strings.SharedMessage_Setup_CloseEditingNever
    case .inOneDay:
        return strings.SharedMessage_Setup_CloseEditingDay
    case .inOneWeek:
        return strings.SharedMessage_Setup_CloseEditingWeek
    case .inOneMonth:
        return strings.SharedMessage_Setup_CloseEditingMonth
    }
}

private func closeEditingFooter(_ value: SharedMessageAttribute.CloseEditing, strings: PresentationStrings) -> String {
    switch value {
    case .never:
        return strings.SharedMessage_Setup_CloseEditingFooterNever
    case .inOneDay:
        return strings.SharedMessage_Setup_CloseEditingFooterDay
    case .inOneWeek:
        return strings.SharedMessage_Setup_CloseEditingFooterWeek
    case .inOneMonth:
        return strings.SharedMessage_Setup_CloseEditingFooterMonth
    }
}

/// Stand-in for the server-side title generation: every call yields a different, shorter or longer
/// run of the message's first words.
private func sharedMessageStubTitle(text: String, variant: Int) -> String {
    let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    if words.isEmpty {
        return ""
    }
    let counts = [4, 2, 5, 3, 6]
    let count = min(words.count, counts[variant % counts.count])
    var result = ""
    for word in words.prefix(count) {
        let candidate = result.isEmpty ? word : result + " " + word
        if candidate.count > SharedMessageAttribute.maxTitleLength {
            break
        }
        result = candidate
    }
    if result.isEmpty {
        result = String(words[0].prefix(SharedMessageAttribute.maxTitleLength))
    }
    return result
}

private func sharedMessageSetupEntries(presentationData: PresentationData, state: SharedMessageSetupState) -> [SharedMessageSetupEntry] {
    let strings = presentationData.strings
    let theme = presentationData.theme
    var entries: [SharedMessageSetupEntry] = []

    entries.append(.titleHeader(theme, strings.SharedMessage_Setup_TitleHeader))
    entries.append(.title(theme, state.title, state.isGeneratingTitle ? "" : strings.SharedMessage_Setup_TitlePlaceholder, state.isGeneratingTitle))
    entries.append(.titleFooter(theme, strings.SharedMessage_Setup_TitleFooter, "\(state.title.count)/\(SharedMessageAttribute.maxTitleLength)"))

    entries.append(.accessHeader(theme, strings.SharedMessage_Setup_WhoCanEditHeader))
    entries.append(.access(theme, .admins, strings.SharedMessage_Setup_Admins, strings.SharedMessage_Setup_AdminsInfo, state.access == .admins))
    entries.append(.access(theme, .allMembers, strings.SharedMessage_Setup_AllMembers, strings.SharedMessage_Setup_AllMembersInfo, state.access == .allMembers))
    var selectedMembersSubtitle = strings.SharedMessage_Setup_Choose
    if state.selectedPeers.count == 1 || state.selectedPeers.count == 2 {
        selectedMembersSubtitle = state.selectedPeers.map { $0.displayTitle(strings: strings, displayOrder: presentationData.nameDisplayOrder) }.joined(separator: ", ")
    } else if state.selectedPeers.count > 2 {
        selectedMembersSubtitle = strings.Story_Privacy_People(Int32(state.selectedPeers.count))
    }
    entries.append(.access(theme, .selectedMembers, strings.SharedMessage_Setup_SelectedMembers, selectedMembersSubtitle, state.access == .selectedMembers))
    entries.append(.accessFooter(theme, strings.SharedMessage_Setup_WhoCanEditFooter))

    entries.append(.closeEditing(theme, strings.SharedMessage_Setup_CloseEditing, closeEditingTitle(state.closeEditing, strings: strings)))
    entries.append(.closeEditingFooter(theme, closeEditingFooter(state.closeEditing, strings: strings)))
    // Comments are no longer a feature; the row is gone and the stored flag is carried as it is.
    entries.append(.notify(theme, strings.SharedMessage_Setup_NotifyChanges, state.notifyChanges))
    entries.append(.notifyFooter(theme, strings.SharedMessage_Setup_NotifyChangesFooter))

    return entries
}

/// `initialSettings` makes it the Manage Editing screen of an already shared message: the rows start
/// from its settings, the title is not generated, and the button says Save.
public func sharedMessageSetupController(context: AccountContext, peerId: EnginePeer.Id, initialTitle: String, messageText: String, initialSettings: SharedMessageSetupResult? = nil, completion: @escaping (SharedMessageSetupResult) -> Void) -> ViewController {
    let isManaging = initialSettings != nil
    let initialState = SharedMessageSetupState(title: String(initialTitle.prefix(SharedMessageAttribute.maxTitleLength)), access: initialSettings?.access ?? .selectedMembers, closeEditing: initialSettings?.closeEditing ?? .never, commentsEnabled: initialSettings?.commentsEnabled ?? true, notifyChanges: initialSettings?.notifyChanges ?? true, isGeneratingTitle: false, selectedPeers: [])
    let statePromise = ValuePromise(initialState)
    let stateValue = Atomic(value: initialState)
    let updateState: ((SharedMessageSetupState) -> SharedMessageSetupState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let generationDisposable = MetaDisposable()
    var generationVariant = 0
    let generateTitleImpl: () -> Void = {
        if stateValue.with({ $0.isGeneratingTitle }) {
            return
        }
        let variant = generationVariant
        generationVariant += 1
        // With no text to draw on, the title is left as it is rather than cleared.
        let generated = sharedMessageStubTitle(text: messageText, variant: variant)
        if generated.isEmpty {
            return
        }
        updateState { state in
            var state = state
            state.isGeneratingTitle = true
            state.title = ""
            return state
        }
        generationDisposable.set((Signal<Never, NoError>.complete()
        |> delay(1.0, queue: Queue.mainQueue())).start(completed: {
            updateState { state in
                var state = state
                state.isGeneratingTitle = false
                state.title = generated
                return state
            }
        }))
    }

    var presentCloseEditingMenuImpl: (() -> Void)?
    var dismissKeyboardImpl: (() -> Void)?
    var openMembersImpl: (() -> Void)?
    var completeImpl: (() -> Void)?
    var cancelImpl: (() -> Void)?

    let arguments = SharedMessageSetupArguments(updateTitle: { title in
        updateState { state in
            var state = state
            state.title = String(title.prefix(SharedMessageAttribute.maxTitleLength))
            return state
        }
    }, selectAccess: { access in
        updateState { state in
            var state = state
            state.access = access
            return state
        }
    }, openMembers: {
        openMembersImpl?()
    }, generateTitle: {
        generateTitleImpl()
    }, dismissKeyboard: {
        dismissKeyboardImpl?()
    }, openCloseEditing: {
        presentCloseEditingMenuImpl?()
    }, updateNotifyChanges: { value in
        updateState { state in
            var state = state
            state.notifyChanges = value
            return state
        }
    }, complete: {
        completeImpl?()
    }, cancel: {
        cancelImpl?()
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let leftNavigationButton = ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
            arguments.cancel()
        })

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(isManaging ? presentationData.strings.SharedMessage_Editor_ManageEditing : presentationData.strings.SharedMessage_Setup_Title), leftNavigationButton: leftNavigationButton, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))

        let footerItem = SharedMessageSetupFooterItem(theme: presentationData.theme, title: isManaging ? presentationData.strings.Common_Save : presentationData.strings.SharedMessage_Setup_Invite, action: {
            arguments.complete()
        })
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: sharedMessageSetupEntries(presentationData: presentationData, state: state), style: .blocks, footerItem: footerItem, animateChanges: false)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal
    |> afterDisposed {
        generationDisposable.dispose()
    })
    controller.navigationPresentation = .modal
    controller.enableInteractiveDismiss = true

    completeImpl = { [weak controller] in
        let state = stateValue.with({ $0 })
        // A selection made and then left behind by switching to Admins or All Members is not carried along.
        let peerIds = state.access == .selectedMembers ? state.selectedPeers.map { $0.id } : []
        completion(SharedMessageSetupResult(title: state.title.trimmingCharacters(in: .whitespacesAndNewlines), access: state.access, peerIds: peerIds, closeEditing: state.closeEditing, commentsEnabled: state.commentsEnabled, notifyChanges: state.notifyChanges))
        controller?.dismiss()
    }

    openMembersImpl = { [weak controller] in
        let selectedPeers = stateValue.with { $0.selectedPeers }
        let membersController = sharedMessageMembersController(context: context, peerId: peerId, selectedPeers: selectedPeers, completion: { peers in
            updateState { state in
                var state = state
                state.selectedPeers = peers
                return state
            }
        })
        controller?.push(membersController)
    }

    presentCloseEditingMenuImpl = { [weak controller] in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        let options: [SharedMessageAttribute.CloseEditing] = [.inOneDay, .inOneWeek, .inOneMonth, .never]
        for option in options {
            items.append(ActionSheetButtonItem(title: closeEditingTitle(option, strings: presentationData.strings), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                updateState { state in
                    var state = state
                    state.closeEditing = option
                    return state
                }
            }))
        }
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        controller?.present(actionSheet, in: .window(.root))
    }

    cancelImpl = { [weak controller] in
        controller?.dismiss()
    }

    dismissKeyboardImpl = { [weak controller] in
        controller?.view.endEditing(true)
    }

    if let initialSettings {
        // The selected members are shown as peers; they are looked up while the screen opens.
        if !initialSettings.peerIds.isEmpty {
            let _ = (context.engine.data.get(EngineDataList(initialSettings.peerIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
            |> deliverOnMainQueue).startStandalone(next: { peers in
                updateState { state in
                    var state = state
                    state.selectedPeers = peers.compactMap { $0 }
                    return state
                }
            })
        }
    } else {
        generateTitleImpl()
    }

    return controller
}
