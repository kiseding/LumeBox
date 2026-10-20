"""Offline tests for the production embedded Spider host.

Optional positional .py paths validate user files without copying them into Git.
All HTTP replies are local fixtures; this test never calls source websites.
"""
import argparse
import base64
import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".cache/python-source-runtime/packages"))
sys.path.insert(0, str(ROOT / "assets/python"))
USER_SCRIPTS = []
CALLS = []


def invoke(raw):
    request = json.loads(raw)
    payload = request["payload"]
    CALLS.append(request)
    if request["method"] == "crypto":
        # Forwarding is tested here; real algorithms use independent Dart KATs.
        return json.dumps({"ok": False, "error": "crypto fixture intentionally unavailable"})
    url = payload["url"]
    headers, status = {"Content-Type": "application/json; charset=utf-8"}, 200
    video = {"vod_id": "v1", "vod_name": "测试影片", "vod_pic": "https://fixture.invalid/cover.jpg", "vod_remarks": "更新中"}
    if "searchByWord" in url:
        body = {"data": {"result": {"list": [{"vodId": "v1", "vodName": "测试影片", "vodPic": "", "typeId1": 1, "vodVersion": "高清"}]}}}
    elif "/anonymous/video/detail" in url:
        body = {"data": {"typeName": "电影", "vodName": "测试影片", "vodRemarks": "高清", "vodYear": "2026", "vodArea": "", "vodActor": "", "vodDirector": "", "vodContent": "说明", "episodeList": [{"name": "第一集", "nid": "ep1"}]}}
    elif "/episode/url" in url:
        body = {"data": {"list": [{"url": "https://fixture.invalid/video.mp4"}]}}
    elif "/app/nav" in url:
        body = {"list": [{"type_id": "1", "type_name": "电影", "type_extend": {"year": "2026,2025"}}]}
    elif "/app/search" in url or "/app/video?" in url:
        body = {"list": [video], "page": 1, "pagecount": 2}
    elif "/app/video_detail" in url:
        body = {"data": {**video, "vod_url_with_player": [{"name": "线路一", "url": "第一集$https://fixture.invalid/video.mp4"}]}}
    elif url.endswith("/api/me"):
        body = {"auth_token": "fixture-public-token"}
    elif "/cookie" in url:
        body = {"ok": True}
        headers["Set-Cookie"] = "fixture=session; Path=/"
    else:
        body = "<html><head><title>测试</title></head><body></body></html>"
        headers["Content-Type"] = "text/html; charset=utf-8"
    if "/redirect" in url:
        status, headers = 302, {"Location": "https://fixture.invalid/cookie"}
        body = ""
    encoded = (json.dumps(body, ensure_ascii=False) if not isinstance(body, str) else body).encode()
    return json.dumps({"ok": True, "value": {"status": status, "headers": headers, "body": base64.b64encode(encoded).decode()}})


native = types.ModuleType("_lume_host")
native.invoke = invoke
sys.modules["_lume_host"] = native
if "lume_python" in sys.modules:
    host = sys.modules["lume_python"]
    host._lume_host = native
else:
    spec = importlib.util.spec_from_file_location("lume_python", ROOT / "assets/python/lume_python.py")
    host = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(host)

FIXTURE = '''
from base.spider import Spider
class Spider(Spider):
    def init(self, extend): self.initialized = extend
    def homeContent(self, filter): return {'class':[{'type_id':'1','type_name':'电影'}], 'filters':{}}
    def homeVideoContent(self): return {'list':[{'vod_id':'one','vod_name':'首页'}]}
    def categoryContent(self, tid, pg, filter, extend): return {'list':[{'vod_id':'one','vod_name':tid}], 'page':int(pg), 'pagecount':2}
    def searchContent(self, key, quick, pg='1'): return {'list':[{'vod_id':'one','vod_name':key + pg}]}
    def detailContent(self, ids): return {'list':[{'vod_id':ids[0],'vod_name':'详情','vod_play_from':'线路一$$$线路二','vod_play_url':'第一集$token1#第二集$token2$$$备用$token3'}]}
    def playerContent(self, flag, id, vipFlags): return {'parse':0,'url':'https://fixture.invalid/' + id + '.mp4','header':'{"Referer":"https://fixture.invalid/"}'}
'''


def call(source, action="call", **kwargs):
    result = json.loads(host.run(json.dumps({"sourceId": source, "action": action, "timeout": 2, **kwargs})))
    return result


