import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backupPolicyChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "dev.tailscale.dart.demo/backup-policy",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler(handleBackupPolicyCall)
    backupPolicyChannel = channel
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
