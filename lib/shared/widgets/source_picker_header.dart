import 'package:flutter/material.dart';

import 'lume_icon.dart';

class SourcePickerHeader extends StatefulWidget {
  const SourcePickerHeader({
    super.key,
    required this.title,
    required this.onManage,
    required this.addAction,
    required this.onQueryChanged,
    this.onSync,
    this.extraActions = const [],
  });

  final String title;
  final VoidCallback onManage;
  final Widget addAction;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback? onSync;
  final List<Widget> extraActions;

  @override
  State<SourcePickerHeader> createState() => _SourcePickerHeaderState();
}

class _SourcePickerHeaderState extends State<SourcePickerHeader> {
  final _query = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (!_searching) {
      _query.clear();
      widget.onQueryChanged('');
      FocusScope.of(context).unfocus();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ...widget.extraActions,
            IconButton(
              tooltip: '源管理',
              onPressed: widget.onManage,
              icon: const LumeIcon(Icons.tune, slot: 'source_picker.manage'),
            ),
            widget.addAction,
            IconButton(
              tooltip: '搜索源',
              onPressed: _toggleSearch,
              isSelected: _searching,
              icon: const LumeIcon(Icons.search, slot: 'source_picker.search'),
            ),
          ],
        ),
      ),
      if (_searching)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: TextField(
            controller: _query,
            autofocus: true,
            onChanged: widget.onQueryChanged,
            decoration: InputDecoration(
              hintText: '搜索源名称或订阅包',
              prefixIcon: const LumeIcon(
                Icons.search,
                slot: 'source_picker.search',
              ),
              suffixIcon: widget.onSync == null
                  ? null
                  : IconButton(
                      tooltip: '同步本板块订阅',
                      icon: const Icon(Icons.sync),
                      onPressed: widget.onSync,
                    ),
            ),
          ),
        ),
      if (!_searching) const SizedBox(height: 2),
    ],
  );
}
