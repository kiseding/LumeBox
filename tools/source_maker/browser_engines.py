"""Optional real-browser providers. No stealth settings or CAPTCHA automation."""
import json
import sys
import time


def run_automation_worker(options, send):
    from core import validate_url
    from browser_session import same_site, LIMIT
    url = validate_url(options['url'])
    engine = options['engine']
    owner = None
    browser = None
    driver = None
    network = []
    from browser_actions import program, network_row
    try:
        if engine == 'playwright':
            from playwright.sync_api import sync_playwright
            owner = sync_playwright().start()
            browser = owner.chromium.launch(channel='msedge', headless=bool(options.get('hidden_test')))
            context = browser.new_context()
            page = context.new_page()
            def record(response):
                try:
                    if response.request.resource_type not in ('fetch', 'xhr') or not same_site(url, response.url):
                        return
                    raw = response.body()
                    if len(raw) <= 256 * 1024:
                        network.append(network_row(response.url, response.status, json.loads(raw)))
                        del network[:-20]
                except Exception:
                    pass
            page.on('response', record)
            page.set_default_timeout(15000)
            page.goto(url, wait_until='load', timeout=20000)
            def navigate(target, selector=''):
                if page.url != target:
                    page.goto(target, wait_until='load', timeout=18000)
                if selector:
                    page.locator(selector).first.wait_for(state='attached', timeout=12000)
                else:
                    page.wait_for_timeout(450)
            current = lambda: page.url
            capture = lambda: page.evaluate('({html:document.contentType.includes("json")?document.body.innerText:document.documentElement.outerHTML,ready:document.readyState,ua:navigator.userAgent,title:document.title})')
            cookies = lambda: context.cookies([page.url])
            apply_actions = lambda actions, selector: page.evaluate(program(actions, selector))
        elif engine == 'selenium':
            import os
            os.environ.setdefault('SE_TIMEOUT', '25')
            from selenium import webdriver
            from selenium.webdriver.edge.options import Options
            from selenium.webdriver.common.by import By
            from selenium.webdriver.support.ui import WebDriverWait
            settings = Options()
            settings.set_capability('ms:loggingPrefs', {'performance': 'ALL'})
            if options.get('hidden_test'):
                settings.add_argument('--headless=new')
            driver = webdriver.Edge(options=settings)
            driver.execute_cdp_cmd('Network.enable', {})
            driver.set_page_load_timeout(18)
            def navigate(target, selector=''):
                if driver.current_url != target:
                    driver.get(target)
                WebDriverWait(driver, 15).until(lambda d: d.execute_script('return document.readyState') == 'complete')
                if selector:
                    WebDriverWait(driver, 12).until(lambda d: d.find_elements(By.CSS_SELECTOR, selector))
                else:
                    time.sleep(.45)
            navigate(url)
            current = lambda: driver.current_url
            capture = lambda: driver.execute_script('return {html:document.contentType.includes("json")?document.body.innerText:document.documentElement.outerHTML,ready:document.readyState,ua:navigator.userAgent,title:document.title};')
            cookies = driver.get_cookies
            def apply_actions(actions, selector):
                driver.set_script_timeout(8)
                value = driver.execute_async_script('var done=arguments[0];' + program(actions, selector) + '.then(done,function(e){done({error:String(e)});});')
                if isinstance(value, dict) and value.get('error'):
                    raise ValueError(value['error'])
                return value
        else:
            raise ValueError('未知浏览器引擎')

        accepted = False
        def accept():
            nonlocal accepted
            info = capture()
            if not same_site(url, current()) or info['ready'] != 'complete':
                send({'event': 'notice', 'message': '请回到目标站点，等页面加载完成后继续'})
                return
            if 'cf-chl-' in info['html'] or 'just a moment' in info.get('title', '').lower():
                send({'event': 'notice', 'message': '页面仍在验证，请手动完成后继续'})
                return
            accepted = True
            send({'ok': True, 'url': current(), 'user_agent': info['ua'], 'cookie_count': len(cookies())})

        if options.get('hidden_test'):
            accept()
        for line in sys.stdin:
            request = json.loads(line)
            if request['action'] == 'close':
                break
            if request['action'] == 'accept':
                if not accepted:
                    accept()
                continue
            if request['action'] == 'network':
                if engine == 'selenium':
                    for event in driver.get_log('performance'):
                        try:
                            message = json.loads(event['message'])['message']
                            response = message['params'].get('response', {})
                            if message['method'] != 'Network.responseReceived' or message['params'].get('type') not in ('XHR', 'Fetch') or not same_site(url, response.get('url', '')):
                                continue
                            body = driver.execute_cdp_cmd('Network.getResponseBody', {'requestId': message['params']['requestId']})
                            raw = body['body']
                            if body.get('base64Encoded'):
                                import base64
                                raw = base64.b64decode(raw).decode()
                            if len(raw) <= 256 * 1024:
                                network.append(network_row(response['url'], response['status'], json.loads(raw)))
                        except Exception:
                            pass
                    del network[:-20]
                send({'ok': True, 'network': network})
                continue
            try:
                if not accepted:
                    raise ValueError('请先完成网页验证')
                target = validate_url(request['url'])
                if not same_site(url, target):
                    raise ValueError('当前会话不能访问其他站点')
                navigate(target, '' if request.get('actions') else request.get('selector', ''))
                if request.get('actions'):
                    apply_actions(request['actions'], request.get('selector', ''))
                info = capture()
                if len(info['html'].encode()) > LIMIT:
                    raise ValueError('网页超过 6MB')
                if not same_site(url, current()):
                    raise ValueError('网页跳转到其他站点，已停止采集')
                send({'ok': True, 'url': current(), 'html': info['html']})
            except Exception as e:
                send({'ok': False, 'error': str(e)})
    except Exception as e:
        send({'ok': False, 'error': engine + ' 无法启动：' + str(e)})
    finally:
        if driver:
            driver.quit()
        if browser:
            browser.close()
        if owner:
            owner.stop()
