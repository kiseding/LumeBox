import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 画中画控制器：生命周期跟随 App（方法通道由它注册）。
  private let pip = PipController()

  /// 语音朗读控制器（AVSpeechSynthesizer）：生命周期跟随 App。
  private let speech = SpeechController()

  /// 屏幕亮度控制器（UIScreen.brightness）：生命周期跟随 App。
  private let brightness = BrightnessController()

  /// 播放缓冲参数控制器：把 Dart 侧给的参数传给 AVPlayer 内核
  /// （经 UserDefaults 与 vendored 插件交接，见该文件文档）。
  private let buffering = BufferingController()

  /// 播放会话控制器：后台音频 + 锁屏 / 控制中心的媒体控制器。
  private let playback = PlaybackSessionController()
  private let wafCookies = WafCookieController()
  private let battery = BatteryController()
  private let configurationExport = ConfigurationExportController()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "LumeBoxConfiguration")?.messenger() {
      configurationExport.register(with: messenger)
      FlutterMethodChannel(name: "lumebox/app_icon", binaryMessenger: messenger).setMethodCallHandler { call, result in
        if call.method == "current" { result(UIApplication.shared.alternateIconName ?? "default"); return }
        guard call.method == "set" else { result(FlutterMethodNotImplemented); return }
        guard UIApplication.shared.supportsAlternateIcons else { result(FlutterError(code: "unsupported", message: "This device does not support alternate icons", details: nil)); return }
        guard let name = call.arguments as? String, ["default", "Aurora", "Obsidian", "Solar", "Orbit", "Prism", "Spark"].contains(name) else { result(FlutterError(code: "icon", message: "Unknown icon", details: nil)); return }
        UIApplication.shared.setAlternateIconName(name == "default" ? nil : name) { error in
          if let error = error { result(FlutterError(code: "icon", message: error.localizedDescription, details: nil)) }
          else { result(true) }
        }
      }
    }
    // 画中画通道：与 Dart 侧 `MethodChannelPipBackend` 的契约一一对应。
    // 用插件注册器的 binaryMessenger 注册，保证与 Flutter 引擎同一条消息通道。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxPip")?.messenger() {
      pip.register(with: messenger)
    }

    // 语音朗读通道：与 Dart 侧 `MethodChannelSpeechBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxSpeech")?.messenger() {
      speech.register(with: messenger)
    }

    // 屏幕亮度通道：与 Dart 侧 `MethodChannelBrightnessBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxBrightness")?.messenger() {
      brightness.register(with: messenger)
    }

    // 播放缓冲参数通道：与 Dart 侧 `MethodChannelBufferingBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxBuffering")?.messenger() {
      buffering.register(with: messenger)
    }

    // 播放会话通道（后台音频 + 锁屏控制）：与 Dart 侧
    // `MethodChannelPlaybackBackend` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxPlayback")?.messenger() {
      playback.register(with: messenger)
    }

    // 网页视图的 Cookie 仓库（内置 WebView 过完 Cloudflare 校验后取回会话）：
    // 与 Dart 侧 `WafWebViewPage` 的契约一一对应。
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxWafCookies")?.messenger() {
      wafCookies.register(with: messenger)
    }

    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "LumeBoxBattery")?.messenger() {
      battery.register(with: messenger)
    }
  }
}

private final class ConfigurationExportController: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var temporary: URL?
  func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "lumebox/configuration", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "export" else { result(FlutterMethodNotImplemented); return }
        guard let self = self else { result(false); return }
        guard self.pending == nil else { result(FlutterError(code: "busy", message: "An export is already open", details: nil)); return }
        guard let args = call.arguments as? [String: Any], let text = args["text"] as? String,
              let name = args["name"] as? String, name == (name as NSString).lastPathComponent else {
          result(FlutterError(code: "arguments", message: "Invalid backup", details: nil)); return
        }
        do {
          let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
          try text.write(to: url, atomically: true, encoding: .utf8)
          var presenter = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
          while let next = presenter?.presentedViewController { presenter = next }
          guard let viewController = presenter else { result(false); return }
          let picker: UIDocumentPickerViewController
          if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true) }
          else { picker = UIDocumentPickerViewController(url: url, in: .exportToService) }
          self.pending = result
          self.temporary = url
          picker.delegate = self
          viewController.present(picker, animated: true)
        } catch { result(FlutterError(code: "export", message: error.localizedDescription, details: nil)) }
      }
  }
  private func finish(_ saved: Bool) {
    let callback = pending
    pending = nil
    if let url = temporary { try? FileManager.default.removeItem(at: url) }
    temporary = nil
    callback?(saved)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(!urls.isEmpty) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
}
