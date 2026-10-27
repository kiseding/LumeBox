import '../../core/reading/comic_image_tools_settings.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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

  bool attempted = false;
  String? attemptedProfile;
  int processed = 0;
  List<String> get texts =>
      widget.texts.where((s) => s.trim().isNotEmpty).toSet().toList();
  String get profile {
    final settings = ComicImageToolsSettings.instance;
    return '${settings.source}|${settings.target}|${settings.translationMode}|${settings.endpoint}|${settings.model}';
  }

  @override
  void didUpdateWidget(covariant SourceTranslationAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.texts, widget.texts)) attempted = false;
  }

  String errorText(Object error) => error is MissingPluginException
      ? '设备端翻译需要 iOS 18 或以上'
      : error is FormatException
      ? error.message.toString()
      : error is PlatformException
      ? error.message ?? '翻译失败，原文保留'
      : '翻译未完成，原文保留；请检查全局翻译设置与网络';

  Future<void> translate({bool retryOnly = false}) async {
    if (busy) return;
    final service = TextTranslationService.shared;
    final all = texts;
    final selectedProfile = profile;
    if (all.isEmpty) {
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('当前没有可翻译的内容，请等待加载完成')));
      return;
    }
    if (!retryOnly && all.every((s) => service.lookup(s) != null)) {
      service.toggleOriginal();
      return;
    }
    await service.boot();
    if (!mounted) return;
    if (!retryOnly && all.every((s) => service.lookup(s) != null)) {
      service.toggleOriginal();
      return;
    }
    final pending = all.where((s) => service.lookup(s) == null).toList();
    setState(() {
      busy = true;
      attempted = true;
      attemptedProfile = selectedProfile;
      processed = all.length - pending.length;
    });
    Object? failure;
    try {
      var start = 0;
      while (start < pending.length &&
          mounted &&
          selectedProfile == profile &&
          listEquals(all, texts)) {
        var end = start, size = 0;
        while (end < pending.length &&
            end - start < 100 &&
            size + pending[end].runes.length <= 40000) {
          size += pending[end].runes.length;
          end++;
        }
        if (end == start) throw const FormatException('文字过长，请分段翻译');
        try {
          await service.translate(pending.sublist(start, end));
        } catch (error) {
          failure = error;
          // A failed language must not prevent the remaining page from translating.
          if (error is! PlatformException ||
              error.code != 'translation_partial') {
            break;
          }
        }
        start = end;
        if (mounted) {
          setState(
            () =>
                processed = all.where((s) => service.lookup(s) != null).length,
          );
        }
      }
    } catch (error) {
      failure = error;
    } finally {
      if (mounted) setState(() => busy = false);
      if (mounted && selectedProfile == profile && listEquals(all, texts)) {
        final complete = all.where((s) => service.lookup(s) != null).length;
        final translated = all
            .where((s) => service.lookup(s) != null && service.lookup(s) != s)
            .length;
        final remaining = all.length - complete;
        if (service.displayOriginal && complete > 0) service.toggleOriginal();
        final summary = '已翻译 $translated 条，未完成 $remaining 条';
        ScaffoldMessenger.of(context)
          ..removeCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 10),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary,
                    key: const ValueKey('source-translation-result'),
                  ),
                  if (complete > translated)
                    Text('原文保留 ${complete - translated} 条'),
                  if (failure != null) Text(errorText(failure)),
                ],
              ),
              action: remaining == 0
                  ? null
                  : SnackBarAction(
                      label: '重试未完成',
                      onPressed: () {
                        if (mounted) unawaited(translate(retryOnly: true));
                      },
                    ),
            ),
          );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: TextTranslationService.shared,
    builder: (context, _) {
      final service = TextTranslationService.shared;
      final cached =
          widget.texts.any((s) => s.trim().isNotEmpty) &&
          widget.texts
              .where((s) => s.trim().isNotEmpty)
              .every((s) => service.lookup(s) != null);
      return IconButton(
        tooltip: busy
            ? '正在翻译… 已完成 $processed/${texts.length}'
            : cached && !service.displayOriginal
            ? '显示原文'
            : ComicImageToolsSettings.instance.target == 'zh-Hans'
            ? '翻译成中文'
            : '翻译成${ComicImageToolsSettings.languages[ComicImageToolsSettings.instance.target]}',
        constraints: const BoxConstraints.tightFor(width: 40, height: 44),
        onPressed: busy ? null : () => translate(),
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Badge(
                isLabelVisible:
                    attempted &&
                    attemptedProfile == profile &&
                    texts.any((s) => service.lookup(s) == null),
                label: Text(
                  '${texts.where((s) => service.lookup(s) == null).length}',
                ),
                child: const Icon(Icons.translate, size: 18),
              ),
      );
    },
  );
}
