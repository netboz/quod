"""Finite current-source/caller/privacy bindings; no live IPC or application."""
import hashlib,json,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
from cue_hashes import Digests
root=Path.cwd();ev=Path(__file__).resolve().parent;m=json.loads(Path(sys.argv[1]).read_text());d=Digests();checks=[]
def check(yes,name):
    if not yes:raise AssertionError(name)
    checks.append(name);print('PASS '+name)
physical=(ev/'PhysicalChecks.cs').read_text();guide=(ev/'MorningJourneyGuide.cs').read_text();cue=(ev/'ViveLookCue.cs').read_text();rehearsal=(ev/'MorningJourneyChecks.cs').read_text()
check(m['passed'] and not m['distributable'] and not m['compiled_application_inputs_copied'],'source-only nondistributable diagnostic composition')
check(len(m['live_source_inputs'])==93 and len(m['supplied_inputs'])==97,'exact current93 plus four removable helpers')
for n,h in m['live_source_inputs'].items():check(d.h(root/n)==h,'actual current product input: '+n)
stage=Path(m['stage'])/'source'
for name in ['PhysicalChecks.cs','ViveLookCue.cs','MorningJourneyGuide.cs','MorningJourneyChecks.cs']:
    check(d.h(stage/'client/godot/tests'/name)==d.h(ev/name)==m['supplied_inputs']['client/godot/tests/'+name],'actual compiled helper: '+name)
dispatch=(stage/'client/godot/tests/ExportChecks.cs').read_text()
check(dispatch.count('phase == "vive-physical"')==1 and dispatch.count('phase == "morning-journey"')==1,'one explicit human phase and one software-only rehearsal dispatch')
check('MorningJourney()' not in physical and not re.search(r'\.(SetInput|SetPose|Submit|Personal|Execute|EmitSignal)\(',physical),'human phase never injects a gesture, Submit or travel')
check(not re.search(r'\.(Send|Read|Personal|Execute|Submit|EmitSignal|SetInput|SetPose)\(',guide),'guidance has no domain/client/input executor')
check('Json.Committed(outcome)' in guide and 'Same(parent,setup[2])' in guide and 'Same(parent,First)' in guide,'created-space guidance uses certified results and exact expected parents')
check('Same(placed,Nested)' in guide and 'sawDisconnected' in guide,'return/reconnect instructions follow installed exact location')
check(guide.index('if(uncertain')<guide.index('if(Step==0') and 'if(working)' in guide,'uncertain or in-flight work cannot advance instructions or invite another Submit')
check('lifecycle.PresentationVisible && adapter.WorkspaceVisible && adapter.GuiSurface.IsVisibleInTree()' in physical and 'native?.GetSessionState()==OpenXRInterface.SessionState.Focused' in physical,'actual native/window/workspace caller gates retained')
check('High(hp),HandReady("left"),HandReady("right"),released)' in physical and 'sample.Neutral' in physical,'actual canonical high/model/authoritative neutral caller bindings retained')
observe=physical[physical.index('        void Observe()'):physical.index('        object Transform(')]
check('HasFocus' not in observe and 'ApplicationFocused' not in physical,'desktop focus remains observational, never a cue veto')
check('SignedSession.Now>=signInExpires ? MorningJourneyGuide.Expired' in observe and 'shownReady=next.StartsWith("READY\\n")' in observe,'expiry withdraws READY and its marker without renewal')
check('ViveLookCue.Compose(ready,released,journeyText)' in observe and 'ViveLookCue.Compose(true,true,text)' in rehearsal,'human frame owner and software label use the SAME pure semantic WAITING compositor')
check('margin.OffsetTop=top+260' in physical and 'margin.OffsetTop=top;' in physical and 'RemoveChild(scroll)' not in physical,'same instruction header reserves/restores layout without detaching installed owners')
check('CustomMinimumSize=new(0,256)' in physical and 'margin.VisibilityChanged-=Visible' in physical,'same fixed-height label follows workspace visibility and retires its callback')
check('FramePostDraw-=Observe;app.Changed-=JourneyChanged;' in physical,'frame and instruction subscriptions retire through the existing owner')
check('public const string Ready="READY"' in cue and 'Fully press/release LEFT trigger ONCE' not in cue,'superseded one-edge-only instruction is absent from the new selector')
check('active && visible && running && nativeFocused && headHigh &&' in cue and 'leftHighAndVisible && rightHighAndVisible && released ? Ready : Waiting' in cue,'unchanged native cue predicate, no new threshold or sample')
check('controller_status' in rehearsal and 's.Read(c)?.Neutral==true' in rehearsal,'software gestures synchronize with actual mapping and released samples')
check('await SelectOption(storage,chosen)' in rehearsal and 'try {await Pixel(pixel' in rehearsal and 'select.Selected==index && !popup.Visible' in rehearsal,'actual native popup items are ray-clicked, never selected by emitted test signals')
check('await OpenResult(first)' in rehearsal and 'await OpenResult(nested)' in rehearsal,'both object selections use the existing exact returned-subject controls')
check('await Instructions()==instructions' in rehearsal and 'SignedView.LiveSockets==0' in rehearsal,'explicit reconnect verifies no replay and consumer retirement')
record={'passed':True,'checks':checks,'source_only':True,'live_queries':False,'application_started':False,'hardware':False,'source_hashes':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [ev/n for n in ['PhysicalChecks.cs','ViveLookCue.cs','MorningJourneyGuide.cs','MorningJourneyChecks.cs']]}}
(ev/'binding-checks.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'passed':True,'checks':len(checks)}))
