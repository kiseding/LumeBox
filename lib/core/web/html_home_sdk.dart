import 'dart:convert';

/// Injected before the imported page's scripts. No SDK is installed in ordinary
/// remote web homes. fetch is only used for this session's loopback RPC.
String htmlHomeSdk(
  String endpoint,
  Map<String, dynamic> storage,
  Map<String, dynamic> viewport,
) {
  String json(Object? value) =>
      jsonEncode(value)
          .replaceAll('<', r'\u003c')
          .replaceAll('\u2028', r'\u2028')
          .replaceAll('\u2029', r'\u2029');
  return '''(function(){
    'use strict';
    var endpoint=${json(endpoint)}, initial=${json(storage)}, viewport=${json(viewport)};
    async function rpc(method, args) {
      var response=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({method:method,args:args||{}})});
      var packet=await response.json();
      if(!response.ok||packet.error)throw new Error(packet.error||('HTTP '+response.status));
      return packet.result;
    }
    function publish(value){
      viewport=Object.assign({},viewport,value||{});
      var style=document.documentElement.style;
      ['Top','Bottom','Left','Right'].forEach(function(side){
        style.setProperty('--fm-safe-'+side.toLowerCase(),(viewport['safe'+side]||0)+'px');
      });
      style.setProperty('--fm-status-bar-height',(viewport.statusBarHeight||0)+'px');
      style.setProperty('--fm-chrome-mode',viewport.chromeMode||'normal');
      window.dispatchEvent(new CustomEvent('fmviewport',{detail:viewport}));
      return viewport;
    }
    window.__lumeHomeViewport=publish;
    var storageWrites=Promise.resolve();
    function persist(method,args){
      storageWrites=storageWrites.then(function(){return rpc(method,args);}).catch(function(){});
    }
    try {
      var storage=window.localStorage, proto=Object.getPrototypeOf(storage);
      var set=proto.setItem, remove=proto.removeItem, clear=proto.clear;
      clear.call(storage);
      Object.keys(initial).forEach(function(key){set.call(storage,key,initial[key]);});
      proto.setItem=function(key,value){
        set.call(this,key,value);
        if(this===storage)persist('storage.set',{key:String(key),value:String(value)});
      };
      proto.removeItem=function(key){
        remove.call(this,key);
        if(this===storage)persist('storage.remove',{key:String(key)});
      };
      proto.clear=function(){
        clear.call(this);
        if(this===storage)persist('storage.clear',{});
      };
    } catch(e) {}
    window.fm={
      req:async function(url,options){
        try{return await rpc('request',{url:String(url),options:options||{}});}
        catch(e){return {ok:false,status:0,body:'',error:e.message,headers:{}};}
      },
      res:function(url,options){
        return endpoint.replace(/rpc\$/, 'resource')+'?url='+encodeURIComponent(url)+
          '&headers='+encodeURIComponent(JSON.stringify((options||{}).headers||{}));
      },
      play:function(url,title,options){
        return rpc('play',{url:String(url),title:title||'',options:options||{}});
      },
      vodInline:async function(detail){
        var episodes=detail.episodes||[], episode=episodes.find(function(e){return e.name===detail.mark;})||episodes[0];
        if(!episode)throw new Error('没有可播放的剧集');
        var resolved=window.__fmWebHomeInlineResolver?
          await window.__fmWebHomeInlineResolver(episode):episode;
        if(typeof resolved==='string')resolved={url:resolved};
        return rpc('play',{url:resolved.url||episode.url,title:detail.vod_name||episode.name||'',
          options:{headers:resolved.headers||episode.headers||{},format:resolved.format||episode.format||''}});
      },
      cache:{
        get:function(key,scope){return rpc('cache.get',{key:String(key),scope:scope||''});},
        set:function(key,value,scope){return rpc('cache.set',{key:String(key),value:value,scope:scope||''});},
        remove:function(key,scope){return rpc('cache.remove',{key:String(key),scope:scope||''});}
      },
      config:function(){return Promise.resolve({driveCheck:false,webHome:true});},
      pan:{
        check:function(items){return Promise.resolve({results:items.map(function(){return {state:'uncertain'};})});},
        play:function(item){return rpc('play',{url:'push://'+item.url,title:item.title||'',options:{password:item.password||''}});}
      },
      ui:{
        getViewport:function(){return viewport;},
        setChrome:async function(options){return publish(await rpc('chrome',options||{}));},
        restoreChrome:async function(){return publish(await rpc('chrome',{mode:'normal'}));}
      }
    };
    publish(viewport);
    window.dispatchEvent(new Event('fmsdk'));
  })();''';
}
