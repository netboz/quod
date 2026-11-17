#!/usr/bin/env python3
"""Publish argument-free call-entry counts from restricted official API dumps."""
import collections,hashlib,json,re,sys
from pathlib import Path
for label in sys.argv[1:]:
    private=Path('/home/yan/.cache/quod-m4-r2-artifacts/private')/label/'api-dump-raw.txt'
    data=private.read_bytes();text=data.decode(errors='replace')
    names=re.findall(r'^XrResult (xr\w+)',text,re.M);counts=collections.Counter(names)
    keep={'xrCreateInstance','xrDestroyInstance','xrCreateSession','xrDestroySession','xrBeginSession','xrRequestExitSession','xrEndSession',
          'xrCreateActionSet','xrDestroyActionSet','xrCreateAction','xrDestroyAction','xrCreateReferenceSpace','xrCreateActionSpace','xrDestroySpace',
          'xrCreateSwapchain','xrDestroySwapchain','xrAcquireSwapchainImage','xrWaitSwapchainImage','xrReleaseSwapchainImage','xrWaitFrame','xrBeginFrame','xrEndFrame'}
    layers=collections.Counter(int(v,0) for v in re.findall(r'^\s*uint32_t frameEndInfo->layerCount = (0x[0-9a-fA-F]+|[0-9]+)$',text,re.M))
    views=collections.Counter(int(v,0) for v in re.findall(r'^\s*uint32_t frameEndInfo->layers\[0\]->viewCount = (0x[0-9a-fA-F]+|[0-9]+)$',text,re.M))
    lifecycle=keep-{'xrAcquireSwapchainImage','xrWaitSwapchainImage','xrReleaseSwapchainImage','xrWaitFrame','xrBeginFrame','xrEndFrame'}
    result={'private_source':str(private),'raw_sha256':hashlib.sha256(data).hexdigest(),'raw_bytes':len(data),
       'scope':'official API-dump records call entry and supplied frame data; it does not record returned result codes',
       'counts':{n:counts[n] for n in sorted(keep)},'submitted_layer_counts':dict(layers),'projection_view_counts':dict(views),
       'lifecycle_order':[n for n in names if n in lifecycle]}
    out=Path(__file__).resolve().parent/label/'api-lifecycle.json'
    if out.exists():raise RuntimeError('Retain prior extraction; choose an unextracted case: '+label)
    out.write_text(json.dumps(result,indent=2)+'\n')
    print(label,json.dumps({'create_swapchains':counts['xrCreateSwapchain'],'destroy_swapchains':counts['xrDestroySwapchain'],'stereo_submissions':views[2]}))
