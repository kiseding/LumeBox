import 'dart:convert';

/// Inserted before any author scripts so their native/browser branch is stable.
String webHomeSdk(String prefix, {Map<String, dynamic> storage = const {}}) =>
    '''<script>${_sdk.replaceAll('__PREFIX__', jsonEncode(prefix)).replaceAll('__STORAGE__', jsonEncode(storage).replaceAll('<', r'\u003c'))}</script>''';

const _sdk = r'''
(function(){'use strict';
const base=__PREFIX__;
const stored=__STORAGE__;
let writes=Promise.resolve();
function saveStorage(method,args){writes=writes.then(function(){return call(method,args);}).catch(function(error){console.error('LumeBox storage:',error.message);});}
Object.defineProperty(window,'localStorage',{configurable:true,value:{
  getItem:function(key){return Object.prototype.hasOwnProperty.call(stored,String(key))?stored[String(key)]:null;},
  setItem:function(key,value){stored[String(key)]=String(value);saveStorage('storage.set',{key:String(key),value:String(value)});},
  removeItem:function(key){delete stored[String(key)];saveStorage('storage.remove',{key:String(key)});},
  clear:function(){Object.keys(stored).forEach(function(key){delete stored[key];});saveStorage('storage.clear',{});},
  key:function(index){return Object.keys(stored)[index]||null;},
  get length(){return Object.keys(stored).length;}
}});
async function call(method,args){
  const response=await fetch(base+'/call',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({method:method,args:args||{}})});
  const reply=await response.json();
  if(!reply.ok) throw new Error(reply.error||'兼容接口调用失败');
  return reply.value;
}
let viewport={chromeMode:'normal',safeTop:0,safeBottom:0,safeLeft:0,safeRight:0};
window.__lumeViewport=function(value){viewport=value;window.dispatchEvent(new CustomEvent('fmviewport',{detail:value}));};
const fm={
  req:function(url,opt){return call('req',{url:url,options:opt||{}});},
  res:function(url,opt){if(!url||/^(data:image\/|blob:)/i.test(url))return url||'';return base+'/res?data='+encodeURIComponent(JSON.stringify({url:url,options:opt||{}}));},
  play:function(url,title,opt){return call('play',{url:url,title:title||'',options:opt||{}});},
  vodInline:async function(vod){
    const episodes=vod.episodes||[];
    const ep=episodes.find(function(e){return e.name===vod.mark;})||episodes[0];
    if(!ep) throw new Error('网页未返回剧集');
    const resolved=typeof window.__fmWebHomeInlineResolver==='function'?await window.__fmWebHomeInlineResolver(ep):ep;
    return fm.play(resolved.url||ep.url,vod.vod_name||ep.name,resolved);
  },
  cache:{
    get:function(key,space){return call('cache.get',{key:key,space:space||''});},
    set:function(key,value,space){return call('cache.set',{key:key,value:value,space:space||''});},
    remove:function(key,space){return call('cache.remove',{key:key,space:space||''});}
  },
  config:function(){return Promise.resolve({driveCheck:false});},
  pan:{
    play:function(value){return call('pan.play',value);},
    check:function(values){return Promise.resolve({results:values.map(function(){return {state:'uncertain'};})});}
  },
  ui:{
    setChrome:function(value){viewport.chromeMode=value.mode||'normal';return call('ui.chrome',value);},
    restoreChrome:function(){return call('ui.chrome',{mode:'normal'});},
    getViewport:function(){return viewport;}
  }
};
window.fm=fm;
document.documentElement.classList.add('fm-native');
window.dispatchEvent(new Event('fmsdk'));
})();
''';

String injectWebHomeSdk(
  String html,
  String prefix, {
  Map<String, dynamic> storage = const {},
}) {
  final script = webHomeSdk(prefix, storage: storage);
  final head = RegExp(r'<head\b[^>]*>', caseSensitive: false).firstMatch(html);
  if (head != null) return html.replaceRange(head.end, head.end, script);
  final root = RegExp(r'<html\b[^>]*>', caseSensitive: false).firstMatch(html);
  if (root != null) {
    return html.replaceRange(root.end, root.end, '<head>$script</head>');
  }
  return '$script$html';
}
