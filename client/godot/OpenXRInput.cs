using Godot;
using Quod.Client;
using NumericsVector2=System.Numerics.Vector2;
using System.Runtime.InteropServices;

// Godot owns tracker/action observations and the OpenXR session. This adapter
// owns their scene lifetime and feeds the ordinary GUI, picking and sender.
public partial class OpenXRInput : Node3D,IControllerConsumer
{
    public sealed class Source : IControllerSource,IDisposable
    {
        public XRControllerTracker Tracker { get; }
        public Node3D Aim { get; }=new() { Name="source-ray" };
        public Node3D Grip { get; }=new() { Name="source-grip" };
        public MeshInstance3D Pointer { get; }=new() { Visible=false };
        // Where the finger rested on the pad last frame while pointing at a panel.
        public Vector2? PadRest;
        bool Alive=>!disposed && IsInstanceValid(Tracker);
        public string Hand=>!Alive ? "none" : Tracker.Hand switch { XRPositionalTracker.TrackerHand.Left=>"left",XRPositionalTracker.TrackerHand.Right=>"right",_=>"none" };
        public string[] Profiles=>Alive && Tracker.Profile=="/interaction_profiles/htc/vive_controller" ? ["htc-vive"] : [];
        static readonly (string Id,string Type,string Press,string? Value,string? Touch,string? Axes)[] Components=[
            ("xr-standard-trigger","trigger","trigger_press","trigger_value",null,null),
            ("xr-standard-squeeze","squeeze","squeeze_press",null,null,null),
            ("xr-standard-touchpad","touchpad","pad_press",null,"pad_touch","pad_axes")];
        public string Layout=>(Alive ? Tracker.Profile : "unavailable")+":"+Hand+":"+string.Join(',',Components.Select(c=>c.Id+":"+string.Join(',',Read(c.Id)?.Features??[])));
        bool disposed;
        public Source(XRControllerTracker tracker,Node3D parent)
        {
            Tracker=tracker;parent.AddChild(Aim);parent.AddChild(Grip);
            var line=new ImmediateMesh();line.SurfaceBegin(Mesh.PrimitiveType.Lines);line.SurfaceAddVertex(Vector3.Zero);line.SurfaceAddVertex(new(0,0,-2));line.SurfaceEnd();
            Pointer.Mesh=line;Pointer.MaterialOverride=new StandardMaterial3D { ShadingMode=BaseMaterial3D.ShadingModeEnum.Unshaded,AlbedoColor=Colors.Gold };Aim.AddChild(Pointer);
        }
        // Godot translates the authored OpenXR grip_pose action to tracker pose grip.
        public bool GripTracked=>Alive && XRServer.GetTracker(Tracker.Name)?.GetInstanceId()==Tracker.GetInstanceId() &&
            Tracker.HasPose("grip") && Tracker.GetPose("grip").HasTrackingData &&
            Tracker.GetPose("grip").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None;
        public bool Current(ulong frame)=>GripTracked && Tracker.HasPose("aim") &&
            Tracker.GetPose("aim").HasTrackingData && Tracker.GetPose("aim").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None;
        public void UpdatePose()
        { if(!Alive)return;if(Tracker.HasPose("aim"))Aim.Transform=Tracker.GetPose("aim").GetAdjustedTransform();if(Tracker.HasPose("grip"))Grip.Transform=Tracker.GetPose("grip").GetAdjustedTransform(); }
        public ComponentSample? Read(string id)
        {
            if(!Alive || Profiles.Length==0)return null;
            var component=Components.SingleOrDefault(c=>c.Id==id);if(component.Id==null)return null;
            var press=Tracker.GetInput(component.Press);if(press.VariantType!=Variant.Type.Bool)return null;
            var features=new List<string>{"press"};var axes=Vector2.Zero;
            if(component.Value!=null && Tracker.GetInput(component.Value).VariantType==Variant.Type.Float)features.Add("value");
            if(component.Touch!=null && Tracker.GetInput(component.Touch).VariantType==Variant.Type.Bool)features.Add("touch");
            if(component.Axes!=null && Tracker.GetInput(component.Axes).VariantType==Variant.Type.Vector2) { features.Add("axes2");axes=Tracker.GetInput(component.Axes).AsVector2(); }
            // OpenXR +Y is up; the portable touchpad contract uses forward=-Y.
            return new(component.Type,features.ToArray(),press.AsBool(),new(axes.X,-axes.Y));
        }
        public void Dispose()
        { if(disposed)return;disposed=true;Aim.GetParent()?.RemoveChild(Aim);Grip.GetParent()?.RemoveChild(Grip);Aim.Free();Grip.Free(); }
    }
    sealed class Visual
    {
        public ControllerProfile? Profile;
        public string? Asset;
        public RenderModels.Lease? Lease;
        public Node3D? Model;
        public string? Failure;
        public long Incarnation;
        public Task Loading=Task.CompletedTask;
    }
    readonly Dictionary<StringName,Source> sources=[];
    readonly Dictionary<IControllerSource,Visual> visuals=[];
    readonly List<Task> loading=[];
    readonly XROrigin3D origin=new() { Name="xr-origin" };
    readonly XRCamera3D camera=new() { Name="xr-camera" };
    readonly MeshInstance3D panel=new() { Name="shared-gui-surface",Mesh=new QuadMesh { Size=new(1.5f,1) } };
    // The pie has its own world-locked surface; the working panel stays put.
    readonly SubViewport pieViewport=new() { Name="pie-viewport",Size=new(800,800),TransparentBg=true,HandleInputLocally=true,Disable3D=true };
    readonly MeshInstance3D pieQuad=new() { Name="pie-surface",Mesh=new QuadMesh(),Visible=false };
    // The HUD strip: body-locked below the central view, tagging along.
    readonly SubViewport hudViewport=new() { Name="hud-viewport",Size=new(1200,(int)HudBar.Height),TransparentBg=true,HandleInputLocally=true,Disable3D=true };
    readonly MeshInstance3D hudQuad=new() { Name="hud-surface",Mesh=new QuadMesh(),Visible=false };
    // The strip stands in the room: where it was placed, from which eye and
    // heading, and the glide that takes it to a new place.
    Transform3D? hudPlaced;
    Transform3D hudFrom;
    Vector3 hudEye;
    float? hudYaw;
    float hudGlide=1;
    bool pointingHud;
    readonly OpenXRApiExtension api=new();
    OpenXRInterface? xr;
    ScenePanel scene=null!;
    SpatialGui gui=null!;
    RenderModels models=null!;
    Func<PhysicsInput?> controls=null!;
    Func<bool> blocked=null!;
    PieMenu pie=null!;
    Func<ScenePanel.Selection?,bool> openPie=null!;
    Func<bool> dismissForm=null!;
    bool attached,presentationSubscribed,active,lifecycleSubscribed,shuttingDown,visible=true,disposed,pointingGui,pointingPie;
    bool workspaceShown=true,placeRequested,movingWorkspace;
    float workspaceDistance=2;
    Transform3D? calibration;
    Vector2I panelPixels;
    string? controlIdentity,mappingIdentity;
    ScenePanel.Selection? pressedSubject;
    ScenePanel.Selection? occurrence;
    Transform3D personalPose;
    Basis occurrenceBasis;
    // Where the form beside a thing in the world was placed, and the thing's
    // pose it was placed for: it stays there until the thing moves.
    (Transform3D Thing,Transform3D Form)? besideThing;
    IControllerSource? pointerSource,pieSource;
    public ControllerInput Router { get; private set; }=null!;
    public bool Running=>active;
    public bool Available=>XRServer.FindInterface("OpenXR") is OpenXRInterface candidate && candidate.IsInitialized() &&
        candidate.GetSessionState() is not (OpenXRInterface.SessionState.Stopping or OpenXRInterface.SessionState.LossPending or OpenXRInterface.SessionState.Exiting);
    public bool WorkspaceVisible=>workspaceShown;
    public bool MovingWorkspace=>movingWorkspace;
    public int MenuRedraws=>pie.Redraws;
    public int LateCallbacks { get; private set; }
    public int Subscriptions { get; private set; }
    public int DriveRequests { get; private set; }
    public int StopRequests { get; private set; }
    public int SnapRequests { get; private set; }
    public int TeleportRequests { get; private set; }
    public string Status { get; private set; }="OpenXR is stopped.";
    public event Action? Changed;
    public Task Completion=>Task.WhenAll(loading);
    public bool AppearanceFailed=>visuals.Values.Any(v=>v.Profile!=null && v.Failure!=null);
    public string AppearanceDetails=>string.Join('\n',visuals.Values.Where(v=>v.Profile!=null && v.Failure!=null).Select(v=>v.Failure));
    public string AppearanceStatus=>AppearanceFailed ? "Controller models could not load." :
        visuals.Values.Any(v=>v.Profile!=null && v.Asset!=null && v.Model==null) ? "Loading controllers…" : "";
    public void RetryAppearances()
    {
        foreach(var (source,visual) in visuals.ToArray())if(visual.Profile!=null && visual.Failure!=null) {
            visual.Asset=null;Appearance(source,visual.Profile);
        }
    }
    public object Metrics=>new { Running,Subscriptions,sources=sources.Count,appearances=visuals.Count,MenuRedraws,LateCallbacks,captures=gui.Captures,DriveRequests,StopRequests,SnapRequests,TeleportRequests,resources=models.Metrics };
    internal MeshInstance3D GuiSurface=>panel;
    internal ScenePanel.Selection? BoundOccurrence=>occurrence;
    internal Source[] Sources=>sources.Values.ToArray();
    public bool Blocked=>blocked() || gui.TextEntryActive;
    internal SubViewport PieSurface=>pieViewport;
    internal SubViewport HudSurface=>hudViewport;
    internal MeshInstance3D HudQuad=>hudQuad;
    internal MeshInstance3D PieQuad=>pieQuad;
    public DeviceProfile Profile { get; set; }=DeviceProfile.Vive;
    // The caller resolves the pointed target and starts its signed menu read;
    // it also answers a press that lands outside an open form, saying whether
    // that press was used.
    public void Configure(ScenePanel scene,SpatialGui gui,RenderModels models,Func<PhysicsInput?> controls,Func<bool> blocked,PieMenu pie,Func<ScenePanel.Selection?,bool> openPie,Func<bool> dismissForm)
    {
        this.scene=scene;this.gui=gui;this.models=models;this.controls=controls;this.blocked=blocked;this.pie=pie;this.openPie=openPie;this.dismissForm=dismissForm;
        pie.Selected+=_=>MenuClosed();pie.Dismissed+=MenuClosed;
        AddChild(origin);origin.AddChild(camera);AddChild(panel);AddChild(pieViewport);AddChild(pieQuad);AddChild(hudViewport);AddChild(hudQuad);
        // The strip and the pie are the hand's own tools: they draw over any
        // boundary or thing between the eye and them, never half behind it.
        hudQuad.MaterialOverride=new StandardMaterial3D { ShadingMode=BaseMaterial3D.ShadingModeEnum.Unshaded,AlbedoTexture=hudViewport.GetTexture(),
            Transparency=BaseMaterial3D.TransparencyEnum.Alpha,CullMode=BaseMaterial3D.CullModeEnum.Disabled,NoDepthTest=true,RenderPriority=120 };
        pieQuad.MaterialOverride=new StandardMaterial3D { ShadingMode=BaseMaterial3D.ShadingModeEnum.Unshaded,AlbedoTexture=pieViewport.GetTexture(),
            Transparency=BaseMaterial3D.TransparencyEnum.Alpha,CullMode=BaseMaterial3D.CullModeEnum.Disabled,NoDepthTest=true,RenderPriority=127 };
        panel.MaterialOverride=new StandardMaterial3D { ShadingMode=BaseMaterial3D.ShadingModeEnum.Unshaded,AlbedoTexture=gui.Surface.GetTexture(),Transparency=BaseMaterial3D.TransparencyEnum.Alpha,CullMode=BaseMaterial3D.CullModeEnum.Disabled };
        panel.Visible=false;Router=new(this);Router.Changed+=()=>Changed?.Invoke();
    }
    public bool Start()
    {
        if(disposed || shuttingDown || active)return active;
        xr=XRServer.FindInterface("OpenXR") as OpenXRInterface;
        if(!Available || xr==null) { Status="No VR runtime or headset was found when Quod started. Start SteamVR with the headset on, then restart Quod.";Changed?.Invoke();return false; }
        xr.SessionFocussed+=Focused;xr.SessionVisible+=Unfocused;xr.SessionSynchronized+=Unfocused;xr.SessionStopping+=Stopping;
        xr.SessionLossPending+=Stopping;xr.InstanceExiting+=Stopping;xr.PoseRecentered+=Recentered;Subscriptions+=7;
        lifecycleSubscribed=true;xr.SetActionSetActive("quod_inputs",true);
        AttachSources();active=true;calibration=null;hudPlaced=null;
        scene.ReleaseInput();scene.PresentXR(true);
        gui.Surface.GuiEmbedSubwindows=true;
        camera.Current=true;PresentWorkspace(true);
        Status="OpenXR active; input requires current focused tracking and signed settings.";Changed?.Invoke();return true;
    }
    // Shared with injected XRServer tracker qualification. No alternate input
    // interpretation or application action path is selected here.
    internal void AttachSources()
    {
        if(attached || disposed)return;attached=true;
        XRServer.Singleton.TrackerAdded+=TrackerAdded;XRServer.Singleton.TrackerRemoved+=TrackerRemoved;XRServer.Singleton.TrackerUpdated+=TrackerUpdated;Subscriptions+=3;
        ObservePresentation(true);ResizePanel();
        foreach(var name in XRServer.GetTrackers((int)XRServer.TrackerType.Controller).Keys)ReconcileSource(name.AsStringName());
    }
    void ReconcileSource(StringName name)
    {
        if(!attached || disposed) { LateCallbacks++;return; }
        var tracker=XRServer.GetTracker(name) as XRControllerTracker;
        if(tracker!=null && (tracker.Type&XRServer.TrackerType.Controller)==0)tracker=null;
        if(sources.TryGetValue(name,out var current) && tracker!=null && IsInstanceValid(current.Tracker) && current.Tracker.GetInstanceId()==tracker.GetInstanceId()) { Router.SourceChanged();return; }
        RetireSource(name);if(tracker==null)return;
        var source=new Source(tracker,origin);sources.Add(name,source);Router.Add(source);
        tracker.ProfileChanged+=ProfileChanged;Subscriptions++;
    }
    // The engine emits removal before erasing its registry. Observe the
    // installed result after that callback, with Current fencing dispatch now.
    void TrackerAdded(StringName name,long type)=>Callable.From(()=>ReconcileSource(name)).CallDeferred();
    void TrackerRemoved(StringName name,long type)=>Callable.From(()=>ReconcileSource(name)).CallDeferred();
    void TrackerUpdated(StringName name,long type)=>Callable.From(()=>ReconcileSource(name)).CallDeferred();
    void ProfileChanged(string profile)=>Router.SourceChanged();
    void RetireSource(StringName name)
    {
        if(!sources.Remove(name,out var source))return;
        if(IsInstanceValid(source.Tracker))source.Tracker.ProfileChanged-=ProfileChanged;
        Subscriptions--;Router.Remove(source);
    }
    void Focused() { Status="OpenXR focused; release controls before use.";Changed?.Invoke(); }
    void Unfocused() { gui.EndTextInput();CancelPresentation();StopMovingWorkspace();HideVisuals();Status="OpenXR input paused: session has no focus.";Changed?.Invoke(); }
    void Stopping() { Unfocused();Status="OpenXR runtime stopped this session.";Changed?.Invoke(); }
    void Recentered() { Router.Cancel();calibration=null;hudPlaced=null; }
    void CancelPresentation() { Router.Cancel();gui.Cancel(); }
    bool StopMovingWorkspace() { if(!movingWorkspace)return false;movingWorkspace=false;placeRequested=false;return true; }
    public void DesktopFocusLost() { gui.EndTextInput();CancelPresentation();if(StopMovingWorkspace())Changed?.Invoke(); }
    public void Visibility(bool next) { visible=next;if(!next){gui.EndTextInput();CancelPresentation();if(StopMovingWorkspace())Changed?.Invoke();HideVisuals();} }
    public void Install(ControllerMapping? mapping)
    {if(mappingIdentity!=mapping?.Digest){gui.EndTextInput();mappingIdentity=mapping?.Digest;}Router.Install(mapping);}
    void ControlChanged() { if(controlIdentity!=scene.ControlIdentity) { InvalidateWorld();controlIdentity=scene.ControlIdentity; } }
    public void ContextChanged() { ControlChanged();Router.ContextChanged(); }
    // A re-read of the same space keeps the headset where it stands in it and
    // leaves the panel, pie and keyboard in use alone: only a press on a thing
    // of the old view is forgotten. Any other change of world ends those and
    // takes the headset's place again from the agent's.
    public void InvalidateWorld(bool sameSpace=false)
    { pressedSubject=null;if(sameSpace)return;gui.EndTextInput();Router.Cancel();calibration=null; }
    // The tracked head stands at the viewer's place, facing its forward.
    internal void Calibrate(Transform3D head)
    {
        var forward=-head.Basis.Z;var inverse=new Basis(Vector3.Up,-Mathf.Atan2(-forward.X,-forward.Z));
        calibration=new(inverse,-(inverse*head.Origin));
    }
    internal void PresentWorkspace(bool spatial)
    {
        ObservePresentation(spatial||attached);
        gui.PresentSpatial(spatial);workspaceShown=true;movingWorkspace=false;placeRequested=spatial;panel.Visible=false;
        ResizePanel();RefreshOccurrence();Changed?.Invoke();
    }
    void ObservePresentation(bool enabled)
    {
        if(presentationSubscribed==enabled)return;presentationSubscribed=enabled;
        if(enabled){gui.Surface.SizeChanged+=ResizePanel;gui.FormSurface.SizeChanged+=ResizePanel;gui.LayoutChanging+=CancelPresentation;Subscriptions+=3;}
        else {gui.Surface.SizeChanged-=ResizePanel;gui.FormSurface.SizeChanged-=ResizePanel;gui.LayoutChanging-=CancelPresentation;Subscriptions-=3;}
    }
    internal void BindOccurrence(ScenePanel.Selection? selected)
    {
        if(occurrence==selected)return;
        CancelPresentation();
        if(occurrence!=null){occurrence.Owner.PresentationChanged-=RefreshOccurrence;occurrence.Owner.HideForm();}
        if(occurrence==null&&selected!=null)personalPose=panel.GlobalTransform;
        occurrence=selected;besideThing=null;
        if(selected==null){panel.GlobalTransform=personalPose;placeRequested=true;}
        else {occurrenceBasis=selected.Owner.ViewerPose.Basis;selected.Owner.PresentationChanged+=RefreshOccurrence;
            if(!ReferenceEquals(selected.Owner,scene)){panel.GlobalTransform=personalPose;placeRequested=true;}}
        RefreshOccurrence();
    }
    internal void PresentForm(bool form)
    {
        if(gui.FormOnly==form)return;CancelPresentation();gui.FormOnly=form;
        ((StandardMaterial3D)panel.MaterialOverride).AlbedoTexture=gui.PresentationSurface.GetTexture();ResizePanel();RefreshOccurrence();
    }
    void RefreshOccurrence()
    {
        if(occurrence==null)return;
        if(occurrence.Pose is not Transform3D pose){gui.EndTextInput();CancelPresentation();occurrence.Owner.HideForm();panel.Visible=false;return;}
        if(!ReferenceEquals(occurrence.Owner,scene)) {
            // A thing in a side view: the form is drawn inside that view, in
            // its stable orientation, above the thing and clear of its front.
            var corners=occurrence.Corners.Select(p=>occurrenceBasis.Inverse()*(p-pose.Origin)).ToArray();
            float top=corners.Length==0 ? 0 : corners.Max(p=>p.Y),front=corners.Length==0 ? 0 : corners.Max(p=>p.Z);
            var pixels=gui.FormSurface.Size;float width=1.5f*workspaceDistance/2;var size=new Vector2(width,width*pixels.Y/pixels.X);
            float height=size.Y*gui.FormSize.Y/pixels.Y;
            var inView=new Transform3D(occurrenceBasis,pose.Origin+occurrenceBasis*new Vector3(0,top+.15f+height/2,front+.15f));
            if(gui.Spatial&&workspaceShown&&gui.PresentationVisible){if(occurrence.Owner.PresentForm(gui.FormSurface.GetTexture(),size,pixels,new(0,-(size.Y-height)/2,0),inView))CancelPresentation();panel.Visible=true;}
            else occurrence.Owner.HideForm();
            return;
        }
        // A thing in the world: the form stands as the panel does, at its
        // distance and angle below eye level, facing the eye, beside the
        // thing on the side toward where the head looks. It is placed once
        // and stays until the thing moves.
        if(besideThing is not {} placed||placed.Thing!=pose)besideThing=placed=(pose,BesideThing(pose,occurrence.Corners));
        if(panel.GlobalTransform!=placed.Form){CancelPresentation();panel.GlobalTransform=placed.Form;}
        panel.Visible=gui.Spatial&&workspaceShown&&gui.PresentationVisible;
    }
    Transform3D BesideThing(Transform3D thing,Vector3[] corners)
    {
        var head=Head();var eye=head.Origin;
        static float Yaw(Vector3 v)=>Mathf.Atan2(-v.X,-v.Z);
        static float Turn(float from,float to)=>Mathf.Wrap(to-from,-Mathf.Pi,Mathf.Pi);
        var toward=thing.Origin-eye;toward.Y=0;var look=-head.Basis.Z;look.Y=0;
        if(Mathf.IsZeroApprox(toward.LengthSquared()))toward=look;
        float centre=Yaw(toward);
        // Left is a positive turn about Up. Toward the view's centre; straight ahead, to the right.
        float side=Mathf.IsZeroApprox(look.LengthSquared())||Turn(centre,Yaw(look))<=0 ? -1 : 1;
        float reach=corners.Select(c=>{var v=c-eye;v.Y=0;return Mathf.IsZeroApprox(v.LengthSquared()) ? 0 : side*Turn(centre,Yaw(v));}).DefaultIfEmpty(0).Max();
        float half=Mathf.Atan(((QuadMesh)panel.Mesh).Size.X/2/workspaceDistance);
        float heading=centre+side*(Math.Max(0,reach)+half);
        return BelowEye(eye,new(-Mathf.Sin(heading),0,-Mathf.Cos(heading)),workspaceDistance,Profile.PanelBelowEyeDegrees);
    }
    public void ShowWorkspace() { CancelPresentation();StopMovingWorkspace();workspaceShown=true;placeRequested=true;Changed?.Invoke(); }
    public void HideWorkspace() { gui.EndTextInput();CancelPresentation();CancelMenu();workspaceShown=false;movingWorkspace=false;placeRequested=false;panel.Visible=false;Changed?.Invoke(); }
    public void MoveWorkspace() { CancelPresentation();workspaceShown=true;movingWorkspace=!movingWorkspace;placeRequested=movingWorkspace;Changed?.Invoke(); }
    public void WorkspaceDistance(float change)
    { float next=Math.Clamp(workspaceDistance+change,Profile.NearestPanel,Profile.FarthestPanel);if(next==workspaceDistance)return;workspaceDistance=next;ResizePanel();ShowWorkspace(); }
    // Below the central view, at reading distance, facing the eye, standing
    // in the room like the panel. It takes a new place in front only once the
    // head has turned past the follow angle or walked away from where it was
    // placed, gliding there; hidden while a pie is open in front of it.
    void PlaceHud(double seconds)
    {
        // The keyboard extends below the panel, into the strip's place: the strip waits while it is up.
        bool shown=gui.Spatial&&!pie.IsOpen&&!gui.TextEntryActive&&hudViewport.GetChildren().OfType<Control>().Any(c=>c.Visible);
        hudQuad.Visible=shown;if(!shown)return;
        var head=XRServer.GetTracker("head") as XRPositionalTracker;
        if(head?.HasPose("default")!=true||!head.GetPose("default").HasTrackingData)return;
        var headWorld=origin.GlobalTransform*head.GetPose("default").GetAdjustedTransform();
        var forward=-headWorld.Basis.Z;forward.Y=0;if(Mathf.IsZeroApprox(forward.LengthSquared()))return;
        float yaw=Mathf.RadToDeg(Mathf.Atan2(-forward.X,-forward.Z)),reading=Profile.ReadingDistance;
        // The workspace's own angular text density: 1600 surface pixels per metre of distance.
        ((QuadMesh)hudQuad.Mesh).Size=new(hudViewport.Size.X*reading/1600,hudViewport.Size.Y*reading/1600);
        float? heading=Profile.FollowYaw(hudYaw,yaw);
        if(hudPlaced==null||heading!=hudYaw||headWorld.Origin.DistanceTo(hudEye)>Profile.HudFollowMetres) {
            hudYaw=heading;hudEye=headWorld.Origin;float turn=Mathf.DegToRad(heading!.Value);
            var target=BelowEye(hudEye,new(-Mathf.Sin(turn),0,-Mathf.Cos(turn)),reading,Profile.HudBelowEyeDegrees);
            if(hudPlaced==null){hudGlide=1;hudQuad.GlobalTransform=target;}else{hudGlide=0;hudFrom=hudQuad.GlobalTransform;}
            hudPlaced=target;
        }
        if(hudGlide>=1)return;
        hudGlide=Math.Min(1,hudGlide+(float)(seconds/Profile.HudGlideSeconds));
        hudQuad.GlobalTransform=hudFrom.InterpolateWith(hudPlaced.Value,Mathf.SmoothStep(0,1,hudGlide));
    }
    // Where the eyes are in the viewed space's own frame (millimetres and
    // degrees, as its marks are placed) and the level direction they look
    // along in thousandths, for a form field the device fills.
    internal Term? ViewerPose()
    {
        if(XRServer.GetTracker("head") is not XRPositionalTracker head||!head.HasPose("default")||!head.GetPose("default").HasTrackingData)return null;
        var eye=scene.SceneRoot.GlobalTransform.AffineInverse()*(origin.GlobalTransform*head.GetPose("default").GetAdjustedTransform());
        var forward=-eye.Basis.Z;forward.Y=0;if(Mathf.IsZeroApprox(forward.LengthSquared()))return null;forward=forward.Normalized();
        static Term N(float value)=>Term.Number(((long)Mathf.Round(value)).ToString());
        return Term.Call("view",
            Term.Call("transform",N(eye.Origin.X*1000),N(eye.Origin.Y*1000),N(eye.Origin.Z*1000),N(0),N(Mathf.RadToDeg(Mathf.Atan2(-forward.X,-forward.Z))),N(0)),
            Term.Call("forward",N(forward.X*1000),N(0),N(forward.Z*1000)));
    }
    // A surface along a level heading, the given angle below eye level, turned to face the eye.
    static Transform3D BelowEye(Vector3 eye,Vector3 heading,float distance,float degrees)
    {
        float below=Mathf.DegToRad(degrees);var at=eye+heading*distance*Mathf.Cos(below)-Vector3.Up*distance*Mathf.Sin(below);
        return new(Basis.LookingAt((at-eye).Normalized(),Vector3.Up),at);
    }
    Vector2? HudHit(IControllerSource source)
    {
        if(!hudQuad.Visible)return null;
        var ray=Ray(source);var inverse=hudQuad.GlobalTransform.AffineInverse();var start=inverse*ray.Origin;var direction=inverse.Basis*ray.Direction;
        if(Math.Abs(direction.Z)<0.000001f)return null;float distance=-start.Z/direction.Z;if(distance<0)return null;
        var size=((QuadMesh)hudQuad.Mesh).Size;var point=start+direction*distance;
        if(Math.Abs(point.X)>size.X/2||Math.Abs(point.Y)>size.Y/2)return null;
        return new Vector2((point.X/size.X+0.5f)*hudViewport.Size.X,(0.5f-point.Y/size.Y)*hudViewport.Size.Y);
    }
    void HudPointer(Vector2 at,bool? pressed)
    {
        InputEventMouse e=pressed is bool down ? new InputEventMouseButton { ButtonIndex=MouseButton.Left,Pressed=down } : new InputEventMouseMotion();
        e.Position=e.GlobalPosition=at;hudViewport.PushInput(e,true);
    }
    void PlaceWorkspace(bool presentable,bool interactive)
    {
        if(!interactive && StopMovingWorkspace())Changed?.Invoke();
        bool shown=workspaceShown&&gui.PresentationVisible;
        if(occurrence==null&&!shown)panel.Visible=false;
        if(!presentable)return;
        if(occurrence!=null&&ReferenceEquals(occurrence.Owner,scene))return;
        if(!gui.Spatial)return;
        if(!placeRequested&&!movingWorkspace){if(occurrence==null)panel.Visible=shown;return;}
        var head=XRServer.GetTracker("head") as XRPositionalTracker;
        if(head?.HasPose("default")!=true)return;
        var pose=head.GetPose("default");
        if(!pose.HasTrackingData || pose.TrackingConfidence==XRPose.TrackingConfidenceEnum.None)return;
        var headWorld=origin.GlobalTransform*pose.GetAdjustedTransform();
        var forward=-headWorld.Basis.Z;forward.Y=0;
        if(Mathf.IsZeroApprox(forward.LengthSquared()))return;
        // In front of where the head looks now, then world-locked.
        var target=BelowEye(headWorld.Origin,forward.Normalized(),workspaceDistance,Profile.PanelBelowEyeDegrees);
        if(panel.GlobalTransform!=target)panel.GlobalTransform=target;
        placeRequested=false;panel.Visible=shown;
    }
    void ResizePanel()
    {
        var mesh=(QuadMesh)panel.Mesh;var pixels=gui.PresentationSurface.Size;
        // Explicit depth changes preserve angular workspace/text/target scale.
        // Placement remains world-stable; no ordinary frame resizes it.
        float density=workspaceDistance/(2*gui.WorkspaceSize.Y);
        var size=new Vector2(density*pixels.X,density*pixels.Y);
        if(pixels==panelPixels && mesh.Size==size){RefreshOccurrence();return;}
        // A keyboard extension changes only the lower edge. The workspace's
        // pixel/world coordinates stay fixed; retain a press entering another
        // control. Hidden key captures cancel through native visibility.
        if(!gui.Spatial || pixels.X!=panelPixels.X || mesh.Size.X!=size.X)CancelPresentation();
        panelPixels=pixels;
        if(mesh.Size!=size)mesh.Size=size;
        mesh.CenterOffset=new(0,-density*(pixels.Y-gui.WorkspaceSize.Y)/2,0);
        RefreshOccurrence();
    }
    public override void _Process(double delta)
    {
        if(!active || xr==null)return;
        var head=XRServer.GetTracker("head") as XRPositionalTracker;
        bool tracked=head?.HasPose("default")==true && head.GetPose("default").HasTrackingData &&
            head.GetPose("default").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None;
        ControlChanged();
        if(tracked && calibration==null)Calibrate(head!.GetPose("default").Transform);
        long time=api.GetPredictedDisplayTime();
        Advance(time>0 ? (ulong)time : 0,xr.GetSessionState()==OpenXRInterface.SessionState.Focused,api.IsRunning(),tracked,delta);
    }
    internal void Advance(ulong frame,bool focused,bool running,bool tracked,double seconds)
    {
        ControlChanged();
        origin.Transform=scene.ViewerPose*(calibration??Transform3D.Identity);
        bool interactive=focused && running && tracked && visible;
        if(!interactive)gui.EndTextInput();
        foreach(var source in sources.Values)source.UpdatePose();
        // A visible session can show the workspace before it owns input focus.
        PlaceWorkspace(running && tracked && visible,interactive);PlaceHud(seconds);
        Router.Frame(frame,interactive);
        foreach(var (source,visual) in visuals)if(visual.Model!=null)visual.Model.Visible=running && tracked && visible && visual.Profile!=null && ((Source)source).GripTracked;
    }
    void HideVisuals() { foreach(var visual in visuals.Values)if(visual.Model!=null)visual.Model.Visible=false; }
    public void Appearance(IControllerSource input,ControllerProfile? profile)
    {
        if(!visuals.TryGetValue(input,out var visual)) { visual=new();visuals.Add(input,visual); }
        visual.Profile=profile;
        if(profile==null) { if(visual.Model!=null)visual.Model.Visible=false;return; }
        if(visual.Asset==profile.Model.Identity)return;
        loading.RemoveAll(task=>task.IsCompleted);
        visual.Incarnation++;if(visual.Model!=null){models.ReleaseInstance(visual.Model);visual.Model=null;}visual.Lease?.Dispose();
        visual.Failure=null;visual.Asset=profile.Model.Identity;visual.Lease=models.Acquire(profile.Model);long expected=visual.Incarnation;
        async Task Load()
        {
            try {
                var node=await visual.Lease.Instantiate();if(node==null)return;
                if(disposed || !visuals.ContainsKey(input) || visual.Incarnation!=expected) { models.ReleaseInstance(node);return; }
                visual.Model=node;node.Visible=false;((Source)input).Grip.AddChild(node);
            } catch(OperationCanceledException) when(disposed || visual.Incarnation!=expected) { }
            catch(Exception error) { if(!disposed && visual.Incarnation==expected)visual.Failure=error.Message; }
            finally { if(!disposed && visual.Incarnation==expected)Changed?.Invoke(); }
        }
        visual.Loading=Load();loading.Add(visual.Loading);
        Changed?.Invoke();
    }
    public void Remove(IControllerSource input)
    {
        if(visuals.Remove(input,out var visual)) {
            visual.Incarnation++;visual.Lease?.Dispose();if(visual.Model!=null)models.ReleaseInstance(visual.Model);
        }
        ((Source)input).Dispose();
    }
    (Vector3 Origin,Vector3 Direction) Ray(IControllerSource input)
    { var pose=((Source)input).Aim.GlobalTransform;return(pose.Origin,-pose.Basis.Z.Normalized()); }
    (Vector2 Point,float Distance)? GuiHit(IControllerSource source)
    {
        var ray=Ray(source);var inverse=panel.GlobalTransform.AffineInverse();var start=inverse*ray.Origin;var direction=inverse.Basis*ray.Direction;
        if(!panel.Visible || Math.Abs(direction.Z)<0.000001f)return null;float distance=-start.Z/direction.Z;if(distance<0)return null;
        var size=((QuadMesh)panel.Mesh).Size;
        var point=start+direction*distance-((QuadMesh)panel.Mesh).CenterOffset;if(Math.Abs(point.X)>size.X/2 || Math.Abs(point.Y)>size.Y/2)return null;
        return(new Vector2((point.X/size.X+0.5f)*gui.PresentationSurface.Size.X,(0.5f-point.Y/size.Y)*gui.PresentationSurface.Size.Y),distance);
    }
    public void Hover(IControllerSource input,string context)
    {
        if(pointerSource!=null && pointerSource!=input)return;
        ((Source)input).Pointer.Visible=true;
        var source=(Source)input;var hit=GuiHit(input);source.Pointer.Scale=new(1,1,(hit?.Distance??2)/2);
        // Only the controller that opened the pie steers it; once its ray
        // leaves the pie's surface it points nothing.
        if(pie.IsOpen) {
            if(PiePoint(input) is {} on){if(pieSource==null||input==pieSource)pie.PointerAt(on);}
            else if(input==pieSource)pie.PointerAway();
            return;
        }
        if(HudHit(input) is {} onHud){HudPointer(onHud,null);scene.PointAt(null);return;}
        if(hit==null&&pointerSource==null&&!Blocked&&Router.MenuOwner==null)PointTarget(input);else scene.PointAt(null);
        if(hit is {} at){gui.Move(at.Point,gui.PresentationSurface);PadScroll(source,at.Point);}
        else {source.PadRest=null;if(pointerSource==input && pointingGui)gui.Move(new(-10000,-10000),gui.PresentationSurface);else gui.Leave();}
    }
    // Sliding a finger on the pad while pointing at a panel scrolls it there,
    // like a wheel: one step per fraction of the pad's travel. Pressing the
    // pad keeps its authored binding; this reads the touch alone.
    void PadScroll(Source source,Vector2 at)
    {
        var tracker=source.Tracker;
        if(!IsInstanceValid(tracker)||tracker.GetInput("pad_touch").VariantType!=Variant.Type.Bool||!tracker.GetInput("pad_touch").AsBool()){source.PadRest=null;return;}
        var axes=tracker.GetInput("pad_axes").AsVector2();
        if(source.PadRest is not Vector2 rest){source.PadRest=axes;return;}
        const float step=.12f;int steps=(int)((axes.Y-rest.Y)/step);
        if(steps==0)return;
        source.PadRest=new(axes.X,rest.Y+steps*step);
        var button=steps>0 ? MouseButton.WheelUp : MouseButton.WheelDown;
        for(int i=0;i<Math.Abs(steps);i++) {
            gui.PresentationSurface.PushInput(new InputEventMouseButton { Position=at,GlobalPosition=at,ButtonIndex=button,Pressed=true,Factor=1 },true);
            gui.PresentationSurface.PushInput(new InputEventMouseButton { Position=at,GlobalPosition=at,ButtonIndex=button,Pressed=false,Factor=1 },true);
        }
    }
    public void Hide(IControllerSource input){((Source)input).Pointer.Visible=false;scene.PointAt(null);}
    // Feedback before the press: the pointed thing shows its pointed-at look;
    // its name is already written above it. Pointing at nothing shows nothing.
    void PointTarget(IControllerSource input)
    { var ray=Ray(input);scene.PointAt(scene.PickRay(ray.Origin,ray.Direction)); }
    // World-locked placement, never following the head: in front of the
    // pointed object (pulled in to reading distance), or along the ray at
    // reading distance for the space; in both cases at least as far below
    // eye level as the profile says.
    void PlacePie(IControllerSource input,ScenePanel.Selection? hit)
    {
        var ray=Ray(input);float reading=Profile.ReadingDistance,radius=PieRadius;
        float distance=hit?.Pose is Transform3D pose ? Math.Clamp((pose.Origin-ray.Origin).Dot(ray.Direction)-radius,radius,reading) : reading;
        var at=ray.Origin+ray.Direction*distance;var head=Head();
        float level=new Vector2(at.X-head.Origin.X,at.Z-head.Origin.Z).Length();
        at.Y=Math.Min(at.Y,head.Origin.Y-level*Mathf.Tan(Mathf.DegToRad(Profile.PieBelowEyeDegrees)));
        PlacePieQuad(at,head);
    }
    // A strip command's pie opens just in front of that command.
    internal void PlacePieAtHud(Vector2 surfacePoint)
    {
        var size=((QuadMesh)hudQuad.Mesh).Size;
        var on=hudQuad.GlobalTransform*new Vector3((surfacePoint.X/hudViewport.Size.X-.5f)*size.X,(.5f-surfacePoint.Y/hudViewport.Size.Y)*size.Y,0);
        var head=Head();var toward=head.Origin-on;
        PlacePieQuad(toward.LengthSquared()>1e-6f ? on+toward.Normalized()*PieRadius : on,head);
    }
    // The workspace's own angular text density: 1600 surface pixels per metre of distance.
    float PieRadius=>300*Profile.ReadingDistance/1600;
    Transform3D Head()=>XRServer.GetTracker("head") is XRPositionalTracker tracker && tracker.HasPose("default") ?
        origin.GlobalTransform*tracker.GetPose("default").GetAdjustedTransform() : camera.GlobalTransform;
    void PlacePieQuad(Vector3 at,Transform3D head)
    {
        float size=pieViewport.Size.X*Profile.ReadingDistance/1600;var facing=at-head.Origin;
        ((QuadMesh)pieQuad.Mesh).Size=new(size,size);
        pieQuad.GlobalTransform=new(facing.LengthSquared()>1e-6f ? Basis.LookingAt(facing.Normalized(),Vector3.Up) : head.Basis,at);
        pieQuad.Visible=true;
    }
    // Where a controller's ray meets the surface that shows the pie.
    Vector2? PiePoint(IControllerSource source)=>pieQuad.Visible ? PieHit(source) : GuiHit(source)?.Point;
    Vector2? PieHit(IControllerSource source)
    {
        var ray=Ray(source);var inverse=pieQuad.GlobalTransform.AffineInverse();var start=inverse*ray.Origin;var direction=inverse.Basis*ray.Direction;
        if(Math.Abs(direction.Z)<0.000001f)return null;float distance=-start.Z/direction.Z;if(distance<0)return null;
        var size=((QuadMesh)pieQuad.Mesh).Size;var point=start+direction*distance;
        return new Vector2((point.X/size.X+0.5f)*pieViewport.Size.X,(0.5f-point.Y/size.Y)*pieViewport.Size.Y);
    }
    public void Press(IControllerSource input)
    {
        if(gui.NativePressed)return;
        pointerSource=input;pressedSubject=null;
        if(pie.IsOpen){pointingPie=true;Trace.Line("press","pie");return;}
        if(HudHit(input) is {} onHud){pointingHud=true;HudPointer(onHud,true);Trace.Line("press",$"strip at={(Vector2I)onHud}");return;}
        if(GuiHit(input) is {} hit) { pointingGui=true;gui.Move(hit.Point,gui.PresentationSurface);Trace.Line("press",$"panel at={(Vector2I)hit.Point} control={gui.Pointed}");gui.Press(); }
        else if(dismissForm()) { pointingGui=false;Trace.Line("press","outside the open form"); }
        else { pointingGui=false;if(!Blocked && Router.MenuOwner==null){var ray=Ray(input);pressedSubject=scene.PickRay(ray.Origin,ray.Direction);}Trace.Line("press",$"world thing={pressedSubject?.Label??(pressedSubject==null ? "none" : "unlabelled")}"); }
    }
    public void Release(IControllerSource input)
    {
        if(pointerSource!=input)return;pointerSource=null;
        if(pointingPie){pointingPie=false;if(pie.IsOpen)pie.CommitAt(PiePoint(input));return;}
        // A strip command that opens a pie hands it to the controller that pressed it.
        if(pointingHud){pointingHud=false;HudPointer(HudHit(input)??new(-1,-1),false);if(pie.IsOpen)pieSource=input;return;}
        if(pointingGui) { Trace.Line("release",$"panel control={gui.Pointed}");gui.Release();return; }
        var before=pressedSubject;pressedSubject=null;
        if(before!=null && !Blocked && Router.MenuOwner==null) { var ray=Ray(input);if(scene.PickRay(ray.Origin,ray.Direction)==before)scene.Select(before); }
    }
    public void Cancel(IControllerSource input)
    { if(pointerSource!=input)return;pointerSource=null;pressedSubject=null;pointingPie=false;
      if(pointingHud){pointingHud=false;HudPointer(new(-1,-1),false);}gui.Cancel(); }
    bool MenuObscured=>gui.NativePressed || gui.Surface.GetEmbeddedSubwindows().Concat(gui.FormSurface.GetEmbeddedSubwindows()).Any(w=>w.Visible) ||
        GetWindow().FindChildren("*","Window",true,false).OfType<Window>().Any(w=>w.Visible && w.Exclusive);
    // Pad press opens the pointed target's pie; holding it is turbo mode. A
    // pie left open by a release (sub-pie, confirmation) continues on the next
    // press, so the second press on Leave space happens inside the same pie.
    public bool OpenMenu(IControllerSource input,NumericsVector2 axes,float threshold)
    {
        if(MenuObscured)return false;
        if(!pie.IsOpen) {
            gui.EndTextInput();var ray=Ray(input);
            var hit=GuiHit(input)!=null ? null : scene.PickRay(ray.Origin,ray.Direction);
            if(!openPie(hit))return false;
            pieSource=input;scene.PointAt(null);if(gui.Spatial)PlacePie(input,hit);
        }
        pie.Threshold=threshold;pie.MoveAxes(axes);return true;
    }
    public void MoveMenu(NumericsVector2 axes,float threshold)
    {
        if(!pie.IsOpen)return;
        if(MenuObscured){Router.CancelMenu();return;}
        pie.MoveAxes(axes);
    }
    public void CommitMenu(){if(pie.IsOpen)pie.Commit();}
    public void CancelMenu()=>pie.Dismiss("dismissed: input withdrawn (focus, a popup or a press elsewhere)");
    void MenuClosed(){Router.MenuSelected();pieQuad.Visible=false;pieSource=null;}
    public void Drive(IControllerSource source,NumericsVector2 axes)
    {
        DriveRequests++;
        var forward=-(scene.DomainBasis*camera.GetCameraTransform().Basis.Z);forward.Y=0;forward=forward.Normalized();var right=forward.Cross(Vector3.Up).Normalized();
        var direction=forward*(-axes.Y)+right*axes.X;controls()?.Drive(direction.X,direction.Y,direction.Z);
    }
    public void Stop() { StopRequests++;controls()?.Drive(0,0,0); }
    public void Snap(IControllerSource source,int direction) { SnapRequests++;controls()?.Snap(direction); }
    public void Teleport(IControllerSource source,float fraction)
    { TeleportRequests++;var direction=scene.DomainBasis*Ray(source).Direction;controls()?.Teleport(direction.X,direction.Z,fraction); }
    public void StopSession()
    {
        if(disposed)return;active=false;Router.Cancel();gui.Cancel();CancelMenu();
        if(attached) {
            attached=false;XRServer.Singleton.TrackerAdded-=TrackerAdded;XRServer.Singleton.TrackerRemoved-=TrackerRemoved;XRServer.Singleton.TrackerUpdated-=TrackerUpdated;Subscriptions-=3;
            foreach(var name in sources.Keys.ToArray())RetireSource(name);
        }
        if(xr!=null && lifecycleSubscribed) {
            xr.SessionFocussed-=Focused;xr.SessionVisible-=Unfocused;xr.SessionSynchronized-=Unfocused;xr.SessionStopping-=Stopping;
            xr.SessionLossPending-=Stopping;xr.InstanceExiting-=Stopping;xr.PoseRecentered-=Recentered;Subscriptions-=7;
            lifecycleSubscribed=false;
        }
        // Godot owns one native session for the application. Uninitialize does
        // not destroy that session, so it cannot be used as a restart boundary.
        // Pause/reentry releases this consumer, retaining the engine's session.
        // Its action set remains owned by that session; no samples dispatch
        // once this consumer has released its sources and gesture owner.
        scene.PresentXR(false);xr=null;
        PresentWorkspace(false);gui.Surface.GuiEmbedSubwindows=false;calibration=null;Status="OpenXR stopped; local sources and captures released.";Changed?.Invoke();
    }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int RequestExitSession(ulong session);
    internal async Task<bool> Shutdown(ulong deadline)
    {
        shuttingDown=true;StopSession();
        var backend=XRServer.FindInterface("OpenXR") as OpenXRInterface;
        if(backend?.IsInitialized()!=true)return true;
        try {
            if(api.IsRunning()) {
                var stopped=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void Stopped()=>stopped.TrySetResult();
                backend.SessionStopping+=Stopped;Subscriptions++;
                try {
                    ulong address=api.GetInstanceProcAddr("xrRequestExitSession");
                    if(address==0)throw new InvalidOperationException("OpenXR does not expose xrRequestExitSession.");
                    var request=Marshal.GetDelegateForFunctionPointer<RequestExitSession>((nint)address);
                    int result=request(api.GetSession());
                    if(result<0)throw new InvalidOperationException("OpenXR exit request failed: "+api.GetErrorString(unchecked((ulong)(long)result)));
                    if(deadline<=SignedSession.Now)throw new TimeoutException("OpenXR shutdown deadline expired.");
                    await stopped.Task.WaitAsync(TimeSpan.FromMilliseconds(deadline-SignedSession.Now));
                    // The engine emits stopping before completing xrEndSession.
                    // Resume at its next processing boundary, never destroy its
                    // native handles from inside that signal callback.
                    await ToSignal(GetTree(),SceneTree.SignalName.ProcessFrame);
                    if(api.IsRunning())throw new InvalidOperationException("OpenXR owner has not completed session stopping.");
                } finally { backend.SessionStopping-=Stopped;Subscriptions--; }
            }
            backend.Uninitialize();return true;
        } catch(Exception error) { Status="OpenXR shutdown unavailable: "+error.Message;GD.PushError(Status);Changed?.Invoke();return false; }
    }
    public override void _ExitTree()
    { StopSession();BindOccurrence(null);disposed=true;Router?.Dispose();models?.Dispose();Changed=null;api.Dispose(); }
}
