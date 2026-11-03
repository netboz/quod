using Godot;
using Quod.Client;
using System.Text.Json;
using File=System.IO.File;

// Removable observation on the existing frame signals. No native calls are
// replaced, no action or frame is submitted here, and no presence is inferred.
public partial class ExportChecks
{
    async Task VrDiagnostic268()
    {
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        var adapter=(OpenXRInput)app.FindChild("openxr-input",true,false);
        string folder=Env("VR263_PRIVATE");
        void Report(string kind,object value){Console.WriteLine(kind+" "+JsonSerializer.Serialize(value));Console.Out.Flush();}
        await Press("create-key");await Press("connect");
        Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"fresh fixture signed identity");
        await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&!Busy);
        var session=app.ActiveSession;
        Report("VR263_PREPARED",new{diagnostic_only=true,library_created=false,signed_world=true,expires_ms=session.Expires});
        var xr=(OpenXRInterface)XRServer.FindInterface("OpenXR");
        using var api=new OpenXRApiExtension();
        var events=new List<object>();
        long began=(long)Time.GetTicksMsec(),pre=0,post=0,advances=0,regressions=0,zero=0,renderAllowed=0,renderDenied=0,disabled=0,mono=0,notPrimary=0;
        long firstTime=0,lastTime=0,lastObserved=0;int thread=System.Environment.CurrentManagedThreadId;
        var ready=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        object Snapshot()=>new{
            elapsed_ms=Time.GetTicksMsec()-(ulong)began,executor_thread=System.Environment.CurrentManagedThreadId,initial_thread=thread,
            initialized=xr.IsInitialized(),running=api.IsRunning(),adapter_running=adapter.Running,
            session_state=xr.GetSessionState().ToString(),can_render=api.CanRender(),
            primary=xr.IsPrimary(),action_set_active=xr.IsActionSetActive("quod_inputs"),
            presence_supported=xr.IsUserPresenceSupported(),presence=xr.IsUserPresenceSupported()?(bool?)xr.IsUserPresent():null,
            scene_visible=scene.Visible,scene_visible_in_tree=scene.IsVisibleInTree(),use_xr=scene.Viewport.UseXR,
            viewport_update=scene.Viewport.RenderTargetUpdateMode.ToString(),stereo_views=scene.Viewport.ViewCount,
            viewport_size=scene.Viewport.Size.ToString(),draws=scene.Viewport.GetRenderInfo(Viewport.RenderInfoType.Visible,Viewport.RenderInfo.DrawCallsInFrame),
            frame_pre=pre,frame_post=post,predicted_time_advances=advances,predicted_time_regressions=regressions,predicted_time_zero=zero,
            first_predicted_time=firstTime,last_predicted_time=lastTime,render_allowed=renderAllowed,render_denied=renderDenied,
            disabled_viewport_observations=disabled,mono_observations=mono,not_primary_observations=notPrimary,
            head=XRServer.GetTracker("head") is XRPositionalTracker h&&h.HasPose("default")?new{tracked=h.GetPose("default").HasTrackingData,confidence=h.GetPose("default").TrackingConfidence.ToString()}:null,
            sources=adapter.Sources.Select(s=>new{hand=s.Hand,profile=s.Tracker.Profile,tracked=s.Current(0),neutral=new[]{"xr-standard-trigger","xr-standard-squeeze","xr-standard-touchpad"}.All(k=>s.Read(k)?.Neutral==true)}).ToArray(),
            models_settled=adapter.Completion.IsCompletedSuccessfully,router=adapter.Router.Status,
            signed_world=State["world_accepted"],expired=session.IsExpired,expires_ms=session.Expires,
            remaining_auth_ms=session.Expires>SignedSession.Now?session.Expires-SignedSession.Now:0,
            events=events.ToArray(),no_library_or_travel_or_source_instruction=true};
        void Event(string name){if(events.Count<32)events.Add(new{name,elapsed_ms=Time.GetTicksMsec()-(ulong)began,state=xr.GetSessionState().ToString()});}
        void Focused()=>Event("focused");void Visible()=>Event("visible");void Synchronized()=>Event("synchronized");void Stopping()=>Event("stopping");
        void Pre(){pre++;}
        void Post(){
            post++;long now=api.GetPredictedDisplayTime();
            if(now<=0)zero++;else{if(firstTime==0)firstTime=now;if(now>lastObserved)advances++;if(now<lastObserved)regressions++;lastTime=now;}
            lastObserved=now;
            if(api.CanRender())renderAllowed++;else renderDenied++;
            if(scene.Viewport.RenderTargetUpdateMode==SubViewport.UpdateMode.Disabled)disabled++;
            if(!scene.Viewport.UseXR||scene.Viewport.ViewCount!=2)mono++;
            if(!xr.IsPrimary())notPrimary++;
            if(api.CanRender()&&xr.GetSessionState()==OpenXRInterface.SessionState.Focused&&adapter.Sources.Length==2&&
               adapter.Sources.All(s=>s.Current(0)&&s.Profiles.Contains("htc-vive")&&new[]{"xr-standard-trigger","xr-standard-squeeze","xr-standard-touchpad"}.All(k=>s.Read(k)?.Neutral==true))&&
               adapter.Completion.IsCompletedSuccessfully&&!session.IsExpired)ready.TrySetResult();
        }
        xr.SessionFocussed+=Focused;xr.SessionVisible+=Visible;xr.SessionSynchronized+=Synchronized;xr.SessionStopping+=Stopping;
        bool admitted=false;
        try{
            await Press("start-xr");
            began=(long)Time.GetTicksMsec();Event("observation-start");
            RenderingServer.FramePreDraw+=Pre;RenderingServer.FramePostDraw+=Post;
            try{await ready.Task.WaitAsync(TimeSpan.FromSeconds(30));admitted=true;}catch(TimeoutException){}
            var result=Snapshot();await File.WriteAllTextAsync(folder+"/native-pump.json",JsonSerializer.Serialize(result));
            Report("VR263_DIAGNOSTIC_RESULT",new{admitted,observation=result,human_opportunity=false});
            if(!admitted)Report("VR263_BLOCKER",result);
        }finally{
            RenderingServer.FramePreDraw-=Pre;RenderingServer.FramePostDraw-=Post;
            xr.SessionFocussed-=Focused;xr.SessionVisible-=Visible;xr.SessionSynchronized-=Synchronized;xr.SessionStopping-=Stopping;
        }
        await app.CloseApplication(admitted?0:1);
    }
}
