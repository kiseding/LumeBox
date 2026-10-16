import '../session/section.dart';
import 'source.dart';
import 'source_preferences.dart';

/// Display grouping never changes a source's section, ID or runtime.
class SourcePickerGroups {
  static List<(String, String)> forSection(Section section) =>
      switch (section) {
        Section.novel => [('novel', '小说'), ('audiobook', '有声小说')],
        Section.comic => [('comic', '漫画'), ('photo', '美图')],
        Section.video => [('video', '视频'), ('movie', '影视')],
        Section.cat => [('cat', '猫源')],
      };

  static String groupFor(Section section, SourceDescriptor source) {
    final groups = forSection(section);
    final saved = SourcePreferences.read(section, source.id).pickerGroup;
    if (groups.any((group) => group.$1 == saved)) return saved;
    if (section == Section.novel && source.group == '听书') return 'audiobook';
    for (final group in groups) {
      if (source.group == group.$2) return group.$1;
    }
    final path = Uri.tryParse(source.originUrl)?.path ?? '';
    for (final group in groups.skip(1)) {
      if (path.contains('/${group.$1}/')) return group.$1;
    }
    if (section == Section.comic && source.id == 'z8pt_comic') return 'photo';
    if (section == Section.video &&
        const {
          'gztv5_video',
          'jpyy2_video',
          'luttt_video',
        }.contains(source.id)) {
      return 'movie';
    }
    return groups.first.$1;
  }
}
