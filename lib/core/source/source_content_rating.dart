/// Explicitly identified adult sources. Unknown sources stay unclassified.
class SourceContentRating {
  static const adultIds = <String>{
    'hhhbook_novel',
    'hlib_novel',
    'aaccoo_novel',
    'xchina_novel',
    'alicesw_novel',
    'jinshuge_novel',
    'book18_novel',
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
      RegExp(r'成人|18禁|18H|18\+|R18|小黄书|色情|NSFW', caseSensitive: false).hasMatch(name);
}
