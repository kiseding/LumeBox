import Flutter
import UIKit

/// A real system navigation control, embedded only in the bottom bar's area.
/// The existing Flutter controller continues to own pages, routes and playback.
final class LumeSystemTabBarFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    registrar.register(LumeSystemTabBarFactory(messenger: messenger), withId: "lumebox/system_tab_bar")
    FlutterMethodChannel(name: "lumebox/system_tab_bar", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard call.method == "capabilities" else {
          result(FlutterMethodNotImplemented)
          return
        }
        if #available(iOS 26.0, *) {
          result(["supported": true, "height": LumeSystemTabBarContainer.fittingHeight(width: 320)])
        } else {
          // Keep the established Dock on systems without the new material.
          result(["supported": false])
        }
      }
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    LumeSystemTabBarView(frame: frame, viewId: viewId, args: args, messenger: messenger)
  }
}

private struct LumeSystemTabSpec: Equatable {
  let id: String
  let label: String
}

private final class LumeSystemTabBarContainer: UIView {
  let bar = UITabBar()
  var onHeightChanged: ((CGFloat) -> Void)?
  private var lastHeight: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    addSubview(bar)
    // Do not replace the system material with a custom UITabBarAppearance.
    // UIKit owns the platter, selected lens, gestures and accessibility.
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static func fittingHeight(width: CGFloat) -> CGFloat {
    let size = UITabBar().sizeThatFits(CGSize(width: max(width, 1), height: 1000))
    return min(max(ceil(size.height), 49), 100)
  }

  var fittingBarHeight: CGFloat {
    let size = bar.sizeThatFits(CGSize(width: max(bounds.width, 1), height: 1000))
    return min(max(ceil(size.height), 49), 100)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let height = fittingBarHeight
    bar.frame = CGRect(x: 0, y: max(0, bounds.height - height), width: bounds.width, height: height)
    if lastHeight != height {
      lastHeight = height
      // Deliver after layout, so Flutter can update its content inset safely.
      DispatchQueue.main.async { [weak self] in self?.onHeightChanged?(height) }
    }
  }
}

private final class LumeSystemTabBarView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let container: LumeSystemTabBarContainer
  private let channel: FlutterMethodChannel
  private var specs: [LumeSystemTabSpec] = []
  private var showLabels = true
  private var iconSize: CGFloat = 24

  init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    container = LumeSystemTabBarContainer(frame: frame)
    channel = FlutterMethodChannel(name: "lumebox/system_tab_bar_\(viewId)", binaryMessenger: messenger)
    super.init()
    container.bar.delegate = self
    container.onHeightChanged = { [weak self] height in
      self?.channel.invokeMethod("metrics", arguments: ["height": height])
    }
    _ = update(args)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      guard let self = self else { result(nil); return }
      guard self.update(call.arguments) else {
        result(FlutterError(code: "configuration", message: "Invalid system tab bar configuration", details: nil))
        return
      }
      result(["height": self.container.fittingBarHeight])
    }
  }

  deinit { channel.setMethodCallHandler(nil) }

  func view() -> UIView { container }

  private func update(_ arguments: Any?) -> Bool {
    guard let values = arguments as? [String: Any],
          let entries = values["entries"] as? [[String: Any]],
          !entries.isEmpty, entries.count <= 5 else { return false }
    var next: [LumeSystemTabSpec] = []
    for entry in entries {
      guard let id = entry["id"] as? String, ["comic", "video", "settings", "search"].contains(id),
            let label = entry["label"] as? String, !label.isEmpty,
            !next.contains(where: { $0.id == id }) else { return false }
      next.append(LumeSystemTabSpec(id: id, label: label))
    }
    let labels = values["showLabels"] as? Bool ?? true
    let rawSize = (values["iconSize"] as? NSNumber)?.doubleValue ?? 24
    let size = CGFloat(rawSize.isFinite ? min(max(rawSize, 18), 30) : 24)
    if specs != next || labels != showLabels || size != iconSize {
      specs = next
      showLabels = labels
      iconSize = size
      let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
      let items = specs.map { spec -> UITabBarItem in
        let symbol: String
        switch spec.id {
        case "comic": symbol = "book"
        case "video": symbol = "play.circle"
        case "search": symbol = "magnifyingglass"
        default: symbol = "gearshape"
        }
        let item = UITabBarItem(
          title: labels ? spec.label : nil,
          image: UIImage(systemName: symbol, withConfiguration: configuration),
          selectedImage: UIImage(systemName: spec.id == "search" ? symbol : symbol + ".fill", withConfiguration: configuration)
        )
        item.accessibilityLabel = spec.label
        item.accessibilityIdentifier = "shell.tab.\(spec.id)"
        return item
      }
      container.bar.setItems(items, animated: false)
    }
    let activeId = values["activeId"] as? String
    let index = specs.firstIndex(where: { $0.id == activeId })
    container.bar.selectedItem = index.flatMap { container.bar.items?[$0] }
    container.overrideUserInterfaceStyle = values["brightness"] as? String == "dark" ? .dark : .light
    if let tint = values["tintColor"] as? NSNumber {
      let argb = tint.uint32Value
      container.bar.tintColor = UIColor(
        red: CGFloat((argb >> 16) & 255) / 255,
        green: CGFloat((argb >> 8) & 255) / 255,
        blue: CGFloat(argb & 255) / 255, alpha: 1
      )
    }
    container.setNeedsLayout()
    return true
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard let index = tabBar.items?.firstIndex(where: { $0 === item }), index < specs.count else { return }
    channel.invokeMethod("selected", arguments: specs[index].id)
  }

  func tabBar(_ tabBar: UITabBar, shouldSelect item: UITabBarItem) -> Bool {
    guard let index = tabBar.items?.firstIndex(where: { $0 === item }), index < specs.count else { return false }
    if specs[index].id == "search" {
      channel.invokeMethod("selected", arguments: "search")
      return false
    }
    return true
  }
}
