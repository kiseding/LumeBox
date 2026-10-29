import '../../shared/widgets/native_glass_controls.dart';
import '../../shared/widgets/native_glass_surfaces.dart';

import 'package:lume_box/shared/widgets/lume_icon.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/tmdb/tmdb.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

class TmdbSettingsPage extends StatefulWidget {
  const TmdbSettingsPage({super.key});
  @override
  State<TmdbSettingsPage> createState() => _TmdbSettingsPageState();
}

class _TmdbSettingsPageState extends State<TmdbSettingsPage> {
  final settings = TmdbSettings.instance;
  late final keyText = TextEditingController(text: settings.apiKey);
  late final api = TextEditingController(text: settings.apiProxy);
  late final image = TextEditingController(text: settings.imageProxy);
  bool testing = false;
  void save() {
    settings.apiKey = keyText.text;
    settings.apiProxy = api.text;
    settings.imageProxy = image.text;
    settings.save();
  }

  @override
  void dispose() {
    keyText.dispose();
    api.dispose();
    image.dispose();
    super.dispose();
  }

  Future<void> test(bool isApi) async {
    save();
    setState(() => testing = true);
    final client = TmdbClient(settings);
    var message = '测试成功';
    try {
      if (isApi) {
        await client.testApi();
      } else {
        final bytes = await client.testImage();
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
        final frame = await codec.getNextFrame();
        frame.image.dispose();
        codec.dispose();
      }
    } catch (error) {
      message = error is StateError
          ? '测试失败：${error.message}'
          : '测试失败：请检查启用状态、Key、代理地址和网络连接。';
    } finally {
      client.dispose();
      if (mounted) setState(() => testing = false);
    }
    if (mounted) {
      await showGlassDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(isApi ? '测试 API 代理' : '测试 图片代理'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> disconnect() async {
    final yes = await showGlassDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('清除本机保存的 API Key 和两个代理地址，并关闭 TMDB？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await settings.disconnect();
    keyText.clear();
    api.clear();
    image.clear();
  }

  Widget appearanceSlider(String label, String field, double min, double max) {
    final value = settings.detailAppearance.value.toJson()[field]!;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                key: ValueKey('tmdb-appearance-$field'),
                value: value,
                min: min,
                max: max,
                label: '${(value * 100).round()}%',
                onChanged: (next) => settings.detailAppearance.value = settings
                    .detailAppearance
                    .value
                    .withValue(field, next),
                onChangeEnd: (_) => settings.save(appearanceOnly: true),
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget appearanceSection() => ExpansionTile(
    key: const Key('tmdb-appearance-section'),
    tilePadding: EdgeInsets.zero,
    childrenPadding: EdgeInsets.zero,
    title: const Text('详情页外观调节', style: TextStyle(fontSize: 14)),
    subtitle: const Text('背景 · 海报 · 渐变 · 标识', style: TextStyle(fontSize: 11)),
    children: [
      appearanceSlider('背景亮度', 'backgroundBrightness', .3, 2.5),
      appearanceSlider('背景色彩', 'backgroundSaturation', 0, 3),
      appearanceSlider('沉浸海报亮度', 'posterBrightness', .2, 1.8),
      appearanceSlider('沉浸渐变强度', 'fadeStrength', 0, 3),
      appearanceSlider('TMDB标识大小', 'logoScale', .5, 2.5),
      Row(
        children: [
          const Expanded(
            child: Text('实时生效 · 松手自动保存', style: TextStyle(fontSize: 11)),
          ),
          TextButton(
            key: const Key('tmdb-appearance-reset'),
            onPressed: () {
              settings.detailAppearance.value = const TmdbDetailAppearance();
              settings.save(appearanceOnly: true);
            },
            child: const Text('恢复默认', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: 'TMDB配置',
    child: ListenableBuilder(
      listenable: Listenable.merge([settings, settings.detailAppearance]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          NativeSwitchListTile.adaptive(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('启用 TMDB', style: TextStyle(fontSize: 14)),
            value: settings.enabled,
            onChanged: (value) {
              settings.enabled = value;
              save();
            },
          ),
          NativeSwitchListTile.adaptive(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('详情页海报背景', style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              '随海报取色；关闭后使用纯色背景',
              style: TextStyle(fontSize: 11),
            ),
            value: settings.detailBackdropEnabled,
            onChanged: (value) {
              settings.detailBackdropEnabled = value;
              save();
            },
          ),
          appearanceSection(),
          const SizedBox(height: 8),
          const Text('海报展示样式'),
          const SizedBox(height: 10),
          SegmentedButton<TmdbPosterStyle>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: TmdbPosterStyle.fixed, label: Text('固定')),
              ButtonSegment(value: TmdbPosterStyle.random, label: Text('随机')),
              ButtonSegment(value: TmdbPosterStyle.carousel, label: Text('轮播')),
            ],
            selected: {settings.posterStyle},
            onSelectionChanged: (values) {
              settings.posterStyle = values.first;
              save();
            },
          ),
          const SizedBox(height: 12),
          Text('图片', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 340 ? 2 : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 10) / columns;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final kind in TmdbImageKind.values)
                    SizedBox(
                      width: width,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('tmdb-image-${kind.name}'),
                        initialValue: settings.imageSize(kind),
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: kind.label,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                        ),
                        items: [
                          for (final size in kind.sizes)
                            DropdownMenuItem(
                              value: size,
                              child: Text(
                                size,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          settings.setImageSize(kind, value);
                          save();
                        },
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          const Text('仅影响下载清晰度，不改变页面尺寸。', style: TextStyle(fontSize: 11)),
          const SizedBox(height: 12),
          TextField(
            controller: keyText,
            maxLines: 1,
            autocorrect: false,
            onChanged: (_) => save(),
            decoration: InputDecoration(
              isDense: true,
              labelText: 'API Key',
              hintText: '留空使用内置密钥',
              helperText: '已内置默认密钥；可填写自己的 v3 Key 或 v4 Token',
              suffixIcon: IconButton(
                tooltip: '清除 API Key',
                icon: const LumeIcon(
                  Icons.cancel,
                  slot: 'tmdb_settings_page.1',
                ),
                onPressed: () {
                  keyText.clear();
                  save();
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: api,
            maxLines: 1,
            onChanged: (_) => save(),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'API代理地址',
              hintText: '例如 shturl.cc/yyIaR0vTjCGrkbxM，留空使用官方地址',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: image,
            maxLines: 1,
            onChanged: (_) => save(),
            decoration: const InputDecoration(
              isDense: true,
              labelText: '图片代理地址',
              hintText: '例如 https://image.tmdb.org/t/p/，留空使用官方图片地址',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: testing || !settings.configured
                      ? null
                      : () => test(true),
                  child: const Text('测试 API 代理'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: testing || !settings.enabled
                      ? null
                      : () => test(false),
                  child: const Text('测试 图片代理'),
                ),
              ),
            ],
          ),
          if (testing) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          const SettingsFooterNote(
            '配置仅保存在本机。请求时使用所配置的 TMDB／代理服务；不会上传至项目服务器。关闭 TMDB 后不发起请求。',
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: testing ? null : disconnect,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('断开连接'),
          ),
        ],
      ),
    ),
  );
}
