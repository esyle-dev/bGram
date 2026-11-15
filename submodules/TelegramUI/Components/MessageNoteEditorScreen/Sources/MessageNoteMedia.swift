import Foundation
import UIKit

/// What a link preview card shows (filled from the host's webpage preview).
public struct MessageNoteLinkCard: Equatable {
    public var url: String
    public var domain: String
    public var title: String?
    public var text: String?

    public init(url: String, domain: String, title: String?, text: String?) {
        self.url = url
        self.domain = domain
        self.title = title
        self.text = text
    }
}

/// Images of annotations.
///
/// A photo picked from the gallery is a demo simulation: it is kept in the app's documents on the sender's device
/// only and travels as an id, so recipients do not get it. A web image (`imageUrl`) is loaded from the web.
public enum MessageNoteMedia {
    private static let cache = NSCache<NSString, UIImage>()

    private static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("MessageNotes", isDirectory: true)
    }

    /// Stores a picked image and returns its id.
    public static func storeLocalImage(_ image: UIImage) -> String? {
        let id = UUID().uuidString
        let scaled = scaledImage(image, maxSide: 1280.0)
        guard let data = scaled.jpegData(compressionQuality: 0.85) else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try data.write(to: self.directory.appendingPathComponent("\(id).jpg"))
        } catch {
            return nil
        }
        self.cache.setObject(scaled, forKey: id as NSString)
        return id
    }

    /// A locally stored image; nil on any device but the sender's.
    public static func localImage(id: String) -> UIImage? {
        if let image = self.cache.object(forKey: id as NSString) {
            return image
        }
        guard !id.contains("/"), let image = UIImage(contentsOfFile: self.directory.appendingPathComponent("\(id).jpg").path) else {
            return nil
        }
        self.cache.setObject(image, forKey: id as NSString)
        return image
    }

    /// Loads a web image; the completion runs on the main queue.
    public static func loadRemoteImage(url: String, completion: @escaping (UIImage?) -> Void) {
        if let image = self.cache.object(forKey: url as NSString) {
            completion(image)
            return
        }
        guard let parsedUrl = URL(string: url), parsedUrl.scheme == "https" || parsedUrl.scheme == "http" else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: parsedUrl) { data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                if let image {
                    self.cache.setObject(image, forKey: url as NSString)
                }
                completion(image)
            }
        }.resume()
    }

    private static func scaledImage(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1.0, maxSide / max(size.width, size.height))
        if scale >= 1.0 {
            return image
        }
        let targetSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: CGPoint(), size: targetSize))
        }
    }
}

/// A link preview card: a site glyph, title, description and domain, and an "open" glyph.
final class MessageNoteLinkCardView: UIView {
    private let iconBackground = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let domainLabel = UILabel()
    private let openIconView = UIImageView()

    var card: MessageNoteLinkCard? {
        didSet {
            self.titleLabel.text = self.card?.title ?? self.card?.domain
            self.textLabel.text = self.card?.text
            self.domainLabel.text = self.card?.domain
            self.setNeedsLayout()
        }
    }

    init(textColor: UIColor, secondaryTextColor: UIColor, accentColor: UIColor, fillColor: UIColor) {
        super.init(frame: CGRect())
        self.backgroundColor = fillColor
        self.layer.cornerRadius = 12.0
        self.layer.cornerCurve = .continuous

        self.iconBackground.backgroundColor = accentColor.withAlphaComponent(0.15)
        self.iconBackground.layer.cornerRadius = 8.0
        self.iconView.image = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.0, weight: .medium))
        self.iconView.tintColor = accentColor
        self.iconView.contentMode = .center

        self.titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
        self.titleLabel.textColor = textColor
        self.textLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.textLabel.textColor = textColor
        self.textLabel.numberOfLines = 2
        self.domainLabel.font = UIFont.systemFont(ofSize: 13.0)
        self.domainLabel.textColor = secondaryTextColor

        self.openIconView.image = UIImage(systemName: "arrow.up.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold))
        self.openIconView.tintColor = secondaryTextColor
        self.openIconView.contentMode = .center

        self.addSubview(self.iconBackground)
        self.iconBackground.addSubview(self.iconView)
        self.addSubview(self.titleLabel)
        self.addSubview(self.textLabel)
        self.addSubview(self.domainLabel)
        self.addSubview(self.openIconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func heightThatFits(width: CGFloat) -> CGFloat {
        let textWidth = width - 10.0 - 36.0 - 10.0 - 30.0
        var height: CGFloat = 10.0 + 20.0
        if let text = self.textLabel.text, !text.isEmpty {
            height += ceil(self.textLabel.sizeThatFits(CGSize(width: textWidth, height: 40.0)).height)
        }
        height += 18.0 + 10.0
        return max(56.0, height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        self.iconBackground.frame = CGRect(x: 10.0, y: 10.0, width: 36.0, height: 36.0)
        self.iconView.frame = self.iconBackground.bounds
        let textX: CGFloat = 10.0 + 36.0 + 10.0
        let textWidth = size.width - textX - 30.0
        var y: CGFloat = 10.0
        self.titleLabel.frame = CGRect(x: textX, y: y, width: textWidth, height: 20.0)
        y += 20.0
        if let text = self.textLabel.text, !text.isEmpty {
            let height = ceil(self.textLabel.sizeThatFits(CGSize(width: textWidth, height: 40.0)).height)
            self.textLabel.frame = CGRect(x: textX, y: y, width: textWidth, height: height)
            y += height
        } else {
            self.textLabel.frame = CGRect()
        }
        self.domainLabel.frame = CGRect(x: textX, y: y, width: textWidth, height: 18.0)
        self.openIconView.frame = CGRect(x: size.width - 28.0, y: 10.0, width: 20.0, height: 20.0)
    }
}

/// Rounds a photo's corners: `top` at the top (following the card's corners) and `bottom` at the bottom.
func applyMessageNotePhotoCorners(_ view: UIView, top: CGFloat, bottom: CGFloat) {
    let bounds = view.bounds
    let path = UIBezierPath()
    path.move(to: CGPoint(x: bounds.minX + top, y: bounds.minY))
    path.addLine(to: CGPoint(x: bounds.maxX - top, y: bounds.minY))
    path.addArc(withCenter: CGPoint(x: bounds.maxX - top, y: bounds.minY + top), radius: top, startAngle: -.pi / 2.0, endAngle: 0.0, clockwise: true)
    path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - bottom))
    path.addArc(withCenter: CGPoint(x: bounds.maxX - bottom, y: bounds.maxY - bottom), radius: bottom, startAngle: 0.0, endAngle: .pi / 2.0, clockwise: true)
    path.addLine(to: CGPoint(x: bounds.minX + bottom, y: bounds.maxY))
    path.addArc(withCenter: CGPoint(x: bounds.minX + bottom, y: bounds.maxY - bottom), radius: bottom, startAngle: .pi / 2.0, endAngle: .pi, clockwise: true)
    path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + top))
    path.addArc(withCenter: CGPoint(x: bounds.minX + top, y: bounds.minY + top), radius: top, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
    path.close()
    let mask = (view.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
    mask.path = path.cgPath
    view.layer.mask = mask
    view.layer.cornerRadius = 0.0
}
