-module(quod_tx_view_page).
-export([init/2]).

init(Req0, health) ->
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain">>}, <<"ok\n">>, Req0), health};
init(Req0, _Opts) ->
    Headers = #{<<"content-type">> => <<"text/html; charset=utf-8">>},
    {ok, cowboy_req:reply(200, Headers, page(), Req0), undefined}.

page() -> <<"<!doctype html><meta charset=utf-8><title>Quod transactions</title>"
         "<style>body{font:14px system-ui;margin:24px;background:#111;color:#e8e8e8}h1{font-size:20px}"
         "#state{color:#8bd}article{border-top:1px solid #444;padding:12px 0}pre{white-space:pre-wrap;word-break:break-word;margin:6px 0;color:#cfd8dc}"
         ".slot{color:#8bd}.time{color:#aaa}</style><h1>Live transactions</h1><p id=state>Connecting...</p><main id=feed></main>"
         "<script>const state=document.querySelector('#state'),feed=document.querySelector('#feed');"
         "function text(label,value){const p=document.createElement('pre');p.textContent=label+': '+value;return p}"
         "function show(e){const a=document.createElement('article'),h=document.createElement('div');h.className='slot';"
         "h.textContent='Slot '+e.slot+'  '+new Date(e.timestamp).toLocaleString()+'  ('+e.transactions.length+' transaction(s))';a.append(h);"
         "for(const t of e.transactions){a.append(text('tx_id',t.tx_id),text('goal',t.goal),text('result',t.result),text('diff',t.diff));}"
         "feed.prepend(a);while(feed.children.length>200)feed.lastChild.remove()}"
         "const ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws');"
         "ws.onopen=()=>state.textContent='Live';ws.onclose=()=>{state.textContent='Disconnected; retrying...';setTimeout(()=>location.reload(),1000)};"
         "ws.onmessage=m=>show(JSON.parse(m.data));</script>">>.
