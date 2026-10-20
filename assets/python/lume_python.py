"""Spider host for embedded CPython. Imported scripts are trusted application code.

The network adapters use the same Dart LumeHttp client as JS sources. No pip,
subprocess, local server or JIT is needed to load an ordinary Spider script.
"""
import base64
import contextvars
import io
import json
import re
import sys
import time
import types
import urllib.error
import urllib.request
from contextlib import contextmanager, redirect_stdout, redirect_stderr

import _lume_host
import requests
from requests.adapters import BaseAdapter
from requests.structures import CaseInsensitiveDict

_contexts = {}
_active = contextvars.ContextVar("lume_source")


def _host(method, payload):
    state = _active.get()
    remaining = state["deadline"] - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Python 源执行超时")
    reply = json.loads(_lume_host.invoke(json.dumps({
        "method": method, "payload": payload,
        "timeout": min(remaining, 30),
    })))
    if not reply.get("ok"):
        raise RuntimeError(reply.get("error", "宿主请求失败"))
    return reply.get("value")


class _HttpAdapter(BaseAdapter):
    def send(self, request, stream=False, timeout=None, verify=True, cert=None, proxies=None):
        body = request.body or b""
        if isinstance(body, str):
            body = body.encode("utf-8")
        if not isinstance(body, bytes):
            raise ValueError("Python 源暂不支持流式上传")
        value = _host("http", {
            "url": request.url, "method": request.method,
            "headers": dict(request.headers), "body": base64.b64encode(body).decode(),
        })
        response = requests.Response()
        response.status_code = value["status"]
        response.headers = CaseInsensitiveDict(value["headers"])
        response._content = base64.b64decode(value["body"])
        response._content_consumed = True
        response.raw = io.BytesIO(response._content)
        from email.message import Message
        message = Message()
        for key, item in value["headers"].items():
            message[key] = item
        response.raw._original_response = types.SimpleNamespace(msg=message)
        response.url = request.url
        response.request = request
        response.encoding = requests.utils.get_encoding_from_headers(response.headers)
        return response

    def close(self):
        pass


_original_session_init = requests.Session.__init__


def _session_init(self):
    _original_session_init(self)
    self.trust_env = False
    self.mount("http://", _HttpAdapter())
    self.mount("https://", _HttpAdapter())


requests.Session.__init__ = _session_init


class _UrlResponse(io.BytesIO):
    def __init__(self, value, url):
        from email.message import Message
        super().__init__(base64.b64decode(value["body"]))
        self.code = self.status = value["status"]
        self.url = url
        self.reason = ""
        self.msg = self.reason
        self.headers = Message()
        for key, item in value["headers"].items():
            self.headers[key] = item

    def info(self):
        return self.headers

    def getcode(self):
        return self.code

    def geturl(self):
        return self.url

    def getheader(self, name, default=None):
        return self.headers.get(name, default)

    def getheaders(self):
        return list(self.headers.items())


class _UrlHandler(urllib.request.HTTPHandler, urllib.request.HTTPSHandler):
    handler_order = 400

    def http_open(self, request):
        data = request.data or b""
        if not isinstance(data, bytes):
            raise ValueError("仅支持 bytes 请求体")
        value = _host("http", {
            "url": request.full_url, "method": request.get_method(),
            "headers": dict(request.header_items()),
            "body": base64.b64encode(data).decode(),
        })
        return _UrlResponse(value, request.full_url)

    https_open = http_open


_build_opener = urllib.request.build_opener


def _opener(*handlers):
    # Prevent custom HTTPSHandler/context from silently bypassing the host.
    handlers = [h for h in handlers if not isinstance(h, (urllib.request.HTTPHandler, urllib.request.HTTPSHandler))]
    return _build_opener(*handlers, _UrlHandler())


urllib.request.build_opener = _opener
urllib.request.install_opener(_opener())

# Some Spiders use http.client directly rather than requests / urllib.
import http.client


