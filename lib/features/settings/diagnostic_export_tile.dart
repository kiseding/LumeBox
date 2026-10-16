import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'diagnostic_exporter.dart';

class DiagnosticExportTile extends StatefulWidget {
  const DiagnosticExportTile({super.key, this.collect, this.save});
  final Future<DiagnosticBundle> Function()? collect;
  final Future<bool> Function(DiagnosticBundle bundle)? save;
  @override
  State<DiagnosticExportTile> createState() => _DiagnosticExportTileState();
}

class _DiagnosticExportTileState extends State<DiagnosticExportTile> {
  bool busy = false;
  String? status;
  Future<void> export() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final bundle =
          await (widget.collect?.call() ?? DiagnosticExporter().collect());
      bool saved;
      if (widget.save != null) {
        saved = await widget.save!(bundle);
      } else if (Platform.isIOS || Platform.isAndroid) {
        saved =
            await const MethodChannel('lumebox/configuration')
                .invokeMethod<bool>('export', {
                  'bytes': bundle.bytes,
                  'name': bundle.name,
                  'mime': 'application/zip',
                }) ??
            false;
      } else {
        final location = await getSaveLocation(
          suggestedName: bundle.name,
          acceptedTypeGroups: const [
            XTypeGroup(label: '诊断包', extensions: ['zip']),
          ],
        );
        saved = location != null;
        if (location != null) {
          await XFile.fromData(
            bundle.bytes,
            mimeType: 'application/zip',
            name: bundle.name,
          ).saveTo(location.path);
        }
      }
      if (mounted) {
        setState(() => status = saved ? '诊断包已导出，可将 ZIP 文件发来排查' : '已取消导出');
      }
    } catch (_) {
      if (mounted) setState(() => status = '诊断包导出失败，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.inventory_2_outlined),
      title: const Text('一键导出诊断包'),
      subtitle: Text(status ?? '版本、系统、源状态和近期日志；过滤敏感信息'),
      trailing: const Icon(Icons.file_upload_outlined),
      onTap: busy ? null : export,
    ),
  );
}
