import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var backupPolicyChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "dev.tailscale.dart.demo/backup-policy",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler(handleBackupPolicyCall)
    backupPolicyChannel = channel

    super.awakeFromNib()
  }

  private func handleBackupPolicyCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "excludeFromBackup" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let path = call.arguments as? String else {
      result(FlutterError(code: "invalid-path", message: "Expected a state directory path.", details: nil))
      return
    }
    do {
      let url = NSURL(fileURLWithPath: path, isDirectory: true)
      try url.setResourceValue(true, forKey: .isExcludedFromBackupKey)
      var excluded: AnyObject?
      try url.getResourceValue(&excluded, forKey: .isExcludedFromBackupKey)
      guard excluded as? Bool == true else {
        throw CocoaError(.fileWriteUnknown)
      }
      result(true)
    } catch {
      result(FlutterError(code: "backup-exclusion-failed", message: error.localizedDescription, details: nil))
    }
  }
}
