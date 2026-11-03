"""Argument-free entry/argument summaries, never fabricated returned success."""
import collections,hashlib,json,re,sys
from pathlib import Path
from environment import TASK
keep={'xrCreateInstance','xrDestroyInstance','xrCreateSession','xrDestroySession','xrBeginSession','xrRequestExitSession','xrEndSession','xrCreateActionSet','xrDestroyActionSet','xrCreateAction','xrDestroyAction','xrCreateReferenceSpace','xrCreateActionSpace','xrDestroySpace','xrCreateSwapchain','xrDestroySwapchain','xrAcquireSwapchainImage','xrWaitSwapchainImage','xrReleaseSwapchainImage','xrWaitFrame','xrBeginFrame','xrEndFrame'}
for label in sys.argv[1:]:
    path=TASK/'private'/label/'api-dump.raw';data=path.read_bytes();text=data.decode(errors='replace')
    names=re.findall(r'^XrResult (xr\w+)',text,re.M);counts=collections.Counter(names)
    layers=collections.Counter(int(v,0) for v in re.findall(r'^\s*uint32_t frameEndInfo->layerCount = (0x[0-9a-fA-F]+|[0-9]+)$',text,re.M))
    views=collections.Counter(int(v,0) for v in re.findall(r'^\s*uint32_t frameEndInfo->layers\[0\]->viewCount = (0x[0-9a-fA-F]+|[0-9]+)$',text,re.M))
    assert sum(layers.values())==counts['xrEndFrame'] and counts['xrEndFrame']>0,'Missing or misparsed frame layer fields'
    result={'raw_path':str(path),'raw_sha256':hashlib.sha256(data).hexdigest(),'raw_bytes':len(data),'scope':'Official API dump call entry/arguments only; no returned-success, scanout or headset-pixel claim','counts':{n:counts[n] for n in sorted(keep)},'submitted_layer_counts':dict(layers),'projection_view_counts':dict(views),'lifecycle_order':[n for n in names if n in keep-{'xrAcquireSwapchainImage','xrWaitSwapchainImage','xrReleaseSwapchainImage','xrWaitFrame','xrBeginFrame','xrEndFrame'}]}
    out=Path(__file__).resolve().parent/label/'api-lifecycle.json';assert not out.exists();out.write_text(json.dumps(result,indent=2)+'\n')
    print(label,json.dumps({'counts':result['counts'],'layers':dict(layers),'views':dict(views)}))
