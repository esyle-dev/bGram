import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import AccountContext
import ContextUI
import BetaFeatures
import UndoUI
import ChatScheduleTimeController

// βeta Features: Time Capsule.
//
// The capsule is a message that is not in the chat yet: it is delivered at the chosen moment, so until then
// nobody — the other side or you — can see it. Delivery is the API's scheduled message, which means the
// capsule really is sealed for everyone, not only for this device. Long-pressing Send offers the capsule
// presets instead of the regular send options while the feature is on.

private let timeCapsulePresets: [(titleRu: String, titleEn: String, delta: Int32)] = [
    ("Через час", "In an hour", 60 * 60),
    ("Через 6 часов", "In 6 hours", 6 * 60 * 60),
    ("Через сутки", "In a day", 24 * 60 * 60),
    ("Через 3 дня", "In 3 days", 3 * 24 * 60 * 60),
    ("Через неделю", "In a week", 7 * 24 * 60 * 60)
]

func chatMessageDisplayTimeCapsuleOptions(selfController: ChatControllerImpl, node: ASDisplayNode) {
    let presentationData = selfController.presentationData
    let isRussian = presentationData.strings.baseLanguageCode.hasPrefix("ru")
    let actionSheet = ActionSheetController(theme: ActionSheetControllerTheme(presentationTheme: presentationData.theme, fontSize: presentationData.listsFontSize))

    var items: [ActionSheetItem] = []
    items.append(ActionSheetTextItem(title: isRussian
        ? "Капсула времени: сообщение появится в чате в выбранный момент. До этого его не видит никто."
        : "Time Capsule: the message appears in the chat at the chosen moment. Until then nobody can see it."))

    let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
    for preset in timeCapsulePresets {
        items.append(ActionSheetButtonItem(title: isRussian ? preset.titleRu : preset.titleEn, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            selfController.sendTimeCapsule(scheduleTime: now + preset.delta)
        }))
    }
    items.append(ActionSheetButtonItem(title: isRussian ? "Выбрать время…" : "Choose a time…", action: { [weak actionSheet] in
        actionSheet?.dismissAnimated()
        selfController.presentScheduleTimePicker(completion: { [weak selfController] (time: Int32, _: Int32?) in
            guard let selfController else {
                return
            }
            selfController.sendTimeCapsule(scheduleTime: time)
        })
    }))

    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: items),
        ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])
    ])
    selfController.present(actionSheet, in: .window(.root))
}

extension ChatControllerImpl {
    /// Sends the composed message as a capsule that opens at `scheduleTime`.
    func sendTimeCapsule(scheduleTime: Int32) {
        let now = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
        guard scheduleTime > now else {
            return
        }
        self.chatDisplayNode.sendCurrentMessage(scheduleTime: scheduleTime, messageEffect: nil) { [weak self] in
            guard let self else {
                return
            }
            self.updateChatPresentationInterfaceState(animated: true, interactive: false, saveInterfaceState: self.presentationInterfaceState.subject != .scheduledMessages, {
                $0.updatedInterfaceState { $0.withUpdatedReplyMessageSubject(nil).withUpdatedSendMessageEffect(nil).withUpdatedPostSuggestionState(nil).withUpdatedForwardMessageIds(nil).withUpdatedForwardOptionsState(nil).withUpdatedComposeInputState(ChatTextInputState(inputText: NSAttributedString(string: ""))) }
            })
        }
        let presentationData = self.presentationData
        let isRussian = presentationData.strings.baseLanguageCode.hasPrefix("ru")
        self.present(UndoOverlayController(presentationData: presentationData, content: .succeed(text: isRussian ? "Капсула запечатана" : "Capsule sealed", timeout: 3.0, customUndoText: nil), elevatedLayout: false, action: { _ in return false }), in: .current)
    }
}