import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/speech/speech_cloud.dart';
import '../../core/speech/speech_local.dart';
import '../../core/speech/speech_settings.dart';

class NovelSpeechModes extends StatefulWidget {
  const NovelSpeechModes({
    super.key,
    required this.settings,
    required this.onChanged,
    this.selectorOnly = false,
    this.optionsOnly = false,
  });
  final bool selectorOnly, optionsOnly;
  final SpeechSettings settings;
  final ValueChanged<SpeechSettings> onChanged;
  @override
  State<NovelSpeechModes> createState() => _NovelSpeechModesState();
}

class _NovelSpeechModesState extends State<NovelSpeechModes> {
  final model = SpeechLocalModel.instance;
  @override
  void initState() {
    super.initState();
    // Tests/unsupported devices may have no platform path provider.
    if (!widget.optionsOnly) unawaited(model.check().catchError((_) => false));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Column(
      children: [
        if (!widget.optionsOnly)
          DropdownButtonFormField<SpeechMode>(
            key: ValueKey(widget.settings.mode),
            initialValue: widget.settings.mode,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '听书模式'),
            items: [
              for (final mode in SpeechMode.values)
                DropdownMenuItem(
                  value: mode,
                  enabled: mode != SpeechMode.local || model.ready,
                  child: Text(
                    '${mode.label}${mode == SpeechMode.local && !model.ready ? '（模型未就绪）' : ''}',
                    overflow: TextOverflow.ellipsis,
                    style: mode == SpeechMode.local && !model.ready
                        ? TextStyle(color: Theme.of(context).disabledColor)
                        : null,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                widget.onChanged(widget.settings.copyWith(mode: value));
              }
            },
          ),
        if (!widget.selectorOnly) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('自动识别对话并切换音色'),
            subtitle: const Text('关闭后全程使用旁白音色'),
            value: widget.settings.autoDialogue,
            onChanged: (value) =>
                widget.onChanged(widget.settings.copyWith(autoDialogue: value)),
          ),
          if (!model.ready)
            TextButton.icon(
              onPressed: model.preparing ? null : model.prepare,
              icon: model.preparing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_for_offline_outlined),
              label: Text(
                model.preparing ? '正在准备内置音色包…' : '准备内置离线音色包（约147 MB）',
              ),
            ),
          if (model.error != null)
            Text(
              model.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          for (final role in ['旁白', '男声', '女声'])
            if (role == '旁白' || widget.settings.autoDialogue)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('$role音色'),
                subtitle: Text(_voice(role).isEmpty ? '系统默认' : _voice(role)),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editVoice(role),
              ),
          if (widget.settings.mode == SpeechMode.cloud ||
              widget.settings.mode == SpeechMode.cloudAi)
            TextButton.icon(
              icon: const Icon(Icons.settings_ethernet),
              label: const Text('配置在线接口与密钥'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _CloudSettingsDialog(),
              ),
            ),
        ],
      ],
    ),
  );
  String _voice(String role) => role == '旁白'
      ? widget.settings.narratorVoice
      : role == '男声'
      ? widget.settings.maleVoice
      : widget.settings.femaleVoice;
  Future<void> _editVoice(String role) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _SpeechVoiceDialog(
        role: role,
        mode: widget.settings.mode,
        value: _voice(role),
      ),
    );
    if (value == null || !mounted) return;
    if (widget.settings.mode == SpeechMode.local &&
        (int.tryParse(value) == null ||
            int.parse(value) < 0 ||
            int.parse(value) > 173)) {
      return;
    }
    widget.onChanged(
      widget.settings.copyWith(
        narratorVoice: role == '旁白' ? value : null,
        maleVoice: role == '男声' ? value : null,
        femaleVoice: role == '女声' ? value : null,
      ),
    );
  }
}

class _CloudSettingsDialog extends StatefulWidget {
  const _CloudSettingsDialog();
  @override
  State<_CloudSettingsDialog> createState() => _CloudSettingsDialogState();
}

