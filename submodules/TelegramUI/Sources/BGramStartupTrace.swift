import Foundation
import UIKit

/// βeta build diagnostics: a tiny on-screen breadcrumb trail so a black-screen hang can be read
/// off the device without a debugger. Stages are appended to a file in Documents as well, and the
/// overlay is removed as soon as the main window shows its content.
public enum BGramStartupTrace {
    private static var overlayWindow: UIWindow?
    private static var label: UILabel?
    private static var fileName: String?

    public static func stage(_ text: String) {
        let stamp = String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        print("[bGram] \(stamp) \(text)")
        if let label {
            label.text = (label.text ?? "") + "\n" + text
        }
        if let fileName, let handle = FileHandle(forWritingAtPath: fileName) {
            handle.seekToEndOfFile()
            handle.write(("\(stamp) \(text)\n").data(using: .utf8) ?? Data())
            handle.closeFile()
        }
    }

    public static func install() {
        let documents = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let path = documents + "/bgram-startup.log"
        FileManager.default.createFile(atPath: path, contents: Data(), attributes: nil)
        fileName = path

        DispatchQueue.main.async {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.windowLevel = .alert + 1
            window.backgroundColor = .black
            let controller = UIViewController()
            controller.view.backgroundColor = .black
            let label = UILabel()
            label.numberOfLines = 0
            label.font = UIFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
            label.textColor = .white
            label.frame = window.bounds.insetBy(dx: 12.0, dy: 60.0)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(label)
            window.rootViewController = controller
            window.isHidden = false
            self.label = label
            self.overlayWindow = window
            if let labelText = label.text {
                label.text = labelText + "\nbGram (debug trace)"
            } else {
                label.text = "bGram (debug trace)"
            }
        }
        stage("launch")
    }

    public static func finish() {
        stage("ui shown")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
            self.label = nil
        }
    }
}