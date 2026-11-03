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
    async Task VrFrameReady()
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
        var store=app.ActiveStore;
        var subject=(human with {InstanceText="analyzer."}).Entity;
            var s0=Actor.FromTerm(app.ActiveAccounts.Setup!.Require("account",6)[2]);
        string ns=Term.Text(human.Namespace).ToString(),anchor=Term.Binary(Identity.Decode(human.Anchor)).ToString();
        string parts="[part(<<\"left\">>,box(500,500,500),transform(-700,0,0,15,25,0),surface(<<\"#6A90D9\">>,0,700,0,[]),label(<<\"Same Analyzer - left\">>,<<\"above\">>),depicts_nothing),part(<<\"right\">>,box(500,500,500),transform(700,0,0,15,25,0),surface(<<\"#60C880\">>,0,700,0,[]),label(<<\"Same Analyzer - right\">>,<<\"above\">>),depicts_nothing)]";
        var account=app.ActiveAccounts.Setup!.Require("account",6);
        string request=Term.Call("form_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom("package_request")).ToString();
        string[] clauses=[
            "instance_of(quod:gui:form,package_request)","instance_of(quod:gui:text_box,answer)","instance_of(quod:gui:button,send_answer)",
            "gui_children(package_request,[answer,send_answer])","attribute(package_request,label,<<\"Measurement request\">>)",
            "attribute(package_request,help,<<\"Name this measurement.\">>)","attribute(answer,label,<<\"Run name\">>)","attribute(send_answer,label,<<\"Send answer\">>)",
            "gui_initial(package_request,answer,<<\"Original\">>)","gui_form(package_request,[field(answer,Answer)],submit(send_answer,assertz(package_answer(Answer))))",
            $"gui_question_policy(package_request,{account[0]},{account[1]})",$"gui_responder_policy(personal,{request},{account[0]})",
            "gui_pending_allowance(personal,4)","gui_completion_allowance(personal,300000)",
            "isa(occurrence_instrument,thing)","instance_of(occurrence_instrument,analyzer)",
            "class_permission(occurrence_instrument,configure,allow)",
            $"class_eidolon(occurrence_instrument,operation(instance),configure,recipe({ns},{anchor},instrument_form))",
            $"eidolon(instrument_form,subject(ontology_ref({ns},{anchor}),instance(analyzer)),operation(instrument_settings))",
            $"entity_scene(analyzer,playing,appearance(analyzer,solid,analyzer,transform(0,0,0,0,0,0),[eidolon(playing,solid,recipe({ns},{anchor},instrument_solid))]))",
            $"eidolon(instrument_solid,analyzer,{parts})",
            $"space_contains({Term.Parse(s0.InstanceText.TrimEnd('.'))},{subject})",
            "instance_of(quod:gui:form,instrument_settings)","instance_of(quod:gui:text_box,run_name)","instance_of(quod:gui:button,apply_configuration)",
            "instance_of(quod:gui:group,measurement_settings)","gui_children(measurement_settings,[run_name])",
            "attribute(measurement_settings,label,<<\"Measurement\">>)",
            "gui_children(instrument_settings,[measurement_settings,apply_configuration])",
            "attribute(instrument_settings,label,<<\"Analyzer settings\">>)","attribute(instrument_settings,help,<<\"Both views share these settings. Changes stay local until Apply configuration.\">>)",
            "attribute(run_name,label,<<\"Run name\">>)","attribute(apply_configuration,label,<<\"Apply configuration\">>)",
            "gui_form(instrument_settings,[field(run_name,Name)],submit(apply_configuration,assertz(instrument_configuration(Name)),operation(configure,[])))",
            "gui_initial(instrument_settings,run_name,<<\"Sweep A\">>)"
        ];
        var result=await ExecuteComplete(session,app.ActiveStore,human,"transaction(("+string.Join(",",clauses.Select(c=>"assertz(("+c+" :- true))"))+" )).",CancellationToken.None);
        Check(Json.Committed(result),"authorized same-ontology fixture offers a non-space instance form and two visual occurrences");
        await Until(()=>State["question_receiver_ready"]?.GetValue<bool>()==true);
        for(int i=0;i<1;i++)Check(Json.Committed(await ExecuteComplete(session,store,human,"gui_open(package_request,Reference).",CancellationToken.None)),"existing signed owner creates one independent pending request");

        IEnumerable<Node> Nodes(Node n){foreach(var child in n.GetChildren()){yield return child;foreach(var nested in Nodes(child))yield return nested;}}
        await Until(()=>Nodes(app).OfType<QuestionPanel>().Count(q=>q.Discovered)==1);
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&scene.SubjectIds(subject).Length==2);
        // Admit a read-only current-place operation view without selecting the
        // Analyzer or touching either future human form. No Enter/Leave is sent.
        await Press("location-operations");
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        await Until(()=>pane.Available&&pane.Operations.Available&&!Busy);
        await Press("space-home");
        Check(State["current_location"]!.ToString()==originalLocation,"preparation preserves the original current place");
        Check(!app.ActiveAccounts.Uncertain&&!store.Snapshot!.Pending.Any(),"preparation has no unresolved signed work");
        Check(gui.Captures==0&&!gui.TextEntryActive,"preparation leaves no capture or text-entry owner");
        await File.WriteAllTextAsync(folder+"/preparation.json",JsonSerializer.Serialize(new{preparation=true,human_credit=false,automated_enter=false,automated_leave=false,automated_form_submit=false,automated_source_save=false,subject=subject.ToString(),occurrences=scene.SubjectIds(subject),questions_created=1,originalLocation,expires_ms=session.Expires,checks}));
        Report("VR263_PREPARED",new{analyzer_occurrences=scene.SubjectIds(subject).Length,signed_world=State["world_accepted"],operation_available=State["operation_available"],question_receiver_ready=State["question_receiver_ready"],expires_ms=session.Expires});
        static bool Finish(string? command)=>command==null||command.Trim() is "" or "finish" or "stop";
        while(true){
            var command=await Task.Run(Console.In.ReadLine);
            if(Finish(command)){Report("VR263_FINISH",new{explicit_finish=true,before_begin=true});await app.CloseApplication();return;}
            if(command!.Trim()=="begin")break;
            if(command.Trim()=="status")Report("VR263_STATUS",new{waiting_for_wear=true,expired=session.IsExpired,expires_ms=session.Expires,signed_world=State["world_accepted"]});
        }
        Check(!session.IsExpired,"explicit begin retains original unexpired sign-in");
        Report("VR263_BEGIN",new{thread=System.Environment.CurrentManagedThreadId,expires_ms=session.Expires});
        await Press("start-xr");
        var xr=XRServer.FindInterface("OpenXR") as OpenXRInterface;
        using var api=new OpenXRApiExtension();
        var visualReady=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        long previous=api.GetPredictedDisplayTime();int rendered=0;bool first=false,visualAdmitted=false,admitted=false;string last="";
        var observation=new FrameObservation(System.Diagnostics.Stopwatch.Frequency);
        long observationStarted=System.Diagnostics.Stopwatch.GetTimestamp();
        object Snapshot(string? milestone=null)=>new{
            milestone,visual_only=milestone=="visual",interactive_readiness_claim=milestone=="interaction",dispatch_authority=false,
            initialized=xr?.IsInitialized()==true,running=api.IsRunning(),adapter_running=adapter.Running,
            session_state=xr?.GetSessionState().ToString(),can_render=api.CanRender(),xr_frames=rendered,frame_observation=observation.Snapshot(),
            primary=xr?.IsPrimary(),action_set_active=xr?.IsActionSetActive("quod_inputs"),
            use_xr=scene.Viewport.UseXR,viewport_update=scene.Viewport.RenderTargetUpdateMode.ToString(),scene_visible=scene.IsVisibleInTree(),predicted_time=api.GetPredictedDisplayTime(),
            presence_supported=xr?.IsUserPresenceSupported(),presence=xr?.IsUserPresenceSupported()==true?(bool?)xr.IsUserPresent():null,
            captures=gui.Captures,question_receiver_ready=State["question_receiver_ready"],
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
            observation.Record(now,api.CanRender(),xr?.GetSessionState().ToString()??"Unavailable",System.Diagnostics.Stopwatch.GetTimestamp()-observationStarted);
            bool frame=adapter.Running&&xr?.IsPrimary()==true&&xr.IsActionSetActive("quod_inputs")&&scene.Viewport.UseXR&&api.IsRunning()&&api.CanRender()&&api.GetViewCount()==2&&scene.Viewport.ViewCount==2&&
                scene.Viewport.RenderTargetUpdateMode==SubViewport.UpdateMode.Always&&scene.Viewport.GetRenderInfo(Viewport.RenderInfoType.Visible,Viewport.RenderInfo.DrawCallsInFrame)>0&&now>previous;
            previous=now;if(frame)rendered++;
            if(frame&&!first){first=true;Report("VR263_FIRST_XR_FRAME",Snapshot());}
            bool head=XRServer.GetTracker("head") is XRPositionalTracker h&&h.HasPose("default")&&h.GetPose("default").HasTrackingData&&h.GetPose("default").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None;
            if(observation.ObserveVisual(frame,head,xr?.GetSessionState()==OpenXRInterface.SessionState.Focused,
                State["world_accepted"]?.GetValue<bool>()==true,State["question_receiver_ready"]?.GetValue<bool>()==true,!session.IsExpired)){
                visualAdmitted=true;Report("VR263_VISUAL_READY",Snapshot("visual"));visualReady.TrySetResult();
            }
            var sources=adapter.Sources;var router=JsonSerializer.SerializeToNode(adapter.Router.Status)!;
            bool usable=frame&&head&&xr?.GetSessionState()==OpenXRInterface.SessionState.Focused&&
                sources.Length==2&&sources.Count(s=>s.Current(0)&&s.Profiles.Contains("htc-vive"))==2&&
                sources.Select(s=>s.Hand).Distinct().Count()==2&&sources.All(s=>new[]{"xr-standard-trigger","xr-standard-squeeze","xr-standard-touchpad"}.All(k=>s.Read(k)?.Neutral==true))&&
                router["available"]?.GetValue<bool>()==true&&router["sources"]!.AsArray().All(s=>s!["reason"]!.ToString()==""&&s["bindings"]!.AsArray().Count>0)&&
                adapter.Completion.IsCompletedSuccessfully&&State["world_accepted"]?.GetValue<bool>()==true&&State["operation_available"]?.GetValue<bool>()==true&&!session.IsExpired&&!adapter.Blocked&&gui.Captures==0&&State["question_receiver_ready"]?.GetValue<bool>()==true;
            if(usable&&!admitted){admitted=true;Report("VR263_READY",Snapshot("interaction"));}
            string state=JsonSerializer.Serialize(new{session=xr?.GetSessionState().ToString(),can_render=api.CanRender(),expired=session.IsExpired,world=State["world_accepted"],operation=State["operation_available"],receiver=State["question_receiver_ready"],router=adapter.Router.Status,tracked=sources.Count(s=>s.Current(0)),models=adapter.Completion.IsCompletedSuccessfully,captures=gui.Captures,blocked=adapter.Blocked});
            if(visualAdmitted&&state!=last){last=state;Report("VR263_STATE",Snapshot());}
        }
        RenderingServer.FramePostDraw+=Observe;
        try{
            using var admissionStop=new CancellationTokenSource();
            var admission=visualReady.Task.WaitAsync(admissionStop.Token);
            var command=Task.Run(Console.In.ReadLine);
            while(await Task.WhenAny(admission,command)!=admission){
                    var line=await command;
                    if(Finish(line)){
                        admissionStop.Cancel();
                        try{await admission;}catch(OperationCanceledException){}
                        RenderingServer.FramePostDraw-=Observe;
                        Report("VR263_FINISH",new{explicit_finish=true,during_admission=true});await app.CloseApplication();return;
                    }
                    if(line!.Trim()=="status")Report("VR263_STATUS",Snapshot());
                    command=Task.Run(Console.In.ReadLine);
                }
            await admission;
            await File.WriteAllTextAsync(folder+"/visual-ready.json",JsonSerializer.Serialize(Snapshot("visual")));
            while(true){var line=await command;if(Finish(line))break;if(line!.Trim()=="status")Report("VR263_STATUS",Snapshot());command=Task.Run(Console.In.ReadLine);}
        }finally{RenderingServer.FramePostDraw-=Observe;}
        Report("VR263_FINISH",new{explicit_finish=true});await app.CloseApplication();
    }
}