def _connection_request(self, method, url, body=None, headers=None, *, encode_chunked=False):
    if url.startswith(("http://", "https://")):
        target = url
    else:
        scheme = "https" if isinstance(self, http.client.HTTPSConnection) else "http"
        host = self.host
        if ":" in host and not host.startswith("["):
            host = "[" + host + "]"
        target = "%s://%s:%s%s" % (scheme, host, self.port, url)
    data = body.encode("utf-8") if isinstance(body, str) else body or b""
    self._lume_response = _UrlResponse(_host("http", {
        "url": target, "method": method, "headers": headers or {},
        "body": base64.b64encode(data).decode(),
    }), target)


def _connection_response(self):
    response = getattr(self, "_lume_response", None)
    if response is None:
        raise http.client.ResponseNotReady()
    self._lume_response = None
    return response


http.client.HTTPConnection.request = _connection_request
http.client.HTTPConnection.getresponse = _connection_response


class _Spider:
    def fetch(self, url, **kwargs):
        return requests.get(url, **kwargs)

    def post(self, url, **kwargs):
        return requests.post(url, **kwargs)

    def log(self, message):
        # Script output can contain credentials; it is deliberately not exported.
        pass

    def getCache(self, key):
        return _active.get()["cache"].get(str(key))

    def setCache(self, key, value):
        _active.get()["cache"][str(key)] = value

    def delCache(self, key):
        _active.get()["cache"].pop(str(key), None)

    def getProxyUrl(self, *args):
        raise RuntimeError("此源需要本地代理服务；iOS 不提供 Android Java / DEX 服务，请配置脚本支持的外部后端")


_base = types.ModuleType("base")
_spider = types.ModuleType("base.spider")
_spider.Spider = _Spider
_base.spider = _spider
sys.modules["base"] = _base
sys.modules["base.spider"] = _spider


def _crypto_module():
    """The subset used by imported Spiders, backed by host PointyCastle."""
    crypto = types.ModuleType("Crypto")
    crypto.__path__ = []
    cipher = types.ModuleType("Crypto.Cipher")
    cipher.__path__ = []
    util = types.ModuleType("Crypto.Util")
    util.__path__ = []
    padding = types.ModuleType("Crypto.Util.Padding")

    def pad(data, block_size, style="pkcs7"):
        if style != "pkcs7" or not 1 <= block_size <= 255:
            raise ValueError("仅支持 PKCS7 padding")
        count = block_size - len(data) % block_size
        return data + bytes([count]) * count

    def unpad(data, block_size, style="pkcs7"):
        if style != "pkcs7" or not data or len(data) % block_size:
            raise ValueError("无效的 PKCS7 padding")
        count = data[-1]
        if not 1 <= count <= block_size or data[-count:] != bytes([count]) * count:
            raise ValueError("无效的 PKCS7 padding")
        return data[:-count]

    padding.pad, padding.unpad = pad, unpad

    class Cipher:
        def __init__(self, algorithm, key, mode, iv=b"", nonce=b""):
            self.algorithm, self.key, self.mode = algorithm, bytes(key), mode
            self.iv, self.nonce, self.aad = bytes(iv), bytes(nonce), b""

        def update(self, data):
            self.aad += bytes(data)

        def _run(self, data, encrypt, tag=b""):
            encode = lambda value: base64.b64encode(value).decode()
            value = _host("crypto", {
                "algorithm": self.algorithm, "mode": self.mode,
                "key": encode(self.key), "iv": encode(self.iv),
                "nonce": encode(self.nonce), "aad": encode(self.aad),
                "data": encode(bytes(data) + bytes(tag)), "encrypt": encrypt,
            })
            return base64.b64decode(value)

        def encrypt(self, data):
            return self._run(data, True)

        def decrypt(self, data):
            return self._run(data, False)

        def encrypt_and_digest(self, data):
            value = self._run(data, True)
            return value[:-16], value[-16:]

        def decrypt_and_verify(self, data, tag):
            return self._run(data, False, tag)

    aes = types.ModuleType("Crypto.Cipher.AES")
    aes.MODE_ECB, aes.MODE_CBC, aes.MODE_GCM, aes.block_size = 1, 2, 11, 16
    aes.new = lambda key, mode, iv=b"", **kw: Cipher("aes", key, mode, iv=kw.get("iv", iv), nonce=kw.get("nonce", b""))
    chacha = types.ModuleType("Crypto.Cipher.ChaCha20_Poly1305")
    chacha.new = lambda *, key, nonce: Cipher("chacha", key, 0, nonce=nonce)
    cipher.AES, cipher.ChaCha20_Poly1305 = aes, chacha
    crypto.Cipher, crypto.Util, util.Padding = cipher, util, padding
    for module in (crypto, cipher, aes, chacha, util, padding):
        sys.modules[module.__name__] = module


