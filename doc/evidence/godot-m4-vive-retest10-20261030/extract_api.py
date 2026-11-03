"""Stream only new completed API dumps; call entries/arguments, never results."""
import collections,hashlib,json,re,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK
keep={'xrCreateInstance','xrDestroyInstance','xrCreateSession','xrDestroySession','xrBeginSession','xrRequestExitSession','xrEndSession','xrCreateActionSet','xrDestroyActionSet','xrCreateAction','xrDestroyAction','xrCreateReferenceSpace','xrCreateActionSpace','xrDestroySpace','xrCreateSwapchain','xrDestroySwapchain','xrAcquireSwapchainImage','xrWaitSwapchainImage','xrReleaseSwapchainImage','xrWaitFrame','xrBeginFrame','xrEndFrame'}
frequent={'xrAcquireSwapchainImage','xrWaitSwapchainImage','xrReleaseSwapchainImage','xrWaitFrame','xrBeginFrame','xrEndFrame'}
def number(v):return int(v,16) if v.lower().startswith(b'0x') else int(v,10)
for label in sys.argv[1:]:
    path=TASK/'private'/label/'api-dump.raw';digest=hashlib.sha256();size=0;counts=collections.Counter();layers=collections.Counter();views=collections.Counter();order=[]
    with path.open('rb') as stream:
        for line in stream:
            digest.update(line);size+=len(line)
            m=re.match(rb'^XrResult (xr\w+)\b',line)
            if m:
                name=m[1].decode();counts[name]+=1
                if name in keep-frequent:order.append(name)
            m=re.fullmatch(rb'\s*uint32_t frameEndInfo->layerCount = (0x[0-9a-fA-F]+|[0-9]+)\s*',line)
            if m:layers[number(m[1])]+=1
            m=re.fullmatch(rb'\s*uint32_t frameEndInfo->layers\[0\]->viewCount = (0x[0-9a-fA-F]+|[0-9]+)\s*',line)
            if m:views[number(m[1])]+=1
    assert counts['xrEndFrame']>0 and sum(layers.values())==counts['xrEndFrame'],'Missing or malformed frameEndInfo layerCount field/header'
    result={'raw_path':str(path),'raw_sha256':digest.hexdigest(),'raw_bytes':size,'scope':'Official dump call entries/arguments only; no returned-result, acquired scanout or headset-pixel claim','counts':{n:counts[n] for n in sorted(keep)},'submitted_layer_counts':dict(layers),'projection_view_counts':dict(views),'lifecycle_order':order}
    out=Path(__file__).resolve().parent/'api-lifecycle.json';assert not out.exists();out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'label':label,**result}))
