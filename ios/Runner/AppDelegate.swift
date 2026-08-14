import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private var sshBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var directoryPickerResult: FlutterResult?
  private var mountedDirectoryURL: URL?
  private var mountedDirectoryHasSecurityAccess = false
  private let directoryBookmarkKey = "netcatty.ios.mountedDirectoryBookmark"

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
    let storageChannel = FlutterMethodChannel(
      name: "app.netcatty.mobile/storage",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    storageChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "Storage service is unavailable", details: nil))
        return
      }
      switch call.method {
      case "getMount":
        result(self.restoreDirectoryMount())
      case "mount":
        self.presentDirectoryPicker(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func presentDirectoryPicker(result: @escaping FlutterResult) {
    guard directoryPickerResult == nil else {
      result(FlutterError(code: "already_active", message: "A directory picker is already open", details: nil))
      return
    }
    guard let presenter = activeViewController() else {
      result(FlutterError(code: "unavailable", message: "Unable to present the directory picker", details: nil))
      return
    }
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    } else {
      picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    directoryPickerResult = result
    presenter.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let result = directoryPickerResult else { return }
    directoryPickerResult = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    do {
      result(try activateDirectoryMount(url, persist: true))
    } catch {
      result(FlutterError(code: "directory_access_failed", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = directoryPickerResult
    directoryPickerResult = nil
    result?(nil)
  }

  private func restoreDirectoryMount() -> [String: Any] {
    if let url = mountedDirectoryURL {
      return directoryMountPayload(url)
    }
    guard let bookmark = UserDefaults.standard.data(forKey: directoryBookmarkKey) else {
      return ["mounted": false]
    }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      let payload = try activateDirectoryMount(url, persist: stale)
      return payload
    } catch {
      UserDefaults.standard.removeObject(forKey: directoryBookmarkKey)
      return ["mounted": false]
    }
  }

  private func activateDirectoryMount(_ url: URL, persist: Bool) throws -> [String: Any] {
    releaseDirectoryMount()
    let granted = url.startAccessingSecurityScopedResource()
    guard granted || FileManager.default.fileExists(atPath: url.path) else {
      throw NSError(
        domain: "app.netcatty.mobile.storage",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "无法访问所选目录，请在系统文件选择器中重新授权。"]
      )
    }
    mountedDirectoryURL = url
    mountedDirectoryHasSecurityAccess = granted
    if persist {
      do {
        let bookmark = try url.bookmarkData(
          options: .minimalBookmark,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: directoryBookmarkKey)
      } catch {
        releaseDirectoryMount()
        throw error
      }
    }
    return directoryMountPayload(url)
  }

  private func directoryMountPayload(_ url: URL) -> [String: Any] {
    return [
      "mounted": true,
      "path": url.path,
      "name": url.lastPathComponent,
    ]
  }

  private func releaseDirectoryMount() {
    if mountedDirectoryHasSecurityAccess {
      mountedDirectoryURL?.stopAccessingSecurityScopedResource()
    }
    mountedDirectoryURL = nil
    mountedDirectoryHasSecurityAccess = false
  }

  private func activeViewController() -> UIViewController? {
    let sceneController = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController
    var controller = sceneController ?? window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
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

  override func applicationWillTerminate(_ application: UIApplication) {
    releaseDirectoryMount()
    endSshBackgroundGrace()
    super.applicationWillTerminate(application)
  }
}