class _CloudSettingsDialogState extends State<_CloudSettingsDialog> {
  final config = SpeechCloudConfig.instance;
  final fields = List.generate(6, (_) => TextEditingController());
  bool loaded = false, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await config.load();
      final keys = await Future.wait([config.key('tts'), config.key('llm')]);
      if (!mounted) return;
      final values = [
        config.ttsUrl,
        config.ttsModel,
        keys[0],
        config.llmUrl,
        config.llmModel,
        keys[1],
      ];
      for (var i = 0; i < fields.length; i++) {
        fields[i].text = values[i];
      }
      setState(() => loaded = true);
    } catch (_) {
      if (mounted) setState(() => error = '无法读取本机接口配置');
    }
  }

  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      for (final index in [0, 3]) {
        if (fields[index].text.trim().isNotEmpty) {
          SpeechCloudConfig.endpoint(
            fields[index].text,
            index == 0 ? '/audio/speech' : '/chat/completions',
          );
        }
      }
      await config.setKey(
        'tts',
        fields[2].text.trim(),
        forEndpoint: fields[0].text.trim(),
      );
      await config.setKey(
        'llm',
        fields[5].text.trim(),
        forEndpoint: fields[3].text.trim(),
      );
      config.ttsUrl = fields[0].text.trim();
      config.ttsModel = fields[1].text.trim();
      config.llmUrl = fields[3].text.trim();
      config.llmModel = fields[4].text.trim();
      if (config.llmModel.isNotEmpty &&
          !config.llmModels.contains(config.llmModel)) {
        config.llmModels.add(config.llmModel);
      }
      await config.save();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => error = '保存失败，请检查 HTTPS 地址和本机密钥访问权限');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('OpenAI 兼容接口'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!loaded && error == null) const LinearProgressIndicator(),
            for (var i = 0; i < fields.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: fields[i],
                  enabled: loaded && !busy,
                  obscureText: i == 2 || i == 5,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: const [
                      'TTS 地址',
                      'TTS 模型',
                      'TTS API-Key',
                      '大模型地址',
                      '大模型名称',
                      '大模型 API-Key',
                    ][i],
                  ),
                ),
              ),
            if (config.llmModels.isNotEmpty)
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: '已保存的大模型'),
                isExpanded: true,
                items: [
                  for (final name in config.llmModels)
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: (value) {
                  if (value != null) fields[4].text = value;
                },
              ),
            const Text('密钥仅保存在本机钥匙串；调用时仅发往对应的自填服务商。简易模式不请求大模型。'),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: loaded && !busy ? _save : null,
        child: const Text('保存'),
      ),
    ],
  );
}

const novelSpeechHelp = ExpansionTile(
  title: Text('📖听书功能使用帮助'),
  initiallyExpanded: false,
  children: [
    Padding(
      padding: EdgeInsets.all(12),
      child: Text('''【四种听书模式新手教程】

1.系统原生语音
手机自带基础朗读，无需联网、零成本。
适合临时快速听书，人声较机械。

2.本地离线AI听书（推荐无网使用）
内置AI音色包，完全离线免费。
自动识别小说对话切换男女声，无任何消费、不用API。
适合长期自用、省电、稳定不掉线。

3.在线云端简易TTS（日常主力推荐）
填入TTS API即可使用超自然真人声。
靠代码识别对话，不消耗AI Token、成本极低。
人声质感远优于系统自带，日常最稳。

4.在线AI智能增强听书（顶级人声效果）
需要填写大模型API KEY联网使用。
AI智能分析整章剧情：自动分辨旁白、男主、女主、情绪停顿。
多人对话不乱读、语气最自然、接近专业配音。
AI接口异常会自动降级为普通在线朗读，不会中断听书。

【通用功能说明】
‑开启「自动切换对话音色」：朗读会自动区分旁白和人物对话
‑关闭则全程统一旁白音色朗读
‑每种模式的语速、音色、音量会单独保存，切换模式设置互不冲突'''),
    ),
  ],
);

class _SpeechVoiceDialog extends StatefulWidget {
  const _SpeechVoiceDialog({
    required this.role,
    required this.mode,
    required this.value,
  });
  final String role, value;
  final SpeechMode mode;
  @override
  State<_SpeechVoiceDialog> createState() => _SpeechVoiceDialogState();
}

class _SpeechVoiceDialogState extends State<_SpeechVoiceDialog> {
  late final controller = TextEditingController(text: widget.value);
  List<(String, String)> voices = [];
  @override
  void initState() {
    super.initState();
    if (widget.mode == SpeechMode.system) unawaited(_load());
    if (widget.mode == SpeechMode.local) {
      voices = [for (var i = 0; i < 174; i++) ('$i', '音色 $i')];
      if (controller.text.isEmpty) controller.text = '0';
    }
  }

  Future<void> _load() async {
    try {
      final data = await const MethodChannel('lumebox/speech')
          .invokeListMethod<dynamic>('speechVoices');
      if (!mounted) return;
      setState(
        () => voices = [
          ('', '系统默认'),
          for (final voice in data ?? [])
            if (voice is Map && voice['id'] is String)
              (
                voice['id'] as String,
                '${voice['name']} · ${voice['language']}',
              ),
        ],
      );
    } catch (_) {
      /* Keep the original system default available. */
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.role}音色'),
    content: SizedBox(
      width: 360,
      child: voices.isEmpty
          ? TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: '音色标识',
                helperText: '填写服务商的 voice 名称，系统模式可留空',
              ),
            )
          : DropdownButtonFormField<String>(
              initialValue: controller.text,
              isExpanded: true,
              items: [
                for (final voice in voices)
                  DropdownMenuItem(
                    value: voice.$1,
                    child: Text(voice.$2, overflow: TextOverflow.ellipsis),
                  ),
                if (!voices.any((v) => v.$1 == controller.text))
                  DropdownMenuItem(
                    value: controller.text,
                    child: Text(controller.text),
                  ),
              ],
              onChanged: (value) {
                if (value != null) controller.text = value;
              },
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text.trim()),
        child: const Text('保存'),
      ),
    ],
  );
}
