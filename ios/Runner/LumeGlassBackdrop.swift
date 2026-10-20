import Flutter
import UIKit

/// 原生系统材质底座：给 Flutter 侧“iOS 原生材质”开关使用。
///
/// iOS 26 使用 UIGlassEffect；旧系统、厚实风格及降低透明度使用磨砂。
/// 普通 UIBlurEffect 不会自动升级为 Liquid Glass。
///
/// 限制：Flutter 平台视图是独立层，不能参与 Flutter 的 `BackdropFilter`
/// 取样，因此 Dart 侧在该模式下会关闭自绘透镜的 Backdrop 折射。
final class LumeGlassBackdropFactory: NSObject, FlutterPlatformViewFactory {
  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  private let messenger: FlutterBinaryMessenger

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    LumeGlassBackdropView(
      frame: frame,
      viewId: viewId,
      args: args,
      messenger: messenger
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class LumeGlassBackdropView: NSObject, FlutterPlatformView {
  private let container = UIView()
  private let effectView: UIVisualEffectView
  private let channel: FlutterMethodChannel
  private var materialKey = ""

  init(
    frame: CGRect,
    viewId: Int64,
    args: Any?,
    messenger: FlutterBinaryMessenger
  ) {
    effectView = UIVisualEffectView()
    channel = FlutterMethodChannel(
      name: "lumebox/glass_backdrop_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    container.frame = frame
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false
    container.layer.cornerCurve = .continuous

    effectView.frame = container.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.layer.cornerCurve = .continuous
    container.addSubview(effectView)
    update(args)

    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self else {
        result(nil)
        return
      }
      self.update(call.arguments)
      result(nil)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    container
  }

  private func update(_ args: Any?) {
    let params = args as? [String: Any] ?? [:]
    let style = params["style"] as? String ?? "regular"
    let reduced = params["reduceTransparency"] as? Bool ?? false
    let radius = Self.cornerRadius(from: args)
    container.layer.cornerRadius = radius
    effectView.layer.cornerRadius = radius
    // Native traits must follow the app theme, including a manually chosen theme.
    container.overrideUserInterfaceStyle = params["brightness"] as? String == "dark"
      ? .dark : .light
    effectView.clipsToBounds = true
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      effectView.cornerConfiguration = .corners(radius: .fixed(Double(radius)))
      effectView.clipsToBounds = style == "thick" || reduced
    }
    #endif
    let key = "\(style):\(reduced)"
    if key != materialKey {
      materialKey = key
      effectView.effect = Self.effect(style: style, reduced: reduced)
    }
  }

  private static func effect(style: String, reduced: Bool) -> UIVisualEffect {
    // Xcode 26 / Swift 6.2 provides the new SDK symbols. Older toolchains can
    // still compile the project and retain the documented material fallback.
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), style != "thick", !reduced {
      let glass = UIGlassEffect(style: style == "thin" ? .clear : .regular)
      // Flutter owns hit testing and pressure animation for this backdrop.
      glass.isInteractive = false
      return glass
    }
    #endif
    if reduced { return UIBlurEffect(style: .systemThickMaterial) }
    switch style {
    case "thin":
      return UIBlurEffect(style: .systemUltraThinMaterial)
    case "thick":
      return UIBlurEffect(style: .systemThickMaterial)
    default:
      return UIBlurEffect(style: .systemMaterial)
    }
  }

  private static func cornerRadius(from args: Any?) -> CGFloat {
    guard
      let params = args as? [String: Any],
      let value = params["cornerRadius"] as? NSNumber
    else {
      return 0
    }
    let radius = value.doubleValue
    return radius.isFinite ? CGFloat(max(0, radius)) : 0
  }
}
