import Foundation
import UIKit
import Display
import AsyncDisplayKit
import AppBundle
import WallpaperBackgroundNode
import ChatControllerInteraction

private let size = CGSize(width: 33.0, height: 33.0)

public final class ChatMessageSwipeToReplyNode: ASDisplayNode {
    public enum Action {
        case reply
        case like
        case unlike
        /// Hides the message from a screenshot: a crossed-out eye.
        case hide
    }
    
    private var backgroundContent: WallpaperBubbleBackgroundNode?
    
    private let backgroundNode: NavigationBackgroundNode
    private let foregroundNode: ASImageNode
    
    private let maskNode: ASDisplayNode
    private let progressLayer: SimpleShapeLayer
    private let fillLayer: SimpleShapeLayer
    private let semiFillLayer: SimpleShapeLayer
    
    private var absolutePosition: (CGRect, CGSize)?
    
    // Концепт «многодействийный свайп»: копия кружка в оверлее окна меняет цвет стрелки и гасит подложку.
    private let action: Action
    private let alternateForegroundNode: ASImageNode
    private var alternateMix: CGFloat = 0.0
    private var outlineMorphLayer: CAShapeLayer?
    public private(set) var currentProgress: CGFloat = 0.0
    /// Круговую волну успеха рисует рейка своей формой (по капсуле); здесь остаётся только пульс масштаба.
    public var circularWaveEnabled = true
    
    public init(fillColor: UIColor, enableBlur: Bool, foregroundColor: UIColor, backgroundNode: WallpaperBackgroundNode?, action: ChatMessageSwipeToReplyNode.Action) {
        self.backgroundNode = NavigationBackgroundNode(color: fillColor, enableBlur: enableBlur)
        self.backgroundNode.isUserInteractionEnabled = false

        self.foregroundNode = ASImageNode()
        self.foregroundNode.isUserInteractionEnabled = false
        self.alternateForegroundNode = ASImageNode()
        self.alternateForegroundNode.isUserInteractionEnabled = false
        self.alternateForegroundNode.alpha = 0.0

        self.action = action
        self.foregroundNode.image = ChatMessageSwipeToReplyNode.makeForegroundImage(action: action, foregroundColor: foregroundColor)
        
        self.maskNode = ASDisplayNode()
        self.progressLayer = SimpleShapeLayer()
        self.fillLayer = SimpleShapeLayer()
        self.semiFillLayer = SimpleShapeLayer()
    
        super.init()
        
        self.allowsGroupOpacity = true
        
        self.addSubnode(self.backgroundNode)
        
        self.maskNode.layer.addSublayer(self.progressLayer)
        self.maskNode.layer.addSublayer(self.fillLayer)
        self.maskNode.layer.addSublayer(self.semiFillLayer)
        
        self.addSubnode(self.foregroundNode)
        self.addSubnode(self.alternateForegroundNode)
        
        let backgroundFrame = CGRect(origin: CGPoint(), size: size).insetBy(dx: -22.0, dy: -22.0)
        
        self.backgroundNode.frame = backgroundFrame
        self.backgroundNode.update(size: self.backgroundNode.bounds.size, cornerRadius: self.backgroundNode.bounds.height / 2.0, transition: .immediate)
        self.foregroundNode.frame = CGRect(origin: CGPoint(), size: size)
        self.alternateForegroundNode.frame = CGRect(origin: CGPoint(), size: size)
                
        self.progressLayer.strokeColor = UIColor.white.cgColor
        self.progressLayer.fillColor = UIColor.clear.cgColor
        self.progressLayer.lineCap = .round
        self.progressLayer.lineWidth = 2.0 - UIScreenPixel
        
        self.fillLayer.strokeColor = UIColor.white.cgColor
        self.fillLayer.fillColor = UIColor.clear.cgColor
        self.fillLayer.isHidden = true
        
        self.semiFillLayer.fillColor = UIColor(rgb: 0xffffff, alpha: 0.6).cgColor
           
        self.maskNode.frame = CGRect(origin: CGPoint(x: 22.0, y: 22.0), size: backgroundFrame.size)
        self.progressLayer.frame = CGRect(origin: .zero, size: size).insetBy(dx: -20.0, dy: -20.0)
        self.fillLayer.frame = CGRect(origin: .zero, size: size)
        
        self.semiFillLayer.frame = self.fillLayer.frame
        self.semiFillLayer.path = UIBezierPath(ovalIn: self.semiFillLayer.bounds).cgPath
        
        let path = UIBezierPath(arcCenter: CGPoint(x: self.progressLayer.frame.width / 2.0, y: self.progressLayer.frame.height / 2.0), radius: size.width / 2.0, startAngle: CGFloat(-0.5 * .pi), endAngle: CGFloat(1.5 * .pi), clockwise: true)
        self.progressLayer.path = path.cgPath
                
        if backgroundNode?.hasExtraBubbleBackground() == true {
            if let backgroundContent = backgroundNode?.makeBubbleBackground(for: .free) {
                backgroundContent.clipsToBounds = true
                backgroundContent.allowsGroupOpacity = true
                self.backgroundContent = backgroundContent
                self.insertSubnode(backgroundContent, at: 0)
            }
        } else {
            self.backgroundContent?.removeFromSupernode()
            self.backgroundContent = nil
        }
        
        if let backgroundContent = self.backgroundContent {
            self.backgroundNode.isHidden = true
            backgroundContent.frame = backgroundFrame
        } else {
            self.backgroundNode.isHidden = false
        }
    }
    
