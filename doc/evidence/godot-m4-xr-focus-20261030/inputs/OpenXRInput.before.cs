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
        public bool Current(ulong frame)=>Alive && XRServer.GetTracker(Tracker.Name)?.GetInstanceId()==Tracker.GetInstanceId() && Tracker.HasPose("aim") && Tracker.HasPose("grip") &&
            Tracker.GetPose("aim").HasTrackingData && Tracker.GetPose("grip").HasTrackingData &&
            Tracker.GetPose("aim").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None && Tracker.GetPose("grip").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None;
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
        public long Incarnation;
        public Task Loading=Task.CompletedTask;
    }
    readonly Dictionary<StringName,Source> sources=[];
    readonly Dictionary<IControllerSource,Visual> visuals=[];
    readonly List<Task> loading=[];
    readonly XROrigin3D origin=new() { Name="xr-origin" };
    readonly XRCamera3D camera=new() { Name="xr-camera" };
    readonly MeshInstance3D panel=new() { Name="shared-gui-surface",Mesh=new QuadMesh { Size=new(1.5f,1) } };
    readonly OpenXRApiExtension api=new();
    OpenXRInterface? xr;
    ScenePanel scene=null!;
    SpatialGui gui=null!;
    RenderModels models=null!;
    Func<PhysicsInput?> controls=null!;
    Func<bool> blocked=null!;
    Func<(string Text,Func<bool> Enabled,Action Activate)[]> menuEntries=null!;
    PanelContainer? menuPanel;
    Button[] menuButtons=[];
    Func<bool>[] menuEnabled=[];
    int selection=-1;
    bool attached,active,lifecycleSubscribed,shuttingDown,applicationFocused=true,visible=true,disposed,pointingGui;
    Transform3D? calibration;
    Vector2I panelPixels;
    string? controlIdentity;
    Term? pressedSubject;
    IControllerSource? pointerSource;
    public ControllerInput Router { get; private set; }=null!;
    public bool Running=>active;
    public int MenuRedraws { get; private set; }
    public int LateCallbacks { get; private set; }
    public int Subscriptions { get; private set; }
    public int DriveRequests { get; private set; }
    public int StopRequests { get; private set; }
    public int SnapRequests { get; private set; }
    public int TeleportRequests { get; private set; }
    public string Status { get; private set; }="OpenXR is stopped.";
    public event Action? Changed;
    public Task Completion=>Task.WhenAll(loading);
    public object Metrics=>new { Running,Subscriptions,sources=sources.Count,appearances=visuals.Count,MenuRedraws,LateCallbacks,captures=gui.Captures,DriveRequests,StopRequests,SnapRequests,TeleportRequests,resources=models.Metrics };
    internal MeshInstance3D GuiSurface=>panel;
    internal Source[] Sources=>sources.Values.ToArray();
    public bool Blocked=>blocked();
    public void Configure(ScenePanel scene,SpatialGui gui,RenderModels models,Func<PhysicsInput?> controls,Func<bool> blocked,Func<(string,Func<bool>,Action)[]> menuEntries)
    {
        this.scene=scene;this.gui=gui;this.models=models;this.controls=controls;this.blocked=blocked;this.menuEntries=menuEntries;
        AddChild(origin);origin.AddChild(camera);AddChild(panel);
        panel.MaterialOverride=new StandardMaterial3D { ShadingMode=BaseMaterial3D.ShadingModeEnum.Unshaded,AlbedoTexture=gui.Surface.GetTexture(),CullMode=BaseMaterial3D.CullModeEnum.Disabled };
        panel.Visible=false;Router=new(this);Router.Changed+=()=>Changed?.Invoke();
    }
    public bool Start()
    {
        if(disposed || shuttingDown || active)return active;
        xr=XRServer.FindInterface("OpenXR") as OpenXRInterface;
        if(xr==null || (!xr.IsInitialized() && !xr.Initialize())) { Status="OpenXR unavailable. Launch with --xr-mode on and a supported installed runtime.";Changed?.Invoke();return false; }
        xr.SessionFocussed+=Focused;xr.SessionVisible+=Unfocused;xr.SessionSynchronized+=Unfocused;xr.SessionStopping+=Stopping;
        xr.SessionLossPending+=Stopping;xr.InstanceExiting+=Stopping;xr.PoseRecentered+=Recentered;Subscriptions+=7;
        lifecycleSubscribed=true;xr.SetActionSetActive("quod_inputs",true);
        AttachSources();active=true;calibration=null;
        scene.ReleaseInput();scene.PresentXR(true);
        gui.Surface.GuiEmbedSubwindows=true;
        camera.Current=true;panel.Visible=true;PositionPanel();
        Status="OpenXR active; input requires current focused tracking and signed settings.";Changed?.Invoke();return true;
    }
    // Shared with injected XRServer tracker qualification. No alternate input
    // interpretation or application action path is selected here.
    internal void AttachSources()
    {
        if(attached || disposed)return;attached=true;
        XRServer.Singleton.TrackerAdded+=TrackerAdded;XRServer.Singleton.TrackerRemoved+=TrackerRemoved;XRServer.Singleton.TrackerUpdated+=TrackerUpdated;Subscriptions+=3;
        gui.Surface.SizeChanged+=ResizePanel;Subscriptions++;ResizePanel();
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
    void Unfocused() { Router.Cancel();gui.Cancel();HideVisuals();Status="OpenXR input paused: session has no focus.";Changed?.Invoke(); }
    void Stopping() { Unfocused();Status="OpenXR runtime stopped this session.";Changed?.Invoke(); }
    void Recentered() { Router.Cancel();calibration=null; }
    public void Focus(bool focused)
    { applicationFocused=focused;if(!focused){Router.Cancel();gui.Cancel();HideVisuals();} }
    public void Visibility(bool next) { visible=next;if(!next){Router.Cancel();gui.Cancel();HideVisuals();} }
    public void Install(ControllerMapping? mapping)=>Router.Install(mapping);
    void ControlChanged() { if(controlIdentity!=scene.ControlIdentity) { InvalidateWorld();controlIdentity=scene.ControlIdentity; } }
    public void ContextChanged() { ControlChanged();Router.ContextChanged(); }
    public void InvalidateWorld() { Router.Cancel();calibration=null;pressedSubject=null; }
    void PositionPanel()=>panel.Transform=scene.CameraPose*new Transform3D(Basis.Identity,new(0,0,-2));
    void ResizePanel()
    {
        var mesh=(QuadMesh)panel.Mesh;var pixels=gui.Surface.Size;
        if(pixels==panelPixels)return;
        var size=new Vector2(mesh.Size.Y*pixels.X/pixels.Y,mesh.Size.Y);
        Router.Cancel();gui.Cancel();panelPixels=pixels;
        if(mesh.Size!=size)mesh.Size=size;
    }
    public override void _Process(double delta)
    {
        if(!active || xr==null)return;
        bool focused=applicationFocused && xr.GetSessionState()==OpenXRInterface.SessionState.Focused && api.IsRunning();
        var head=XRServer.GetTracker("head") as XRPositionalTracker;
        bool tracked=head?.HasPose("default")==true && head.GetPose("default").HasTrackingData &&
            head.GetPose("default").TrackingConfidence!=XRPose.TrackingConfidenceEnum.None;
        ControlChanged();
        if(tracked && calibration==null) {
            var pose=head!.GetPose("default").Transform;var forward=-pose.Basis.Z;
            var inverse=new Basis(Vector3.Up,-Mathf.Atan2(-forward.X,-forward.Z));
            calibration=new(inverse,-(inverse*pose.Origin));
        }
        long time=api.GetPredictedDisplayTime();Advance(time>0 ? (ulong)time : 0,focused && tracked);
    }
    internal void Advance(ulong frame,bool interactive)
    {
        ControlChanged();
        origin.Transform=scene.CameraPose*(calibration??Transform3D.Identity);
        interactive&=applicationFocused && visible;
        foreach(var source in sources.Values)source.UpdatePose();
        Router.Frame(frame,interactive);
        foreach(var (source,visual) in visuals)if(visual.Model!=null)visual.Model.Visible=interactive && visual.Profile!=null && source.Current(frame);
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
        visual.Asset=profile.Model.Identity;visual.Lease=models.Acquire(profile.Model);long expected=visual.Incarnation;
        async Task Load()
        {
            try {
                var node=await visual.Lease.Instantiate();if(node==null)return;
                if(disposed || !visuals.ContainsKey(input) || visual.Incarnation!=expected) { models.ReleaseInstance(node);return; }
                visual.Model=node;node.Visible=false;((Source)input).Grip.AddChild(node);
            } catch(OperationCanceledException) { }
            catch(Exception error) { if(!disposed && visual.Incarnation==expected){Status="Controller appearance unavailable: "+error.Message;Changed?.Invoke();} }
        }
        visual.Loading=Load();loading.Add(visual.Loading);
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
    Vector2? GuiPoint(IControllerSource source)
    {
        var ray=Ray(source);var inverse=panel.GlobalTransform.AffineInverse();var start=inverse*ray.Origin;var direction=inverse.Basis*ray.Direction;
        if(!panel.Visible || Math.Abs(direction.Z)<0.000001f)return null;float distance=-start.Z/direction.Z;if(distance<0)return null;
        var size=((QuadMesh)panel.Mesh).Size;
        var point=start+direction*distance;if(Math.Abs(point.X)>size.X/2 || Math.Abs(point.Y)>size.Y/2)return null;
        return new Vector2((point.X/size.X+0.5f)*gui.Surface.Size.X,(0.5f-point.Y/size.Y)*gui.Surface.Size.Y);
    }
    public void Hover(IControllerSource input,string context)
    {
        if(pointerSource!=null && pointerSource!=input)return;
        ((Source)input).Pointer.Visible=true;
        if(GuiPoint(input) is Vector2 point)gui.Move(point);else if(pointerSource==input && pointingGui)gui.Move(new(-10000,-10000));else gui.Leave();
    }
    public void Hide(IControllerSource input)=>((Source)input).Pointer.Visible=false;
    public void Press(IControllerSource input)
    {
        if(gui.NativePressed)return;
        pointerSource=input;pressedSubject=null;
        if(GuiPoint(input) is Vector2 point) { pointingGui=true;gui.Move(point);gui.Press(); }
        else { pointingGui=false;if(!Blocked && Router.MenuOwner==null){var ray=Ray(input);pressedSubject=scene.PickRay(ray.Origin,ray.Direction);} }
    }
    public void Release(IControllerSource input)
    {
        if(pointerSource!=input)return;pointerSource=null;
        if(pointingGui) { gui.Release();return; }
        var before=pressedSubject;pressedSubject=null;
        if(before!=null && !Blocked && Router.MenuOwner==null) { var ray=Ray(input);if(scene.PickRay(ray.Origin,ray.Direction)?.ToString()==before.ToString())scene.Select(before); }
    }
    public void Cancel(IControllerSource input)
    { if(pointerSource!=input)return;pointerSource=null;pressedSubject=null;gui.Cancel(); }
    public bool OpenMenu(IControllerSource input,NumericsVector2 axes,float threshold)
    {
        if(menuPanel!=null)return false;
        var entries=menuEntries();if(entries.Length==0)return false;
        menuEnabled=entries.Select(e=>e.Enabled).ToArray();
        menuPanel=new() { Name="xr-menu",Position=new(280,100),Size=new(640,400) };gui.Surface.AddChild(menuPanel);
        var column=new VBoxContainer();menuPanel.AddChild(column);
        menuButtons=entries.Select(e=> {
            var button=new Button { Text=e.Text,Disabled=!e.Enabled() };column.AddChild(button);
            button.Pressed+=()=> { Router.MenuSelected();CancelMenu();if(e.Enabled())e.Activate(); };return button;
        }).ToArray();selection=-1;MenuRedraws++;MoveMenu(axes,threshold);return true;
    }
    public void MoveMenu(NumericsVector2 axes,float threshold)
    {
        if(menuPanel==null)return;
        int next=axes.Length()<threshold ? -1 : (int)Math.Floor(((Math.Atan2(axes.X,-axes.Y)+Math.PI*2+Math.PI/menuButtons.Length)%(Math.PI*2))/(Math.PI*2/menuButtons.Length));
        if(next==selection)return;selection=next;MenuRedraws++;if(selection>=0)menuButtons[selection].GrabFocus();else gui.Surface.GuiReleaseFocus();
    }
    public void CommitMenu()
    { var selected=selection>=0 && selection<menuButtons.Length ? menuButtons[selection] : null;if(selected?.Disabled==false)selected.EmitSignal(BaseButton.SignalName.Pressed);else CancelMenu(); }
    public void RefreshMenu()
    { for(int i=0;i<menuButtons.Length;i++)menuButtons[i].Disabled=!menuEnabled[i](); }
    public void CancelMenu()
    { if(menuPanel==null)return;menuPanel.GetParent()?.RemoveChild(menuPanel);menuPanel.QueueFree();menuPanel=null;menuButtons=[];menuEnabled=[];selection=-1; }
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
            gui.Surface.SizeChanged-=ResizePanel;Subscriptions--;
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
        panel.Visible=false;gui.Surface.GuiEmbedSubwindows=false;calibration=null;Status="OpenXR stopped; local sources and captures released.";Changed?.Invoke();
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
    { StopSession();disposed=true;Router?.Dispose();models?.Dispose();Changed=null;api.Dispose(); }
}
