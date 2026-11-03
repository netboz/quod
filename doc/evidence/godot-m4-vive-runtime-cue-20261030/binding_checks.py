"""Finite actual-source and pure publication fixtures; no live commands or IPC."""
import ast,copy,json
from pathlib import Path
from cue_hashes import Digests,raw
root=Path.cwd();ev=Path(__file__).resolve().parent;digests=Digests();checks=[]
def check(yes,name):
 if not yes:raise AssertionError(name)
 checks.append(name);print('PASS '+name,flush=True)
old=root/'doc/evidence/godot-m4-vive-headset-cue-20261030'
before=(old/'PhysicalChecks.cs').read_text();actual=(ev/'PhysicalChecks.cs').read_text();cue=(ev/'ViveLookCue.cs').read_text()
expected=before.replace(',lifecycle.ApplicationFocused','').replace('bool Active,bool ApplicationFocused,bool PresentationVisible','bool Active,bool PresentationVisible').replace('active,applicationFocused,visible','active,visible').replace('s.Read(id) is ComponentSample { Pressed:false }','s.Read(id) is ComponentSample sample && sample.Neutral')
check(actual==expected,'complete observer delta is only obsolete desktop-focus binding removal and existing neutral predicate')
check((ev/'inputs/historical-PhysicalChecks.cs').read_bytes()==(old/'PhysicalChecks.cs').read_bytes() and (ev/'inputs/historical-ViveLookCue.cs').read_bytes()==(old/'ViveLookCue.cs').read_bytes(),'historical helpers remain exact immutable reference bytes')
check('applicationFocused' not in actual and 'ApplicationFocused' not in actual and 'applicationFocused' not in cue,'no removed product member/reflection/cue dependency remains')
observe=actual[actual.index('        void Observe()'):actual.index('        // Bounded read-only observation')]
check('GetWindow().HasFocus()' not in observe and actual.count('window_focused=GetWindow().HasFocus()')==1 and 'HasFocus' not in cue,'desktop Window.HasFocus remains a separate geometry observation only')
check('ViveLookCue.Text(lifecycle.Active,lifecycle.PresentationVisible,\n                lifecycle.NativeRunning,native?.GetSessionState()==OpenXRInterface.SessionState.Focused,\n                High(hp),HandReady("left"),HandReady("right"),released)' in observe,'actual frame caller binds current consumer/visibility/native/head/left/right/neutral predicates in order')
check('=>(active,visible,calibration,api.IsRunning(),api.GetPredictedDisplayTime());' in actual,'diagnostic partial reads the current existing production gates without setters')
hand=actual[actual.index('        bool HandReady'):actual.index('        var rows=')]
check(all(s in hand for s in ['s.Hand==hand && s.Current(0)','High(s.Tracker.GetPose("aim"))','High(s.Tracker.GetPose("grip"))','n.IsVisibleInTree()','m.IsVisibleInTree()']),'actual hand predicate requires registered canonical aim+grip and visible model/mesh')
check('pose?.HasTrackingData==true && pose.TrackingConfidence==XRPose.TrackingConfidenceEnum.High' in actual,'actual High predicate requires tracking data and High confidence')
check('s.Read(id) is ComponentSample sample && sample.Neutral' in observe and 'public bool Neutral => !Pressed && Axes.Length()<0.01f;' in (root/'client/godot/Core/Controllers.cs').read_text(),'released gate uses the actual production neutral predicate including axes')
check(actual.count('RenderingServer.FramePostDraw+=Observe')==1 and actual.count('RenderingServer.FramePostDraw-=Observe')==1 and 'finally { RenderingServer.FramePostDraw-=Observe;instruction.GetParent()?.RemoveChild(instruction);instruction.Free();' in actual,'one existing frame owner unsubscribes and retires its cue through finally')
check(all(t not in observe for t in ['SetPose(','SetInput(','Router.Frame(','DesktopFocusLost(','Visibility(','Install(','Drive(','Press(','case "sample"','GetTree().Quit']),'frame cue never samples gestures, injects poses/input, changes authority or refocuses')
product=(root/'client/godot/OpenXRInput.cs').read_text()
check('bool interactive=focused && running && tracked && visible;' in product and 'visual.Model.Visible=interactive && visual.Profile!=null && source.Current(frame)' in product,'model cue observes the same production native/visibility/profile/current-source presentation contract')
check('instruction.Text=next' in observe and 'if(next!=cueState)' in observe and 'ViveLookCue.Ready ? Colors.LimeGreen : Colors.Yellow' in observe,'cue writes only changed text/color; missing gates withdraw READY rather than latch it')
selected=json.loads((root/'doc/evidence/godot-m4-xr-focus-20261030/inputs/client-xr-focus-final01-manifest.json').read_text())
check(len(selected['supplied_inputs'])==92 and all(digests.h(root/n)==d for n,d in selected['supplied_inputs'].items()),'all92 live product/source inputs still equal independently selected final01')
manifest=json.loads((ev/'inputs/client-runtime-cue01-manifest.json').read_text());stage=Path(manifest['stage'])/'source'
check(manifest['passed'] and len(manifest['supplied_inputs'])==94 and not manifest['compiled_application_inputs_copied'] and not manifest['distributable'],'new source-only94-input composition is compiled diagnostic/non-distributable only')
dispatch='if (phase == "physics") { await PhysicsJourney(); return; }';export=(root/'client/godot/tests/ExportChecks.cs').read_text()
check((stage/'client/godot/tests/ExportChecks.cs').read_text()==export.replace(dispatch,dispatch+'\n            if (phase == "vive-physical") { await VivePhysical(); return; }') and all((stage/'client/godot/tests'/n).read_bytes()==(ev/n).read_bytes() for n in ['PhysicalChecks.cs','ViveLookCue.cs']),'actual staged dispatch and both compiled helpers exactly match inspected caller sources')
# Execute only the existing publisher's pure geometry projection loop with
# non-sensitive in-memory fixtures. Never import/run its live driver module.
publisher=root/'doc/evidence/godot-m4-vive-retest-20261030/physical09.py';tree=ast.parse(publisher.read_text())
loops=[n for n in ast.walk(tree) if isinstance(n,ast.For) and isinstance(n.target,ast.Name) and n.target.id=='snapshot'];assert len(loops)==1;loop=loops[0]
for node in ast.walk(loop):
 if isinstance(node,ast.Call):assert (isinstance(node.func,ast.Name) and node.func.id in ['sum','ValueError']) or (isinstance(node.func,ast.Attribute) and node.func.attr in ['get','pop'])
