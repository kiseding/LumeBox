import 'package:flutter_test/flutter_test.dart';
import 'package:lume_box/shared/widgets/glass_card.dart';

/// 顶栏内容的顶部让位几何。
///
/// 回归背景：真机上「标题栏压进灵动岛」。灵动岛机型的安全区（59–62）本来就
/// 只比岛下沿多出 9–11pt，再统一上移 12pt 正好让进岛里。这里把「哪类机型
/// 可以上移、最多移多少」钉成用例，避免下次调参又调回去。
void main() {
  test('灵动岛机型不上移：内容停在系统安全线', () {
    for (final inset in <double>[59, 62, 68]) {
      expect(trimmedTopInset(inset), inset, reason: 'inset=$inset 不应被缩');
    }
  });

  test('刘海机型保留一档上移，且仍低于状态栏文字', () {
    expect(trimmedTopInset(47), 35);
    expect(trimmedTopInset(44), 32);
    // 状态栏很薄时按剩余空间收，不会把内容压到屏幕顶。
    expect(trimmedTopInset(30), 24);
  });

  test('薄状态栏（无刘海机／安卓）原样返回', () {
    expect(trimmedTopInset(0), 0);
    expect(trimmedTopInset(20), 20);
    expect(trimmedTopInset(24), 24);
  });

  test('任何 inset 都只让一档，且不会越过自身', () {
    for (var inset = 0.0; inset <= 80; inset += 0.5) {
      final trimmed = trimmedTopInset(inset);
      expect(trimmed, lessThanOrEqualTo(inset), reason: 'inset=$inset');
      expect(
        inset - trimmed,
        lessThanOrEqualTo(kLumeTopInsetTrim),
        reason: 'inset=$inset',
      );
    }
  });
}
