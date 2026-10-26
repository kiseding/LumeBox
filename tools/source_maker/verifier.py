"""Run generated JavaScript in embedded QuickJS with LumeBox's HTTP contract."""
import base64
import json
import time

import quickjs

from core import Fetcher


def execute(script, expression, fetcher=None):
    fetcher = fetcher or Fetcher()
    context = quickjs.Context()
    context.set_memory_limit(48 * 1024 * 1024)
    context.set_max_stack_size(1024 * 1024)
    started = time.monotonic()

    def fetch(url, selector=''):
        if time.monotonic() - started > 65:
            raise ValueError('测试超过 65 秒，请稍后重试')
        try:
            final, body = fetcher.get(url, selector=selector) if hasattr(fetcher, 'accept') or getattr(fetcher, 'supports_selector', False) else fetcher.get(url)
            return json.dumps({'status': 200, 'url': final, 'body': body})
        except Exception as e:
            # Preserve actionable errors across the Python/JS boundary.
            return json.dumps({'error': str(e)})

    context.add_callable('__fetch', fetch)
    context.add_callable('atob', lambda value: base64.b64decode(value).decode('latin1'))
    context.eval('''
      var __host = {get:async function(url, selector) {
        var r=JSON.parse(__fetch(url,typeof selector==='string'?selector:'')); if(r.error) throw new Error(r.error); return r;
      }};
    ''')
    context.eval(script)
    context.eval('LumeSource.http = __host; LumeSource.web={render:async function(o){var r=await __host.get(o.url,o.waitForSelector||\'\');return {html:r.body,url:r.url};}}; var __result=null, __error=null, __done=false;')
    context.eval('(async function(){try{__result=JSON.stringify(await (' + expression + '));}catch(e){__error=String(e);}finally{__done=true;}})();')
    jobs = 0
    while context.execute_pending_job():
        jobs += 1
        if jobs > 2000 or time.monotonic() - started > 90:
            raise ValueError('测试超时')
    error = context.eval('__error')
    if error:
        raise ValueError(error)
    if not context.eval('__done'):
        raise ValueError('脚本未完成执行')
    return json.loads(context.eval('__result'))


def verify(script, fetcher=None):
    result = execute(script, '''(async function(){
      var stage='分类';
      try {
      var cats = await LumeSource.categories();
      stage='筛选';
      var filters=typeof LumeSource.filters==='function' ? await LumeSource.filters({}) : {groups:[]};
      var groups=filters.groups||[];
      stage='列表';
      var list = await LumeSource.list({page:1});
      if(!list.items.length) throw new Error('列表为空');
      var samples=list.items.slice(0,3), last,covered=0;
      for(var i=0;i<samples.length;i++) {
      var first=samples[i];stage='详情（样本 '+(i+1)+'/'+samples.length+'）';
      var detail = await LumeSource.detail({id:first.id});
      if(!detail || !detail.title) throw new Error('详情没有标题');
      if(first.cover || detail.cover)covered++;
      stage='选集（样本 '+(i+1)+'/'+samples.length+'）';
      var chapters = await LumeSource.chapters({id:first.id});
      if(!chapters.length) throw new Error('没有识别到章节或播放线路');
      stage='内容（样本 '+(i+1)+'/'+samples.length+'）';
      var content = await LumeSource.content({id:first.id,chapterId:chapters[0].id});
      if(content.kind==='images' && !content.images.length) throw new Error('图片为空');
      if((content.kind==='video' || content.kind==='audio') && !content.url) throw new Error('媒体地址为空');
      if(['images','video','audio'].indexOf(content.kind)<0)throw new Error('正文类型不受支持');
      last={categories:cats.filter(function(c){return c.id!==C.url;}).length,filters:groups.length,items:list.items.length,title:detail.title,chapters:chapters.length,kind:content.kind,samples:samples.length,
        size:content.kind==='images' ? content.images.length : content.url};
      }
      if(cats.length && cats[0].id!==C.url || cats.length>1) {
        stage='分类切换';var cat=cats.filter(function(c){return c.id!==C.url;})[0];
        if(cat && !(await LumeSource.list({page:1,categoryId:cat.id})).items.length)throw new Error('分类列表为空');
      }
      if(groups.length) {
        stage='筛选回传';var selected={},group=groups[0], option=group.options.filter(function(o){return o.id;})[0];
        if(option){selected[group.id]=option.id;if(!(await LumeSource.list({page:1,filters:selected})).items.length)throw new Error('筛选列表为空');}
      }
      last.covered=covered;return last;
      } catch(e) {throw new Error(stage+'失败：'+String(e.message||e));}
    })()''', fetcher)
    size = str(result['size']) if result['kind'] == 'images' else '已提取媒体地址（未验证实际播放）'
    category = str(result['categories']) if result['categories'] else '未识别（仅全部）'
    filters = str(result['filters']) if result['filters'] else '未适配'
    cover = f"封面 {result['covered']}/{result['samples']}（仅检查地址，未下载图片）"
    return f"抽样链路通过 {result['samples']} 条：分类 {category} / 筛选 {filters} / 列表 {result['items']} / {cover} / 详情「{result['title']}」 / 章节 {result['chapters']} / 正文 {result['kind']} {size}"


