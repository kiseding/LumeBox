import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/translation/text_translation.dart';

class SourceText extends StatelessWidget {
  const SourceText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: TextTranslationService.shared,
    builder: (context, _) {
      final service = TextTranslationService.shared;
      return Text(
        service.displayOriginal ? text : service.lookup(text) ?? text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    },
  );
}

/// User starts the system translation sheet explicitly. Browsing never opens it.
class SourceTranslationAction extends StatefulWidget {
  const SourceTranslationAction({super.key, required this.texts});
  final List<String> texts;
  @override
  State<SourceTranslationAction> createState() =>
      _SourceTranslationActionState();
}

class _SourceTranslationActionState extends State<SourceTranslationAction> {
  bool busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(TextTranslationService.shared.boot());
  }

  Future<void> translate() async {
    final service = TextTranslationService.shared;
    final texts = widget.texts
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList();
    if (texts.isEmpty) return;
    if (texts.every((s) => service.lookup(s) != null)) {
      service.toggleOriginal();
      return;
    }
    setState(() => busy = true);
    try {
      // Bound long feeds in both count and characters, as with reader OCR.
      var start = 0;
      while (start < texts.length && mounted) {
        var end = start, size = 0;
        while (end < texts.length &&
            end - start < 100 &&
            size + texts[end].runes.length <= 40000) {
          size += texts[end].runes.length;
          end++;
        }
        if (end == start) throw const FormatException('文字过长，请分段翻译');
        await service.translate(texts.sublist(start, end));
        start = end;
      }
      if (service.displayOriginal) service.toggleOriginal();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is MissingPluginException
                  ? '设备端翻译需要 iOS 18 或以上'
                  : error is FormatException
                  ? error.message
                  : error is PlatformException
                  ? error.message ?? '翻译失败，原文保留'
                  : '翻译未完成，原文保留；请检查系统语言包',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: TextTranslationService.shared,
    builder: (context, _) {
      final service = TextTranslationService.shared;
      final cached = widget.texts
          .where((s) => s.trim().isNotEmpty)
          .every((s) => service.lookup(s) != null);
      return TextButton.icon(
        onPressed: busy ? null : translate,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.translate, size: 18),
        label: Text(
          busy
              ? '正在翻译…'
              : cached && !service.displayOriginal
              ? '显示原文'
              : '翻译成中文',
        ),
      );
    },
  );
}
