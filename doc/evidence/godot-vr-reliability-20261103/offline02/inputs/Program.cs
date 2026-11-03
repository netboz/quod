using System.Text.Json;
using System.Text.Json.Nodes;

int checks = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new Exception(name);
    checks++;
    Console.WriteLine("PASS " + name);
}
JsonNode Snapshot(FrameObservation value) => JsonSerializer.SerializeToNode(value.Snapshot())!;
long Number(JsonNode n, string key) => n[key]!.GetValue<long>();

var empty = Snapshot(new FrameObservation(1000));
Check(Number(empty,"frame_post_draw_count")==0, "no callbacks is an explicit zero");
Check(empty["first_predicted_time"] is null && empty["last_predicted_time"] is null,
    "no callback does not invent a predicted-time sample");
Check(empty["first_session_state"] is null && empty["retained_state_transitions"]!.AsArray().Count==0,
    "no callback does not invent a session transition");
Check(empty["native_frame_call_count"] is null && empty["direct_should_render"] is null,
    "native calls and direct shouldRender remain unobserved");

var blocked = new FrameObservation(1000);
for (int i=0;i<5;i++) blocked.Record(100+i*10,false,"Synchronized",i*11);
var retained = blocked.Snapshot();
var before = JsonSerializer.SerializeToNode(retained)!;
Check(Number(before,"frame_post_draw_count")==5, "callbacks count even when render admission is false");
Check(Number(before,"first_predicted_time")==100 && Number(before,"last_predicted_time")==140,
    "first and last positive predicted times are retained");
Check(Number(before,"increasing_predicted_time_count")==4, "progress is counted independently of CanRender");
Check(Number(before,"can_render_false_count")==5 && Number(before,"can_render_true_count")==0,
    "false render admission is measured without manufactured rendered frames");
Check(Number(before,"sampled_state_transition_count")==0, "unchanged state is not a transition");
Check(Number(before,"first_callback_elapsed_ticks")==0 && Number(before,"last_callback_elapsed_ticks")==44,
    "zero-based monotonic callback interval is retained with its frequency");
blocked.Record(150,true,"Visible",55);
blocked.Record(160,true,"Focused",66);
blocked.Record(160,false,"Synchronized",77);
var after = Snapshot(blocked);
Check(Number(after,"frame_post_draw_count")==8 && Number(after,"can_render_true_count")==2 &&
    Number(after,"can_render_false_count")==6, "recovery and withdrawal accumulate without resetting counters");
var changes = after["retained_state_transitions"]!.AsArray();
Check(changes.Count==3 && Number(after,"sampled_state_transition_count")==3,
    "visible focused and synchronized transitions are retained");
Check(changes[0]!["from"]!.ToString()=="Synchronized" && changes[0]!["to"]!.ToString()=="Visible" &&
    Number(changes[0]!,"callback")==6 && Number(changes[0]!,"elapsed_ticks")==55,
    "transition binds its initiating and resulting states to the callback interval");
var retainedAfterUpdates = JsonSerializer.SerializeToNode(retained)!;
Check(Number(retainedAfterUpdates,"frame_post_draw_count")==5 && retainedAfterUpdates["retained_state_transitions"]!.AsArray().Count==0,
    "a retained snapshot does not mutate with later samples");

var resets = new FrameObservation(1000);
foreach(long t in new long[]{0,0,100,110,110,90,0,-1,5}) resets.Record(t,false,"Ready",0);
var reset = Snapshot(resets);
Check(Number(reset,"first_predicted_time")==0 && Number(reset,"last_predicted_time")==5,
    "initial zero is not replaced by the first positive time");
Check(Number(reset,"increasing_predicted_time_count")==3 && Number(reset,"equal_predicted_time_count")==2 &&
    Number(reset,"decreasing_predicted_time_count")==3, "equal and decreasing times are distinguished from progression");
Check(Number(reset,"positive_predicted_time_count")==5 && Number(reset,"zero_predicted_time_count")==3 &&
    Number(reset,"negative_predicted_time_count")==1, "nonpositive samples remain explicit");

var bounded = new FrameObservation(1000);
for(int i=0;i<10000;i++) bounded.Record(i,false,i%2==0?"Synchronized":"Visible",i);
var limited = Snapshot(bounded);
Check(limited["retained_state_transitions"]!.AsArray().Count==64 &&
    Number(limited,"sampled_state_transition_count")==9999 && Number(limited,"omitted_state_transitions")==9935,
    "transition storage remains bounded while total and omitted counts stay truthful");
Check(limited["last_session_state"]!.ToString()=="Visible" && Number(limited,"last_predicted_time")==9999,
    "the latest state and time remain current after retention fills");
Check(JsonSerializer.Serialize(bounded.Snapshot()).Length<16000,
    "large callback sequences retain a bounded payload-free report");
var visual = new FrameObservation(1000);
Check(!visual.ObserveVisual(true,true,true,true,true,true), "no callback cannot report visual readiness");
visual.Record(100,true,"Focused",0);
Check(!visual.ObserveVisual(false,true,true,true,true,true), "missing advancing stereo cannot be replaced by positive time");
Check(!visual.ObserveVisual(true,true,false,true,true,true), "visible but unfocused stereo is not visual ready");
Check(!visual.ObserveVisual(true,false,true,true,true,true), "focused stereo still requires current head tracking");
Check(!visual.ObserveVisual(true,true,true,false,true,true), "world withdrawal refuses visual admission");
Check(!visual.ObserveVisual(true,true,true,true,false,true), "receiver withdrawal refuses visual admission");
Check(!visual.ObserveVisual(true,true,true,true,true,false), "expired sign-in refuses visual admission");
Check(visual.ObserveVisual(true,true,true,true,true,true), "first qualifying callback immediately admits visual inspection without controller or model input");
Check(Number(Snapshot(visual),"visual_ready_callback")==1, "visual observation retains the first qualifying callback index");
Check(!visual.ObserveVisual(true,true,true,true,true,true), "same callback never emits a duplicate milestone");
visual.Record(110,false,"Synchronized",1);
Check(!visual.ObserveVisual(false,true,false,true,true,true), "withdrawal never emits a ready event");
visual.Record(120,true,"Focused",2);
Check(!visual.ObserveVisual(true,true,true,true,true,true), "visual recovery does not reset or re-emit the milestone");
Check(Number(Snapshot(visual),"frame_post_draw_count")==3 && Number(Snapshot(visual),"can_render_false_count")==1,
    "visual notification does not reset callback or withdrawal evidence");
var independent = new FrameObservation(1000);
independent.Record(10,true,"Focused",0);
Check(independent.ObserveVisual(true,true,true,true,true,true), "a fresh observer owns an independent one-shot milestone");
Console.WriteLine("FRAME_OBSERVATION_PASS "+JsonSerializer.Serialize(new{checks,synthetic=true,
    native_runtime_started=false,fixture_started=false,rendered_frame_claim=false}));

await AdmissionChecks.Run();