def verify_config(config, rows, fetcher=None):
    from core import generate
    from exports import export_source
    extension, raw, route = export_source(config, rows)
    target = config.get('target', config['category'])
    if target == 'web':
        return f'HTML 导航快照已生成，{len(rows)} 个链接，{len(raw)} 字节。导入位置：{route}。网页打开效果需在 App 中检查。'
    if target == 'python':
        namespace = {}
        exec(compile(raw, 'generated.py', 'exec'), namespace)
        spider = namespace['Spider']()
        if fetcher:
            spider._get = lambda url: fetcher.get(url)[1]
            def api(**params):
                from urllib.parse import urlencode
                url = config['api'] + ('&' if '?' in config['api'] else '?') + urlencode(params)
                return json.loads(fetcher.get(url)[1])
            spider._api = api
        home = spider.homeVideoContent()
        samples = home.get('list', [])[:3]
        if not samples:
            raise ValueError('PY 列表为空')
        for first in samples:
            detail = spider.detailContent([str(first['vod_id'])])['list'][0]
            episode = detail['vod_play_url'].split('$$$')[0].split('#')[0].split('$', 1)[1]
            content = spider.playerContent('', episode, [])
            if not content.get('url'):
                raise ValueError('PY Spider 没有返回媒体地址')
        return f'PY Spider 抽样通过 {len(samples)} 条：列表、详情、选集、媒体地址；未验证实际播放。'
    if target == 'module':
        return verify(raw.decode().replace('module.exports = GeneratedSource;', 'var LumeSource = GeneratedSource;'), fetcher)
    result = verify(generate(config), fetcher)
    if target == 'kazumi':
        result += '\n已生成 Kazumi JSON；XPath 的浏览器解析与实际播放仍需在 App 中验证。'
    elif target == 'cat':
        result += '\n已生成 Node 猫源 ZIP；本次仅检查抓取链路，Node 服务启动需在 App 中验证。'
    return result


def verify_with_fallback(config, rows, fetcher=None):
    from core import target_config
    try:
        return config, verify_config(config, rows, fetcher)
    except Exception as first:
        if config.get('target') != 'video' or config.get('useBrowser'):
            raise
        candidate = target_config(config, 'python')
        try:
            result = verify_config(candidate, rows, fetcher)
        except Exception as second:
            raise ValueError('JS 未通过：' + str(first) + '\nPY 备用方案也未通过：' + str(second)) from second
        return candidate, 'JS 未通过：' + str(first) + '\n已自动尝试 PY 备用方案。' + result
