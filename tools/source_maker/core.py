"""Discovery and portable LumeSource generation; no credentials in exported files."""
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit
from urllib.request import Request, build_opener, HTTPCookieProcessor
from http.cookiejar import CookieJar

from bs4 import BeautifulSoup

TARGETS = {'有声小说': 'audio', '漫画': 'comic', '图片': 'images', '视频': 'video',
           'PY': 'python', '模块': 'module', '猫源': 'cat', 'Kazumi': 'kazumi', '网页': 'web'}
SECTIONS = {'audio': 'video', 'comic': 'comic', 'images': 'comic', 'video': 'video',
            'python': 'video', 'module': 'video', 'cat': 'cat', 'kazumi': 'video', 'web': 'video'}


def target_config(config, target):
    if target not in SECTIONS:
        raise ValueError('不支持的模块：' + str(target))
    config = dict(config)
    config.update(target=target, category=SECTIONS[target],
                  media='audio' if target == 'audio' else 'images' if target in ('comic', 'images') else 'video')
    return config


def api_base(url):
    parts = urlsplit(url)
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
             if k.lower() not in ('ac', 'ids', 'wd', 'pg', 't')]
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), ''))


def source_filename(config, extension):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', config['name']).strip().rstrip('. ')
    name = name[:100].rstrip('. ') or config['id']
    if re.match(r'^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', name, re.I):
        name = '_' + name
    return name + extension

MAX_BYTES = 6 * 1024 * 1024
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36'


def validate_url(value):
    value = value.strip()
    if '://' not in value:
        value = 'https://' + value
    p = urlsplit(value)
    if p.scheme not in ('http', 'https') or not p.hostname or p.username or p.password:
        raise ValueError('请输入有效的 http(s) 网址，不要在网址中包含账号密码')
    return value


class Fetcher:
    def __init__(self):
        self.opener = build_opener(HTTPCookieProcessor(CookieJar()))

    def get(self, url):
        url = validate_url(url)
        try:
            with self.opener.open(Request(url, headers={'User-Agent': UA, 'Accept': 'text/html,application/json', 'Accept-Encoding': 'identity'}), timeout=18) as r:
                raw = r.read(MAX_BYTES + 1)
                if len(raw) > MAX_BYTES:
                    raise ValueError('页面超过 6MB，请改填具体的列表页')
                charset = r.headers.get_content_charset()
                if not charset:
                    m = re.search(br'charset\s*=\s*["\x27]?([\w-]+)', raw[:8192], re.I)
                    charset = m.group(1).decode('ascii') if m else 'utf-8'
                try:
                    body = raw.decode(charset, errors='replace')
                except LookupError:
                    body = raw.decode('utf-8', errors='replace')
                if re.search(r'<title[^>]*>\s*(Just a moment|Attention Required)|cf-chl-|验证您是真人', body, re.I):
                    raise ValueError('站点需要人工验证，请点击「连接所选引擎」，手动完成后继续')
                return r.url, body
        except HTTPError as e:
            code = e.code
            e.close()
            raise ValueError(f'站点返回 HTTP {code}，可能需要登录、验证或稍后重试') from e
        except URLError as e:
            raise ValueError(f'无法连接：{e.reason}') from e


def html_items(html, base, pattern=''):
    soup = BeautifulSoup(html, 'html.parser')
    out, seen = [], set()
    rule = re.compile(pattern, re.I) if pattern else None
    for a in soup.select('a[href]'):
        href = a.get('href', '').strip()
        if not href or href.startswith(('#', 'javascript:', 'mailto:', 'tel:', 'data:')):
            continue
        url = urljoin(base, href)
        image = a.find('img')
        title = a.get('title') or a.get_text(' ', strip=True) or (image.get('alt') if image else '')
        if not title or url in seen or (rule and not rule.search(url)):
            continue
        seen.add(url)
        cover = (image.get('data-original') or image.get('data-src') or image.get('src') or '') if image else ''
        out.append({'id': url, 'title': title, 'cover': urljoin(base, cover) if cover else ''})
    return out


def guess_pattern(rows, base):
    host = urlsplit(base).netloc
    groups = Counter()
    for r in rows:
        p = urlsplit(r['id'])
        if p.netloc != host or not p.path.strip('/'):
            continue
        if re.search(r'/(?:c|category|categories|type|types|tag|tags|genre|genres|actor|actors|model|models|login|register|search|about|contact)(?:/|$)', p.path, re.I):
            continue
        # Group card links even when a site's detail slug contains no numeric ID.
        if '/' in p.path.strip('/'):
            path = re.escape(p.path.rsplit('/', 1)[0]) + r'/[^/?#]+'
        else:
            path = re.sub(r'\d+', lambda _: r'\d+', re.escape(p.path))
        groups[path] += 3 if r['cover'] else 1
    if not groups:
        return re.escape(urlsplit(base).scheme + '://' + host) + r'/[^#]+'
    return '^' + re.escape(urlsplit(base).scheme + '://' + host) + groups.most_common(1)[0][0] + r'(?:[?#]|$)'


