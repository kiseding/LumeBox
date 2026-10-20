import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/shell/dock_liquid_settings.dart';

/// iOS 原生系统材质底座，用于和自绘 Shader 方案做 A/B 对比。
///
/// iOS 26 原生层使用 `UIGlassEffect`，旧系统回退磨砂。
/// Flutter 侧负责布局，图标/文字/交互仍由 Flutter
/// 绘制，因此这是“原生材质底座 + Flutter 内容层”，不是完整的原生 TabBar。
///
/// 限制：受 Flutter 平台视图合成方式限制，原生视图无法参与 Flutter 的
/// `BackdropFilter` 取样，所以该模式下会关闭自绘透镜的折射/清澈遮罩，
/// 只保留填充、描边与拖动形变。
class DockNativeGlass extends StatefulWidget {
  const DockNativeGlass({
    super.key,
    required this.borderRadius,
    required this.cornerRadius,
    this.style = DockNativeGlassStyle.regular,
    this.tintColor = Colors.white,
    this.tintOpacity = .06,
    this.reduceTransparency = false,
  });

  static const String viewType = 'lumebox/glass_backdrop';
  static const String updateChannelPrefix = 'lumebox/glass_backdrop';

  /// 只有 iPhone 真机/模拟器才有原生 `UIVisualEffectView`。
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  final BorderRadius borderRadius;
  final double cornerRadius;
  final DockNativeGlassStyle style;
  final Color tintColor;
  final double tintOpacity;
  final bool reduceTransparency;

  @override
  State<DockNativeGlass> createState() => _DockNativeGlassState();
}

class _DockNativeGlassState extends State<DockNativeGlass> {
  MethodChannel? _channel;
  Map<String, Object?>? _sent;

  Map<String, Object?> get _configuration => <String, Object?>{
    'style': widget.style.name,
    'cornerRadius': widget.cornerRadius,
    'brightness': Theme.of(context).brightness.name,
    'reduceTransparency': widget.reduceTransparency,
  };

  @override
  void didUpdateWidget(DockNativeGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pushConfiguration();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pushConfiguration();
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('${DockNativeGlass.updateChannelPrefix}_$id');
    _sent = null;
    _pushConfiguration();
  }

  Future<void> _pushConfiguration() async {
    final channel = _channel;
    if (channel == null) return;
    final params = _configuration;
    if (mapEquals(_sent, params)) return;
    _sent = params;
    try {
      await channel.invokeMethod<void>('update', params);
    } on PlatformException catch (error) {
      _sent = null;
      debugPrint('Native dock configuration unavailable: $error');
    } on MissingPluginException {
      _sent = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!DockNativeGlass.supported) return const SizedBox.expand();
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          child: UiKitView(
            viewType: DockNativeGlass.viewType,
            creationParams: _configuration,
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _onPlatformViewCreated,
          ),
        ),
        if (widget.tintOpacity > 0)
          IgnorePointer(
            child: ClipRRect(
              borderRadius: widget.borderRadius,
              child: ColoredBox(
                color: widget.tintColor.withValues(
                  alpha: widget.tintOpacity.clamp(0.0, 1.0),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
