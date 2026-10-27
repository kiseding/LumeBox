"""Native Windows GUI. Fetching stays on a worker; Tk runs only on the main thread."""
import json
import os
import queue
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from core import TARGETS, Fetcher, discover, generate, html_items, target_config, source_filename
from exports import export_source

ENGINES = {'内置浏览器': 'webview', 'Playwright': 'playwright', 'Selenium': 'selenium',
    'Scrapling HTTP': 'scrapling-fetcher', 'Scrapling 异步 HTTP': 'scrapling-async',
    'Scrapling HTTP 会话': 'scrapling-session', 'Scrapling 异步 HTTP 会话': 'scrapling-async-session',
    'Scrapling 浏览器': 'scrapling-browser', 'Scrapling 异步浏览器': 'scrapling-async-browser',
    'Scrapling 浏览器会话': 'scrapling-browser-session', 'Scrapling 异步浏览器会话': 'scrapling-async-browser-session'}


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title('LumeBox 制源工坊 0.5 · Windows')
        self.geometry('1160x820')
        self.minsize(960, 720)
        self.configure(bg='#f4f6fa')
        self.events = queue.Queue()
        self.config_data = None
        self.rows = []
        self.artifact = None
        self.validated_signature = None
        self.busy = False
        self.browser = None
        self.fetcher = Fetcher()
        self.browser_actions = {}
        self.updates = queue.Queue()
        self.batch_stop = None
        from adaptive_rules import AdaptiveProfiles
        self.adaptive_store = AdaptiveProfiles()
        self.adaptive_enabled = True
        self.protocol('WM_DELETE_WINDOW', self.close_app)
        self.output_dir = Path.home() / 'Documents' / 'LumeBox Sources'
        style = ttk.Style(self)
        style.theme_use('clam')
        style.configure('.', font=('Microsoft YaHei UI', 10), background='#f4f6fa')
        style.configure('TButton', padding=(14, 8))
        style.configure('Accent.TButton', foreground='white', background='#4d5eea')
        style.configure('Treeview', rowheight=32, background='white', fieldbackground='white')
        style.configure('TEntry', padding=6)
        shell = ttk.Frame(self, padding=24)
        shell.pack(fill='both', expand=True)
        # Reserve the action bar first. Expanding panels must never hide conversion.
        actions = ttk.Frame(shell)
        actions.pack(side='bottom', fill='x', pady=(12, 0))
        self.conversion_status = tk.StringVar(value='流程：识别链接 → 生成源 → 验证源 → 导出文件')
        ttk.Label(actions, textvariable=self.conversion_status, foreground='#4d5eea').pack(anchor='w', pady=(0, 8))
        action_row = ttk.Frame(actions)
        action_row.pack(fill='x')
        ttk.Label(shell, text='LumeBox 制源工坊', font=('Microsoft YaHei UI', 23, 'bold')).pack(anchor='w')
        ttk.Label(shell, text='1 识别网页　→　2 生成源代码　→　3 验证与导出', foreground='#68738a').pack(anchor='w', pady=(4, 18))
        bar = ttk.Frame(shell)
        bar.pack(fill='x')
        self.url = tk.StringVar()
        entry = ttk.Entry(bar, textvariable=self.url, font=('Microsoft YaHei UI', 12))
        entry.pack(side='left', fill='x', expand=True)
        entry.bind('<Return>', lambda _: self.analyze())
        self.category = tk.StringVar(value='视频')
        target_box = ttk.Combobox(bar, textvariable=self.category, values=list(TARGETS), state='readonly', width=10)
        target_box.pack(side='left', padx=10)
        target_box.bind('<<ComboboxSelected>>', lambda _: self.target_changed())
        self.analyze_btn = ttk.Button(bar, text='开始识别', style='Accent.TButton', command=self.analyze)
        self.analyze_btn.pack(side='left')
        self.browser_btn = ttk.Button(bar, text='连接所选引擎', command=self.verify_in_browser)
        self.browser_btn.pack(side='left', padx=(8, 0))
        browser_row = ttk.Frame(shell)
        browser_row.pack(fill='x', pady=(6, 0))
        self.browser_engine = tk.StringVar(value='内置浏览器')
        ttk.Combobox(browser_row, textvariable=self.browser_engine, values=list(ENGINES), state='readonly', width=26).pack(side='left')
        ttk.Button(browser_row, text='已验证，继续', command=self.accept_browser).pack(side='left', padx=8)
        ttk.Button(browser_row, text='结束浏览器会话', command=self.end_browser).pack(side='left')
        batch_btn = ttk.Button(browser_row, text='批量制源 · Scrapy', command=self.batch_dialog)
        batch_btn.pack(side='right')
        ttk.Button(browser_row, text='暂停批量', command=lambda: self.batch_stop.set() if self.batch_stop else None).pack(side='right', padx=6)
        adaptive_row = ttk.Frame(shell)
        adaptive_row.pack(fill='x', pady=(6, 0))
        adaptive_value = tk.BooleanVar(value=True)
        ttk.Checkbutton(adaptive_row, text='Scrapling 改版自动适应 · 验证通过后学习', variable=adaptive_value,
            command=lambda: setattr(self, 'adaptive_enabled', adaptive_value.get())).pack(side='left')
        ttk.Button(adaptive_row, text='忘记本站样本', command=lambda: self.attempt(self.forget_profile)).pack(side='left', padx=8)
        ttk.Button(adaptive_row, text='浏览器操作 / 接口记录', command=self.browser_options_dialog).pack(side='right')
        self.status = tk.StringVar(value='准备就绪 · 支持静态 HTML / 苹果 CMS · 生成后不需要本工具常驻')
        ttk.Label(shell, textvariable=self.status, wraplength=1070, foreground='#4d5eea').pack(anchor='w', pady=14)
        self.progress = ttk.Progressbar(shell, mode='indeterminate')
        self.progress.pack(fill='x', pady=(0, 10))
        panes = ttk.Panedwindow(shell, orient='horizontal')
        panes.pack(fill='both', expand=True)
        left, right_pane = ttk.Frame(panes), ttk.Frame(panes, padding=(18, 0, 0, 0))
        panes.add(left, weight=3)
        panes.add(right_pane, weight=2)
        # Source settings scroll independently on small windows and high DPI.
        settings_canvas = tk.Canvas(right_pane, highlightthickness=0, bg='#f4f6fa', width=350)
        settings_scroll = ttk.Scrollbar(right_pane, orient='vertical', command=settings_canvas.yview)
        settings_canvas.configure(yscrollcommand=settings_scroll.set)
        settings_scroll.pack(side='right', fill='y')
        settings_canvas.pack(side='left', fill='both', expand=True)
        right = ttk.Frame(settings_canvas)
        settings_window = settings_canvas.create_window((0, 0), window=right, anchor='nw')
        right.bind('<Configure>', lambda _: settings_canvas.configure(scrollregion=settings_canvas.bbox('all')))
        settings_canvas.bind('<Configure>', lambda e: settings_canvas.itemconfigure(settings_window, width=e.width))
        self.settings_canvas = settings_canvas
        ttk.Label(left, text='抓取预览', font=('Microsoft YaHei UI', 13, 'bold')).pack(anchor='w', pady=(0, 10))
        treeframe = ttk.Frame(left)
        treeframe.pack(fill='both', expand=True)
        self.tree = ttk.Treeview(treeframe, columns=('title', 'url'), show='headings', selectmode='browse')
        self.tree.heading('title', text='标题')
        self.tree.heading('url', text='条目地址 / ID')
        self.tree.column('title', width=210)
        self.tree.column('url', width=300)
        scroll = ttk.Scrollbar(treeframe, command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side='left', fill='both', expand=True)
        scroll.pack(side='right', fill='y')
        ttk.Label(left, text='记录与测试结果', foreground='#68738a').pack(anchor='w', pady=(12, 5))
        self.log = tk.Text(left, height=7, wrap='word', font=('Microsoft YaHei UI', 9), relief='flat', padx=10, pady=8, state='disabled')
        self.log.pack(fill='x')
        ttk.Label(right, text='源设置', font=('Microsoft YaHei UI', 13, 'bold')).pack(anchor='w', pady=(0, 10))
        self.fields = {}
        labels = [('name', '源名称'), ('id', '源 ID'), ('list', '列表网址 · 可用 {page}'), ('search', '搜索网址 · 可用 {keyword} 和 {page}'), ('links', '列表链接规则 · 正则表达式'), ('categoryLinks', '分类链接规则 · 正则表达式'), ('chapters', '章节 / 选集链接规则 · 正则表达式'), ('contentId', '漫画 / 图片内容元素 ID · 可选')]
        for key, label in labels:
            ttk.Label(right, text=label, foreground='#68738a').pack(anchor='w', pady=(5, 2))
            value = tk.StringVar()
            ttk.Entry(right, textvariable=value).pack(fill='x')
            self.fields[key] = value
        ttk.Button(right, text='编辑 Kazumi XPath', command=self.edit_kazumi).pack(anchor='w', pady=(8, 0))
        ttk.Button(right, text='高级解析规则 · CSS', command=self.edit_rules).pack(anchor='w', pady=(6, 0))
        ttk.Button(right, text='查看各引擎功能范围', command=self.show_capabilities).pack(anchor='w', pady=(6, 0))
        self.target_note = tk.StringVar(value='视频 → LumeSource JS · 实时抓取与直链播放')
        ttk.Label(right, textvariable=self.target_note, wraplength=360, foreground='#68738a').pack(anchor='w', pady=8)
        self.buttons = []
        for label, callback in [('重新预览', self.preview), ('保存工程', self.save_project), ('打开工程', self.open_project)]:
            b = ttk.Button(action_row, text=label, command=callback)
            b.pack(side='left', padx=(0, 8))
            self.buttons.append(b)
        self.export_btn = ttk.Button(action_row, text='导出源', style='Accent.TButton', command=self.export, state='disabled')
        self.export_btn.pack(side='right')
        self.verify_btn = ttk.Button(action_row, text='验证源', command=self.test_first)
        self.verify_btn.pack(side='right', padx=8)
        self.generate_btn = ttk.Button(action_row, text='生成源', style='Accent.TButton', command=self.prepare)
        self.generate_btn.pack(side='right')
        self.buttons.extend([self.verify_btn, self.generate_btn])
        self.buttons.append(self.browser_btn)
        self.buttons.append(batch_btn)
        for value in self.fields.values():
            value.trace_add('write', lambda *_: self.invalidate())
        self.url.trace_add('write', lambda *_: self.invalidate())
        self.after(100, self.drain)

    def note(self, message):
        self.log.configure(state='normal')
        self.log.insert('end', message + '\n')
        self.log.see('end')
        self.log.configure(state='disabled')

    def close_app(self):
        if self.browser:
            self.browser.close()
        self.adaptive_store.close()
        self.destroy()

    def active_fetcher(self):
        base = self.browser if self.browser else self.fetcher
        if self.adaptive_enabled:
            from adaptive_rules import AdaptiveFetcher
            return AdaptiveFetcher(base, self.adaptive_store)
        return base

    def forget_profile(self):
        from core import validate_url
        self.adaptive_store.forget(validate_url(self.url.get()))
        self.note('已忘记本站已学习的解析样本，下次通过验证后会重新学习。')

    def browser_options_dialog(self):
        dialog = tk.Toplevel(self)
        dialog.title('浏览器操作与接口响应')
        dialog.geometry('660x420')
        ttk.Label(dialog, text='用于动态列表加载；设置会保存到工程和浏览器 JS 源。\n每页最多点击 3 次、滚动 3 次。HTTP 模式不执行浏览器操作。', wraplength=600).pack(padx=16, pady=12)
        values = {}
        for key, label in [('click','加载更多按钮 CSS（可留空）'), ('clicks','点击次数 0～3'), ('scroll','滚动次数 0～3'), ('wait','操作后等待出现的 CSS（可留空）')]:
            ttk.Label(dialog, text=label).pack(anchor='w', padx=16)
            values[key] = tk.StringVar(value=str(self.browser_actions.get(key, 0 if key in ('clicks', 'scroll') else '')))
            ttk.Entry(dialog, textvariable=values[key]).pack(fill='x', padx=16, pady=(0, 6))
        def save():
            data = {key: value.get().strip() for key, value in values.items()}
            for key in ('clicks','scroll'):
                data[key] = int(data[key])
                if not 0 <= data[key] <= 3:
                    raise ValueError('次数必须在 0～3 之间')
            self.browser_actions = data
            if self.browser:
                self.browser.actions = data
            self.invalidate()
            dialog.destroy()
        def inspect():
            if not self.browser:
                raise ValueError('请先连接 Playwright、Selenium 或 Scrapling 浏览器')
            def done(rows):
                self.note('接口记录只用于辅助适配，不会自动写入源：\n' + json.dumps(rows, ensure_ascii=False, indent=2))
                self.status.set(f'已读取 {len(rows)} 条 JSON 接口响应，见日志；常见敏感字段已隐藏')
            self.work(self.browser.network, done)
        row = ttk.Frame(dialog)
        row.pack(fill='x', padx=16, pady=12)
        ttk.Button(row, text='读取接口响应（不含请求头）', command=lambda: self.attempt(inspect)).pack(side='left')
        ttk.Button(row, text='保存操作', command=lambda: self.attempt(save)).pack(side='right')

    def show_capabilities(self):
        dialog = tk.Toplevel(self)
        dialog.title('已接入的能力与使用范围')
        dialog.geometry('800x530')
        text = tk.Text(dialog, wrap='word', padx=18, pady=18, font=('Microsoft YaHei UI', 11))
        text.pack(fill='both', expand=True)
        text.insert('1.0', '''Playwright / Selenium
真实浏览器、手动登录与验证、会话 Cookie、点击加载更多、滚动、等待元素、同站 JSON 接口响应记录。

Scrapling 0.5
Fetcher、AsyncFetcher、HTTP 同步/异步会话；StealthyFetcher 同步/异步浏览器抓取与 StealthySession / AsyncStealthySession。浏览器支持同样的页面操作与接口记录，验证仍由你手动完成。

自动适应
验证通过后学习列表卡片、章节和漫画图片区域。以后重新识别同一网址时尝试匹配变化的结构，并生成普通 CSS；无法可靠恢复或源验证失败时阻止导出。学习数据保存在本机，已导入手机的源不会自行安装 Scrapling 或自动更新。

Scrapy
最多 10 个站点的公开入口采集；可调并发、间隔、重试，自动限速、robots 规则、进度、暂停与任务文件续作；已导出文件校验完整后复用。当前请求完成后暂停后续处理。

转换
视频优先 JS、静态失败尝试 PY；漫画目前导出 JS。分类、筛选、分页、封面、详情、选集和内容都需要对应规则。抓取成功不等于源已可用，检查媒体地址不等于实际起播。

范围
这是制源工作流的集成，并非所有框架 API 的图形化编辑器。分布式部署、远程爬虫集群、MCP 服务、任意专用加密播放器等没有接入。''')
        text.configure(state='disabled')

    def accept_browser(self):
        if self.browser and not self.browser.ready:
            self.browser.accept()
            self.status.set('正在检查当前网页；如验证未通过，请继续在浏览器中操作')

    def end_browser(self):
        if self.busy:
            self.note('请等待当前操作结束；验证时可以直接关闭浏览器窗口取消。')
            return
        if self.browser:
            self.browser.close()
            self.browser = None
            self.invalidate()
            self.note('浏览器会话已结束。动态源再次测试前需重新连接所选引擎并完成验证。')

    def batch_dialog(self):
        dialog = tk.Toplevel(self)
        dialog.title('批量制源 · 最多 10 个公开站点')
        dialog.geometry('650x420')
        ttk.Label(dialog, text='每行一个列表网址。按当前模块识别、验证，通过的才导出。\n需要登录或手动验证的站点，请返回主界面单独处理。', wraplength=600).pack(padx=16, pady=16)
        urls = tk.Text(dialog, height=10)
        urls.pack(fill='both', expand=True, padx=16)
        settings_frame = ttk.Frame(dialog)
        settings_frame.pack(fill='x', padx=16, pady=8)
        settings_values = {}
        for key, label, default in [('concurrency','并发 1～4','2'), ('delay','间隔秒 .3～5','.5'), ('retries','失败重试 0～2','1')]:
            ttk.Label(settings_frame, text=label).pack(side='left')
            settings_values[key] = tk.StringVar(value=default)
            ttk.Entry(settings_frame, textvariable=settings_values[key], width=4).pack(side='left', padx=(2, 8))
        def run():
            values = list(dict.fromkeys(u.strip() for u in urls.get('1.0', 'end').splitlines() if u.strip()))
            from core import validate_url
            for value in values:
                validate_url(value)
            if not 1 <= len(values) <= 10:
                raise ValueError('请输入 1～10 个网址')
            directory = filedialog.askdirectory(parent=dialog, title='选择批量导出目录')
            if not directory:
                return
            target = TARGETS[self.category.get()]
            settings = {'concurrency': int(settings_values['concurrency'].get()), 'delay': float(settings_values['delay'].get()), 'retries': int(settings_values['retries'].get())}
            self.batch_stop = threading.Event()
            dialog.destroy()
            from batch_crawler import batch_convert
            def done(reports):
                passed = sum(r['ok'] for r in reports)
                state = '已暂停，可选择相同目录继续' if self.batch_stop.is_set() else '完成'
                self.status.set(f'批量{state}：{passed}/{len(reports)} 个通过，结果在 {directory}')
                self.note(json.dumps(reports, ensure_ascii=False, indent=2))
            self.work(lambda: batch_convert(values, target, directory, settings, self.batch_stop, self.updates.put), done)
        ttk.Button(dialog, text='选择目录并开始', command=lambda: self.attempt(run)).pack(pady=16)
        ttk.Button(dialog, text='暂停当前批量任务', command=lambda: self.batch_stop.set() if self.batch_stop else None).pack()

    def verify_in_browser(self):
        from core import validate_url
        def start():
            url = validate_url(self.url.get())
            from browser_session import BrowserSession
            target = TARGETS[self.category.get()]
            engine = ENGINES[self.browser_engine.get()]
            def run():
                if self.browser:
                    self.browser.close()
                    self.browser = None
                browser = BrowserSession(url, engine=engine, on_open=lambda session: setattr(self, 'browser', session))
                self.browser = browser
                browser.actions = dict(self.browser_actions)
                try:
                    c, rows, message = discover(browser.url, target, self.active_fetcher())
                    c['useBrowser'] = browser.browser_mode
                    return c, rows, message
                except Exception:
                    browser.close()
                    self.browser = None
                    raise
            def done(result):
                c, rows, message = result
                self.load_config(c)
                self.show_rows(rows)
                self.note('采集引擎已连接。HTTP 模式直接读取页面；浏览器模式支持动态网页。Cookie 不写入源文件，手机 App 上需重新验证。')
                self.note(message)
            self.work(run, done)
            self.status.set('请在新浏览器窗口手动验证，再返回本工具点击「已验证，继续」')
        self.attempt(start)

    def invalidate(self):
        self.artifact = None
        self.validated_signature = None
        self.export_btn.configure(state='disabled')
        self.conversion_status.set('流程：识别链接 → 生成源 → 验证源 → 导出文件')

    def fingerprint(self, config):
        return json.dumps([config, self.rows], ensure_ascii=False, sort_keys=True)

    def refresh_export(self):
        ready = self.artifact and self.artifact[0] == self.validated_signature
        self.export_btn.configure(state='normal' if ready else 'disabled')

    def prepare(self, show_preview=True):
        def convert():
            c = self.collect()
            extension, data, route = export_source(c, self.rows)
            self.artifact = (self.fingerprint(c), extension, data, route)
            self.refresh_export()
            checked = '抽样验证已通过' if self.validated_signature == self.artifact[0] else '草稿，验证通过后才能导出'
            filename = source_filename(c, extension)
            self.conversion_status.set(f'已生成 {filename} · {len(data):,} 字节 · {checked}')
            self.note(f'源代码草稿已生成：{extension}。这不代表网站已适配；需抽样验证作品、选集和内容后才能导出。\n导入位置：{route}')
            if show_preview:
                self.show_source(filename, data, extension, route)
        self.attempt(convert)

    def show_source(self, filename, data, extension, route):
        dialog = tk.Toplevel(self)
        dialog.title('源已生成 · ' + filename)
        dialog.geometry('900x640')
        ttk.Label(dialog, text=filename + ' · 尚需验证抓取链路', font=('Microsoft YaHei UI', 13, 'bold')).pack(anchor='w', padx=16, pady=12)
        ttk.Label(dialog, text='导入位置：' + route, wraplength=850).pack(anchor='w', padx=16)
        frame = ttk.Frame(dialog, padding=16)
        frame.pack(fill='both', expand=True)
        code = tk.Text(frame, wrap='none', font=('Consolas', 10), relief='flat')
        scroll = ttk.Scrollbar(frame, command=code.yview)
        code.configure(yscrollcommand=scroll.set)
        scroll.pack(side='right', fill='y')
        code.pack(fill='both', expand=True)
        if extension == '.zip':
            import io
            import zipfile
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                display = '猫源 ZIP 文件：\n' + '\n'.join(archive.namelist()) + '\n\n--- index.js ---\n' + archive.read('index.js').decode('utf-8')
        else:
            display = data.decode('utf-8')
        code.insert('1.0', display)
        code.configure(state='disabled')
        buttons = ttk.Frame(dialog, padding=(16, 0, 16, 16))
        buttons.pack(side='bottom', fill='x', before=frame)
        ttk.Button(buttons, text='返回验证', command=dialog.destroy).pack(side='left')
        ttk.Button(buttons, text='导出源文件', style='Accent.TButton', command=self.export).pack(side='right')

    def work(self, fn, done):
        if self.busy:
            return
        self.busy = True
        for b in [self.analyze_btn, self.export_btn] + self.buttons:
            b.configure(state='disabled')
        self.progress.start(12)
        self.status.set('正在抓取，请稍候…')
        def worker():
            try:
                self.events.put((done, fn(), None))
            except Exception as e:
                self.events.put((done, None, str(e)))
        threading.Thread(target=worker, daemon=True).start()

    def drain(self):
        while True:
            try:
                self.note(self.updates.get_nowait())
            except queue.Empty:
                break
        try:
            done, value, error = self.events.get_nowait()
            self.busy = False
            self.progress.stop()
            for b in [self.analyze_btn, self.export_btn] + self.buttons:
                b.configure(state='normal')
            self.refresh_export()
            if error:
                self.validated_signature = None
                self.refresh_export()
                if self.artifact:
                    self.conversion_status.set('验证未通过，已阻止导出 · 可保存工程继续适配')
                self.status.set('操作未完成：' + error)
                self.note(error)
            else:
                try:
                    done(value)
                except Exception as e:
                    self.status.set('操作未完成：' + str(e))
                    self.note(str(e))
        except queue.Empty:
            pass
        self.after(100, self.drain)

    def show_rows(self, rows):
        self.invalidate()
        self.rows = rows
        self.tree.delete(*self.tree.get_children())
        for row in rows:
            self.tree.insert('', 'end', values=(row['title'], row['id']))
        self.status.set(f'抓取到 {len(rows)} 个候选链接 · 尚未证明是作品 · 下一步点击底部「生成源」')

    def load_config(self, config):
        if config.get('category') == 'novel':
            raise ValueError('旧工程是文字小说格式，当前 App 不支持；请重新选择有声小说并识别网址')
        self.config_data = config
        self.browser_actions = dict(config.get('browserActions', self.browser_actions))
        if self.browser:
            self.browser.actions = dict(self.browser_actions)
        self.url.set(config['url'])
        target = config.get('target', config['category'])
        self.category.set(next(k for k, v in TARGETS.items() if v == target))
        for k, v in self.fields.items():
            v.set(config.get(k, ''))
        self.target_changed()

    def target_changed(self):
        if hasattr(self, 'export_btn'):
            self.invalidate()
        notes = {'audio': '有声小说 → JS · category=video / kind=audio',
                 'comic': '漫画 → JS · category=comic / 图片章节',
                 'images': '图片 → JS · category=comic / 详情即图集；导入后可分组为美图',
                 'video': '视频 → JS · category=video / 视频直链',
                 'python': 'PY 视频源：支持公开 HTML 与苹果 CMS。视频默认先尝试 JS，失败再尝试 PY。漫画目前导出 JS。',
                 'module': '模块 → .cjs · CommonJS 源对象导出',
                 'cat': '猫源 → ZIP · Node start() / index.config.js / MD5',
                 'kazumi': 'Kazumi → JSON · XPath 或 JSON API 规则',
                 'web': '网页 → HTML · 导航快照，点击访问原网页'}
        self.target_note.set(notes[TARGETS[self.category.get()]])

    def edit_rules(self):
        if not self.config_data:
            return
        dialog = tk.Toplevel(self)
        dialog.title('高级解析规则 · 保存后重新生成和验证')
        dialog.geometry('760x620')
        ttk.Label(dialog, text='支持标签、.class、#id、[属性]、后代、> 和逗号；留空使用通用解析。', wraplength=700).pack(anchor='w', padx=18, pady=10)
        values = {}
        for key, label in [('listSelector','列表卡片'), ('linkSelector','卡片内作品链接'), ('titleSelector','卡片内标题'), ('coverSelector','卡片内封面'), ('chapterSelector','详情页章节链接'), ('imageSelector','章节内漫画图片'), ('nextSelector','下一页链接')]:
            ttk.Label(dialog, text=label).pack(anchor='w', padx=18, pady=(5, 1))
            values[key] = tk.StringVar(value=self.config_data.get(key, ''))
            ttk.Entry(dialog, textvariable=values[key]).pack(fill='x', padx=18)
        def save():
            self.config_data.update({k: v.get().strip() for k, v in values.items()})
            self.invalidate()
            self.note('解析规则已保存，需重新预览、生成并验证。')
            dialog.destroy()
        ttk.Button(dialog, text='保存规则', command=save).pack(pady=14)

    def edit_kazumi(self):
        if not self.config_data:
            return
        dialog = tk.Toplevel(self)
        dialog.title('Kazumi XPath 规则')
        dialog.geometry('700x240')
        values = {}
        for key, label, default in [('searchXPath', '搜索结果链接 XPath', '//a[@href]'), ('chapterXPath', '章节链接 XPath', "//a[contains(@href,'/play/') or contains(@href,'/vodplay/')]")]:
            ttk.Label(dialog, text=label).pack(anchor='w', padx=18, pady=(12, 2))
            values[key] = tk.StringVar(value=self.config_data.get(key, default))
            ttk.Entry(dialog, textvariable=values[key]).pack(fill='x', padx=18)
        def save():
            self.config_data.update({k: v.get().strip() for k, v in values.items()})
            self.invalidate()
            dialog.destroy()
        ttk.Button(dialog, text='保存规则', command=save).pack(pady=18)

    def collect(self):
        if not self.config_data:
            raise ValueError('请先输入网址并识别，或打开已保存的工程')
        if self.url.get().strip() != self.config_data['url']:
            raise ValueError('顶部网址已改变，请点击「开始识别」后再生成该网站的源')
        config = dict(self.config_data)
        if any(self.browser_actions.values()):
            config['browserActions'] = dict(self.browser_actions)
        else:
            config.pop('browserActions', None)
        config.update({k: v.get().strip() for k, v in self.fields.items()})
        config = target_config(config, TARGETS[self.category.get()])
        if config['mode'] == 'maccms' and config['media'] == 'images':
            raise ValueError('视频接口无法作为漫画或图片源')
        generate(config)
        return config

    def analyze(self):
        if not self.browser and self.browser_engine.get() != '内置浏览器':
            self.verify_in_browser()
            return
        url, category = self.url.get(), TARGETS[self.category.get()]
        def done(result):
            config, rows, message = result
            if self.browser:
                config['useBrowser'] = self.browser.browser_mode
            self.load_config(config)
            self.show_rows(rows)
            self.note(message)
        self.work(lambda: discover(url, category, self.active_fetcher()), done)

    def attempt(self, fn):
        try:
            fn()
        except Exception as e:
            messagebox.showerror('无法完成', str(e), parent=self)

    def preview(self):
        def start():
            c = self.collect()
            if c.get('useBrowser') and not self.browser:
                raise ValueError('该工程使用浏览器会话，请先点击「连接所选引擎」')
            def run():
                f = self.active_fetcher()
                if c['mode'] == 'maccms':
                    sep = '&' if '?' in c['api'] else '?'
                    d = json.loads(f.get(c['api'] + sep + 'ac=detail&pg=1')[1])
                    return [{'id': str(v['vod_id']), 'title': v['vod_name'], 'cover': v.get('vod_pic', '')} for v in d.get('list', [])]
                from verifier import execute
                return execute(generate(c), 'LumeSource.list({page:1}).then(function(v){return v.items;})', f)
            self.work(run, self.show_rows)
        self.attempt(start)

    def test_first(self):
        def start():
            c = self.collect()
            if not self.rows and c['target'] != 'web':
                raise ValueError('请先重新预览，得到至少一条内容')
            if c.get('useBrowser') and not self.browser:
                raise ValueError('请先连接所选引擎并完成验证恢复浏览器会话')
            from verifier import verify_with_fallback
            rows = list(self.rows)
            signature = self.fingerprint(c)
            self.validated_signature = None
            self.refresh_export()
            def done(result):
                checked, report = result
                self.status.set('源检查完成 · 验证范围见日志，媒体未实际起播')
                self.note(report)
                if self.fingerprint(self.collect()) == signature:
                    if checked != c:
                        self.load_config(checked)
                        self.prepare(show_preview=False)
                    signature_now = self.fingerprint(self.collect())
                    self.validated_signature = signature_now
                    self.refresh_export()
                    self.conversion_status.set('抽样链路已通过 · 分类/筛选支持情况见日志 · 媒体未实际起播')
            def run():
                fetcher = self.active_fetcher()
                checked, report = verify_with_fallback(c, rows, fetcher)
                if self.adaptive_enabled and hasattr(fetcher, 'pages'):
                    try:
                        count = self.adaptive_store.learn(checked, rows, fetcher)
                        report += f'\nScrapling 已记住 {count} 组规则样本；将来重新识别时尝试适应改版，恢复后仍需验证。'
                    except Exception as error:
                        report += '\n解析验证通过，样本学习未完成：' + str(error)
                return checked, report
            self.work(run, done)
        self.attempt(start)

    def save_project(self):
        def save():
            c = self.collect()
            p = filedialog.asksaveasfilename(parent=self, title='保存制源工程', defaultextension='.json', initialfile=c['id'] + '.project.json', filetypes=[('制源工程', '*.json')])
            if p:
                Path(p).write_text(json.dumps(c, ensure_ascii=False, indent=2), encoding='utf-8')
                self.note('工程已保存：' + p)
        self.attempt(save)

    def open_project(self):
        def load():
            p = filedialog.askopenfilename(parent=self, filetypes=[('制源工程', '*.json')])
            if p:
                c = json.loads(Path(p).read_text(encoding='utf-8-sig'))
                generate(c)
                self.load_config(c)
                self.show_rows([])
                self.note('工程已打开，请重新预览。')
        self.attempt(load)

    def export(self):
        def save():
            c = self.collect()
            if not self.artifact or self.artifact[0] != self.fingerprint(c):
                raise ValueError('请先点击「生成源」。修改规则或重新预览后，需要重新生成')
            if self.validated_signature != self.artifact[0]:
                raise ValueError('该源尚未通过验证，不能导出为可用源。请点击「验证源」；失败时保存工程继续适配')
            _, extension, data, route = self.artifact
            self.output_dir.mkdir(parents=True, exist_ok=True)
            p = filedialog.asksaveasfilename(parent=self, title='导出到 LumeBox', initialdir=self.output_dir, initialfile=source_filename(c, extension), defaultextension=extension, filetypes=[('LumeBox 源文件', '*' + extension)])
            if p:
                Path(p).write_bytes(data)
                self.status.set('导出完成 · ' + route)
                self.note('已导出：' + p)
                messagebox.showinfo('导出完成', '导入位置：' + route + '\n\n' + p, parent=self)
        self.attempt(save)


if __name__ == '__main__':
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == '--engine-check':
        from browser_check import browser_checks
        try:
            results = browser_checks(sys.argv[2])
        except Exception as error:
            results = {'self_check': {'ok': False, 'error': str(error)}}
            Path(sys.argv[2]).write_text(json.dumps(results, ensure_ascii=False), encoding='utf-8')
        sys.exit(0 if all(value['ok'] for value in results.values()) else 1)
    if '--scrapy-worker' in sys.argv:
        from batch_crawler import run_scrapy_worker
        run_scrapy_worker()
        sys.exit(0)
    if '--browser-worker' in sys.argv:
        from browser_session import run_worker
        run_worker()
        sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == '--self-test':
        from smoke import smoke
        sys.exit(0 if smoke(sys.argv[2]) else 1)
    if os.name == 'nt':
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    App().mainloop()
