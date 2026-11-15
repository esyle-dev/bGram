import Foundation
import UIKit
import Display
import ComponentFlow
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ViewControllerComponent
import ResizableSheetComponent
import MultilineTextComponent
import ListSectionComponent
import ListActionItemComponent
import GlassBarButtonComponent
import BundleIconComponent

/// One row of the "Show all" sheet. Images are drawn once, when the sheet is made, so the rows
/// compare equal across updates (`Image` compares its image by identity).
struct SharedMessageVersionsSheetRow: Equatable {
    let versionId: Int
    let title: String
    let time: String
    let icon: UIImage?
    let avatars: UIImage?

    static func ==(lhs: SharedMessageVersionsSheetRow, rhs: SharedMessageVersionsSheetRow) -> Bool {
        return lhs.versionId == rhs.versionId && lhs.title == rhs.title && lhs.time == rhs.time && lhs.icon === rhs.icon && lhs.avatars === rhs.avatars
    }
}

/// The rows of one day, newest first, under that day's heading ("Today", "Yesterday", "November 3").
struct SharedMessageVersionsSheetSection: Equatable {
    let id: Int
    let title: String
    let rows: [SharedMessageVersionsSheetRow]
}

private final class SharedMessageVersionsSheetContentComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let sections: [SharedMessageVersionsSheetSection]
    let select: (Int) -> Void

    init(sections: [SharedMessageVersionsSheetSection], select: @escaping (Int) -> Void) {
        self.sections = sections
        self.select = select
    }

    static func ==(lhs: SharedMessageVersionsSheetContentComponent, rhs: SharedMessageVersionsSheetContentComponent) -> Bool {
        return lhs.sections == rhs.sections
    }

    final class View: UIView {
        private var sectionViews: [Int: ComponentView<Empty>] = [:]

        func update(component: SharedMessageVersionsSheetContentComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
            let environment = environment[ViewControllerComponentContainer.Environment.self].value
            let theme = environment.theme.withModalBlocksBackground()
            let sideInset: CGFloat = 16.0
            let sectionSpacing: CGFloat = 24.0

            // Below the sheet's title bar.
            var contentHeight: CGFloat = 76.0 + 9.0

            var validIds = Set<Int>()
            for (index, section) in component.sections.enumerated() {
                validIds.insert(section.id)
                let sectionView: ComponentView<Empty>
                if let current = self.sectionViews[section.id] {
                    sectionView = current
                } else {
                    sectionView = ComponentView()
                    self.sectionViews[section.id] = sectionView
                }

                var items: [AnyComponentWithIdentity<Empty>] = []
                for row in section.rows {
                    let versionId = row.versionId
                    let titleComponent = AnyComponent(VStack([
                        AnyComponentWithIdentity(id: 0, component: AnyComponent(MultilineTextComponent(
                            text: .plain(NSAttributedString(string: row.title, font: Font.regular(17.0), textColor: theme.list.itemPrimaryTextColor)),
                            maximumNumberOfLines: 1
                        ))),
                        AnyComponentWithIdentity(id: 1, component: AnyComponent(MultilineTextComponent(
                            text: .plain(NSAttributedString(string: row.time, font: Font.regular(15.0), textColor: theme.list.itemSecondaryTextColor)),
                            maximumNumberOfLines: 1
                        )))
                    ], alignment: .left, spacing: 2.0))

                    var accessory: ListActionItemComponent.Accessory? = nil
                    if let avatars = row.avatars {
                        accessory = .custom(ListActionItemComponent.CustomAccessory(
                            component: AnyComponentWithIdentity(id: AnyHashable("avatars"), component: AnyComponent(Image(image: avatars, size: avatars.size))),
                            insets: UIEdgeInsets(top: 0.0, left: 8.0, bottom: 0.0, right: 16.0)
                        ))
                    }

                    items.append(AnyComponentWithIdentity(id: row.versionId, component: AnyComponent(ListActionItemComponent(
                        theme: theme,
                        style: .glass,
                        title: titleComponent,
                        contentInsets: UIEdgeInsets(top: 10.0, left: 0.0, bottom: 10.0, right: 0.0),
                        leftIcon: row.icon.flatMap { icon in
                            .custom(AnyComponentWithIdentity(id: AnyHashable("icon"), component: AnyComponent(Image(image: icon, size: icon.size))), false)
                        },
                        accessory: accessory,
                        action: { _ in
                            component.select(versionId)
                        }
                    ))))
                }

                let sectionSize = sectionView.update(
                    transition: transition,
                    component: AnyComponent(ListSectionComponent(
                        theme: theme,
                        style: .glass,
                        header: AnyComponent(MultilineTextComponent(
                            text: .plain(NSAttributedString(string: section.title.uppercased(), font: Font.regular(13.0), textColor: theme.list.freeTextColor)),
                            maximumNumberOfLines: 1
                        )),
                        footer: nil,
                        items: items
                    )),
                    environment: {},
                    containerSize: CGSize(width: availableSize.width - sideInset * 2.0, height: 10000.0)
                )
                if index != 0 {
                    contentHeight += sectionSpacing
                }
                let sectionFrame = CGRect(origin: CGPoint(x: sideInset, y: contentHeight), size: sectionSize)
                if let view = sectionView.view {
                    if view.superview == nil {
                        self.addSubview(view)
                    }
                    transition.setFrame(view: view, frame: sectionFrame)
                }
                contentHeight += sectionSize.height
            }
            for (id, sectionView) in self.sectionViews where !validIds.contains(id) {
                sectionView.view?.removeFromSuperview()
                self.sectionViews.removeValue(forKey: id)
            }

            contentHeight += 16.0 + environment.safeInsets.bottom
            return CGSize(width: availableSize.width, height: contentHeight)
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

private final class SharedMessageVersionsSheetComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let title: String
    let sections: [SharedMessageVersionsSheetSection]
    let select: (Int) -> Void

    init(title: String, sections: [SharedMessageVersionsSheetSection], select: @escaping (Int) -> Void) {
        self.title = title
        self.sections = sections
        self.select = select
    }

    static func ==(lhs: SharedMessageVersionsSheetComponent, rhs: SharedMessageVersionsSheetComponent) -> Bool {
        return lhs.title == rhs.title && lhs.sections == rhs.sections
    }

    final class View: UIView {
        private let sheet = ComponentView<(ViewControllerComponentContainer.Environment, ResizableSheetComponentEnvironment)>()
        private let animateOut = ActionSlot<Action<Void>>()
        private var isDismissing = false

        func update(component: SharedMessageVersionsSheetComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
            let environment = environment[ViewControllerComponentContainer.Environment.self].value
            let controller = environment.controller
            let theme = environment.theme.withModalBlocksBackground()

            // `completion` runs once the sheet is gone, so a version opens over the editor, not over the sheet.
            let dismiss: (Bool, (() -> Void)?) -> Void = { [weak self] animated, completion in
                guard let self, !self.isDismissing else {
                    return
                }
                self.isDismissing = true
                let performDismiss: () -> Void = {
                    if let controller = controller() as? SharedMessageVersionsSheet {
                        controller.completePendingDismiss()
                        controller.dismiss(animated: false)
                    }
                    completion?()
                }
                if animated {
                    self.animateOut.invoke(Action { _ in
                        performDismiss()
                    })
                } else {
                    performDismiss()
                }
            }

            let sheetSize = self.sheet.update(
                transition: transition,
                component: AnyComponent(ResizableSheetComponent<ViewControllerComponentContainer.Environment>(
                    content: AnyComponent<ViewControllerComponentContainer.Environment>(SharedMessageVersionsSheetContentComponent(
                        sections: component.sections,
                        select: { versionId in
                            dismiss(true, {
                                component.select(versionId)
                            })
                        }
                    )),
                    titleItem: AnyComponent(MultilineTextComponent(
                        text: .plain(NSAttributedString(string: component.title, font: Font.semibold(17.0), textColor: theme.list.itemPrimaryTextColor)),
                        maximumNumberOfLines: 1
                    )),
                    leftItem: AnyComponent(GlassBarButtonComponent(
                        size: CGSize(width: 44.0, height: 44.0),
                        backgroundColor: nil,
                        isDark: theme.overallDarkAppearance,
                        state: .glass,
                        component: AnyComponentWithIdentity(id: "close", component: AnyComponent(BundleIconComponent(
                            name: "Navigation/Close",
                            tintColor: theme.chat.inputPanel.panelControlColor
                        ))),
                        action: { _ in
                            dismiss(true, nil)
                        }
                    )),
                    backgroundColor: .color(theme.list.modalBlocksBackgroundColor),
                    animateOut: self.animateOut
                )),
                environment: {
                    environment
                    ResizableSheetComponentEnvironment(
                        theme: theme,
                        statusBarHeight: environment.statusBarHeight,
                        safeInsets: environment.safeInsets,
                        inputHeight: 0.0,
                        metrics: environment.metrics,
                        deviceMetrics: environment.deviceMetrics,
                        isDisplaying: environment.isVisible,
                        isCentered: environment.presentsFloatingPanels,
                        screenSize: availableSize,
                        regularMetricsSize: nil,
                        dismiss: { animated in
                            dismiss(animated, nil)
                        }
                    )
                },
                forceUpdate: true,
                containerSize: availableSize
            )
            self.sheet.parentState = state
            if let sheetView = self.sheet.view {
                if sheetView.superview == nil {
                    self.addSubview(sheetView)
                }
                transition.setFrame(view: sheetView, frame: CGRect(origin: .zero, size: sheetSize))
            }
            return availableSize
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

/// "Show all" in the versions menu: every version, grouped by day, in a bottom sheet like the AI
/// screen's. Tapping a version closes the sheet first and only then opens the version, so there is
/// never more than one layer over the editor.
final class SharedMessageVersionsSheet: ViewControllerComponentContainer {
    private var isDismissed = false
    private var dismissCompletion: (() -> Void)?

    init(context: AccountContext, title: String, sections: [SharedMessageVersionsSheetSection], select: @escaping (Int) -> Void) {
        super.init(
            context: context,
            component: SharedMessageVersionsSheetComponent(title: title, sections: sections, select: select),
            navigationBarAppearance: .none
        )
        self.statusBar.statusBarStyle = .Ignore
        self.navigationPresentation = .flatModal
        self.blocksBackgroundWhenInOverlay = true
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    fileprivate func completePendingDismiss() {
        let dismissCompletion = self.dismissCompletion
        self.dismissCompletion = nil
        dismissCompletion?()
    }

    override func dismiss(completion: (() -> Void)? = nil) {
        if !self.isDismissed {
            self.isDismissed = true
            self.dismissCompletion = completion
            if let view = self.node.hostView.findTaggedView(tag: ResizableSheetComponent<ViewControllerComponentContainer.Environment>.View.Tag()) as? ResizableSheetComponent<ViewControllerComponentContainer.Environment>.View {
                view.dismissAnimated()
            } else {
                self.completePendingDismiss()
                self.dismiss(animated: false)
            }
        }
    }
}
