import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/shell/dock_liquid_settings.dart';

/// iOS 原生系统材质底座，用于和自绘 Shader 方案做 A/B 对比。
///
/// 原生层用 `UIVisualEffectView` 的系统材质；iOS 26 上系统材质会自动采用
/// Liquid Glass 外观。Flutter 侧只负责裁剪与布局，图标/文字/交互仍由 Flutter
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
  });

  static const String viewType = 'lumebox/glass_backdrop';
  static const String updateChannelPrefix = 'lumebox/glass_backdrop';

  /// 只有 iPhone 真机/模拟器才有原生 `UIVisualEffectView`。
  static bool get supported => !kIsWeb && Platform.isIOS;

  final BorderRadius borderRadius;
  final double cornerRadius;
  final DockNativeGlassStyle style;
  final Color tintColor;
  final double tintOpacity;

  @override
  State<DockNativeGlass> createState() => _DockNativeGlassState();
}

class _DockNativeGlassState extends State<DockNativeGlass> {
  MethodChannel? _channel;

  @override
  void didUpdateWidget(DockNativeGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) _pushStyle();
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('${DockNativeGlass.updateChannelPrefix}_$id');
  }

  void _pushStyle() {
    _channel?.invokeMethod<void>('update', <String, Object?>{
      'style': widget.style.name,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!DockNativeGlass.supported) return const SizedBox.expand();
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          IgnorePointer(
            child: UiKitView(
              viewType: DockNativeGlass.viewType,
              creationParams: <String, Object?>{
                'cornerRadius': widget.cornerRadius,
                'style': widget.style.name,
              },
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _onPlatformViewCreated,
            ),
          ),
          if (widget.tintOpacity > 0)
            IgnorePointer(
              child: ColoredBox(
                color: widget.tintColor.withValues(
                  alpha: widget.tintOpacity.clamp(0.0, 1.0),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
