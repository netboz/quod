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
            return new {
                utc=DateTimeOffset.UtcNow.ToString("O"),window_focused=GetWindow().HasFocus(),session_state=native?.GetSessionState().ToString(),
                head=Pose(head?.HasPose("default")==true ? head.GetPose("default") : null),
                scene_camera=Transform(scene.CameraPose),xr_origin=Transform(origin.GlobalTransform),
                camera_local=Transform(camera.Transform),camera_global=Transform(camera.GlobalTransform),camera_view=Transform(view),
                panel=Transform(panel.GlobalTransform),panel_in_camera=Transform(view.AffineInverse()*panel.GlobalTransform),
                camera_in_panel=Transform(panel.GlobalTransform.AffineInverse()*view),panel_visible=panel.IsVisibleInTree(),
                panel_size=new[]{size.X,size.Y},gui_pixels=new[]{gui.Surface.Size.X,gui.Surface.Size.Y},
                sources=adapter.Sources.Select(s=>new {
                    hand=s.Hand,current=s.Current(0),
                    native_aim=Pose(s.Tracker.HasPose("aim") ? s.Tracker.GetPose("aim") : null),
                    native_grip=Pose(s.Tracker.HasPose("grip") ? s.Tracker.GetPose("grip") : null),
                    aim_local=Transform(s.Aim.Transform),aim_global=Transform(s.Aim.GlobalTransform),
                    grip_local=Transform(s.Grip.Transform),grip_global=Transform(s.Grip.GlobalTransform),
                    models=s.Grip.GetChildren().OfType<Node3D>().Select(n=>new {
                        visible=n.Visible,visible_in_tree=n.IsVisibleInTree(),global=Transform(n.GlobalTransform),
                        meshes=n.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>().Select(m=>new {
                            visible=m.Visible,visible_in_tree=m.IsVisibleInTree(),global=Transform(m.GlobalTransform),
                            bounds_position=new[]{m.GetAabb().Position.X,m.GetAabb().Position.Y,m.GetAabb().Position.Z},
                            bounds_size=new[]{m.GetAabb().Size.X,m.GetAabb().Size.Y,m.GetAabb().Size.Z}
                        }).ToArray()
                    }).ToArray()
                }).ToArray()
            };
        }
        object Snapshot(string phase)=>new { phase,frames,validHead,highHead,sources=rows.Values.ToArray(),button_presses=pressed.ToDictionary(),router=adapter.Router.Status,metrics=adapter.Metrics,cancellations=gui.Cancellations,state=State,geometry=Geometry() };
        async Task Save(string phase)
        {
            // Serialize immediately: rows are live observations, not another
            // mutable inventory or deferred reference to a changed snapshot.
            snapshots.Add(JsonSerializer.SerializeToElement(Snapshot(phase)));
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
        } finally { RenderingServer.FramePostDraw-=Observe;await Save("observer-retired"); }
    }
}