_crypto_module()


@contextmanager
def _budget(state, seconds):
    state["deadline"] = time.monotonic() + min(max(float(seconds), 1), 60)
    token = _active.set(state)
    previous = sys.gettrace()

    def trace(frame, event, arg):
        if time.monotonic() > state["deadline"]:
            raise TimeoutError("Python 源执行超时")
        return trace

    sys.settrace(trace)
    try:
        class Quiet:
            def write(self, value):
                return len(value)
            def flush(self):
                pass
        with redirect_stdout(Quiet()), redirect_stderr(Quiet()):
            yield
    finally:
        sys.settrace(previous)
        _active.reset(token)


def _decoded(value):
    if isinstance(value, str):
        return json.loads(value) if value.strip() else {}
    return value or {}


def _items(value):
    raw = _decoded(value)
    entries = raw if isinstance(raw, list) else raw.get("list", [])
    return [{"id": "py:" + str(x.get("vod_id", x.get("id", ""))),
             "title": str(x.get("vod_name", x.get("name", ""))),
             "cover": x.get("vod_pic", x.get("pic", "")),
             "subtitle": str(x.get("vod_remarks", x.get("remarks", "")))}
            for x in entries if isinstance(x, dict) and x.get("vod_id", x.get("id")) is not None]


def _detail(state, item_id):
    if state.get("detail_id") != item_id:
        value = _decoded(state["spider"].detailContent([item_id]))
        entries = value.get("list", []) if isinstance(value, dict) else value
        state["detail"] = entries[0] if entries else {}
        state["detail_id"] = item_id
    return state["detail"]


def _dispatch(state, method, arg):
    spider = state["spider"]
    if not state["initialized"]:
        init = getattr(spider, "init", None)
        if init:
            init(state.get("config", {}).get("extend", ""))
        state["initialized"] = True
    arg = arg or {}
    if method in ("categories", "filters"):
        value = _decoded(spider.homeContent(True))
        if method == "categories":
            return [{"id": str(x["type_id"]), "title": str(x["type_name"])} for x in value.get("class", [])]
        groups = value.get("filters", {})
        return [{"id": x["key"], "title": x.get("name", x["key"]),
                 "options": [{"id": str(v.get("v", "")), "title": str(v.get("n", ""))} for v in x.get("value", [])]}
                for x in groups.get(str(arg.get("categoryId", "")), [])]
    if method in ("list", "home"):
        if arg.get("keyword"):
            import inspect
            search = spider.searchContent
            if len(inspect.signature(search).parameters) >= 3:
                raw = search(arg["keyword"], False, str(arg.get("page", 1)))
            elif arg.get("page", 1) == 1:
                raw = search(arg["keyword"], False)
            else:
                return {"items": [], "hasMore": False}
        elif arg.get("categoryId"):
            raw = spider.categoryContent(str(arg["categoryId"]), str(arg.get("page", 1)), True, arg.get("filters", {}))
        else:
            raw = getattr(spider, "homeVideoContent", lambda: spider.homeContent(False))()
        value = _decoded(raw)
        items = _items(value)
        if method == "home":
            return items
        more = False
        if isinstance(value, dict):
            try:
                more = int(value.get("page", arg.get("page", 1))) < int(value.get("pagecount", value.get("page_count", 0)))
                if not value.get("pagecount", value.get("page_count")):
                    more = bool(items) and (len(items) >= int(value["limit"]) if value.get("limit") else bool(arg.get("keyword") or arg.get("categoryId")))
            except (ValueError, TypeError):
                pass
        return {"items": items, "hasMore": more}
    if method in ("detail", "chapters"):
        item_id = str(arg["id"])
        raw = _detail(state, item_id[3:] if item_id.startswith("py:") else item_id)
        if method == "detail":
            return {"id": item_id, "title": raw.get("vod_name", ""),
                    "cover": raw.get("vod_pic", ""), "subtitle": raw.get("vod_remarks", ""),
                    "description": raw.get("vod_content", "")}
        flags = str(raw.get("vod_play_from", "")).split("$$$")
        chapters = []
        for index, line in enumerate(str(raw.get("vod_play_url", "")).split("$$$")):
            flag = flags[index] if index < len(flags) else ""
            for entry in line.split("#"):
                if not entry.strip():
                    continue
                title, sep, target = entry.partition("$")
                chapters.append({"id": json.dumps({"flag": flag, "id": target if sep else title}),
                                 "title": (flag + " · " if len(flags) > 1 else "") + (title if sep else "播放")})
        return chapters
    if method == "content":
        episode = json.loads(arg["chapterId"])
        raw = _decoded(spider.playerContent(episode.get("flag", ""), episode["id"], []))
        url = str(raw.get("url", ""))
        if not url:
            raise ValueError("源未返回播放地址；请检查站点、外部解析后端或 Android 专属依赖")
        headers = _decoded(raw.get("header", raw.get("headers", {})))
        return {"kind": "video", "url": url, "headers": headers,
                "webParse": str(raw.get("parse", 0)) == "1" or (str(raw.get("jx", 0)) == "1" and not re.search(r"\.(?:mp4|m3u8|mp3|m4a|aac|flac|mkv|webm|mpd)(?:$|[?#])", url, re.I))}
    raise ValueError("Python 源不提供接口：" + method)


