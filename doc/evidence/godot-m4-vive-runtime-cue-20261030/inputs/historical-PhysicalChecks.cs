using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

// Diagnostic-only partial, supplied to a separate source-only export. Real
// Main, signed views, source/router, Control tree and render owners are reused.
public partial class ExportChecks
{
    async Task VivePhysical()
    {
        var adapter=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        // Reuse the already qualified read-only instruction Label on the shared
        // GUI viewport. Only this diagnostic frame owner changes its text.
        var instruction=new Label { Name="vive-look-instruction",Position=new(30,30),MouseFilter=Control.MouseFilterEnum.Ignore };
        instruction.AddThemeFontSizeOverride("font_size",32);
        instruction.Text=ViveLookCue.Waiting;gui.Surface.AddChild(instruction);
        string cueState=instruction.Text;
        bool High(XRPose? pose)=>pose?.HasTrackingData==true && pose.TrackingConfidence==XRPose.TrackingConfidenceEnum.High;
        bool HandReady(string hand)=>adapter.Sources.Any(s=>s.Hand==hand && s.Current(0) &&
            High(s.Tracker.GetPose("aim")) && High(s.Tracker.GetPose("grip")) &&
            s.Grip.GetChildren().OfType<Node3D>().Any(n=>n.IsVisibleInTree() && n.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>().Any(m=>m.IsVisibleInTree())));
        var rows=new Dictionary<string,JsonObject>();
        var previous=new Dictionary<(string,string),bool>();
        var pressed=new Dictionary<string,int>();
        var snapshots=new List<object>();
        int frames=0,validHead=0,highHead=0;string headState="";
        string[] components=["xr-standard-trigger","xr-standard-squeeze","xr-standard-touchpad"];
        void Observe()
        {
            frames++;
            if(frames==1)Console.Error.WriteLine("M4_VIVE_FIRST_DRAW");
            var head=XRServer.GetTracker("head") as XRPositionalTracker;
            var hp=head?.HasPose("default")==true ? head.GetPose("default") : null;
            string hs=hp==null ? "missing" : hp.HasTrackingData+":"+hp.TrackingConfidence;
            if(hs!=headState){headState=hs;Console.Error.WriteLine("M4_VIVE_HEAD "+hs);}
            if(hp?.HasTrackingData==true && hp.TrackingConfidence!=XRPose.TrackingConfidenceEnum.None){validHead++;if(hp.TrackingConfidence==XRPose.TrackingConfidenceEnum.High)highHead++;}
            var lifecycle=adapter.ObservePhysicalLifecycle();
            var native=XRServer.FindInterface("OpenXR") as OpenXRInterface;
            bool released=adapter.Sources.Where(s=>s.Hand is "left" or "right").All(s=>components.All(id=>s.Read(id) is ComponentSample { Pressed:false }));
            string next=ViveLookCue.Text(lifecycle.Active,lifecycle.ApplicationFocused,lifecycle.PresentationVisible,
                lifecycle.NativeRunning,native?.GetSessionState()==OpenXRInterface.SessionState.Focused,
                High(hp),HandReady("left"),HandReady("right"),released);
            if(next!=cueState) { cueState=next;instruction.Text=next;
                instruction.Modulate=next==ViveLookCue.Ready ? Colors.LimeGreen : Colors.Yellow;
                Console.Error.WriteLine("M4_VIVE_LOOK_CUE "+(next==ViveLookCue.Ready ? "READY" : "WAITING")+" frame="+frames); }
            foreach(var source in adapter.Sources) {
                string name=source.Tracker.Name+":"+source.Tracker.GetInstanceId();
                if(!rows.TryGetValue(name,out var row)) {
                    row=new JsonObject { ["name"]=source.Tracker.Name.ToString(),["instance"]=source.Tracker.GetInstanceId().ToString(),["hand"]=source.Hand,["profile"]=source.Tracker.Profile,["tracked_frames"]=0,["pose_disagreements"]=0,["edges"]=new JsonArray() };rows.Add(name,row);
                }
                var aim=source.Tracker.HasPose("aim") ? source.Tracker.GetPose("aim") : null;
                var grip=source.Tracker.HasPose("grip") ? source.Tracker.GetPose("grip") : null;
                string pose=(aim==null ? "missing" : aim.HasTrackingData+":"+aim.TrackingConfidence)+"/"+(grip==null ? "missing" : grip.HasTrackingData+":"+grip.TrackingConfidence);
                if(row["pose"]?.ToString()!=pose){row["pose"]=pose;Console.Error.WriteLine("M4_VIVE_POSE "+source.Hand+" "+pose);}
                if(source.Current(0)) {
                    row["tracked_frames"]=row["tracked_frames"]!.GetValue<int>()+1;
                    if(!source.Aim.Transform.IsEqualApprox(aim!.GetAdjustedTransform()) || !source.Grip.Transform.IsEqualApprox(grip!.GetAdjustedTransform()))row["pose_disagreements"]=row["pose_disagreements"]!.GetValue<int>()+1;
                }
                foreach(string component in components)if(source.Read(component) is ComponentSample sample) {
                    var key=(name,component);bool prior=previous.GetValueOrDefault(key);
                    if(prior!=sample.Pressed) {
                        var edge=new JsonObject { ["component"]=component,["pressed"]=sample.Pressed,["frame"]=frames,["current"]=source.Current(0),["axes_x"]=sample.Axes.X,["axes_y"]=sample.Axes.Y };
                        row["edges"]!.AsArray().Add(edge);Console.Error.WriteLine("M4_VIVE_EDGE "+source.Hand+" "+edge.ToJsonString());
                    }
                    previous[key]=sample.Pressed;
                }
            }
        }
        // Bounded read-only observation on the existing Godot context, only
        // when a snapshot is requested. No pose, focus or placement is changed.
        object Transform(Transform3D t)=>new {
            origin=new[]{t.Origin.X,t.Origin.Y,t.Origin.Z},
            basis_columns=new[]{new[]{t.Basis.X.X,t.Basis.X.Y,t.Basis.X.Z},new[]{t.Basis.Y.X,t.Basis.Y.Y,t.Basis.Y.Z},new[]{t.Basis.Z.X,t.Basis.Z.Y,t.Basis.Z.Z}}
        };
        object? Pose(XRPose? pose)=>pose==null ? null : new {
            tracked=pose.HasTrackingData,confidence=pose.TrackingConfidence.ToString(),
            raw=Transform(pose.Transform),adjusted=Transform(pose.GetAdjustedTransform())
        };
        object Geometry()
        {
            var camera=(XRCamera3D)adapter.FindChild("xr-camera",true,false);
            var origin=(XROrigin3D)adapter.FindChild("xr-origin",true,false);
            var panel=adapter.GuiSurface;var view=camera.GetCameraTransform();
            var head=XRServer.GetTracker("head") as XRPositionalTracker;
            var native=XRServer.FindInterface("OpenXR") as OpenXRInterface;
            var size=(panel.Mesh as QuadMesh)?.Size??Vector2.Zero;
            var renderCamera=scene.Viewport.GetCamera3D();
            var lifecycle=adapter.ObservePhysicalLifecycle();
            var world=XRServer.WorldOrigin;var reference=XRServer.GetReferenceFrame();var hmd=XRServer.GetHmdTransform();
            var target=native?.GetRenderTargetSize()??Vector2.Zero;
            return new {
                utc=DateTimeOffset.UtcNow.ToString("O"),observed_frame=frames,thread=System.Environment.CurrentManagedThreadId,context=System.Threading.SynchronizationContext.Current?.GetType().FullName,
                thread_model_setting=ProjectSettings.HasSetting("rendering/driver/threads/thread_model") ? ProjectSettings.GetSetting("rendering/driver/threads/thread_model").ToString() : null,
                window_focused=GetWindow().HasFocus(),session_state=native?.GetSessionState().ToString(),
                adapter_lifecycle=new { lifecycle.Active,lifecycle.ApplicationFocused,lifecycle.PresentationVisible,lifecycle.NativeRunning,lifecycle.PredictedDisplayTime,calibration=lifecycle.Calibration is Transform3D c ? Transform(c) : null },
                head=Pose(head?.HasPose("default")==true ? head.GetPose("default") : null),
                world_scale=XRServer.WorldScale,world_origin=Transform(world),reference_frame=Transform(reference),hmd_transform=Transform(hmd),
                native_target_pixels=new[]{target.X,target.Y},
                scene_camera=Transform(scene.CameraPose),xr_origin=Transform(origin.GlobalTransform),
                xr_origin_current=origin.Current,viewport_use_xr=scene.Viewport.UseXR,viewport_pixels=new[]{scene.Viewport.Size.X,scene.Viewport.Size.Y},
                actual_viewport_camera=renderCamera==null ? null : new { name=renderCamera.Name.ToString(),xr_camera=renderCamera==camera,renderCamera.Near,renderCamera.Far,renderCamera.CullMask },
                camera_local=Transform(camera.Transform),camera_global=Transform(camera.GlobalTransform),camera_getter_transform=Transform(view),
                panel=Transform(panel.GlobalTransform),panel_in_camera=Transform(view.AffineInverse()*panel.GlobalTransform),
                camera_in_panel=Transform(panel.GlobalTransform.AffineInverse()*view),panel_visible=panel.IsVisibleInTree(),
                panel_size=new[]{size.X,size.Y},gui_pixels=new[]{gui.Surface.Size.X,gui.Surface.Size.Y},
                representative_font_pixels=app.FindChild("export-backup",true,false) is Button backup ? backup.GetThemeFontSize("font_size") : (int?)null,
                sources=adapter.Sources.Select(s=>new {
                    hand=s.Hand,current=s.Current(0),
                    native_aim=Pose(s.Tracker.HasPose("aim") ? s.Tracker.GetPose("aim") : null),
                    native_grip=Pose(s.Tracker.HasPose("grip") ? s.Tracker.GetPose("grip") : null),
                    aim_local=Transform(s.Aim.Transform),aim_global=Transform(s.Aim.GlobalTransform),
                    grip_local=Transform(s.Grip.Transform),grip_global=Transform(s.Grip.GlobalTransform),
                    models=s.Grip.GetChildren().OfType<Node3D>().Select(n=>new {
                        visible=n.Visible,visible_in_tree=n.IsVisibleInTree(),global=Transform(n.GlobalTransform),
                        meshes=n.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>().Select(m=>new {
                            visible=m.Visible,visible_in_tree=m.IsVisibleInTree(),layers=m.Layers,global=Transform(m.GlobalTransform),
                            bounds_position=new[]{m.GetAabb().Position.X,m.GetAabb().Position.Y,m.GetAabb().Position.Z},
                            bounds_size=new[]{m.GetAabb().Size.X,m.GetAabb().Size.Y,m.GetAabb().Size.Z}
                        }).ToArray()
                    }).ToArray()
                }).ToArray()
            };
        }
        async Task<object> RendererGeometry(Transform3D panelTransform,Camera3D renderCamera)
        {
            var native=XRServer.FindInterface("OpenXR") as OpenXRInterface ?? throw new InvalidOperationException("OpenXR interface unavailable for observation.");
            var cameraName=renderCamera.Name.ToString();var near=renderCamera.Near;var far=renderCamera.Far;
            using var extension=new OpenXRApiExtension();
            var completion=new TaskCompletionSource<object>(TaskCreationOptions.RunContinuationsAsynchronously);
            RenderingServer.CallOnRenderThread(Callable.From(()=> {
                try {
                    var world=XRServer.WorldOrigin;var reference=XRServer.GetReferenceFrame();var hmd=XRServer.GetHmdTransform();
                    bool locked=XRServer.CameraLockedToOrigin;var eyes=new List<object>();
                    for(uint i=0;i<native.GetViewCount();i++) {
                        // Observe the renderer's composition on its own thread.
                        // These getters can return cached views, not validity.
                        var eye=native.GetTransformForView(i,world);
                        var rendered=locked ? eye*hmd.AffineInverse()*reference.AffineInverse() : eye;
                        eyes.Add(new { index=i,interface_view=Transform(eye),renderer_transform=Transform(rendered),
                            panel_from_main_in_render_eye=Transform(rendered.AffineInverse()*panelTransform),
                            render_eye_in_panel_from_main=Transform(panelTransform.AffineInverse()*rendered) });
                    }
                    var target=native.GetRenderTargetSize();
                    completion.TrySetResult(new { utc=DateTimeOffset.UtcNow.ToString("O"),thread=System.Environment.CurrentManagedThreadId,
                        context=System.Threading.SynchronizationContext.Current?.GetType().FullName,dispatch="RenderingServer.CallOnRenderThread",
                        native_running=extension.IsRunning(),predicted_display_time=extension.GetPredictedDisplayTime(),
                        world_origin=Transform(world),reference_frame=Transform(reference),hmd_transform=Transform(hmd),camera_locked_to_origin=locked,
                        native_target_pixels=new[]{target.X,target.Y},render_view_getters=eyes.ToArray(),getter_count=eyes.Count,
                        camera_name_from_main=cameraName,camera_near_from_main=near,camera_far_from_main=far,
                        native_view_return_status_exposed=false,may_use_cached_views=true,projection_getter_called=false });
                } catch(Exception error) { completion.TrySetException(error); }
            }));
            return await completion.Task;
        }
        object Snapshot(string phase,object? nodeGeometry=null,object? renderer=null)=>new { phase,frames,validHead,highHead,sources=rows.Values.ToArray(),button_presses=pressed.ToDictionary(),router=adapter.Router.Status,metrics=adapter.Metrics,cancellations=gui.Cancellations,state=State,geometry=new { node=nodeGeometry??Geometry(),renderer } };
        async Task Save(string phase,object? nodeGeometry=null,object? renderer=null)
        {
            // Serialize immediately: rows are live observations, not another
            // mutable inventory or deferred reference to a changed snapshot.
            snapshots.Add(JsonSerializer.SerializeToElement(Snapshot(phase,nodeGeometry,renderer)));
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new { diagnostic=true,hardware=true,checks,snapshots }));
            Console.Error.WriteLine("M4_VIVE_RECORDED "+phase);Console.Error.Flush();
        }
        await Press("create-key");await Press("connect");
        Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"physical fixture authenticates the exact owned network");
        await Press("register");
        if(State["human"]==null)await Press("resolve");
        Check(State["human"]!=null,"physical fixture retains its original signed human");
        await Press("prepare");await Press("setup");
        if(State["setup"]==null)await Press("resolve");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true && State["operation_available"]?.GetValue<bool>()==true && State["controller_status"]?["available"]?.GetValue<bool>()==true);
        Check(!app.ActiveAccounts.Uncertain,"physical fixture has no unknown original operation");
        var human=app.ActiveAccounts.Human!;
        var mapping=ControllerMapping.Decode(Json.Binding(await app.ActiveSession.Read(human,"controller_preferences_view(me,View).",CancellationToken.None),"View"))!;
        Check(mapping.Profiles.Single().Model.Digest=="bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94","signed projection selects the pinned admitted Vive appearance");
        foreach(var button in app.FindChildren("*","Button",true,false).OfType<Button>()) {
            string name=button.Name;button.Pressed+=()=>{pressed[name]=pressed.GetValueOrDefault(name)+1;Console.Error.WriteLine("M4_VIVE_GUI "+name);};
        }
        RenderingServer.FramePostDraw+=Observe;
        try {
            await Press("start-xr");Check(adapter.Running,"ordinary signed-in Start OpenXR attaches the real owner");
            await Save("ready");Console.Error.WriteLine("M4_VIVE_PRODUCT_READY");Console.Error.Flush();
            // Console's synchronized reader may perform its read synchronously.
            // Keep that qualification-only blocking stream off the Godot thread;
            // every observation/consumer continuation resumes on its context.
            while(await Task.Run(Console.In.ReadLine) is string command) {
                switch(command) {
                    case "sample": {
                        int fresh=0,headValid=0,both=0;long prior=0;var sourceFrames=new Dictionary<OpenXRInput.Source,int>();bool agreement=true;
                        using var api=new OpenXRApiExtension();
                        for(int i=0;i<90;i++) {
                            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
                            long t=api.GetPredictedDisplayTime();if(t>prior){fresh++;prior=t;}
                            if(XRServer.GetTracker("head") is XRPositionalTracker h && h.HasPose("default") && h.GetPose("default").HasTrackingData && h.GetPose("default").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None)headValid++;
                            var current=adapter.Sources.Where(s=>s.Current(0)).ToArray();if(current.Any(s=>s.Hand=="left") && current.Any(s=>s.Hand=="right"))both++;
                            foreach(var s in current) {sourceFrames[s]=sourceFrames.GetValueOrDefault(s)+1;agreement&=s.Aim.Transform.IsEqualApprox(s.Tracker.GetPose("aim").GetAdjustedTransform()) && s.Grip.Transform.IsEqualApprox(s.Tracker.GetPose("grip").GetAdjustedTransform());}
                        }
                        snapshots.Add(new { phase="ninety_frames",fresh,headValid,both,agreement,sources=sourceFrames.Select(p=>new {hand=p.Key.Hand,frames=p.Value}) });await Save("sample");
                        Check(fresh>0 && headValid>0 && api.GetViewCount()==2,"ready real runtime supplies fresh confident stereo head frames within ninety draws");
                        Check(both>0 && sourceFrames.Keys.Any(s=>s.Hand=="left") && sourceFrames.Keys.Any(s=>s.Hand=="right"),"both actual Vive sources have current canonical aim and grip within ninety draws");
                        Check(agreement,"both source nodes agree with adjusted native aim and grip transforms");
                        await adapter.Completion;await Save("sample-passed");break;
                    }
                    case "status":await Save("status");break;
                    case "geometry":
                        await adapter.Completion;
                        await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
                        var nodeGeometry=Geometry();var panelTransform=adapter.GuiSurface.GlobalTransform;
                        var renderCamera=scene.Viewport.GetCamera3D() ?? throw new InvalidOperationException("Viewport camera unavailable for observation.");
                        var renderer=await RendererGeometry(panelTransform,renderCamera);
                        await Save("geometry",nodeGeometry,renderer);break;
                    case "gui-check":
                        Check(pressed.GetValueOrDefault("export-backup")==1 && app.FindChild("backup-dialog",true,false)!=null,"one mapped physical trigger release reaches the existing backup GUI once");
                        Check(gui.Captures==0,"physical GUI trigger release retires native capture");await Save("gui-passed");break;
                    case "close-form":
                        if(app.FindChild("operations",true,false) is OperationsPanel operations)operations.Cancel();
                        Check(!adapter.Blocked,"ordinary local form cancellation exposes the shared scene context");await Save("form-closed");break;
                    case "stop":
                        await Press("stop-xr");await adapter.Completion;
                        Check(adapter.Subscriptions==0 && adapter.Router.Count==0 && gui.Captures==0,"real adapter stop retires every source subscription and capture");await Save("stopped");break;
                    case "restart":await Press("start-xr");Check(adapter.Running,"ordinary Start OpenXR reenters the existing native session");await Save("restarted");break;
                    case "finish":await Save("finished");Console.Error.WriteLine("M4_VIVE_PRODUCT_FINISHED");Console.Error.Flush();return;
                    default:throw new InvalidOperationException("Unknown diagnostic instruction.");
                }
            }
            throw new EndOfStreamException("Physical qualification input closed before finish.");
        } finally { RenderingServer.FramePostDraw-=Observe;instruction.GetParent()?.RemoveChild(instruction);instruction.Free();await Save("observer-retired"); }
    }
}

// Included only in this diagnostic source. Observe the existing owner's
// exact gates; do not add a setter, another owner or a production trace.
public partial class OpenXRInput
{
    internal (bool Active,bool ApplicationFocused,bool PresentationVisible,Transform3D? Calibration,bool NativeRunning,long PredictedDisplayTime) ObservePhysicalLifecycle()
        =>(active,applicationFocused,visible,calibration,api.IsRunning(),api.GetPredictedDisplayTime());
}
