import 'package:flutter/material.dart';

import '../../core/net/network_activity.dart';

class NetworkWaitingView extends StatelessWidget {
  const NetworkWaitingView({super.key, required this.child, this.topInset = 0});
  final Widget child;

  /// 提示条还要额外让出的顶部高度。
  ///
  /// 宿主把内容铺到顶栏之下时（`GlassScaffold(behindBar: true)`，漫画探索页就是），
  /// 这个 Stack 的顶边就是屏幕顶边，`top: 8` 会让提示条落在状态栏那一带——灵动岛
  /// 机型上正好被岛压住（真机截图："正在等待网络"和时间/电量并排，中间是岛）。
  /// 这时宿主把顶栏总高传进来，提示条落到顶栏下沿；已在 `SafeArea` 里避让过顶部
  /// 的宿主传 0（默认），保持原来的位置。
  final double topInset;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(child: child),
      ValueListenableBuilder<Set<String>>(
        valueListenable: NetworkActivity.waiting,
        builder: (context, waiting, _) => waiting.isEmpty
            ? const SizedBox.shrink()
            : Positioned(
                top: topInset + 8,
                left: 16,
                right: 16,
                child: IgnorePointer(
                  child: Center(
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(18),
                      elevation: 2,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Text(
                          '正在等待网络，恢复后继续…',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    ],
  );
}
