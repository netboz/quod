from pathlib import Path
import json,urllib.request
session=json.loads(Path('_build/quod27-desktop-259-03/session.json').read_text())
endpoint=session['endpoint']+'/session/'+session['session']
def command(path,body=None,method='POST'):
 data=json.dumps(body or {}).encode() if method=='POST' else None
 r=urllib.request.Request(endpoint+path,data=data,method=method,headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(r,timeout=40) as response:v=json.load(response)['value']
 if isinstance(v,dict) and 'error' in v and 'stacktrace' in v:raise RuntimeError(str(v))
 return v
def evaluate(script,args=None):return command('/execute/sync',{'script':script,'args':args or []})
def wait_js(condition):
 return command('/execute/async',{'script':'const done=arguments[arguments.length-1];const ready=()=>('+condition+');if(ready())return done(true);const observer=new MutationObserver(()=>{if(ready()){observer.disconnect();clearTimeout(timer);done(true)}});observer.observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true});const timer=setTimeout(()=>{observer.disconnect();done(false)},15000);','args':[]})
def element(selector):return command('/element',{'using':'css selector','value':selector})['element-6066-11e4-a52e-4f735466cecf']
def click(selector):return command('/element/'+element(selector)+'/click')
def fill(selector,text):
 e=element(selector);command('/element/'+e+'/clear');return command('/element/'+e+'/value',{'text':text})
def inspect():return evaluate('return {url:location.href,text:document.body.innerText,buttons:[...document.querySelectorAll("button")].map(x=>({text:x.innerText,title:x.title,disabled:x.disabled})),fields:[...document.querySelectorAll("textarea,input")].map(x=>({tag:x.tagName,type:x.type,placeholder:x.placeholder,aria:x.getAttribute("aria-label")}))}')
