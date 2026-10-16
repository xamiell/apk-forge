import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // One screen with four panels side by side: open wide, and never so
    // narrow that the columns stack.
    self.minSize = NSSize(width: 1280, height: 760)
    self.setContentSize(NSSize(width: 1440, height: 900))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
