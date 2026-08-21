import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var sshBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var pictureInPictureChannel: FlutterMethodChannel?
  private var terminalPictureInPictureStorage: AnyObject?

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
    let pictureInPictureChannel = FlutterMethodChannel(
      name: "app.netcatty.mobile/picture_in_picture",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    self.pictureInPictureChannel = pictureInPictureChannel
    pictureInPictureChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      guard #available(iOS 15.0, *) else {
        if call.method == "isSupported" || call.method == "enter" {
          result(false)
        } else {
          result(nil)
        }
        return
      }
      let controller = self.terminalPictureInPictureController()
      switch call.method {
      case "isSupported":
        result(controller.isSupported)
      case "enter":
        guard let arguments = call.arguments as? [String: Any] else {
          result(false)
          return
        }
        controller.start(
          arguments: arguments,
          sourceView: self.activeViewController()?.view
        ) { entered in
          result(entered)
        }
      case "update":
        if let arguments = call.arguments as? [String: Any] {
          controller.update(arguments: arguments)
        }
        result(nil)
      case "stop":
        controller.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  @available(iOS 15.0, *)
  private func terminalPictureInPictureController() -> TerminalPictureInPictureController {
    if let existing = terminalPictureInPictureStorage as? TerminalPictureInPictureController {
      return existing
    }
    let controller = TerminalPictureInPictureController { [weak self] active in
      guard let self else { return }
      self.pictureInPictureChannel?.invokeMethod(
        "stateChanged",
        arguments: ["active": active]
      )
      if active {
        self.endSshBackgroundGrace()
      } else if UIApplication.shared.applicationState != .active {
        self.beginSshBackgroundGrace()
      }
    }
    terminalPictureInPictureStorage = controller
    return controller
  }

  private var isTerminalPictureInPictureActive: Bool {
    if #available(iOS 15.0, *),
       let controller = terminalPictureInPictureStorage as? TerminalPictureInPictureController {
      return controller.isActiveOrStarting
    }
    return false
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
    guard !isTerminalPictureInPictureActive else { return }
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
    if #available(iOS 15.0, *),
       let controller = terminalPictureInPictureStorage as? TerminalPictureInPictureController {
      controller.stop()
    }
    endSshBackgroundGrace()
    super.applicationWillTerminate(application)
  }
}

@available(iOS 15.0, *)
private final class TerminalPictureInPictureController: NSObject {
  private let displayLayer = AVSampleBufferDisplayLayer()
  private let sourceContainer = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
  private let onStateChanged: (Bool) -> Void
  private var pictureInPictureController: AVPictureInPictureController?
  private var startCompletion: ((Bool) -> Void)?
  private var starting = false
  private let renderQueue = DispatchQueue(
    label: "app.netcatty.mobile.pip-render",
    qos: .utility
  )
  private var renderGeneration = 0
  private var lastFrameSignature: Int?
  private var pixelBufferPool: CVPixelBufferPool?
  private var formatDescription: CMVideoFormatDescription?

  init(onStateChanged: @escaping (Bool) -> Void) {
    self.onStateChanged = onStateChanged
    super.init()
    displayLayer.videoGravity = .resizeAspect
    displayLayer.frame = sourceContainer.bounds
    sourceContainer.isUserInteractionEnabled = false
    sourceContainer.alpha = 0.01
    sourceContainer.layer.addSublayer(displayLayer)
  }

  var isSupported: Bool {
    AVPictureInPictureController.isPictureInPictureSupported()
  }

  var isActiveOrStarting: Bool {
    starting || pictureInPictureController?.isPictureInPictureActive == true
  }