    private static func makeForegroundImage(action: Action, foregroundColor: UIColor) -> UIImage? {
        return generateImage(CGSize(width: 33.0, height: 33.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            
            switch action {
            case .reply:
                if let image = UIImage(bundleImageName: "Chat/Message/ShareIcon") {
                    let imageRect = CGRect(origin: CGPoint(x: floor((size.width - image.size.width) / 2.0), y: floor((size.height - image.size.height) / 2.0)), size: image.size)
                    
                    context.translateBy(x: imageRect.midX, y: imageRect.midY)
                    context.scaleBy(x: -1.0, y: -1.0)
                    context.translateBy(x: -imageRect.midX, y: -imageRect.midY)
                    context.clip(to: imageRect, mask: image.cgImage!)
                    context.setFillColor(foregroundColor.cgColor)
                    context.fill(imageRect)
                }
            case .hide:
                if let image = UIImage(bundleImageName: "Chat/Message/AgeRestricted") {
                    let imageRect = CGRect(origin: CGPoint(x: floor((size.width - image.size.width) / 2.0), y: floor((size.height - image.size.height) / 2.0)), size: image.size)
                    
                    context.translateBy(x: imageRect.midX, y: imageRect.midY)
                    context.scaleBy(x: 1.0, y: -1.0)
                    context.translateBy(x: -imageRect.midX, y: -imageRect.midY)
                    context.clip(to: imageRect, mask: image.cgImage!)
                    context.setFillColor(foregroundColor.cgColor)
                    context.fill(imageRect)
                }
            case .like, .unlike:
                if let image = UIImage(bundleImageName: action == .like ? "Chat/Reactions/SwipeActionHeartFilled" : "Chat/Reactions/SwipeActionHeartBroken") {
                    let imageRect = CGRect(origin: CGPoint(x: floor((size.width - image.size.width) / 2.0), y: floor((size.height - image.size.height) / 2.0)), size: image.size)
                    
                    context.translateBy(x: imageRect.midX, y: imageRect.midY)
                    context.scaleBy(x: 1.0, y: -1.0)
                    context.translateBy(x: -imageRect.midX, y: -imageRect.midY)
                    if case .like = action {
                        context.translateBy(x: 0.0, y: -1.0)
                    } else {
                        context.translateBy(x: 0.5, y: -1.0)
                    }
                    context.clip(to: imageRect, mask: image.cgImage!)
                    context.setFillColor(foregroundColor.cgColor)
                    context.fill(imageRect)
                }
            }
        })
    }
    
    override public func didLoad() {
        super.didLoad()
        
        if let backgroundContent = self.backgroundContent {
            backgroundContent.view.mask = self.maskNode.view
        } else {
            self.backgroundNode.view.mask = self.maskNode.view
        }
    }
    
