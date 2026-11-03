using Godot;
using Quod.Client;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task OpenXRRuntime()
    {
        var adapter=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        using var api=new OpenXRApiExtension();
        var cycles=new List<object>();
        var calibration=typeof(OpenXRInput).GetField("calibration",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!;
        for(int cycle=1;cycle<=3;cycle++) {
            Check(adapter.Start(),"installed OpenXR interface starts cycle "+cycle);
            if(cycle==1 && Env("M1B_PHASE")=="openxr-input")await ObserveOpenXRControls(adapter);
            long previous=0;int fresh=0,tracked=0,high=0;var samples=new List<long>();
            int invalidStartupFrames=0;bool invalidHeadCalibration=false;
            var sourceSamples=new Dictionary<OpenXRInput.Source,int>();bool sourcePosesAgree=true;
            for(int i=0;i<90;i++) {
                await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
                long time=api.GetPredictedDisplayTime();if(time>previous){fresh++;previous=time;samples.Add(time);}
                if(XRServer.GetTracker("head") is XRPositionalTracker head && head.HasPose("default") && head.GetPose("default").HasTrackingData && head.GetPose("default").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None) {
                    tracked++;if(head.GetPose("default").TrackingConfidence==XRPose.TrackingConfidenceEnum.High)high++;
                } else if(tracked==0) { invalidStartupFrames++;invalidHeadCalibration|=calibration.GetValue(adapter)!=null; }
                foreach(var source in adapter.Sources.Where(s=>s.Current(0))) {
                    sourceSamples[source]=sourceSamples.GetValueOrDefault(source)+1;
                    sourcePosesAgree&=source.Aim.Transform.IsEqualApprox(source.Tracker.GetPose("aim").GetAdjustedTransform()) &&
                        source.Grip.Transform.IsEqualApprox(source.Tracker.GetPose("grip").GetAdjustedTransform());
                }
            }
            var xr=XRServer.FindInterface("OpenXR") as OpenXRInterface??throw new Exception("OpenXR interface disappeared");
            long draws=scene.Viewport.GetRenderInfo(Viewport.RenderInfoType.Visible,Viewport.RenderInfo.DrawCallsInFrame);
            var sourceTracking=adapter.Sources.Select(s=>new { name=s.Tracker.Name.ToString(),valid_frames=sourceSamples.GetValueOrDefault(s),
                aim=s.Tracker.HasPose("aim") ? s.Tracker.GetPose("aim").TrackingConfidence.ToString() : "missing",
                grip=s.Tracker.HasPose("grip") ? s.Tracker.GetPose("grip").TrackingConfidence.ToString() : "missing" }).ToArray();
            await File.WriteAllTextAsync(Env("M1B_RESULT")+".cycle"+cycle+".json",System.Text.Json.JsonSerializer.Serialize(new {
                cycle,fresh,tracked,high,invalidStartupFrames,invalidHeadCalibration,sourceTracking,sourcePosesAgree,draws,
                update_mode=scene.Viewport.RenderTargetUpdateMode.ToString(),view_count=scene.Viewport.ViewCount,session_state=xr.GetSessionState().ToString(),can_render=api.CanRender() }));
            if(invalidStartupFrames>0)Check(!invalidHeadCalibration,"startup without a valid native head pose cannot establish world calibration");
            Check(fresh>0 && tracked>0 && api.GetViewCount()==2,"real runtime supplies fresh stereo head frames cycle "+cycle);
            Check(scene.Viewport.ViewCount==2,"XR scene retains the runtime's stereo render layout cycle "+cycle);
            Check(scene.Viewport.RenderTargetUpdateMode==SubViewport.UpdateMode.Always && draws>0,"hidden desktop container keeps the actual XR scene rendering cycle "+cycle);
            if(sourceSamples.Count>0)Check(sourcePosesAgree,"adapter uses the native tracker aim and grip poses cycle "+cycle);
            var profiles=adapter.Sources.Select(s=>new { name=s.Tracker.Name.ToString(),profile=s.Tracker.Profile,hand=s.Hand,components=s.Layout }).ToArray();
            var system=xr.GetSystemInfo().ToDictionary(p=>p.Key.AsString(),p=>p.Value.ToString());
            adapter.StopSession();await adapter.Completion;
            Check(adapter.Subscriptions==0 && adapter.Router.Count==0,"OpenXR adapter stop releases every subscribed source cycle "+cycle);
            Check(scene.Viewport.ViewCount==1 && scene.Viewport.GetCamera3D()==scene.FindChild("scene-camera",true,false),"XR stop restores the same desktop mono scene and camera cycle "+cycle);
            cycles.Add(new { cycle,fresh,tracked,high,draws,profiles,sourceTracking,source_pose_agreement_qualified=sourceSamples.Count>0 && sourcePosesAgree,system,frame_times=samples,metrics=adapter.Metrics });
            Console.WriteLine("M4_XR_CYCLE "+cycle);Console.Out.Flush();
        }
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { passed=true,simulated=System.Environment.GetEnvironmentVariable("SIMULATED_ENABLE")=="1",checks,cycles }));
        Console.WriteLine("M4_XR_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task ObserveOpenXRControls(OpenXRInput adapter)
    {
        Check(System.Environment.GetEnvironmentVariable("SIMULATED_ENABLE")!="1","wand observation requires a real runtime hardware source");
        string[] components=["xr-standard-trigger","xr-standard-squeeze","xr-standard-touchpad"];
        var previous=new Dictionary<(OpenXRInput.Source Source,string Component),bool>();
        var neutral=new HashSet<(OpenXRInput.Source,string)>();var down=new HashSet<(OpenXRInput.Source,string)>();var completed=new HashSet<(OpenXRInput.Source,string)>();
        var tracked=new HashSet<OpenXRInput.Source>();
        var states=new Dictionary<string,int>();var edges=new List<object>();
        var instruction=new Label { Text="XR INPUT OBSERVATION READY\nPress/release trigger, grip and touchpad on each wand.",Position=new(30,30),MouseFilter=Control.MouseFilterEnum.Ignore };
        ((SpatialGui)app.FindChild("shared-gui",true,false)).Surface.AddChild(instruction);
        long until=System.Diagnostics.Stopwatch.GetTimestamp()+60*System.Diagnostics.Stopwatch.Frequency;
        Console.WriteLine("M4_XR_INPUT_READY");Console.Out.Flush();
        while(System.Diagnostics.Stopwatch.GetTimestamp()<until) {
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            string state=((OpenXRInterface)XRServer.FindInterface("OpenXR")).GetSessionState().ToString();states[state]=states.GetValueOrDefault(state)+1;
            foreach(var source in adapter.Sources.Where(s=>s.Profiles.Contains("htc-vive"))) {
                if(source.Current(0))tracked.Add(source);
                foreach(string component in components) {
                    var sample=source.Read(component);if(sample==null)continue;
                    var key=(source,component);bool pressed=sample.Pressed;
                    if(pressed!=previous.GetValueOrDefault(key))edges.Add(new { source=source.Tracker.Name.ToString(),component,pressed });
                    if(!pressed)neutral.Add(key);
                    if(pressed && neutral.Contains(key) && !previous.GetValueOrDefault(key))down.Add(key);
                    if(!pressed && previous.GetValueOrDefault(key) && down.Contains(key))completed.Add(key);
                    previous[key]=pressed;
                }
            }
            if(completed.Select(k=>k.Item1).Distinct().Count(s=>components.All(c=>completed.Contains((s,c))))>=2)break;
        }
        instruction.QueueFree();
        var observations=adapter.Sources.Select(s=>new { name=s.Tracker.Name.ToString(),profile=s.Tracker.Profile,hand=s.Hand,layout=s.Layout,tracked=tracked.Contains(s),aim=s.Tracker.HasPose("aim") ? s.Tracker.GetPose("aim").TrackingConfidence.ToString() : "missing",grip=s.Tracker.HasPose("grip") ? s.Tracker.GetPose("grip").TrackingConfidence.ToString() : "missing",released=components.Where(c=>completed.Contains((s,c))).ToArray() }).ToArray();
        await File.WriteAllTextAsync(Env("M1B_RESULT")+".input.json",System.Text.Json.JsonSerializer.Serialize(new { observations,states,edges,coverage="actual runtime button/pose delivery; no signed mapping installed; no mapped gesture or headset-pixel claim" }));
        Check(observations.Count(s=>s.tracked && s.released.Length==components.Length)>=2,"both actual Vive wands deliver tracked trigger grip and touchpad press/release");
        Check(adapter.DriveRequests==0 && adapter.SnapRequests==0 && adapter.TeleportRequests==0,"hardware observations without signed settings cannot dispatch travel");
        Console.WriteLine("M4_XR_INPUT_RECEIVED");Console.Out.Flush();
    }
}