compiled=compile(ast.Module(body=[loop],type_ignores=[]),str(publisher),'exec')
node={'window_focused':False,'session_state':'Focused','panel_size':[2,1],'gui_pixels':[800,400],'sources':[{'hand':'left','current':True,'models':[{'visible':True,'meshes':[{'visible_in_tree':True}]}]}],'adapter_lifecycle':{'Active':True,'PresentationVisible':True,'NativeRunning':True},'private_matrix':'ROOM-SENTINEL','private_id':'OWNER-SENTINEL'}
raw_fixture=json.dumps({'snapshots':[{'phase':'status','geometry':{'node':node,'renderer':{'private':'RENDER-SENTINEL'}}}]});sanitized=json.loads(raw_fixture)
exec(compiled,{'sanitized':sanitized,'sum':sum,'ValueError':ValueError});published=json.dumps(sanitized)
check(all(s not in published for s in ['ROOM-SENTINEL','OWNER-SENTINEL','RENDER-SENTINEL','private_matrix']),'actual publisher projection omits raw geometry/owner fields from the new lifecycle shape')
receipt=sanitized['snapshots'][0]['geometry_receipt'];check(receipt['window_focused'] is False and receipt['model_visibility'][0]['visible_meshes']==1,'publisher preserves separate false desktop observation and true model observation without fabricating a veto')
check(json.loads(raw_fixture)['snapshots'][0]['geometry']['node']['private_matrix']=='ROOM-SENTINEL','projection leaves original raw fixture bytes unchanged')
try:exec(compiled,{'sanitized':{'snapshots':[{'phase':'status'}]},'sum':sum,'ValueError':ValueError})
except ValueError as error:check(str(error)=='Missing diagnostic geometry snapshot','missing-geometry error is bounded and contains no raw identifiers')
else:raise AssertionError('Expected private projection error')
record={'passed':True,'checks':checks,'count':len(checks),'publisher_source_sha256':raw(publisher),'fixture_kind':'pure non-sensitive in-memory source-binding/geometry projection; no live IPC or driver module import','product_inputs_unchanged':92,'functional_app_or_native_runtime_started':False,'hardware':False,'new_domain_writes':0,'api_bytes_read':0}
(ev/'binding-checks.json').write_text(json.dumps(record,indent=2)+'\n');digests.write(ev/'binding-stat-digests.json');print(json.dumps({'passed':True,'checks':len(checks),'hardware':False,'live_queries':0}))