class HostTests(unittest.TestCase):
    def setUp(self):
        CALLS.clear()
        host._contexts.clear()
        self.assertTrue(call("fixture", "load", script=FIXTURE)["ok"])

    def value(self, method, arg=None):
        result = call("fixture", method=method, argument=arg)
        self.assertTrue(result["ok"], result)
        return result["value"]

    def test_spider_end_to_end_and_line_identity(self):
        self.assertEqual(self.value("categories")[0]["title"], "电影")
        self.assertEqual(self.value("home")[0]["title"], "首页")
        self.assertEqual(self.value("list", {"keyword": "电影", "page": 2})["items"][0]["title"], "电影2")
        self.assertTrue(self.value("list", {"keyword": "电影"})["hasMore"])
        self.assertEqual(self.value("detail", {"id": "one"})["title"], "详情")
        chapters = self.value("chapters", {"id": "one"})
        self.assertEqual(len(chapters), 3)
        self.assertNotEqual(chapters[0]["id"], chapters[2]["id"])
        content = self.value("content", {"id": "one", "chapterId": chapters[0]["id"]})
        self.assertEqual(content["url"], "https://fixture.invalid/token1.mp4")
        self.assertIn("Referer", content["headers"])

    def test_two_argument_search_does_not_fabricate_more_pages(self):
        source = FIXTURE.replace("def searchContent(self, key, quick, pg='1')", "def searchContent(self, key, quick)").replace("key + pg", "key")
        self.assertTrue(call("fixture", "load", script=source)["ok"])
        self.assertEqual(self.value("list", {"keyword": "电影", "page": 2})["items"], [])

    def test_requests_cookies_redirects_and_urllib(self):
        source = FIXTURE + '''
    def homeVideoContent(self):
        import requests, urllib.request, http.client
        session = requests.Session()
        response = session.get('https://fixture.invalid/redirect')
        assert session.cookies.get('fixture') == 'session'
        assert response.status_code == 200
        urllib.request.urlopen('https://fixture.invalid/page').read()
        conn = http.client.HTTPSConnection('fixture.invalid')
        conn.request('GET', '/direct')
        assert conn.getresponse().status == 200
        return {'list':[{'vod_id':'ok','vod_name':'网络通过'}]}
'''
        self.assertTrue(call("fixture", "load", script=source)["ok"])
        self.assertEqual(self.value("home")[0]["title"], "网络通过")
        self.assertEqual(len(CALLS), 4)

    def test_namespace_cache_dispose_and_missing_dependency(self):
        self.assertTrue(call("second", "load", script=FIXTURE)["ok"])
        host._contexts["fixture"]["cache"]["key"] = "secret"
        self.assertEqual(host._contexts["second"]["cache"], {})
        self.assertTrue(call("fixture", "dispose")["ok"])
        self.assertFalse(call("fixture", method="categories")["ok"])
        bad = call("bad", "load", script="import a_missing_spider_dependency\n" + FIXTURE)
        self.assertIn("a_missing_spider_dependency", bad["error"]["message"])

    def test_threadpool_retains_source_identity(self):
        source = FIXTURE + '''
    def homeVideoContent(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=2) as executor:
            replies = list(executor.map(lambda _: self.fetch('https://fixture.invalid/cookie').json(), range(2)))
        assert all(reply['ok'] for reply in replies)
        return {'list':[{'vod_id':'thread','vod_name':'线程通过'}]}
'''
        self.assertTrue(call("fixture", "load", script=source)["ok"])
        self.assertEqual(self.value("home")[0]["title"], "线程通过")
        self.assertTrue(all(request["sourceId"] == "fixture" for request in CALLS))

    def test_aliases_alternate_signatures_and_function_modules(self):
        source = '''
def initialize(): pass
def getHomeContent(): return {'class':[{'type_id':'1','type_name':'电影'}]}
def getCategoryContent(tid, pg=1, extend=None):
    assert isinstance(pg, int)
    return {'list':[{'vod_id':'id','vod_name':extend['year']}], 'page':pg, 'pagecount':3}
def search(key, page=1):
    assert isinstance(page, int)
    return {'list':[{'vod_id':'id','vod_name':str(page)}]}
def getDetailContent(ids): return {'list':[{'vod_id':ids[0],'vod_name':'别名'}]}
def getPlayerContent(flag, id): return {'url':'https://fixture.invalid/video.mp4'}
'''
        self.assertTrue(call('fixture', 'load', script=source)['ok'])
        self.assertEqual(self.value('categories')[0]['title'], '电影')
        self.assertEqual(self.value('list', {'keyword':'q','page':2})['items'][0]['title'], '2')
        self.assertEqual(self.value('list', {'categoryId':'1','page':2,'filters':{'year':'2026'}})['items'][0]['title'], '2026')
        self.assertEqual(self.value('detail', {'id':'id'})['title'], '别名')

    def test_xpath_pyquery_httpx_and_async_client(self):
        source = FIXTURE + '''
    def homeVideoContent(self):
        import asyncio, httpx
        from lxml import etree, html
        from pyquery import PyQuery as pq
        document = etree.HTML('<div class="cards"><a href="/one">第一集</a><a href="/two">第二集</a></div>')
        assert document.xpath('//div[contains(@class,"cards")]/a/@href') == ['/one', '/two']
        assert document.xpath('count(//a)') == 2
        assert document.xpath('//a')[0].getparent().tag == 'div'
        assert pq('<a href="/one">第一集</a>')('a').attr('href') == '/one'
        assert self.cleanText('<b>文字</b>') == '文字'
        assert httpx.get('https://fixture.invalid/cookie').json()['ok']
        with httpx.Client(headers={'User-Agent':'fixture-custom-UA'}) as client:
            assert client.get('https://fixture.invalid/cookie').json()['ok']
        async def run():
            async with httpx.AsyncClient() as client:
                return (await client.get('https://fixture.invalid/cookie')).json()['ok']
        assert asyncio.run(run())
        return {'list':[{'vod_id':'https://fixture.invalid/album/1','vod_name':'通用兼容'}]}
'''
        result = call('fixture', 'load', script=source)
        self.assertTrue(result['ok'], result)
        item = self.value('home')[0]
        self.assertEqual(item['title'], '通用兼容')
        self.assertEqual(item['id'], 'py:https://fixture.invalid/album/1')
        self.assertTrue(any(request['payload'].get('headers', {}).get('user-agent') == 'fixture-custom-UA' for request in CALLS))

    def test_legacy_encoding_and_dependency_diagnostics(self):
        encoded = base64.b64encode(('# coding: gbk\n' + FIXTURE).encode('gbk')).decode()
        result = call('fixture', 'load', script='# LumePythonBytes: ' + encoded)
        self.assertTrue(result['ok'], result)
        self.assertEqual(self.value('categories')[0]['title'], '电影')
        optional = FIXTURE + '\n    def android_only(self):\n        from java.lang import Runtime\n'
        result = call('fixture', 'load', script=optional)
        self.assertTrue(result['ok'], result)
        self.assertTrue(any('Android' in item for item in result['value']['warnings']))
        from Crypto.Hash import SHA256, HMAC
        self.assertEqual(SHA256.new(b'abc').hexdigest(), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
        self.assertEqual(len(HMAC.new(b'key', b'message', SHA256).digest()), 32)

    def test_cpu_timeout_and_web_parse(self):
        source = FIXTURE.replace("def homeContent(self, filter): return", "def homeContent(self, filter):\n        while True:\n            pass\n        return")
        self.assertTrue(call("loop", "load", script=source)["ok"])
        result = call("loop", method="categories")
        self.assertEqual(result["error"]["kind"], "timeout")
        source = FIXTURE.replace("'parse':0", "'parse':1")
        self.assertTrue(call("fixture", "load", script=source)["ok"])
        chapter = self.value("chapters", {"id": "one"})[0]
        self.assertTrue(self.value("content", {"id": "one", "chapterId": chapter["id"]})["webParse"])

    def test_user_scripts_load_dependencies_and_categories(self):
        for index, path in enumerate(USER_SCRIPTS):
            with self.subTest(script=path.name):
                source_id = "user_" + str(index)
                loaded = call(source_id, "load", script=path.read_text(encoding="utf-8-sig"))
                self.assertTrue(loaded["ok"], {"file": path.name, "result": loaded})
                categories = call(source_id, method="categories")
                self.assertTrue(categories["ok"], {"file": path.name, "result": categories})
                self.assertGreater(len(categories["value"]), 0)
                print("Validated load/dependencies/categories:", path.name)
                if path.name in ("金牌.py", "影探4K.py"):
                    search = call(source_id, method="list", argument={"keyword": "测试", "page": 1})
                    self.assertTrue(search["ok"], search)
                    item = search["value"]["items"][0]
                    detail = call(source_id, method="detail", argument={"id": item["id"]})
                    self.assertTrue(detail["ok"], detail)
                    episodes = call(source_id, method="chapters", argument={"id": item["id"]})
                    self.assertTrue(episodes["ok"], episodes)
                    content = call(source_id, method="content", argument={"id": item["id"], "chapterId": episodes["value"][0]["id"]})
                    self.assertTrue(content["ok"], content)
                    self.assertEqual(content["value"]["url"], "https://fixture.invalid/video.mp4")
                    print("Validated offline search/detail/episodes/play:", path.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scripts", nargs="*", type=Path)
    options = parser.parse_args()
    USER_SCRIPTS.extend(options.scripts)
    unittest.main(argv=[sys.argv[0]], verbosity=2)
