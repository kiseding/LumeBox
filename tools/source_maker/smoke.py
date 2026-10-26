"""Check the shipped Tk, HTML parser, QuickJS and runtime asset without network."""
import json
from pathlib import Path


def smoke(report):
    from app import App
    from core import TARGETS, discover, generate, target_config
    from exports import export_source
    from verifier import execute

    class Fixture:
        def get(self, url):
            return url, '<title>打包验证</title><a href="/book/1"><img src="/cover.jpg" alt="验证作品"></a>'

    app = None
    try:
        config, rows, _ = discover('https://fixture.example/', 'audio', Fixture())
        app = App()
        app.attributes('-alpha', 0)
        app.load_config(config)
        app.show_rows(rows)
        app.update()
        layouts = []
        for geometry in ('1160x820', '960x720'):
            app.geometry(geometry)
            app.update()
            for button in (app.generate_btn, app.verify_btn, app.export_btn):
                x, y = button.winfo_rootx() - app.winfo_rootx(), button.winfo_rooty() - app.winfo_rooty()
                assert button.winfo_ismapped(), button['text']
                assert 0 <= x and x + button.winfo_width() <= app.winfo_width(), (geometry, button['text'], x)
                assert 0 <= y and y + button.winfo_height() <= app.winfo_height(), (geometry, button['text'], y)
            layouts.append(geometry)
        app.prepare(show_preview=False)
        assert app.artifact and app.artifact[2].startswith(b'// LumeSource:')
        assert 'disabled' in app.export_btn.state(), 'Unverified source must not be exportable'
        app.validated_signature = app.artifact[0]
        app.refresh_export()
        assert 'disabled' not in app.export_btn.state()
        app.fields['name'].set('修改后需要重新生成')
        assert app.artifact is None and 'disabled' in app.export_btn.state()
        script = generate(app.collect())
        value = execute(script, 'LumeSource.list({page:1})', Fixture())
        assert value['items'][0]['title'] == '验证作品'
        assert value['items'][0]['id'] == 'https://fixture.example/book/1'
        formats = {}
        for label, target in TARGETS.items():
            candidate = target_config(config, target)
            if target in ('python', 'kazumi'):
                candidate.update(mode='maccms', api='https://fixture.example/api')
            extension, raw, _ = export_source(candidate, rows)
            assert raw
            if target == 'python':
                compile(raw, 'export.py', 'exec')
            formats[label] = extension
        import tempfile
        from adaptive_rules import AdaptiveFetcher, AdaptiveProfiles
        class Cards:
            def get(self, url):
                return url, '<title>Adaptive fixture</title><article class="video-card"><a href="/item/1">Lesson</a><img src="/cover.jpg"></article>'
        with tempfile.TemporaryDirectory() as directory:
            profiles = AdaptiveProfiles(directory)
            try:
                fetcher = AdaptiveFetcher(Cards(), profiles)
                adaptive_config, adaptive_rows, _ = discover('https://fixture.example/', 'video', fetcher)
                assert profiles.learn(adaptive_config, adaptive_rows, fetcher) == 1
                changed = '<title>Adaptive fixture</title><article class="changed-card"><a href="/item/1">Lesson</a><img src="/cover.jpg"></article>'
                selector, nodes = profiles.recover(changed, adaptive_config['url'], 'listSelector')
                assert selector == 'article.changed-card' and nodes
            finally:
                profiles.close()
        from app import ENGINES
        Path(report).write_text(json.dumps({'ok': True, 'gui': app.title(), 'items': value['items'], 'formats': formats, 'layouts': layouts, 'conversion_and_stale_export': True, 'adaptive_relocation': True, 'engine_options':len(ENGINES), 'source_bytes': len(script.encode())}, ensure_ascii=False, indent=2), encoding='utf-8')
        return True
    except Exception as e:
        import traceback
        Path(report).write_text(json.dumps({'ok': False, 'error': str(e), 'traceback':traceback.format_exc()}, ensure_ascii=False), encoding='utf-8')
        return False
    finally:
        if app:
            app.destroy()
