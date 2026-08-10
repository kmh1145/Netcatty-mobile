import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var sshBackgroundTask: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "app.netcatty.mobile/connection",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "beginBackgroundGrace":
        self?.beginSshBackgroundGrace()
        result(nil)
      case "endBackgroundGrace":
        self?.endSshBackgroundGrace()
        result(nil)
      case "setActive":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func beginSshBackgroundGrace() {
    guard sshBackgroundTask == .invalid else { return }
    sshBackgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "Finish active SSH network work"
    ) { [weak self] in
      self?.endSshBackgroundGrace()
    }
  }

  private func endSshBackgroundGrace() {
    guard sshBackgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(sshBackgroundTask)
    sshBackgroundTask = .invalid
  }
}
