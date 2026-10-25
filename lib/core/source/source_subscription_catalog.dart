import '../session/section.dart';

class SubscriptionCatalog {
  static const base =
      'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/';
  static const totalUrl = '${base}all';
  static const audiobooksUrl = '${base}audiobooks';
  static const sections = [Section.comic, Section.video];
  static const names = {Section.comic: 'comics', Section.video: 'videos'};
  static String canonical(String url, Section section) {
    const old = {
      Section.comic: [
        'comics',
        'photos',
        'comic/sources.txt',
        'photo/sources.txt',
        '漫画订阅.js',
      ],
      Section.video: [
        'videos',
        'movies',
        'video/sources.txt',
        'movie/sources.txt',
        '视频订阅.js',
      ],
    };
    return (old[section] ?? []).any((name) => url == '$base$name')
        ? '$base${names[section]}'
        : url;
  }

  static bool validUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }
}