    /// Постоянный масштаб поверх анимаций успеха (клон Reply в капсуле рейки действий крупнее штатного кружка).
    public var baseScale: CGFloat = 1.0
    private var animatedWave = false
    public func updateProgress(_ progress: CGFloat) {
        let progress = max(0.0, min(1.0, progress))
        self.currentProgress = progress
        var foregroundProgress = min(1.0, progress * 1.2)
        var scaleProgress = 0.65 + foregroundProgress * 0.35
        
        if !self.animatedWave {
            let path = UIBezierPath(arcCenter: CGPoint(x: self.progressLayer.frame.width / 2.0, y: self.progressLayer.frame.height / 2.0), radius: size.width / 2.0, startAngle: CGFloat(-0.5 * .pi), endAngle: CGFloat(-0.5 * .pi + progress * 2.0 * .pi), clockwise: true)
            self.progressLayer.path = path.cgPath
        } else {
            foregroundProgress = progress
            scaleProgress = progress
            self.maskNode.alpha = progress
        }
        
        self.semiFillLayer.opacity = Float(progress)
        
        self.layer.sublayerTransform = CATransform3DMakeScale(scaleProgress, scaleProgress, 1.0)
        
        self.foregroundNode.alpha = foregroundProgress * (1.0 - self.alternateMix)
        self.foregroundNode.transform = CATransform3DMakeScale(foregroundProgress, foregroundProgress, 1.0)
        self.alternateForegroundNode.alpha = foregroundProgress * self.alternateMix
        self.alternateForegroundNode.transform = CATransform3DMakeScale(foregroundProgress, foregroundProgress, 1.0)
        
        if progress == 1.0 {
            self.playSuccessAnimation()
        }
    }
    
    public func playSuccessAnimation() {
        guard !self.animatedWave else {
            return
        }
        let base = self.baseScale
        self.layer.transform = CATransform3DMakeScale(base * 1.1, base * 1.1, 1.0)
        self.layer.animateScale(from: base, to: base * 1.1, duration: 0.2, completion: { [weak self] _ in
            self?.layer.transform = CATransform3DMakeScale(base, base, 1.0)
            self?.layer.animateScale(from: base * 1.1, to: base, duration: 0.15)
        })
        
        self.animatedWave = true
        
        if !self.circularWaveEnabled {
            self.progressLayer.opacity = 0.0
            return
        }
        
        var lineWidth = self.progressLayer.lineWidth
        self.progressLayer.lineWidth = 0.0
        self.progressLayer.animate(from: lineWidth as NSNumber, to: 0.0 as NSNumber, keyPath: "lineWidth", timingFunction: CAMediaTimingFunctionName.linear.rawValue, duration: 0.3, completion: { _ in
            
        })
        
        var path = self.progressLayer.path
        var targetPath = UIBezierPath(arcCenter: CGPoint(x: self.progressLayer.frame.width / 2.0, y: self.progressLayer.frame.height / 2.0), radius: 35.0, startAngle: CGFloat(-0.5 * .pi), endAngle: CGFloat(-0.5 * .pi + 2.0 * .pi), clockwise: true).cgPath
        self.progressLayer.path = targetPath
        self.progressLayer.animate(from: path, to: targetPath, keyPath: "path", timingFunction: kCAMediaTimingFunctionSpring, duration: 0.3)
        
        self.progressLayer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3)
        
