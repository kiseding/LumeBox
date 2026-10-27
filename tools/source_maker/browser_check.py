import json
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class LocalHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Set-Cookie', 'fixture=accepted; HttpOnly; Path=/')
        self.end_headers()
        if self.path == '/robots.txt':
            self.wfile.write(b'User-agent: *\nAllow: /\n')
        elif self.path == '/item/1':
            self.wfile.write(b'<h1>Public lesson</h1><video src="/lesson.mp4"></video>')
        elif self.path == '/static':
            self.wfile.write(b'<title>Public lessons</title><article class="video-card"><a href="/item/1">Lesson</a><img src="/cover.jpg"></article>')
        elif self.path.startswith('/api'):
            self.wfile.write(b'{"title":"Local API fixture","token":"must-be-redacted"}')
        elif self.path == '/interactive':
            self.wfile.write(b'<title>Actions</title><button id="more" onclick="fetch(\'/api?token=secret\').then(r=>r.json()).then(v=>{document.querySelector(\'#content\').innerHTML=\'<article class=video-card><a href=/item/1>Lesson</a><img src=/cover.jpg></article>\'})">More</button><div id="content"></div>')
        else:
            self.wfile.write(b'<title>Local fixture</title><div id="root"></div><script>setTimeout(()=>{document.querySelector("#root").innerHTML="<p class=ready>dynamic fixture</p><article class=video-card><a href=/item/1>Lesson</a><img src=/cover.jpg></article>"},750)</script>')


def browser_checks(report):
    from browser_session import BrowserSession
    from batch_crawler import crawl_public_pages
    from core import discover
    from verifier import verify_config
    server = ThreadingHTTPServer(('127.0.0.1', 0), LocalHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f'http://127.0.0.1:{server.server_port}/'
    results = {}
    try:
        engines = ('webview', 'playwright', 'selenium', 'scrapling-browser', 'scrapling-async-browser', 'scrapling-browser-session', 'scrapling-async-browser-session')
        for engine in engines:
            browser = None
            try:
                browser = BrowserSession(url, hidden_test=True, engine=engine)
                final, html = browser.get(url, selector='.ready')
                assert '<p class="ready">dynamic fixture</p>' in html, html
                assert browser.cookie_count >= 1
                config, rows, _ = discover(url, 'video', browser)
                config['useBrowser'] = True
                chain = verify_config(config, rows, browser)
                results[engine] = {'ok': True, 'cookies': browser.cookie_count, 'dynamic': True, 'chain': chain}
                browser.actions = {'click':'#more','clicks':1,'wait':'.video-card'}
                _, acted = browser.get(url + 'interactive', selector='.video-card')
                assert '<article class="video-card">' in acted
                results[engine]['click_wait'] = True
                if engine != 'webview':
                    records = browser.network()
                    assert any('Local API fixture' in json.dumps(r) for r in records), records
                    assert 'must-be-redacted' not in json.dumps(records)
                    results[engine]['api_records'] = True
            except Exception as e:
                results[engine] = {'ok': False, 'error': str(e)}
            finally:
                if browser:
                    browser.close()
        for engine in ('scrapling-fetcher','scrapling-async','scrapling-session','scrapling-async-session'):
            browser = None
            try:
                browser = BrowserSession(url + 'static', hidden_test=True, engine=engine)
                config, rows, _ = discover(url + 'static', 'video', browser)
                result = verify_config(config, rows, browser)
                results[engine] = {'ok':True,'chain':result}
            except Exception as error:
                results[engine] = {'ok':False,'error':str(error)}
            finally:
                if browser:
                    browser.close()
        pages = crawl_public_pages([url])
        results['scrapy'] = {'ok': 'Local fixture' in pages[url].get('html', ''), 'error': pages[url].get('error')}
        import tempfile
        from batch_crawler import batch_convert
        with tempfile.TemporaryDirectory() as directory:
            reports = batch_convert([url + 'static', url + 'item/1'], 'video', directory)
            assert reports[0]['ok'], reports
            assert not reports[1]['ok'], reports
            assert Path(directory, reports[0]['file']).exists()
            assert Path(directory, '采集诊断.json').exists()
            resumed = batch_convert([url + 'static', url + 'item/1'], 'video', directory)
            assert resumed[0]['file'] == reports[0]['file']
            assert len(list(Path(directory).glob('*.js'))) == 1
            stop = threading.Event(); stop.set()
            paused = batch_convert([url + 'static', url + 'item/1'], 'video', directory, stop=stop)
            assert paused[0]['ok']
            results['batch_conversion'] = {'ok': True, 'validated_export': True, 'invalid_page_rejected': True, 'checkpoint_resume':True,'pause':True}
    finally:
        server.shutdown()
        server.server_close()
    Path(report).write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    return results
