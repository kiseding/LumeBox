import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lume_box/core/theme/lume_theme.dart';

/// 底层主题的可见性约束：输入框、胶囊、卡片在白色与浅灰底上都必须有边界。
void main() {
  tearDown(() => LumeTheme.applyBrightness(Brightness.light));

  for (final brightness in Brightness.values) {
    test('$brightness：输入框 / 胶囊 / 卡片都有可见边界与文字色', () {
      final theme = LumeTheme.build(brightness: brightness);
      final input = theme.inputDecorationTheme;

      expect(input.filled, isTrue);
      expect(input.fillColor, LumeTheme.surfaceAlt);
      expect(input.hintStyle?.color, LumeTheme.textSecondary);
      expect(
        input.contentPadding,
        const EdgeInsets.fromLTRB(12, 12, 12, 12),
        reason: '文字左侧/上方至少留 12px',
      );

      final enabled = input.enabledBorder! as OutlineInputBorder;
      expect(enabled.borderSide.color, LumeTheme.inputBorder);
      expect(enabled.borderSide.width, 1);
      final focused = input.focusedBorder! as OutlineInputBorder;
      expect(focused.borderSide.color, LumeTheme.accent);
      expect(focused.borderSide.width, greaterThan(1));

      final chipLabel = WidgetStateProperty.resolveAs<TextStyle>(
        theme.chipTheme.labelStyle!,
        const <WidgetState>{},
      );
      expect(chipLabel.color, isNotNull);
      expect(chipLabel.color, isNot(Colors.transparent));
      expect(theme.chipTheme.side?.color, LumeTheme.inputBorder);

      expect(theme.cardTheme.elevation, greaterThan(0));
      final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
      expect(cardShape.side.color, LumeTheme.inputBorder);
      expect(cardShape.side.width, 1);
    });
  }
}