        self.fillLayer.isHidden = false
        self.fillLayer.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).cgPath
        self.fillLayer.lineWidth = 2.0 - UIScreenPixel
                
        lineWidth = self.fillLayer.lineWidth
        self.fillLayer.lineWidth = 18.0
        self.fillLayer.animate(from: lineWidth as NSNumber, to: 18.0 as NSNumber, keyPath: "lineWidth", timingFunction: CAMediaTimingFunctionName.linear.rawValue, duration: 0.3)
        
        path = self.fillLayer.path
        targetPath = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 9.0, dy: 9.0)).cgPath
        self.fillLayer.path = targetPath
        self.fillLayer.animate(from: path, to: targetPath, keyPath: "path", timingFunction: CAMediaTimingFunctionName.linear.rawValue, duration: 0.3)
    }
    
    /// Контур контурной стрелки Reply (`Chat/Context Menu/Reply`, PDF 24×24, вписан в 22 pt по центру кружка 33 pt):
    /// внешний контур залит целиком, внутренний «вырез» растёт от точки (`innerScale` 0) до полного размера (1).
    private static func outlineMorphPath(innerScale s: CGFloat) -> CGPath {
        let k: CGFloat = 22.0 / 24.0
        let origin: CGFloat = 5.5
        let o: (CGFloat, CGFloat) -> CGPoint = { x, y in
            return CGPoint(x: origin + x * k, y: origin + y * k)
        }
        let center = CGPoint(x: 12.0654, y: 12.3686)
        let i: (CGFloat, CGFloat) -> CGPoint = { x, y in
            return o(center.x + (x - center.x) * s, center.y + (y - center.y) * s)
        }
        let path = UIBezierPath()
        path.move(to: o(11.6650, 8.3493))
        path.addCurve(to: o(20.1893, 18.7208), controlPoint1: o(17.3842, 8.6001), controlPoint2: o(20.2782, 12.1420))
        path.addCurve(to: o(19.7529, 19.4603), controlPoint1: o(20.1852, 19.0272), controlPoint2: o(20.0191, 19.3086))
        path.addCurve(to: o(18.5908, 19.1668), controlPoint1: o(19.3480, 19.6913), controlPoint2: o(18.8351, 19.5591))
        path.addCurve(to: o(18.5731, 19.1375), controlPoint1: o(18.5847, 19.1572), controlPoint2: o(18.5788, 19.1475))
        path.addCurve(to: o(11.6650, 15.6776), controlPoint1: o(17.3358, 16.9674), controlPoint2: o(15.0610, 15.8090))
        path.addLine(to: o(11.6650, 18.3459))
        path.addCurve(to: o(11.3499, 19.1427), controlPoint1: o(11.6650, 18.6419), controlPoint2: o(11.5523, 18.9267))
        path.addCurve(to: o(9.7032, 19.1958), controlPoint1: o(10.9099, 19.6121), controlPoint2: o(10.1726, 19.6359))
        path.addLine(to: o(2.9343, 12.8499))
        path.addCurve(to: o(2.8811, 12.7968), controlPoint1: o(2.9071, 12.8239), controlPoint2: o(2.9071, 12.8239))
        path.addCurve(to: o(2.9343, 11.1501), controlPoint1: o(2.4411, 12.3274), controlPoint2: o(2.4649, 11.5901))
        path.addLine(to: o(9.7032, 4.8042))
        path.addCurve(to: o(10.5000, 4.4891), controlPoint1: o(9.9191, 4.6018), controlPoint2: o(10.2040, 4.4891))
        path.addCurve(to: o(11.6650, 5.6541), controlPoint1: o(11.1434, 4.4891), controlPoint2: o(11.6650, 5.0107))
        path.addLine(to: o(11.6650, 8.3493))
        path.close()
        // вырез
        path.move(to: i(11.0000, 9.6650))
        path.addCurve(to: i(10.3350, 9.0000), controlPoint1: i(10.6327, 9.6650), controlPoint2: i(10.3350, 9.3673))
        path.addLine(to: i(10.3350, 6.0350))
        path.addLine(to: i(3.9723, 12.0000))
        path.addLine(to: i(10.3350, 17.9650))
        path.addLine(to: i(10.3350, 15.0000))
        path.addCurve(to: i(11.0000, 14.3350), controlPoint1: i(10.3350, 14.6327), controlPoint2: i(10.6327, 14.3350))
        path.addCurve(to: i(18.8228, 17.2069), controlPoint1: i(14.5034, 14.3350), controlPoint2: i(17.1304, 15.2887))
        path.addCurve(to: i(11.0000, 9.6650), controlPoint1: i(18.4849, 12.1064), controlPoint2: i(15.9223, 9.6650))
        path.close()
        return path.cgPath
    }

    /// Концепт: залитая стрелка превращается в контурную — внутри заливки раскрывается вырез по форме стрелки.
    public func playOutlineMorph(color: UIColor, duration: Double) {
        let layer = CAShapeLayer()
        layer.frame = CGRect(origin: .zero, size: CGSize(width: 33.0, height: 33.0))
        layer.fillColor = color.cgColor
        layer.fillRule = .evenOdd
        let from = ChatMessageSwipeToReplyNode.outlineMorphPath(innerScale: 0.001)
        let to = ChatMessageSwipeToReplyNode.outlineMorphPath(innerScale: 1.0)
        layer.path = from
        self.layer.addSublayer(layer)
        self.outlineMorphLayer = layer
        self.alternateMix = 1.0
        ContainedViewLayoutTransition.animated(duration: 0.06, curve: .linear).updateAlpha(node: self.foregroundNode, alpha: 0.0)
        layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.06)
        // Сначала мгновение стоит заливка, потом внутри раскрывается вырез по форме стрелки.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: { [weak layer] in
            guard let layer else {
                return
            }
            layer.path = to
            layer.animate(from: from, to: to, keyPath: "path", timingFunction: CAMediaTimingFunctionName.linear.rawValue, duration: duration, mediaTimingFunction: CAMediaTimingFunction(controlPoints: 0.0, 0.4, 0.0, 1.0))
        })
    }

    /// Концепт: цвет стрелки плавно меняется на `color` (mix = 1) или возвращается к исходному (mix = 0).
    public func setAlternateForeground(color: UIColor?, outlineIconName: String? = nil, duration: Double) {
        if let color, self.alternateForegroundNode.image == nil {
            if let outlineIconName, let icon = UIImage(bundleImageName: outlineIconName) {
                self.alternateForegroundNode.image = generateImage(size, rotatedContext: { size, context in
                    context.clear(CGRect(origin: .zero, size: size))
                    let fitted = icon.size.width > 0.0 ? min(22.0 / icon.size.width, 22.0 / icon.size.height) : 1.0
                    let imageSize = CGSize(width: icon.size.width * fitted, height: icon.size.height * fitted)
                    let imageRect = CGRect(origin: CGPoint(x: floor((size.width - imageSize.width) / 2.0), y: floor((size.height - imageSize.height) / 2.0)), size: imageSize)
                    context.translateBy(x: imageRect.midX, y: imageRect.midY)
                    context.scaleBy(x: 1.0, y: -1.0)
                    context.translateBy(x: -imageRect.midX, y: -imageRect.midY)
                    context.clip(to: imageRect, mask: icon.cgImage!)
                    context.setFillColor(color.cgColor)
                    context.fill(imageRect)
                })
            } else {
                self.alternateForegroundNode.image = ChatMessageSwipeToReplyNode.makeForegroundImage(action: self.action, foregroundColor: color)
            }
        }
        let mix: CGFloat = color == nil ? 0.0 : 1.0
        self.alternateMix = mix
        let base = max(0.0, min(1.0, self.currentProgress * 1.2))
        let transition: ContainedViewLayoutTransition = duration > 0.0 ? .animated(duration: duration, curve: .easeInOut) : .immediate
        transition.updateAlpha(node: self.foregroundNode, alpha: base * (1.0 - mix))
        transition.updateAlpha(node: self.alternateForegroundNode, alpha: base * mix)
    }
    
    /// Концепт: подложка кружка (с кольцом и волной успеха) гаснет, пока под ним растёт капсула.
    public func setPlateAlpha(_ alpha: CGFloat, duration: Double) {
        let transition: ContainedViewLayoutTransition = duration > 0.0 ? .animated(duration: duration, curve: .easeInOut) : .immediate
        if let backgroundContent = self.backgroundContent {
            transition.updateAlpha(layer: backgroundContent.layer, alpha: alpha)
        } else {
            transition.updateAlpha(node: self.backgroundNode, alpha: alpha)
        }
    }
    
    public func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) {
        self.absolutePosition = (rect, containerSize)
    }
}

public extension ChatMessageSwipeToReplyNode.Action {
    init(_ action: ChatControllerInteractionSwipeAction?) {
        if let action = action {
            switch action {
            case .none:
                self = .reply
            case .reply:
                self = .reply
            case .hideFromScreenshot:
                self = .hide
            }
        } else {
            self = .reply
        }
    }
}
