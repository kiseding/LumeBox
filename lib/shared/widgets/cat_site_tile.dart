import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';

/// 猫源专用极简卡片：没有左侧图标、没有右侧菜单，文字单行居中。
///
/// 高度**写死 64**：双列时两列等宽，长名字（例如「日期:20261017」）只允许
/// 省略号，不允许折行把卡片撑高。左右各留 16 的内边距，给省略号一点落点。
///
/// 这是猫源独立的外观逻辑，不经过通用 `ListTile` / `ColumnList` 的默认配置，
/// 因此其它板块的源列表不会被这里的尺寸与对齐方式影响。
class CatSiteTile extends StatelessWidget {
  const CatSiteTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.busy = false,
  });

  /// 固定高度：所有猫源行（单列 / 双列）都用这一档。
  static const double height = 64;

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// 源操作进行中：中间显示一个小转圈，仍然保持同样的高度与居中。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = dark ? LumeTheme.surfaceAlt : const Color(0xFFF7F8FA);
    final radius = BorderRadius.circular(8);
    return SizedBox(
      height: height,
      child: Material(
        color: selected
            ? Color.alphaBlend(
                LumeTheme.accent.withValues(alpha: .08),
                cardColor,
              )
            : cardColor,
        borderRadius: radius,
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
