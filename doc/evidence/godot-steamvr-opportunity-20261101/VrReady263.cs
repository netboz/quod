using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

// Removable preparation/readiness observer. Production input, focus, tracking,
// authorization and lifetime owners are unchanged. No human action is automated.
public partial class ExportChecks
{
    async Task VrReady263()
    {
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        var adapter=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        string folder=Env("VR263_PRIVATE");
        void Report(string kind,object value){Console.WriteLine(kind+" "+JsonSerializer.Serialize(value));Console.Out.Flush();}
        await Press("create-key");await Press("connect");
        Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"fresh fixture signed identity");
        await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&!Busy);
        var human=app.ActiveAccounts.Human!;var session=app.ActiveSession;
        var originalLocation=State["current_location"]!.ToString();
        await Press("create-operations");
        var pane=(EidolonPanel)app.FindChild("representations",true,false);var operations=pane.Operations;
        async Task Select(OptionButton c,int i){Check(i>0&&i<c.ItemCount,"offered preparation choice");c.Select(i);c.EmitSignal(OptionButton.SignalName.ItemSelected,(long)i);await Frame();}
        var storage=(OptionButton)operations.FindChild("operation-storage",true,false);
        await Select(storage,Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==human.Namespace+" @ "+human.Anchor));await Until(()=>!operations.IsWorking);
        var classes=(OptionButton)operations.FindChild("operation-class",true,false);
        await Select(classes,Enumerable.Range(1,classes.ItemCount-1).Single(i=>classes.GetItemText(i)=="space"));await Until(()=>pane.Available&&operations.Available);
        var offered=pane.Offered.Single(e=>e.Operation&&e.Style=="create");
        var choose=pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==offered.Exact.ToString());
        Check(!choose.Disabled,"ordinary offered Create preparation");choose.EmitSignal(BaseButton.SignalName.Pressed);await Until(()=>operations.Available&&!operations.IsWorking);
        var name=(LineEdit)operations.FormPanel.Input("space_name")!;name.Text="Library";name.EmitSignal(LineEdit.SignalName.TextChanged,"Library");await Frame();
        var submit=(Button)operations.FormPanel.Input(operations.Current!.Form.Submit.ToString())!;
        Check(!submit.Disabled,"one enabled explicit Library Create preparation");submit.EmitSignal(BaseButton.SignalName.Pressed);
        await Until(()=>!operations.IsWorking&&operations.LastOutcome!=null);
        Check(Json.Committed(operations.LastOutcome!),"Library preparation original outcome committed");
        var child=Result(SpaceResults(operations.LastOutcome!),"space");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&scene.SubjectIds(child).Length>0);
        await Press("space-home");
        Check(State["current_location"]!.ToString()==originalLocation,"preparation never enters the child");
        await File.WriteAllTextAsync(folder+"/preparation.json",JsonSerializer.Serialize(new{preparation=true,human_credit=false,automated_enter=false,automated_source_save=false,child=child.ToString(),originalLocation,expires_ms=session.Expires,checks}));
        Report("VR263_PREPARED",new{library_visible=scene.SubjectLabel(child)=="Library",signed_world=true,expires_ms=session.Expires});
        await Press("start-xr");
        var xr=XRServer.FindInterface("OpenXR") as OpenXRInterface;
        using var api=new OpenXRApiExtension();
        var ready=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        long previous=0;int rendered=0;bool first=false,admitted=false;string last="";
        object Snapshot()=>new{
            initialized=xr?.IsInitialized()==true,running=api.IsRunning(),adapter_running=adapter.Running,
            session_state=xr?.GetSessionState().ToString(),can_render=api.CanRender(),xr_frames=rendered,
            stereo_views=scene.Viewport.ViewCount,draws=scene.Viewport.GetRenderInfo(Viewport.RenderInfoType.Visible,Viewport.RenderInfo.DrawCallsInFrame),
            runtime_system=xr?.GetSystemInfo().ToDictionary(p=>p.Key.AsString(),p=>p.Value.ToString()),
            head=XRServer.GetTracker("head") is XRPositionalTracker h&&h.HasPose("default") ? new{tracked=h.GetPose("default").HasTrackingData,confidence=h.GetPose("default").TrackingConfidence.ToString()}:null,
            sources=adapter.Sources.Select(s=>new{hand=s.Hand,profile=s.Tracker.Profile,tracked=s.Current(0),neutral=new[]{"xr-standard-trigger","xr-standard-squeeze","xr-standard-touchpad"}.All(k=>s.Read(k)?.Neutral==true)}).ToArray(),
            router=adapter.Router.Status,models_settled=adapter.Completion.IsCompletedSuccessfully,metrics=adapter.Metrics,
            signed_world=State["world_accepted"],operation_available=State["operation_available"],expired=session.IsExpired,
            expires_ms=session.Expires,remaining_auth_ms=session.Expires>SignedSession.Now?session.Expires-SignedSession.Now:0,
            workspace_visible=adapter.WorkspaceVisible,window_focus=GetWindow().HasFocus(),blocked=adapter.Blocked};
        void Observe(){
            long now=api.GetPredictedDisplayTime();
            bool frame=adapter.Running&&api.IsRunning()&&api.CanRender()&&api.GetViewCount()==2&&scene.Viewport.ViewCount==2&&
                scene.Viewport.RenderTargetUpdateMode==SubViewport.UpdateMode.Always&&scene.Viewport.GetRenderInfo(Viewport.RenderInfoType.Visible,Viewport.RenderInfo.DrawCallsInFrame)>0&&now>previous;
            previous=now;if(frame)rendered++;
            if(frame&&!first){first=true;Report("VR263_FIRST_XR_FRAME",Snapshot());}
            bool head=XRServer.GetTracker("head") is XRPositionalTracker h&&h.HasPose("default")&&h.GetPose("default").HasTrackingData&&h.GetPose("default").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None;
            var sources=adapter.Sources;var router=JsonSerializer.SerializeToNode(adapter.Router.Status)!;
            bool usable=frame&&head&&xr?.GetSessionState()==OpenXRInterface.SessionState.Focused&&
                sources.Count(s=>s.Current(0)&&s.Profiles.Contains("htc-vive"))==2&&
                sources.Select(s=>s.Hand).Distinct().Count()==2&&sources.All(s=>new[]{"xr-standard-trigger","xr-standard-squeeze","xr-standard-touchpad"}.All(k=>s.Read(k)?.Neutral==true))&&
                router["available"]?.GetValue<bool>()==true&&router["sources"]!.AsArray().All(s=>s!["reason"]!.ToString()==""&&s["bindings"]!.AsArray().Count>0)&&
                adapter.Completion.IsCompletedSuccessfully&&State["world_accepted"]?.GetValue<bool>()==true&&State["operation_available"]?.GetValue<bool>()==true&&!session.IsExpired&&!adapter.Blocked;
            if(usable&&!admitted){admitted=true;ready.TrySetResult();}
            string state=xr?.GetSessionState().ToString()+":"+session.IsExpired+":"+State["world_accepted"]+":"+sources.Count(s=>s.Current(0));
            if(admitted&&state!=last){last=state;Report("VR263_STATE",Snapshot());}
        }
        RenderingServer.FramePostDraw+=Observe;
        try{
            try{await ready.Task.WaitAsync(TimeSpan.FromSeconds(30));}
            catch(TimeoutException){Report("VR263_BLOCKER",Snapshot());throw;}
            var snapshot=Snapshot();await File.WriteAllTextAsync(folder+"/ready.json",JsonSerializer.Serialize(snapshot));Report("VR263_READY",snapshot);
            while(true){var command=await Task.Run(Console.In.ReadLine);if(command==null||command.Trim() is "" or "finish" or "stop")break;if(command.Trim()=="status")Report("VR263_STATUS",Snapshot());}
        }finally{RenderingServer.FramePostDraw-=Observe;}
        Report("VR263_FINISH",new{explicit_finish=true});await app.CloseApplication();
    }
}
