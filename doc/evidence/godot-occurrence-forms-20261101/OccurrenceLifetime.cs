using Godot;
using Quod.Client;
using System.Text.Json;
using Json=Quod.Client.Json;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task OccurrenceLifetime(ScenePanel scene,Term subject,string[] ids,string parts)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;var store=app.ActiveStore;
        using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(180));
        async Task Commit(string goal)=>Check(Json.Committed(await ExecuteComplete(session,store,human,goal,limit.Token)),"authorized lifetime fixture edit commits through the existing source owner");
        async Task Parts(string value)=>await Commit("transaction((retract((eidolon(instrument_solid,analyzer,_) :- true)),assertz((eidolon(instrument_solid,analyzer,"+value+") :- true)))).");
        var left=scene.Pick(scene.Project(ids[0],Vector3.Zero))!;var right=scene.Pick(scene.Project(ids[1],Vector3.Zero))!;
        scene.Select(right);
        var pane=(EidolonPanel)app.FindChild("representations",true,false);var ops=pane.Operations;
        await Until(()=>pane.Available&&ops.Available&&pane.Selected?.Operation==true);await Frame();await Frame();
        var editor=(LineEdit)ops.FormPanel.Input("run_name")!;var draft=ops.FormPanel.Draft;
        var personal=(Button)pane.FindChild("form-personal-workspace",true,false);int clicks=0,downs=0;personal.Pressed+=()=>clicks++;personal.ButtonDown+=()=>downs++;
        OccurrencePoint(gui,personal);await Frame();gui.Press();await Frame();
        Check(downs==1&&gui.Captures==1&&gui.FormSurface.GuiGetHoveredControl()==personal,"actual native placement press is captured before the authorized scene change");
        var states=new List<object>();bool withdrawn=false;
        void Observe(){withdrawn|=right.Pose==null;states.Add(new{valid=right.Pose!=null,captures=gui.Captures,pressed=gui.NativePressed,near=pane.NearOccurrence,count=scene.Count,ids=scene.Ids});}
        var flags=System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic;
        var route=((List<SignedView>)typeof(Main).GetField("views",flags)!.GetValue(app)!).First();
        var world=(SignedView)typeof(Main).GetField("worldView",flags)!.GetValue(app)!;
        void Route(string reason)=>states.Add(new{owner="navigation",reason,route.Updating,worldUpdating=world.Updating,valid=right.Pose!=null});
        void World(string reason)=>states.Add(new{owner="world",reason,world.Updating,routeUpdating=route.Updating,valid=right.Pose!=null});
        route.Withdrawn+=Route;world.Withdrawn+=World;
        scene.PresentationChanged+=Observe;
        try {await Parts(parts.Replace("transform(700,0,0","transform(900,0,0"));await Until(()=>State["world_accepted"]!.GetValue<bool>()&&scene.Ids.Contains(ids[1])&&Mathf.IsEqualApprox(scene.WorldPose(ids[1]).Origin.X,.9f));}
        finally{scene.PresentationChanged-=Observe;route.Withdrawn-=Route;world.Withdrawn-=World;}
        gui.Release();await Frame();
        var current=scene.Pick(scene.Project(ids[1],Vector3.Zero));
        await File.WriteAllTextAsync("/work/capture-refresh.json",JsonSerializer.Serialize(new{withdrawn,states,downs,clicks,captures=gui.Captures,oldIdentity=right.Identity,currentIdentity=current?.Identity,oldPose=right.Pose?.ToString(),currentPose=current?.Pose?.ToString(),editorRetained=ReferenceEquals(editor,ops.FormPanel.Input("run_name"))}));
        Check(withdrawn&&clicks==0&&!gui.NativePressed&&gui.Captures==0&&pane.NearOccurrence,"real signed updating and changed geometry cancel the captured action without delivering its release");
        Check(right.Pose!=null&&ReferenceEquals(editor,ops.FormPanel.Input("run_name"))&&ReferenceEquals(draft,ops.FormPanel.Draft)&&left.Pose!=null,"movement and authorized refresh retain both occurrence incarnations and the native form");
        string onlyLeft="["+Term.Parse(parts).Items[0]+"]";
        await Parts(onlyLeft);await Until(()=>State["world_accepted"]!.GetValue<bool>()&&scene.SubjectIds(subject).Length==1);
        Check(right.Pose==null&&left.Pose!=null&&!((Control)pane.FindChild("representation-content",true,false)).IsVisibleInTree(),"removing the selected occurrence withdraws only that placement while the independent occurrence remains");
        await Parts(parts);await Until(()=>State["world_accepted"]!.GetValue<bool>()&&scene.SubjectIds(subject).Length==2);
        var replacement=scene.Pick(scene.Project(ids[1],Vector3.Zero))!;
        Check(replacement.Id==right.Id&&replacement.Identity!=right.Identity&&right.Pose==null&&left.Pose!=null,"reusing a removed mark ID cannot revive the previous visual incarnation");
        int selected=0;void Selected(ScenePanel.Selection _)=>selected++;scene.Selected+=Selected;
        try{scene.Select(right);Check(selected==0,"stale occurrence cannot dispatch a subject choice");scene.Select(replacement);Check(selected==1,"fresh accepted replacement dispatches once through the same subject owner");}
        finally{scene.Selected-=Selected;}
        Check(ReferenceEquals(editor,ops.FormPanel.Input("run_name"))&&ReferenceEquals(draft,ops.FormPanel.Draft)&&pane.Occurrence==replacement,"explicit replacement pick reuses the same semantic controller and local draft");
        // Inspect the real textured plane from a software camera. This is no
        // headset pose, comfort or native OpenXR admission claim.
        xr.PresentWorkspace(true);await Frame();await Frame();
        var originalCamera=scene.Viewport.GetCamera3D();var mode=scene.Viewport.RenderTargetUpdateMode;var dimensions=scene.Viewport.Size;
        var camera=new Camera3D {Position=new(0,1,4),Current=true};scene.Viewport.AddChild(camera);camera.LookAt(new(.3f,.7f,0));
        scene.Viewport.Size=new(1200,800);scene.Viewport.RenderTargetUpdateMode=SubViewport.UpdateMode.Always;
        await Frame();await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
        using(var image=scene.Viewport.GetTexture().GetImage())Check(image.SavePng("/work/occurrence-plane.png")==Error.Ok,"actual scene raster includes the existing textured form plane above the selected object");
        await File.WriteAllTextAsync("/work/occurrence-plane.json",JsonSerializer.Serialize(new{subject=subject.ToString(),left=left.Pose.ToString(),right=replacement.Pose.ToString(),panel=xr.GuiSurface.GlobalTransform.ToString(),xrRunning=xr.Running,visible=xr.GuiSurface.Visible,sameSurface=xr.GuiSurface.MaterialOverride is StandardMaterial3D material&&ReferenceEquals(material.AlbedoTexture,gui.FormSurface.GetTexture())}));
        camera.Current=false;originalCamera.MakeCurrent();camera.QueueFree();scene.Viewport.Size=dimensions;scene.Viewport.RenderTargetUpdateMode=mode;
        xr.PresentWorkspace(false);await Frame();await Frame();
        await Commit("transaction((retract((class_permission(occurrence_instrument,configure,allow) :- true)),assertz((class_permission(occurrence_instrument,configure,deny) :- true)))).");
        await Until(()=>ops.Available&&ops.Current?.Availability=="unavailable");
        await ops.Submit();
        Check(ops.LastOutcome!=null&&!Json.Committed(ops.LastOutcome),"the original explicit operation is refused by the executing agent's committed permission owner");
        string recipe=$"class_eidolon(occurrence_instrument,operation(instance),configure,recipe({Term.Text(human.Namespace)},{Term.Binary(Identity.Decode(human.Anchor))},instrument_form))";
        await Commit("retract(("+recipe+" :- true)).");await Until(()=>ops.Available&&ops.Offered.Count==0);
        Check(ops.Current==null&&ops.FormPanel.Descriptor==null,"actual authored-offer withdrawal removes its native action controls");
        await Renew(app,"worldView");Check(State["world_accepted"]!.GetValue<bool>()&&scene.SubjectIds(subject).Length==2,"fresh independent world acceptance remains separate from form permission denial");
        var result=await session.Read(human,"findall(X,instrument_configuration(X),Configurations).",limit.Token);
        Check(Json.Binding(result,"Configurations").Items.Length==0&&!store.Snapshot!.Pending.Any(),"selection capture cancellation movement removal and refusal submit no domain configuration or replay");
    }
}
