import 'package:flutter/material.dart';

import '../../shared/widgets/glass_card.dart';
import 'comic_download_center.dart';

class DownloadCenterPage extends StatefulWidget {
  const DownloadCenterPage({super.key, this.center});
  final ComicDownloadCenter? center;
  @override
  State<DownloadCenterPage> createState() => _DownloadCenterPageState();
}

class _DownloadCenterPageState extends State<DownloadCenterPage> {
  late final center = widget.center ?? ComicDownloadCenter.instance;
  @override
  void initState() {
    super.initState();
    center.boot();
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '下载中心',
    child: ListenableBuilder(
      listenable: center,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('退出详情页后任务继续；重开 App 后可继续未完成任务。系统挂起期间可能暂停网络传输。'),
          if (center.storageError != null) Text(center.storageError!),
          if (!center.tasks.any((t) => t.indices.isNotEmpty))
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('暂无下载任务，请在漫画详情页添加'),
            ),
          for (final task in center.tasks.reversed.where(
            (t) => t.indices.isNotEmpty,
          ))
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${switch (task.state) {
                        'running' => '下载中',
                        'done' => '已完成',
                        'failed' => '有失败，可重试',
                        _ => '已暂停',
                      }} · ${task.running ? task.downloader?.progress.chapterDone ?? 0 : task.completed}/${task.indices.length} 章',
                    ),
                    if (task.running)
                      LinearProgressIndicator(
                        value: task.downloader?.progress.fraction,
                      ),
                    if (task.error != null) Text(task.error!),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (task.running)
                          TextButton(
                            onPressed: () => center.pause(task),
                            child: const Text('暂停'),
                          )
                        else
                          TextButton(
                            onPressed: task.downloader?.progress.running == true
                                ? null
                                : () => center.resume(task),
                            child: Text(task.state == 'done' ? '检查补下' : '继续'),
                          ),
                        if (task.state == 'failed')
                          TextButton(
                            onPressed: () =>
                                center.resume(task, failedOnly: true),
                            child: const Text('重试失败章节'),
                          ),
                        if (!task.running)
                          TextButton(
                            onPressed: task.downloader?.progress.running == true
                                ? null
                                : () => center.remove(task),
                            child: const Text('移除任务'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
