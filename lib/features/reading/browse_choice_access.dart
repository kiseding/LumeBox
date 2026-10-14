import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/source/source.dart';
import '../../core/theme/lume_theme.dart';

/// Long horizontal choices keep a fixed, searchable access point.
class BrowseChoiceAccess extends StatelessWidget {
  const BrowseChoiceAccess({
    super.key,
    required this.child,
    required this.choices,
    required this.onSelected,
    this.selectedId,
    this.title = '分类',
    this.includeAll = true,
  });
  final Widget child;
  final List<SourceCategory> choices;
  final String? selectedId;
  final String title;
  final bool includeAll;
  final ValueChanged<String?> onSelected;

  Future<void> _open(BuildContext context) async {
    final value = await showModalBottomSheet<_Choice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ChoiceSheet(
        choices: choices,
        selectedId: selectedId,
        title: title,
        includeAll: includeAll,
      ),
    );
    if (value != null) onSelected(value.id);
  }

  @override
  Widget build(BuildContext context) {
    if (choices.length <= 8) return child;
    final selected = choices.where((item) => item.id == selectedId).firstOrNull;
    return Row(
      children: [
        Expanded(child: child),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 112),
          child: Tooltip(
            message: '展开全部$title',
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: LumeTheme.accent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(60, 34),
              ),
              onPressed: () => _open(context),
              icon: const Icon(Icons.expand_more, size: 18),
              iconAlignment: IconAlignment.end,
              label: Text(
                selected?.title ?? '全部$title',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Choice {
  const _Choice(this.id);
  final String? id;
}

class _ChoiceSheet extends StatefulWidget {
  const _ChoiceSheet({
    required this.choices,
    required this.selectedId,
    required this.title,
    required this.includeAll,
  });
  final List<SourceCategory> choices;
  final String? selectedId;
  final String title;
  final bool includeAll;
  @override
  State<_ChoiceSheet> createState() => _ChoiceSheetState();
}

class _ChoiceSheetState extends State<_ChoiceSheet> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final options = [
      if (widget.includeAll) const SourceCategory(id: '', title: '全部'),
      ...widget.choices.where(
        (item) => !widget.includeAll || item.title != '全部',
      ),
    ];
    final shown = options
        .where(
          (item) =>
              item.title.toLowerCase().contains(query.trim().toLowerCase()),
        )
        .toList();
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: math.min(580, media.size.height * .72),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '全部${widget.title}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (value) => setState(() => query = value),
                decoration: InputDecoration(
                  hintText: '搜索${widget.title}',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('没有匹配的选项'))
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: shown.length,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 170,
                            mainAxisExtent: 48,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                      itemBuilder: (_, index) {
                        final option = shown[index];
                        final all =
                            widget.includeAll &&
                            index == 0 &&
                            option.id.isEmpty &&
                            option.title == '全部';
                        final selected = all
                            ? widget.selectedId == null
                            : option.id == widget.selectedId;
                        return TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: selected
                                ? LumeTheme.accent
                                : LumeTheme.textPrimary,
                            backgroundColor: selected
                                ? LumeTheme.accent.withValues(alpha: .15)
                                : LumeTheme.accent.withValues(alpha: .04),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => Navigator.pop(
                            context,
                            _Choice(all ? null : option.id),
                          ),
                          child: Text(
                            option.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
