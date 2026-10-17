import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';

/// 猫源专用极简卡片：没有左侧图标、没有右侧菜单，文字单行居中。
///
/// 双列默认 64 高、单列 56 高：高度只由调用方按列数传入，长名字（例如
/// 「日期:20261017」）只允许省略号，不允许折行把卡片撑高。左右各留 16 的
/// 内边距，给省略号一点落点；上下由 [Center] 保持等距呼吸空间。
///
/// 1px 浅灰描边让纯白卡片从浅色抽屉背景中浮起来；选中态把描边换成淡紫，
/// 同时铺一层极浅的主题色。其它板块的源列表不受这里的尺寸影响。
class CatSiteTile extends StatelessWidget {
  const CatSiteTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.busy = false,
    this.height = defaultHeight,
  });

  /// 未显式指定时的卡片高度（双列 / 通用来源列表）。
  static const double defaultHeight = 60;

  /// 单列列表更紧凑；双列保持 64 以得到接近 2.2 的宽高比。
  final double height;

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// 源操作进行中：中间显示一个小转圈，仍然保持同样的高度与居中。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = dark ? LumeTheme.surfaceAlt : LumeTheme.surface;
    final radius = BorderRadius.circular(8);
    final borderColor = selected
        ? LumeTheme.accent.withValues(alpha: .55)
        : dark
        ? Colors.white.withValues(alpha: .16)
        : const Color(0xFFE5E5EA);
    final shape = RoundedRectangleBorder(
      borderRadius: radius,
      side: BorderSide(color: borderColor, width: 1),
    );
    return SizedBox(
      height: height,
      child: Material(
        color: selected
            ? Color.alphaBlend(
                LumeTheme.accent.withValues(alpha: .08),
                cardColor,
              )
            : cardColor,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Row(
                      children: <Widget>[
                        // Expanded + maxLines 1 + ellipsis：双列再窄也只显示一行，
                        // 绝不换行。textAlign.center 让文字在整行宽度里水平居中。
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: LumeTheme.textPrimary,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
