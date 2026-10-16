import 'package:flutter/material.dart';

import '../../core/media/media_library.dart';
import 'media_library_page.dart';
import 'media_resource_router.dart';

class MediaResourcePage extends StatelessWidget {
  const MediaResourcePage({super.key, required this.resource});
  final MediaResource resource;
  Future<void> _open(
    BuildContext context,
    MediaResource entry,
    int index,
  ) async {
    try {
      await openMediaResource(context, entry, index: index);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开此条目，请检查类型、源或网络')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MediaLibrary.instance,
    builder: (context, _) {
      final entry = MediaLibrary.instance.byId(resource.id) ?? resource;
      return Scaffold(
        appBar: AppBar(
          title: Text(entry.title),
          actions: [
            IconButton(
              tooltip: '类型与所在库',
              icon: const Icon(Icons.drive_file_move_outline),
              onPressed: () => editMediaPlacement(context, entry),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(
                    entry.kind == ResourceKind.audioBook
                        ? Icons.headphones_rounded
                        : Icons.library_books_outlined,
                    size: 64,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    entry.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${entry.kind.label} · ${entry.destination.label}库 · ${entry.episodes.length} 集',
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: entry.episodes.isEmpty
                        ? null
                        : () => _open(context, entry, 0),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      entry.kind == ResourceKind.novel ? '开始阅读' : '播放',
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: entry.episodes.length,
                itemBuilder: (context, index) => ListTile(
                  title: Text(entry.episodes[index].title),
                  leading: Text('${index + 1}'),
                  onTap: () => _open(context, entry, index),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
