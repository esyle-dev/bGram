import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import BetaFeatures

private final class BetaFeaturesScreenArguments {
    let toggle: (BetaFeature, Bool) -> Void

    init(toggle: @escaping (BetaFeature, Bool) -> Void) {
        self.toggle = toggle
    }
}

private enum BetaFeaturesScreenSection: Int32 {
    case header
    case features
    case footer
}

private enum BetaFeaturesScreenEntry: ItemListNodeEntry {
    enum StableId: Hashable {
        case header
        case feature(BetaFeature)
        case footer
    }

    case header(String)
    case feature(index: Int, feature: BetaFeature, title: String, text: String, value: Bool)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .header:
            return BetaFeaturesScreenSection.header.rawValue
        case .feature:
            return BetaFeaturesScreenSection.features.rawValue
        case .footer:
            return BetaFeaturesScreenSection.footer.rawValue
        }
    }

    var sortIndex: Int {
        switch self {
        case .header:
            return -1
        case let .feature(index, _, _, _, _):
            return index
        case .footer:
            return 1000
        }
    }

    var stableId: StableId {
        switch self {
        case .header:
            return .header
        case let .feature(_, feature, _, _, _):
            return .feature(feature)
        case .footer:
            return .footer
        }
    }

    static func <(lhs: BetaFeaturesScreenEntry, rhs: BetaFeaturesScreenEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! BetaFeaturesScreenArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .feature(_, feature, title, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, value: value, enableInteractiveChanges: true, enabled: BetaFeatures.isAvailable(feature), sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(feature, value)
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func betaFeaturesScreenEntries(presentationData: PresentationData) -> [BetaFeaturesScreenEntry] {
    let isRussian = presentationData.strings.baseLanguageCode.hasPrefix("ru")

    var entries: [BetaFeaturesScreenEntry] = []
    entries.append(.header(isRussian ? "ФУНКЦИИ СБОРКИ" : "BUILD FEATURES"))
    var index = 0
    for feature in BetaFeature.allCases {
        entries.append(.feature(index: index, feature: feature, title: feature.title(isRussian: isRussian), text: feature.description(isRussian: isRussian), value: BetaFeatures.isEnabled(feature)))
        index += 1
    }
    entries.append(.footer(isRussian
        ? "Все функции включены по умолчанию. Выключенная функция просто убирает свою точку входа — остальной клиент работает как обычно."
        : "Every feature is on by default. Turning one off removes its entry point only — the rest of the client behaves as usual."))
    return entries
}

public func betaFeaturesScreen(context: AccountContext) -> ViewController {
    let stateValue = ValuePromise<Int32>(0, ignoreRepeated: true)
    var state: Int32 = 0

    let arguments = BetaFeaturesScreenArguments(toggle: { feature, value in
        BetaFeatures.setEnabled(value, for: feature)
        state += 1
        stateValue.set(state)
    })

    let signal = combineLatest(
        context.sharedContext.presentationData,
        stateValue.get()
    )
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("βeta Features"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: betaFeaturesScreenEntries(presentationData: presentationData),
            style: .blocks,
            ensureVisibleItemTag: nil,
            emptyStateItem: nil,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}