def discover(url, category='video', fetcher=None):
    if category == 'novel':
        raise ValueError('当前 LumeBox 不支持文字小说，请选择有声小说')
    fetcher = fetcher or Fetcher()
    final, html = fetcher.get(url)
    soup = BeautifulSoup(html, 'html.parser')
    name = soup.title.get_text(strip=True) if soup.title else urlsplit(final).hostname
    name = re.sub(r'\s+', ' ', name).strip() or urlsplit(final).hostname
    config = {'url': final, 'id': 'web-' + hashlib.sha256(final.encode()).hexdigest()[:12],
              'name': name, 'category': category, 'mode': 'html', 'api': '', 'list': final,
              'search': '', 'links': '', 'chapters': r'(?:/play/|/vodplay/|/chapter/|/read/|/\d+/\d+\.html)', 'contentId': '',
              'categoryLinks': r'/(?:category|categories|catalog|type|genre)/',
              'filterFormIndex': -1, 'filterAction': '', 'filterKeys': [], 'filterNames': {}}
    config = target_config(config, category)
    for index, form in enumerate(soup.select('form')):
        selects = form.select('select[name]')
        action = urljoin(final, form.get('action') or final)
        if selects and form.get('method', 'get').lower() == 'get' and urlsplit(action).netloc == urlsplit(final).netloc:
            config.update(filterFormIndex=index, filterAction=action,
                          filterKeys=[select['name'] for select in selects])
            for select in selects:
                label = soup.find('label', attrs={'for': select.get('id', '')})
                config['filterNames'][select['name']] = select.get('aria-label') or (label.get_text(strip=True) if label else '') or select.get('title') or select['name']
            break
    for form in soup.select('form'):
        if form.get('method', 'get').lower() != 'get':
            continue
        field = form.find('input', attrs={'name': re.compile(r'^(wd|q|keyword|search)$', re.I)})
        if field:
            action = urljoin(final, form.get('action') or final)
            config['search'] = action + ('&' if '?' in action else '?') + field['name'] + '={keyword}'
            break
    if category == 'web':
        rows = html_items(html, final)
        return config, rows, '网页入口已抓取；导出 HTML 导航页，通过 App 的网页模块导入。'
    # Only probe a CMS endpoint when the page advertises that engine; never scan paths.
    candidates = [final] if html.lstrip().startswith('{') else []
    if re.search(r'maccms|mac_url|player_aaaa|/voddetail/|/vodplay/', html, re.I):
        candidates.append(urljoin(final, '/api.php/provide/vod/'))
    for candidate in candidates:
        try:
            data = json.loads(html if candidate == final else fetcher.get(candidate)[1])
            if isinstance(data, dict) and data.get('list') and 'vod_id' in data['list'][0]:
                if category in ('comic', 'images'):
                    raise ValueError('这是视频接口，请选择视频、PY、模块、猫源或 Kazumi')
                config.update(mode='maccms', api=api_base(candidate))
                rows = [{'id': str(v['vod_id']), 'title': v.get('vod_name', ''), 'cover': urljoin(final, v.get('vod_pic') or '')} for v in data['list']]
                return config, rows, '已识别苹果 CMS 接口，可实时获取分类、分页、搜索和播放线路。'
        except (ValueError, KeyError, TypeError, IndexError):
            continue
    all_rows = html_items(html, final)
    from rule_detection import inferred_cards, inspect_pages
    rule_config, card_rows = inferred_cards(html, final, getattr(fetcher, 'adaptive_store', None))
    config.update(rule_config)
    if card_rows:
        all_rows = card_rows
    config['links'] = guess_pattern(all_rows, final)
    rows = card_rows or html_items(html, final, config['links'])
    if not rows:
        raise ValueError('没有识别到内容链接。页面可能由 JavaScript 动态加载，请填写实际列表页或公开 JSON 接口')
    path = urlsplit(rows[0]['id']).path
    prefix = path.rsplit('/', 1)[0] + '/' if '/' in path.strip('/') else re.split(r'\d', path, maxsplit=1)[0]
    if "'" not in prefix:
        config['searchXPath'] = "//a[contains(@href,'" + prefix + "')]"
    config['chapterXPath'] = "//a[contains(@href,'/play/') or contains(@href,'/vodplay/') or contains(@href,'/chapter/')]"
    inspect_pages(config, rows, fetcher)
    categories = html_items(html, final, config['categoryLinks'])
    profile = config.get('profile', '通用链接')
    return config, rows, f'规则方案：{profile}。分类链接 {len(categories)} 个，标准 GET 筛选组 {len(config["filterKeys"])} 个；已检查首条详情及漫画阅读区。未识别能力尚未适配，请抽样验证。' + config.get('inspectionNote', '')


def generate(config):
    config = dict(config)
    if config.get('category') == 'novel':
        raise ValueError('旧工程使用文字小说模式，请重新选择有声小说并识别网址')
    config = target_config(config, config.get('target', config['category']))
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', config['id']):
        raise ValueError('源 ID 只能包含英文字母、数字、短横线和下划线，最多 64 位')
    if not config['name'].strip():
        raise ValueError('请填写源名称')
    for key in ('links', 'chapters', 'categoryLinks'):
        re.compile(config.get(key, ''))
    for key in ('url', 'list'):
        validate_url(config[key])
    if config['search']:
        validate_url(config['search'])
    if config['mode'] == 'maccms':
        validate_url(config['api'])
    root = Path(getattr(sys, '_MEIPASS', Path(__file__).parent))
    runtime = (root / 'runtime.js').read_text(encoding='utf-8')
    helpers = (root / 'html_rules.js').read_text(encoding='utf-8')
    helpers += '\n' + (root / 'page_actions.js').read_text(encoding='utf-8')
    identity = {k: config[k] for k in ('id', 'name', 'category')}
    identity.update(version='1.0.0', mirrors=[config['url']])
    identity['mediaType'] = config['media']
    if config['target'] == 'images':
        identity['group'] = '美图'
    return '// LumeSource: ' + json.dumps(identity, ensure_ascii=False) + '\n' + helpers + '\n' + runtime.replace('__CONFIG__', json.dumps(config, ensure_ascii=False), 1)
