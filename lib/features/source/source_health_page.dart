import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session/section.dart';
import '../../core/source/source.dart';
import '../../core/source/source_health.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/lume_icon.dart';

class SourceHealthPage extends StatefulWidget {
  const SourceHealthPage({
    super.key,
    required this.section,
    required this.manager,
    required this.source,
  });
  final Section section;
  final SourceManager manager;
  final SourceDescriptor source;
  @override
  State<SourceHealthPage> createState() => _SourceHealthPageState();
}

class _SourceHealthPageState extends State<SourceHealthPage> {
  SourceHealthCheck? _check;
  List<SourceHealthStep> _steps = [];
  bool _running = true;
  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _check?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    _check?.cancel();
    late final SourceHealthCheck check;
    check = SourceHealthCheck(
      manager: widget.manager,
      section: widget.section,
      descriptor: widget.source,
      onChanged: (steps) {
        if (mounted && identical(_check, check)) setState(() => _steps = steps);
      },
    );
    setState(() {
      _check = check;
      _steps = [];
      _running = true;
    });
    await check.run();
    if (mounted && identical(_check, check)) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    title: '源体检',
    effectModule: GlassModule.sources,
    behindBar: true,
    actions: [
      TextButton(
        onPressed: _running ? () => _check?.cancel() : _run,
        child: Text(_running ? '停止' : '重新体检'),
      ),
    ],
    child: ListView(
      padding: GlassScaffold.barInset(context).add(const EdgeInsets.all(16)),
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.source.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(_running ? '正在逐项检查…' : '检查结束，请查看每项结果。'),
              const SizedBox(height: 8),
              const Text('检查实际接口和少量图片数据，不会起播视频或下载整本内容。退出页面会停止本次体检。'),
            ],
          ),
        ),
        for (final step in _steps)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: GlassCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (step.running)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    LumeIcon(
                      step.issue == SourceHealthIssue.none
                          ? Icons.check_circle_outline
                          : Icons.info_outline,
                      slot: 'source_health.result',
                      color: step.issue == SourceHealthIssue.none
                          ? Colors.green
                          : Theme.of(context).colorScheme.error,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        if (step.issue != SourceHealthIssue.none)
                          Text(
                            step.issue.label,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        Text(step.message),
                        if (step.issue.suggestion.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(step.issue.suggestion),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
