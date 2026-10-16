import 'package:flutter/material.dart';

import '../../core/reading/chapter_display_order.dart';

class ChapterAutoOrderSwitch extends StatefulWidget {
  const ChapterAutoOrderSwitch({
    super.key,
    required this.order,
    this.onChanged,
  });
  final ChapterDisplayOrder order;
  final VoidCallback? onChanged;
  @override
  State<ChapterAutoOrderSwitch> createState() => _AutoState();
}

class _AutoState extends State<ChapterAutoOrderSwitch> {
  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    title: const Text('章节自动修正排序'),
    subtitle: const Text('按章节号展示；关闭后恢复手动正序 / 倒序，不改源数据'),
    value: widget.order.automatic,
    onChanged: (v) {
      setState(() => widget.order.automatic = v);
      widget.onChanged?.call();
    },
  );
}

/// Added only to reader chapter panels. Existing detail/catalog controls stay.
class ChapterManualOrderDropdown extends StatelessWidget {
  const ChapterManualOrderDropdown({
    super.key,
    required this.order,
    required this.onChanged,
  });
  final ChapterDisplayOrder order;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => DropdownButton<bool>(
    key: const ValueKey('reader-chapter-manual-order'),
    value: order.descending,
    items: const [
      DropdownMenuItem(value: false, child: Text('正序')),
      DropdownMenuItem(value: true, child: Text('倒序')),
    ],
    onChanged: (v) {
      if (v != null) {
        order.descending = v;
        onChanged();
      }
    },
  );
}
