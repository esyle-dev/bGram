import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramPresentationData

/// The capsule over a shared editor's toolbar: a 16pt SF Symbol, 8pt, then the title and an optional
/// grey subtitle after a " · ", 16pt at the sides, 40pt tall. The background is the toast's (a dark blur,
/// the tab bar colour under a dark theme), so it reads like the "Text copied" notice.
final class RichTextCollaborationNoticeView: UIView {
    static let height: CGFloat = 40.0
    private static let sideInset: CGFloat = 16.0
    private static let iconSize: CGFloat = 16.0
    private static let iconSpacing: CGFloat = 8.0
    private static let fontSize: CGFloat = 15.0

    private let backgroundView: UIView
    private let effectView: UIVisualEffectView
    private var contentView: UIView
    private var iconView: UIImageView
    private var label: UILabel

    /// The notice on screen; it stays set while the capsule fades out, so the text does not vanish first.
    private(set) var notice: RichTextCollaborationHost.Notice?
    private(set) var isShown = false

    override init(frame: CGRect) {
        self.backgroundView = UIView()
        self.backgroundView.clipsToBounds = true
        self.backgroundView.layer.cornerRadius = RichTextCollaborationNoticeView.height * 0.5
        self.backgroundView.layer.cornerCurve = .continuous
        self.effectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        self.contentView = UIView()
        self.iconView = UIImageView()
        self.label = UILabel()

        super.init(frame: frame)

        self.isUserInteractionEnabled = false
        self.alpha = 0.0
        self.addSubview(self.backgroundView)
        self.backgroundView.addSubview(self.effectView)
        self.addSubview(self.contentView)
        self.contentView.addSubview(self.iconView)
        self.contentView.addSubview(self.label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The capsule has a notice to show but has not been placed yet; the next layout places it
    /// without animation and then runs `animateIn`, so it never slides in from a stale position.
    private(set) var needsAppear = false

    /// Shows `notice`, or hides the capsule when it is nil. A change of notice while shown cross-fades
    /// the contents; the size change follows the layout transition the caller applies next.
    func setNotice(_ notice: RichTextCollaborationHost.Notice?) {
        if let notice {
            if self.isShown && !self.needsAppear, let previous = self.notice, previous != notice {
                // Old contents fade out in place while the new ones fade in.
                let oldContent = self.contentView
                let newContent = UIView()
                let newIcon = UIImageView()
                let newLabel = UILabel()
                newContent.addSubview(newIcon)
                newContent.addSubview(newLabel)
                newContent.frame = oldContent.frame
                self.addSubview(newContent)
                self.contentView = newContent
                self.iconView = newIcon
                self.label = newLabel
                oldContent.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak oldContent] _ in
                    oldContent?.removeFromSuperview()
                })
                newContent.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
            self.notice = notice
            self.applyContents(notice)
            if !self.isShown {
                self.isShown = true
                self.needsAppear = true
            }
        } else if self.isShown {
            self.isShown = false
            if self.needsAppear {
                // Never placed, so never seen.
                self.needsAppear = false
                return
            }
            self.animateOut()
        }
    }

    /// The "Text copied" toast's entrance: fade in over 0.3 s while growing from 96% on a spring.
    func animateIn() {
        self.needsAppear = false
        self.alpha = 1.0
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
        self.layer.animateScale(from: 0.96, to: 1.0, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
    }

    /// The toast's exit: fade out over 0.25 s while shrinking to 96% on a spring.
    private func animateOut() {
        self.alpha = 0.0
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue)
        self.layer.animateScale(from: 1.0, to: 0.96, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { [weak self] _ in
            guard let self, !self.isShown else {
                return
            }
            self.layer.removeAnimation(forKey: "transform.scale")
        })
    }

    private func applyContents(_ notice: RichTextCollaborationHost.Notice) {
        let symbolName: String
        let color: UIColor
        switch notice.icon {
        case .saved:
            symbolName = "checkmark.icloud"
            color = UIColor(rgb: 0x008bff)
        case .offline:
            symbolName = "icloud.slash"
            color = UIColor(rgb: 0xff9f0a)
        case .synced:
            symbolName = "checkmark.icloud"
            color = UIColor(rgb: 0x30d158)
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: RichTextCollaborationNoticeView.iconSize, weight: .regular)
        self.iconView.image = UIImage(systemName: symbolName, withConfiguration: configuration)?.withRenderingMode(.alwaysTemplate)
        self.iconView.tintColor = color

        let font = Font.regular(RichTextCollaborationNoticeView.fontSize)
        let text = NSMutableAttributedString(string: notice.title, font: font, textColor: .white)
        if let subtitle = notice.subtitle {
            text.append(NSAttributedString(string: " · ", font: font, textColor: .white))
            text.append(NSAttributedString(string: subtitle, font: font, textColor: UIColor(white: 1.0, alpha: 0.55)))
        }
        self.label.attributedText = text
        self.label.lineBreakMode = .byTruncatingTail
    }

    /// The capsule's size for the current notice, laid out at that size; at most `maxWidth` wide.
    func update(theme: PresentationTheme, maxWidth: CGFloat, transition: ComponentTransition) -> CGSize {
        // As the toast: under a dark theme the tab bar colour stands under the blur.
        self.backgroundView.backgroundColor = theme.overallDarkAppearance ? theme.rootController.tabBar.backgroundColor : .clear

        let iconBox = CGSize(width: RichTextCollaborationNoticeView.iconSize + 4.0, height: RichTextCollaborationNoticeView.height)
        let fixedWidth = RichTextCollaborationNoticeView.sideInset * 2.0 + iconBox.width + RichTextCollaborationNoticeView.iconSpacing
        let labelSize = self.label.sizeThatFits(CGSize(width: max(1.0, maxWidth - fixedWidth), height: RichTextCollaborationNoticeView.height))
        let labelWidth = min(ceil(labelSize.width), max(1.0, maxWidth - fixedWidth))
        let size = CGSize(width: fixedWidth + labelWidth, height: RichTextCollaborationNoticeView.height)

        self.contentView.frame = CGRect(origin: .zero, size: size)
        let iconSize = self.iconView.image?.size ?? CGSize(width: RichTextCollaborationNoticeView.iconSize, height: RichTextCollaborationNoticeView.iconSize)
        let iconX = RichTextCollaborationNoticeView.sideInset + floor((iconBox.width - iconSize.width) * 0.5)
        self.iconView.frame = CGRect(origin: CGPoint(x: iconX, y: floor((size.height - iconSize.height) * 0.5)), size: iconSize)
        let labelX = RichTextCollaborationNoticeView.sideInset + iconBox.width + RichTextCollaborationNoticeView.iconSpacing
        self.label.frame = CGRect(x: labelX, y: floor((size.height - ceil(labelSize.height)) * 0.5), width: labelWidth, height: ceil(labelSize.height))

        // The capsule follows a change of text width on the caller's transition.
        let backgroundFrame = CGRect(origin: .zero, size: size)
        transition.setFrame(view: self.backgroundView, frame: backgroundFrame)
        transition.setFrame(view: self.effectView, frame: backgroundFrame)
        return size
    }
}
