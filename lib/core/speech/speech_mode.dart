enum SpeechMode {
  system('系统自带 TTS'),
  local('本地离线 VITS · sherpa-onnx'),
  cloud('在线云端 TTS · 简易（正则）'),
  cloudAi('在线云端 TTS · AI 增强');

  const SpeechMode(this.label);
  final String label;
  static SpeechMode parse(Object? name) =>
      values.where((m) => m.name == name).firstOrNull ?? system;
}
