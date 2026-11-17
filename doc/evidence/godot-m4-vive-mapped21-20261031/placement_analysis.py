"""Derived relative geometry only; no room coordinates, API reads or live queries."""
import json,math
from pathlib import Path
root=Path.cwd();ev=Path(__file__).resolve().parent
private=Path('/data/quod-m4-vr-ca84d4f8-20261029/private/native-vive-product21/read-only-captures')
def matrix(t):return [[*([t['basis_columns'][j][i] for j in range(3)]),t['origin'][i]] for i in range(3)]+[[0,0,0,1]]
def mul(a,b):return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]
def inverse(m):
    a,b,c=m[0][:3];d,e,f=m[1][:3];g,h,i=m[2][:3]
    determinant=a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g);assert abs(determinant)>1e-9
    r=[[e*i-f*h,c*h-b*i,b*f-c*e],[f*g-d*i,a*i-c*g,c*d-a*f],[d*h-e*g,b*g-a*h,a*e-b*d]]
    r=[[v/determinant for v in row] for row in r]
    return [r[j]+[-sum(r[j][k]*m[k][3] for k in range(3))] for j in range(3)]+[[0,0,0,1]]
def angle(a,b):return math.degrees(math.acos(max(-1,min(1,sum(x*y for x,y in zip(a,b))/math.sqrt(sum(x*x for x in a)*sum(x*x for x in b))))))
def relative(m):
    p=[m[i][3] for i in range(3)];distance=math.sqrt(sum(v*v for v in p));assert distance>0
    return {'centre_distance_metres':distance,'forward_angle_degrees':angle(p,[0,0,-1]),
        'horizontal_angle_degrees':math.degrees(math.atan2(p[0],-p[2])),
        'vertical_angle_degrees':math.degrees(math.atan2(p[1],math.hypot(p[0],p[2]))),
        'panel_facing_eye_degrees':angle([m[i][2] for i in range(3)],[-v for v in p]),
        'panel_up_vs_eye_up_degrees':angle([m[i][1] for i in range(3)],[0,1,0]),
        'eye_on_front_side':inverse(m)[2][3]>0}
reports=[]
for label in ['baseline01','after-response01']:
    data=json.loads((private/(label+'.raw.json')).read_text())['snapshots'][-1];node=data['geometry']['node'];render=data['geometry']['renderer']
    panel=matrix(node['panel']);origin=matrix(node['xr_origin'])
    row={'label':label,'node_utc':node['utc'],'frame':node['observed_frame'],'head_confidence':None if node['head'] is None else node['head']['confidence'],
        'panel_visible':node['panel_visible'],'window_focused_observation':node['window_focused'],'native_session':node['session_state'],
        'panel_size':node['panel_size'],'gui_pixels':node['gui_pixels'],
        'relative_to_node_camera':relative(matrix(node['panel_in_camera'])),
        'relative_to_node_camera_global':relative(mul(inverse(matrix(node['camera_global'])),panel)),
        'relative_to_adjusted_head':None if node['head'] is None else relative(mul(inverse(mul(origin,matrix(node['head']['adjusted']))),panel)),
        'panel_up_vs_world_up_degrees':angle([panel[i][1] for i in range(3)],[0,1,0]),'render_eyes':[]}
    if render:
        row['renderer_utc']=render['utc'];row['cached_views_possible']=render['may_use_cached_views'];row['native_return_status_exposed']=render['native_view_return_status_exposed']
        row['render_eyes']=[{'index':e['index'],**relative(matrix(e['panel_from_main_in_render_eye']))} for e in render['render_view_getters']]
    reports.append(row)
record={'scope':'Later separate samples, not the unknown human look interval or a causal hardware/placement verdict. Renderer getters can be cached; node and renderer times differ.',
    'reports':reports,'API_bytes_read':0,'live_queries':0,'raw_room_coordinates_published':False}
(ev/'placement-analysis.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2))
