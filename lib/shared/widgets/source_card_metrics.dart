import 'package:flutter/widgets.dart';

/// 源选择列表里四个板块（小说 / 漫画 / 视频 / 猫源）共用的卡片度量。
///
/// 这里刻意只放**跨板块必须一致**的数值：高度、圆角、描边与图标尺寸。
/// 各板块自己的内容结构（图标 / 标题 / 版本 / 标签 / 三点、猫源的居中文字）
/// 仍然由各自组件决定。
abstract final class SourceCardMetrics {
  /// 卡片高度：四个板块固定 51，不再按列数或板块分叉。
  static const double height = 51;

  /// 卡片圆角。
  static const double radius = 10;

  /// 左侧图标（普通源）的边长；51 高下仍留出上下呼吸空间。
  static const double iconSize = 32;

  /// 未选中态描边：浅灰 #E5E5EA。
  static const Color unselectedBorder = Color(0xFFE5E5EA);

  static const BorderRadius borderRadius = BorderRadius.all(
    Radius.circular(radius),
  );

  /// 紧凑卡片的轻阴影：比全局 [LumeTheme.cardShadow] 更淡、更短，
  /// 避免阴影比 1px 描边更深，把线框感吃掉。
  static const List<BoxShadow> shadow = <BoxShadow>[
    BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2)),
  ];
}
