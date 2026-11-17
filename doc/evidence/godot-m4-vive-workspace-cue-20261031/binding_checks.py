"""Finite current-source composition checks; no application, input or live IPC."""
import json,os,shutil
from pathlib import Path
from cue_hashes import Digests,TASK,key,raw
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent;old=ev.parent/'godot-m4-vive-runtime-cue-20261030'
d=Digests();checks=[]
def check(yes,name):
    assert yes,name
    checks.append(name);print('PASS '+name,flush=True)
before=(old/'PhysicalChecks.cs').read_text();actual=(ev/'PhysicalChecks.cs').read_text()
expected=before.replace('var instruction=new Label { Name="vive-look-instruction",Position=new(30,30),MouseFilter=Control.MouseFilterEnum.Ignore };',
    'var instruction=new Label { Name="vive-look-instruction",CustomMinimumSize=new(0,144),AutowrapMode=TextServer.AutowrapMode.WordSmart,MouseFilter=Control.MouseFilterEnum.Ignore };')
expected=expected.replace('instruction.Text=ViveLookCue.Waiting;gui.Surface.AddChild(instruction);',
    'instruction.Text=ViveLookCue.Waiting;\n        var content=gui.Surface.GetChildren().OfType<MarginContainer>().Single().GetChild<ScrollContainer>(0).GetChild<VBoxContainer>(0);\n        content.AddChild(instruction);content.MoveChild(instruction,1);')
expected=expected.replace('ViveLookCue.Text(lifecycle.Active,lifecycle.PresentationVisible,',
    'ViveLookCue.Text(lifecycle.Active,lifecycle.PresentationVisible && adapter.WorkspaceVisible && adapter.GuiSurface.IsVisibleInTree(),')
check(actual==expected,'complete diagnostic delta is shared-layout label placement and actual workspace visibility only')
prior=json.loads((old/'inputs/client-runtime-cue01-manifest.json').read_text())
check(raw(old/'PhysicalChecks.cs')==prior['supplied_inputs']['client/godot/tests/PhysicalChecks.cs'] and
    raw(ev/'ViveLookCue.cs')==prior['supplied_inputs']['client/godot/tests/ViveLookCue.cs'],
    'qualified historical observer remains unchanged; cue selector is byte-identical to its prior21 pure checks')
copies=TASK/'private/build-inputs/workspace-cue-binding01';copies.mkdir(mode=0o700,parents=True,exist_ok=False)
bindings={}
for p in [ev/'PhysicalChecks.cs',ev/'ViveLookCue.cs',root/'client/godot/Main.cs',root/'client/godot/SpatialGui.cs',root/'client/godot/OpenXRInput.cs']:
    target=copies/p.name;shutil.copy2(p,target);assert raw(target)==raw(p)
    bindings[str(p)]={'copy':str(target),'sha256':raw(p),'mode':p.stat().st_mode&0o7777}
(ev/'inputs/binding-preexecution.json').write_text(json.dumps(bindings,indent=2)+'\n')
main=(root/'client/godot/Main.cs').read_text();gui=(root/'client/godot/SpatialGui.cs').read_text()
check(all(s in main for s in ['gui.SetContent(margin);workspaceContent=margin;',
    'var scroll = new ScrollContainer { FollowFocus = true }; margin.AddChild(scroll);',
    'var root = new VBoxContainer { SizeFlagsHorizontal = SizeFlags.ExpandFill }; scroll.AddChild(root);']) and
    'Surface.AddChild(next)' in gui,'cue attaches to the actual existing shared scroll/VBox content owner, not an overlay or second form')
check('CustomMinimumSize=new(0,144)' in actual and 'AutowrapMode=TextServer.AutowrapMode.WordSmart' in actual and
    'content.MoveChild(instruction,1)' in actual and 'MouseFilter=Control.MouseFilterEnum.Ignore' in actual,
    'fixed-height non-intercepting cue precedes the same controls and does not change height with held-trigger text')
observe=actual[actual.index('        void Observe()'):actual.index('        // Bounded read-only observation')]
check('lifecycle.PresentationVisible && adapter.WorkspaceVisible && adapter.GuiSurface.IsVisibleInTree()' in observe,
    'actual cue caller withholds READY for a hidden or not-yet-placed workspace in addition to window visibility')
check('lifecycle.NativeRunning,native?.GetSessionState()==OpenXRInterface.SessionState.Focused,\n                High(hp),HandReady("left"),HandReady("right"),released)' in observe and
    's.Read(id) is ComponentSample sample && sample.Neutral' in observe,
    'actual native-running/focus/head/canonical-model/neutral wiring is retained without a new policy threshold')
check('HasFocus' not in observe and 'applicationFocused' not in actual and 'ApplicationFocused' not in actual and
    actual.count('window_focused=GetWindow().HasFocus()')==1,
    'desktop focus remains a literal geometry observation and never a persistent cue veto')
check(actual.count('RenderingServer.FramePostDraw+=Observe')==1 and actual.count('RenderingServer.FramePostDraw-=Observe')==1 and
    'instruction.GetParent()?.RemoveChild(instruction);instruction.Free();' in actual,
    'the same frame owner changes cue text and retires its subscription and label')
check(all(s not in observe for s in ['SetPose(','SetInput(','Router.Frame(','Drive(','Press(','GetTree().Quit']) and
    'if(next!=cueState)' in observe,'no new pose/input/domain/sample authority or repeated unchanged cue work')
m=json.loads((ev/'inputs/client-workspace-cue01-manifest.json').read_text());accepted=json.loads((root/'doc/evidence/godot-m4-workspace-20261030/inputs/client-workspace-final06-manifest.json').read_text())
check(m['passed'] and m['live_source_inputs']==accepted['supplied_inputs'] and len(m['live_source_inputs'])==93 and
    len(m['supplied_inputs'])==95 and len(m['export_outputs'])==196 and not m['distributable'] and not m['compiled_application_inputs_copied'],
    'new source-only95-input diagnostic binds the exact accepted93 current inputs,196 exports and nondistributable scope')
cache=Path(m['digest_cache']['path']);check(raw(cache)==m['digest_cache']['sha256'],'new build digest cache authenticates before exact-stat reuse')
for r in json.loads(cache.read_text())['records']:d.values[tuple(r['stat_key'])]=r['sha256']
stage=Path(m['stage'])/'source'
for n,digest in m['live_source_inputs'].items():assert key(root/n) in d.values and d.h(root/n)==digest
dispatch='if (phase == "physics") { await PhysicsJourney(); return; }'
check((stage/'client/godot/tests/ExportChecks.cs').read_text()==(root/'client/godot/tests/ExportChecks.cs').read_text().replace(dispatch,dispatch+'\n            if (phase == "vive-physical") { await VivePhysical(); return; }') and
    all((stage/'client/godot/tests'/n).read_bytes()==(ev/n).read_bytes() for n in ['PhysicalChecks.cs','ViveLookCue.cs']),
    'actual compiled dispatch and helpers equal the inspected caller; all93 current product inputs remain unchanged')
record={'passed':True,'checks':checks,'count':len(checks),'pure_cue21':'unchanged selector identity reused; no rerun',
    'historical_privacy_projection20':'same full geometry/publisher shapes; old source qualification reused without rerun',
    'product_source_changes':0,'functional_application_started':False,'native_runtime_started':False,'live_queries':0,'API_bytes_read':0}
(ev/'binding-checks.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'checks':len(checks),'product_source_changes':0,'native_or_live_queries':0}))