  func start(
    arguments: [String: Any],
    sourceView: UIView?,
    completion: @escaping (Bool) -> Void
  ) {
    guard isSupported else {
      completion(false)
      return
    }
    if pictureInPictureController?.isPictureInPictureActive == true || starting {
      completion(true)
      return
    }
    attachSource(to: sourceView)
    update(arguments: arguments)
    configurePlaybackSession()
    if pictureInPictureController == nil {
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: displayLayer,
        playbackDelegate: self
      )
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      controller.requiresLinearPlayback = true
      controller.canStartPictureInPictureAutomaticallyFromInline = false
      pictureInPictureController = controller
    }
    starting = true
    startCompletion = completion
    attemptStart(remainingAttempts: 20)
  }

  func update(arguments: [String: Any]) {
    let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = arguments["text"] as? String ?? ""
    let connected = arguments["connected"] as? Bool ?? false
    let background = uiColor(
      arguments["backgroundColor"],
      fallback: 0xff111318
    )
    let foreground = uiColor(
      arguments["foregroundColor"],
      fallback: 0xffe4e2e8
    )
    let accent = uiColor(
      arguments["accentColor"],
      fallback: 0xffff8a3d
    )
    let resolvedTitle = title?.isEmpty == false ? title! : "SSH Terminal"
    let resolvedText = text.isEmpty ? "等待终端输出…" : text
    var hasher = Hasher()
    hasher.combine(resolvedTitle)
    hasher.combine(resolvedText)
    hasher.combine(connected)
    hasher.combine(arguments["backgroundColor"] as? Int ?? 0)
    hasher.combine(arguments["foregroundColor"] as? Int ?? 0)
    hasher.combine(arguments["accentColor"] as? Int ?? 0)
    let signature = hasher.finalize()
    guard signature != lastFrameSignature else { return }
    lastFrameSignature = signature
    renderGeneration += 1
    let generation = renderGeneration
    renderQueue.async { [weak self] in
      guard let self,
            let pixelBuffer = self.renderFrame(
              title: resolvedTitle,
              text: resolvedText,
              connected: connected,
              background: background,
              foreground: foreground,
              accent: accent
            ) else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.renderGeneration else { return }
        self.enqueue(pixelBuffer)
      }
    }
  }

  func stop() {
    renderGeneration += 1
    lastFrameSignature = nil
    starting = false
    finishStart(false)
    if pictureInPictureController?.isPictureInPictureActive == true {
      pictureInPictureController?.stopPictureInPicture()
    } else {
      detachSource()
      deactivatePlaybackSession()
      onStateChanged(false)
    }
  }

  private func attachSource(to view: UIView?) {
    guard sourceContainer.superview == nil, let view else { return }
    view.insertSubview(sourceContainer, at: 0)
  }

  private func detachSource() {
    sourceContainer.removeFromSuperview()
    displayLayer.flushAndRemoveImage()
  }

  private func configurePlaybackSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    try? session.setActive(true)
  }

  private func deactivatePlaybackSession() {
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
  }

  private func attemptStart(remainingAttempts: Int) {
    guard starting, let controller = pictureInPictureController else { return }
    if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self, self.starting else { return }
        self.starting = false
        self.finishStart(false)
        self.onStateChanged(false)
      }
      return
    }
    guard remainingAttempts > 0 else {
      starting = false
      finishStart(false)
      detachSource()
      deactivatePlaybackSession()
      onStateChanged(false)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.attemptStart(remainingAttempts: remainingAttempts - 1)
    }
  }

  private func finishStart(_ entered: Bool) {
    let completion = startCompletion
    startCompletion = nil
    completion?(entered)
  }

  private func renderFrame(
    title: String,
    text: String,
    connected: Bool,
    background: UIColor,
    foreground: UIColor,
    accent: UIColor
  ) -> CVPixelBuffer? {
    let width = 960
    let height = 540
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
      let context = renderer.cgContext
      context.setFillColor(background.cgColor)
      context.fill(CGRect(origin: .zero, size: size))

      context.setFillColor(background.blended(with: foreground, amount: 0.08).cgColor)
      context.fill(CGRect(x: 0, y: 0, width: width, height: 66))
      context.setFillColor((connected ? UIColor.systemGreen : UIColor.systemOrange).cgColor)
      context.fillEllipse(in: CGRect(x: 24, y: 25, width: 16, height: 16))

      let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 25, weight: .semibold),
        .foregroundColor: foreground,
      ]
      (title as NSString).draw(
        in: CGRect(x: 54, y: 17, width: width - 130, height: 36),
        withAttributes: titleAttributes
      )
      let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 19, weight: .medium),
        .foregroundColor: accent,
      ]
      ("PiP" as NSString).draw(
        in: CGRect(x: width - 72, y: 20, width: 52, height: 30),
        withAttributes: badgeAttributes
      )

      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byClipping
      paragraph.minimumLineHeight = 25
      paragraph.maximumLineHeight = 25
      let terminalAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular),
        .foregroundColor: foreground,
        .paragraphStyle: paragraph,
      ]
      (text as NSString).draw(
        in: CGRect(x: 22, y: 79, width: width - 44, height: height - 94),
        withAttributes: terminalAttributes
      )
    }
    guard let cgImage = image.cgImage else { return nil }

    if pixelBufferPool == nil {
      let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      ]
      let poolAttributes: [CFString: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey: 3,
      ]
      let bufferAttributes: [CFString: Any] = [
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey:
          attributes[kCVPixelBufferIOSurfacePropertiesKey] as Any,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      ]
      CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        poolAttributes as CFDictionary,
        bufferAttributes as CFDictionary,
        &pixelBufferPool
      )
    }
    guard let pixelBufferPool else { return nil }
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(
      kCFAllocatorDefault,
      pixelBufferPool,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
          let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
              CGBitmapInfo.byteOrder32Little.rawValue
          ) else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixelBuffer
  }

  private func enqueue(_ pixelBuffer: CVPixelBuffer) {
    if displayLayer.status == .failed {
      displayLayer.flush()
    }
    guard displayLayer.isReadyForMoreMediaData else { return }
    if formatDescription == nil {
      guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      ) == noErr else { return }
    }
    guard let formatDescription else { return }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 2),
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    ) == noErr, let sampleBuffer else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ) {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    displayLayer.enqueue(sampleBuffer)
  }

  private func uiColor(_ value: Any?, fallback: UInt32) -> UIColor {
    let raw = UInt32(truncating: value as? NSNumber ?? NSNumber(value: fallback))
    return UIColor(
      red: CGFloat((raw >> 16) & 0xff) / 255,
      green: CGFloat((raw >> 8) & 0xff) / 255,
      blue: CGFloat(raw & 0xff) / 255,
      alpha: CGFloat((raw >> 24) & 0xff) / 255
    )
  }
}

