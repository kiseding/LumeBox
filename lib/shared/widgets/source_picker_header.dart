import 'package:flutter/material.dart';

import 'lume_icon.dart';

class SourcePickerHeader extends StatelessWidget {
  const SourcePickerHeader({
    super.key,
    required this.title,
    required this.onManage,
    required this.addAction,
    required this.onQueryChanged,
    this.extraActions = const [],
  });

  final String title;
  final VoidCallback onManage;
  final Widget addAction;
  final ValueChanged<String> onQueryChanged;
  final List<Widget> extraActions;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ...extraActions,
            IconButton(
              tooltip: '源管理',
              onPressed: onManage,
              icon: const LumeIcon(Icons.tune, slot: 'source_picker.manage'),
            ),
            addAction,
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.pop(context),
              icon: const LumeIcon(Icons.close, slot: 'source_picker.close'),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: TextField(
          onChanged: onQueryChanged,
          decoration: const InputDecoration(
            hintText: '搜索源名称或订阅包',
            prefixIcon: LumeIcon(Icons.search, slot: 'source_picker.search'),
          ),
        ),
      ),
    ],
  );
}
