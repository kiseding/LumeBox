/// Explicitly identified adult sources. Unknown sources stay unclassified.
class SourceContentRating {
  static const adultIds = <String>{
    'mmcg18_comic',
    'jm18_comic',
    'mh18_comic',
    'hanman18_comic',
    'manwa_comic',
    'jmcomic_comic',
    'rouman5_comic',
    'seyoumanhua_comic',
    'cartoon18_comic',
    'hanime1_video',
    'hanime_video',
    'xanimu_video',
    'chaturbate_video',
  };
  static bool isAdult(String id, String name) =>
      adultIds.contains(id) ||
      adultIds.any(
        (known) => id.endsWith(':$known') || id.endsWith('|$known'),
      ) ||
      RegExp(
        r'成人|18禁|18H|18\+|R18|小黄书|色情|NSFW',
        caseSensitive: false,
      ).hasMatch(name);
}
