async function browserDocument(actions, selector) {
  var a=actions||{}, pause=function(ms){return new Promise(function(r){setTimeout(r,ms);});};
  var scroll=Math.max(0,Math.min(3,Number(a.scroll)||0)), clicks=Math.max(0,Math.min(3,Number(a.clicks)||0));
  if(a.click) {
    for(var i=0;i<clicks;i++) {
      var button=document.querySelector(a.click);
      if(!button || button.disabled)break;
      if(button.tagName==='BUTTON' && button.type==='submit' && button.form)throw new Error('制源操作不提交表单，请选择加载更多按钮');
      button.click();await pause(350);
    }
  }
  for(var j=0;j<scroll;j++){window.scrollTo(0,document.documentElement.scrollHeight);await pause(350);}
  var wanted=a.wait||selector;
  if(wanted){var until=Date.now()+2000;while(!document.querySelector(wanted)&&Date.now()<until)await pause(100);
    if(!document.querySelector(wanted))throw new Error('网页没有出现指定内容：'+wanted);}
  return document.contentType.includes('json')?document.body.innerText:document.documentElement.outerHTML;
}
