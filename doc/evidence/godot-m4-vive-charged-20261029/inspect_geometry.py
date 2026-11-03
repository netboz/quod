"""Private exact input copy, small relative-only geometry receipt; no setters."""
import hashlib,json,math,os,re,sys
from pathlib import Path

os.umask(0o077)
label,suffix=sys.argv[1:];assert re.fullmatch(r'[a-z0-9-]+',label) and re.fullmatch(r'[a-z0-9-]+',suffix)
ev=Path(__file__).resolve().parent
private=Path('/data/quod-m4-vr-ca84d4f8-20261029/private')/label
path=private/'client-result.raw.json';before=path.stat();data=path.read_bytes();after=path.stat()
key=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
assert key(before)==key(after) and after.st_mode&0o777==0o600 and private.stat().st_mode&0o777==0o700
copies=private/'observations';copies.mkdir(mode=0o700,exist_ok=True)
copy=copies/(suffix+'.json')
with copy.open('xb') as output:output.write(data)
copy.chmod(0o600)
root=json.loads(data);snap=next(s for s in reversed(root['snapshots']) if s.get('phase')=='geometry')
node=snap['geometry']['node'];renderer=snap['geometry']['renderer']
assert renderer['dispatch']=='RenderingServer.CallOnRenderThread' and not renderer['native_view_return_status_exposed'] and not renderer['projection_getter_called']
def norm(v):return math.sqrt(sum(x*x for x in v))
def difference(a,b):return norm([x-y for x,y in zip(a,b)])
def angle(forward,delta):
    denominator=norm(forward)*norm(delta)
    return None if denominator==0 else math.degrees(math.acos(max(-1,min(1,sum(a*b for a,b in zip(forward,delta))/denominator))))
eyes=[]
for view in renderer['render_view_getters']:
    p=view['panel_from_main_in_render_eye']['origin'];side=view['render_eye_in_panel_from_main']['origin'][2]
    eyes.append({'index':view['index'],'panel_distance_metres':norm(p),'panel_centre_forward_degrees':angle([0,0,-1],p),
                 'panel_centre_in_front_of_eye':p[2]<0,'eye_on_panel_front_side':side>0,
                 'panel_local_eye_depth_metres':side})
sources=[]
for source in node['sources']:
    pose=lambda p:None if p is None else {'tracked':p['tracked'],'confidence':p['confidence']}
    sources.append({'hand':source['hand'],'current_predicate':source['current'],
        'aim':pose(source['native_aim']),'grip':pose(source['native_grip']),
        'model_roots':len(source['models']),'visible_roots':sum(m['visible'] for m in source['models']),
        'meshes':sum(len(m['meshes']) for m in source['models']),
        'visible_meshes':sum(mesh['visible_in_tree'] for m in source['models'] for mesh in m['meshes'])})
width,height=node['panel_size'];pixels_x,pixels_y=node['gui_pixels']
result={'case':label,'phase':snap['phase'],'private_input':{'path':str(copy),'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'mode':0o600},
        'scope':'Relative-only observations. Native view status/freshness and pixels are not exposed or inferred. Node and renderer times differ.',
        'node_utc':node['utc'],'renderer_utc':renderer['utc'],'node_thread':node['thread'],'node_context':node['context'],
        'renderer_thread':renderer['thread'],'renderer_context':renderer['context'],'thread_model_setting':node['thread_model_setting'],
        'window_focused':node['window_focused'],'adapter_lifecycle':{k:v for k,v in node['adapter_lifecycle'].items() if k!='calibration'},
        'calibration_present':node['adapter_lifecycle']['calibration'] is not None,'session_state':node['session_state'],
        'head':None if node['head'] is None else {'tracked':node['head']['tracked'],'confidence':node['head']['confidence']},
        'xr_origin_current':node['xr_origin_current'],'viewport_use_xr':node['viewport_use_xr'],'viewport_camera':node['actual_viewport_camera'],
        'origin_to_main_world_translation_difference':difference(node['xr_origin']['origin'],node['world_origin']['origin']),
        'main_to_renderer_world_translation_difference':difference(node['world_origin']['origin'],renderer['world_origin']['origin']),
        'view_getter_count':renderer['getter_count'],'native_view_success_unexposed':True,'may_use_cached_views':True,
        'panel_visible':node['panel_visible'],'panel_size_metres':node['panel_size'],'gui_pixels':node['gui_pixels'],
        'panel_to_texture_aspect_ratio':None if height==0 or pixels_y==0 or pixels_x==0 else (width/height)/(pixels_x/pixels_y),
        'representative_font_pixels':node['representative_font_pixels'],'eyes':eyes,'sources':sources,'metrics':snap['metrics']}
target=ev/label/(suffix+'-geometry-receipt.json');assert not target.exists();target.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