def execute(request):
    request = json.loads(request)
    source_id, action = request["sourceId"], request["action"]
    if action == "dispose":
        state = _contexts.pop(source_id, None)
        if state:
            # Drop sessions and namespace without running arbitrary destroy code.
            state.clear()
        return {"ok": True, "value": None}
    if action == "load":
        state = {"cache": {}, "config": {}, "initialized": False}
        _contexts.pop(source_id, None)
        with _budget(state, request.get("timeout", 15)):
            namespace = {"__name__": "lume_import_" + source_id, "__file__": "imported_source.py"}
            exec(compile(request["script"], "imported_source.py", "exec"), namespace)
            cls = namespace.get("Spider")
            if not isinstance(cls, type):
                raise ValueError("Python 源必须声明 Spider 类")
            spider = cls()
            for name in ("homeContent", "categoryContent", "detailContent", "playerContent"):
                if not callable(getattr(spider, name, None)):
                    raise ValueError("Python 源缺少接口：" + name)
            state.update(namespace=namespace, spider=spider)
            _contexts[source_id] = state
        return {"ok": True, "value": {"methods": ["categories", "list", "detail", "chapters", "content", "filters"] + (["home"] if hasattr(spider, "homeVideoContent") else [])}}
    state = _contexts.get(source_id)
    if state is None:
        raise ValueError("Python 源已释放，请重新选择")
    if action == "config":
        state["config"] = request.get("config", {})
        state["spider"].config = state["config"]
        return {"ok": True, "value": None}
    with _budget(state, request.get("timeout", 30)):
        return {"ok": True, "value": _dispatch(state, request["method"], request.get("argument"))}


def run(request):
    try:
        result = execute(request)
        encoded = json.dumps(result, ensure_ascii=False)
        if len(encoded.encode("utf-8")) > 8 * 1024 * 1024:
            raise ValueError("Python 源结果超过 8MB")
        return encoded
    except Exception as error:
        # No traceback or arguments: these often include tokens and passwords.
        message = str(error)
        if isinstance(error, ModuleNotFoundError):
            message = "Python 源缺少依赖：" + str(error.name)
        return json.dumps({"ok": False, "error": {
            "kind": "timeout" if isinstance(error, TimeoutError) else "script",
            "message": (type(error).__name__ + ": " + message)[:1000],
        }}, ensure_ascii=False)
