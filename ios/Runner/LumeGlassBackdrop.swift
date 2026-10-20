import Flutter
import UIKit

/// 原生系统材质底座：给 Flutter 侧“iOS 原生材质”开关使用。
///
/// 这里用系统的 `UIVisualEffectView` + `UIBlurEffect` 材质；iOS 26 上系统
/// 材质会自动采用 Liquid Glass 外观，旧系统则保持系统磨砂。这样不依赖
/// iOS 26 SDK 的新符号，CI 的 Xcode 版本变化不会让工程编译失败。
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

  init(
    frame: CGRect,
    viewId: Int64,
    args: Any?,
    messenger: FlutterBinaryMessenger
  ) {
    effectView = UIVisualEffectView(effect: Self.effect(from: args))
    channel = FlutterMethodChannel(
      name: "lumebox/glass_backdrop_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    let radius = Self.cornerRadius(from: args)
    container.frame = frame
    container.backgroundColor = .clear
    container.clipsToBounds = true
    container.layer.cornerRadius = radius
    container.layer.cornerCurve = .continuous

    effectView.frame = container.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.clipsToBounds = true
    effectView.layer.cornerRadius = radius
    effectView.layer.cornerCurve = .continuous
    container.addSubview(effectView)

    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self else {
        result(nil)
        return
      }
      self.effectView.effect = Self.effect(from: call.arguments)
      result(nil)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    container
  }

  private static func effect(from args: Any?) -> UIVisualEffect {
    let style = (args as? [String: Any])?["style"] as? String
    switch style {
    case "thin":
      return UIBlurEffect(style: .systemUltraThinMaterial)
    case "thick":
      return UIBlurEffect(style: .systemThinMaterial)
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
    return CGFloat(truncating: value)
  }
}
