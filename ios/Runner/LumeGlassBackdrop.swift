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
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    LumeGlassBackdropView(frame: frame, args: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class LumeGlassBackdropView: NSObject, FlutterPlatformView {
  private let container = UIView()
  private let effectView: UIVisualEffectView

  init(frame: CGRect, args: Any?) {
    effectView = UIVisualEffectView(
      effect: UIBlurEffect(style: .systemUltraThinMaterial)
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
  }

  func view() -> UIView {
    container
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
