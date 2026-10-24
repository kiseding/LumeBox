import Flutter
import UIKit

/// Native UIKit glass navigation, embedded only in the bottom bar's area.
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


/// One native glass surface with public UIKit controls. A system UITabBar draws
/// its own floating platter; putting another material beneath it creates the
/// second white capsule and makes the visible height differ from Flutter's.
private final class LumeSystemTabBarContainer: UIView {
  let material = UIVisualEffectView()
  private var buttons: [UIButton] = []
  private var selectionViews: [UIView] = []
  private var specs: [LumeSystemTabSpec] = []
  var onSelect: ((String) -> Void)?
  var activeId: String?
  var materialOpacity: CGFloat = 0.6
  var showLabels = true
  var iconSize: CGFloat = 24
  var accent = UIColor.systemPurple

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .clear)
      glass.tintColor = nil
      material.effect = glass
    } else { material.effect = UIBlurEffect(style: .systemUltraThinMaterial) }
    #else
    material.effect = UIBlurEffect(style: .systemUltraThinMaterial)
    #endif
    material.isUserInteractionEnabled = false
    material.clipsToBounds = true
    addSubview(material)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  static func fittingHeight(width: CGFloat) -> CGFloat { 64 }

  func configure(_ next: [LumeSystemTabSpec]) {
    if specs != next {
      buttons.forEach { $0.removeFromSuperview() }
      selectionViews.forEach { $0.removeFromSuperview() }
      buttons = []; selectionViews = []; specs = next
      for (index, spec) in specs.enumerated() {
        let selected = UIView()
        selected.isUserInteractionEnabled = false
        addSubview(selected); selectionViews.append(selected)
        let button = UIButton(type: .custom)
        button.tag = index
        button.accessibilityLabel = spec.label
        button.accessibilityIdentifier = "shell.tab.\(spec.id)"
        button.addTarget(self, action: #selector(activate(_:)), for: .touchUpInside)
        addSubview(button); buttons.append(button)
      }
    }
    material.alpha = materialOpacity
    for (index, spec) in specs.enumerated() {
      let selected = spec.id == activeId
      let symbol: String
      switch spec.id {
      case "comic": symbol = "book"
      case "video": symbol = "play.circle"
      case "search": symbol = "magnifyingglass"
      default: symbol = "gearshape"
      }
      let imageName = selected && spec.id != "search" ? symbol + ".fill" : symbol
      var config = UIButton.Configuration.plain()
      config.image = UIImage(systemName: imageName, withConfiguration:
        UIImage.SymbolConfiguration(pointSize: iconSize, weight: .regular))
      config.baseForegroundColor = selected ? accent : .label
      config.imagePlacement = .top
      config.imagePadding = 2
      config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
      if showLabels {
        var title = AttributedString(spec.label)
        title.font = UIFont.systemFont(ofSize: 10, weight: selected ? .semibold : .regular)
        config.attributedTitle = title
      }
      buttons[index].configuration = config
      buttons[index].accessibilityTraits = selected ? [.button, .selected] : [.button]
      selectionViews[index].backgroundColor = selected ? accent.withAlphaComponent(0.10 * materialOpacity) : .clear
    }
    setNeedsLayout()
  }

  @objc private func activate(_ button: UIButton) {
    guard button.tag >= 0 && button.tag < specs.count else { return }
    let id = specs[button.tag].id
    if id != "search" { activeId = id; configure(specs) }
    onSelect?(id)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    material.frame = bounds
    material.layer.cornerRadius = bounds.height / 2
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      material.cornerConfiguration = .corners(radius: .fixed(Double(bounds.height / 2)))
    }
    #endif
    let inset: CGFloat = 4
    let width = max(0, bounds.width - inset * 2) / CGFloat(max(1, specs.count))
    for i in buttons.indices {
      let frame = CGRect(x: inset + CGFloat(i) * width, y: inset,
        width: width, height: max(0, bounds.height - inset * 2))
      buttons[i].frame = frame
      selectionViews[i].frame = frame
      selectionViews[i].layer.cornerRadius = frame.height / 2
    }
  }
}

private final class LumeSystemTabBarView: NSObject, FlutterPlatformView {
  private let container: LumeSystemTabBarContainer
  private let channel: FlutterMethodChannel

  init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    container = LumeSystemTabBarContainer(frame: frame)
    channel = FlutterMethodChannel(name: "lumebox/system_tab_bar_\(viewId)", binaryMessenger: messenger)
    super.init()
    container.onSelect = { [weak self] id in self?.channel.invokeMethod("selected", arguments: id) }
    _ = update(args)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      guard let self = self else { result(nil); return }
      guard self.update(call.arguments) else {
        result(FlutterError(code: "configuration", message: "Invalid native navigation configuration", details: nil)); return
      }
      result(["height": LumeSystemTabBarContainer.fittingHeight(width: self.container.bounds.width)])
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
    container.showLabels = values["showLabels"] as? Bool ?? true
    let rawSize = (values["iconSize"] as? NSNumber)?.doubleValue ?? 24
    container.iconSize = CGFloat(rawSize.isFinite ? min(max(rawSize, 18), 30) : 24)
    container.activeId = values["activeId"] as? String
    container.overrideUserInterfaceStyle = values["brightness"] as? String == "dark" ? .dark : .light
    let rawOpacity = (values["materialOpacity"] as? NSNumber)?.doubleValue ?? 0.6
    container.materialOpacity = CGFloat(rawOpacity.isFinite ? min(1, max(0, rawOpacity)) : 0.6)
    if let tint = values["tintColor"] as? NSNumber {
      let argb = tint.uint32Value
      container.accent = UIColor(red: CGFloat((argb >> 16) & 255) / 255,
        green: CGFloat((argb >> 8) & 255) / 255, blue: CGFloat(argb & 255) / 255, alpha: 1)
    }
    container.configure(next)
    return true
  }
}