@available(iOS 15.0, *)
extension TerminalPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {}

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    true
  }
}

@available(iOS 15.0, *)
extension TerminalPictureInPictureController: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    starting = false
    finishStart(true)
    onStateChanged(true)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    starting = false
    finishStart(false)
    detachSource()
    deactivatePlaybackSession()
    onStateChanged(false)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    starting = false
    finishStart(false)
    detachSource()
    deactivatePlaybackSession()
    onStateChanged(false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first
    scene?.windows.first?.makeKeyAndVisible()
    completionHandler(true)
  }
}

private extension UIColor {
  func blended(with color: UIColor, amount: CGFloat) -> UIColor {
    var red1: CGFloat = 0
    var green1: CGFloat = 0
    var blue1: CGFloat = 0
    var alpha1: CGFloat = 0
    var red2: CGFloat = 0
    var green2: CGFloat = 0
    var blue2: CGFloat = 0
    var alpha2: CGFloat = 0
    guard getRed(&red1, green: &green1, blue: &blue1, alpha: &alpha1),
          color.getRed(&red2, green: &green2, blue: &blue2, alpha: &alpha2) else {
      return self
    }
    let fraction = min(max(amount, 0), 1)
    return UIColor(
      red: red1 + (red2 - red1) * fraction,
      green: green1 + (green2 - green1) * fraction,
      blue: blue1 + (blue2 - blue1) * fraction,
      alpha: alpha1 + (alpha2 - alpha1) * fraction
    )
  }
}
