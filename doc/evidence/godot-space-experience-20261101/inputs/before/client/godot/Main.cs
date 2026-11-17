using Godot;
using Quod.Client;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Environment = System.Environment;
using File = System.IO.File;
using Json = Quod.Client.Json;

[assembly: System.Runtime.Versioning.SupportedOSPlatform("linux")]

public partial class Main : Control
{
    [Signal] public delegate void ChangedEventHandler();
    LocalStore? store;
    Identity? key;
    SignedSession? session;
    Accounts? accounts;
    readonly List<SignedView> views = [];
    SignedView? worldView;
    Task retiredWorld = Task.CompletedTask;
    Navigation? navigation;
    bool navigationAvailable;
    WorldProjection? projection;
    long worldIncarnation;
    PhysicsInput? controls;
    OpenXRInput xr=null!;
    RenderModels models=null!;
    SpatialGui gui=null!;
    Control workspaceContent=null!;
    readonly VBoxContainer connectionShell=new();
    readonly VBoxContainer connectionDetails=new() { Visible=false };
    readonly VBoxContainer toolsPanel=new() { Visible=false };
    readonly HFlowContainer accountSetup=new();
    readonly HFlowContainer accountActions=new();
    readonly Label connectionTitle=new() {Name="connection-title",ThemeTypeVariation="Heading",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly Label connectionHelp=new() {Name="connection-help",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly HFlowContainer workspaceControls=new();
    readonly HFlowContainer workspaceAppearance=new();
    bool showConnection;
    VBoxContainer? localControllers;
    Label? localControllerStatus;
    readonly Dictionary<string,OptionButton> sourceChoices=[];
    string sourceSchema="";
    Task worldChanges=Task.CompletedTask;
    CancellationTokenSource? action;
    Task activeAction = Task.CompletedTask;
    Task backupWork = Task.CompletedTask;
    Window? backupDialog;
    CancellationTokenSource? backupCancellation;
    long incarnation;
    bool disposed, closing, released;
    bool busy, worldAccepted;
    string state = "offline";
    readonly Label status = new() { Name = "status", AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly Label identityLabel = new() { Name = "identity", AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly Label location = new() { Name = "location", AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly Label controllers = new() { Name = "controllers", AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly LineEdit endpoint = new() { Name = "endpoint", PlaceholderText = "https://node:14570", Text = "https://localhost:14570", SizeFlagsHorizontal = SizeFlags.ExpandFill };
    readonly LineEdit ca = new() { Name = "ca", PlaceholderText = "Optional trusted CA PEM path", SizeFlagsHorizontal = SizeFlags.ExpandFill };
    readonly VBoxContainer body = new() { Name = "body", SizeFlagsHorizontal = SizeFlags.ExpandFill };
    OperationsPanel? operations;
    EidolonPanel? representations;
    ScenePanel scene = null!;
    public Task ViewsDisposed { get; private set; } = Task.CompletedTask;
    QuestionHub? questions;
    readonly Dictionary<string, Button> buttons = [];
    public override void _Ready()
    {
        GetTree().AutoAcceptQuit = false;
        gui=new() { Name="shared-gui" };AddChild(gui);
        var margin = new MarginContainer { OffsetLeft = 28, OffsetTop = 22, AnchorRight = 1, AnchorBottom = 1, OffsetRight = -28, OffsetBottom = -22 };
        gui.SetContent(margin);workspaceContent=margin;
        var scroll = new ScrollContainer { FollowFocus = true,HorizontalScrollMode=ScrollContainer.ScrollMode.Disabled }; margin.AddChild(scroll);
        var root = new VBoxContainer { SizeFlagsHorizontal = SizeFlags.ExpandFill }; scroll.AddChild(root);
        var header=new HFlowContainer();root.AddChild(header);header.AddChild(new Label { Text="Quod",ThemeTypeVariation="Heading" });
        Add(header,"workspace-connection","Connection / identity",()=>{showConnection=!showConnection;UpdateWorkspace();return Task.CompletedTask;});
        Add(header,"client-tools","Inspection & settings",()=>{toolsPanel.Visible=!toolsPanel.Visible;return Task.CompletedTask;});
        var statusPanel=new PanelContainer();root.AddChild(statusPanel);statusPanel.AddChild(status);
        root.AddChild(connectionShell);connectionShell.AddChild(connectionTitle);connectionShell.AddChild(connectionHelp);
        connectionShell.AddChild(accountSetup);
        var keys = Row(connectionShell); Add(keys, "create-key", "Create my key", CreateKey); Add(keys, "import-backup", "Import encrypted backup", () => { BackupDialog(false); return Task.CompletedTask; });
        Add(keys, "connect", "Connect", Connect); Add(keys, "disconnect", "Disconnect", () => { Disconnect(); return Task.CompletedTask; });
        Add(keys,"connection-details","Server, identity & backup details",()=>{connectionDetails.Visible=!connectionDetails.Visible;return Task.CompletedTask;});
        connectionShell.AddChild(connectionDetails);connectionDetails.AddChild(identityLabel);
        connectionDetails.AddChild(new Label { Text="Active keys use private local files, not a backup passphrase. Encrypted backups have a separate passphrase.",AutowrapMode=TextServer.AutowrapMode.WordSmart });
        connectionDetails.AddChild(new Label { Text="Server endpoint" });connectionDetails.AddChild(endpoint);
        connectionDetails.AddChild(new Label { Text="Trusted CA file (optional)" });connectionDetails.AddChild(ca);
        Add(connectionDetails, "export-backup", "Export encrypted backup", () => { BackupDialog(true); return Task.CompletedTask; });
        connectionDetails.AddChild(location);connectionDetails.AddChild(controllers);
        Add(accountSetup, "register", "Create my account", Register);
        Add(accountSetup, "prepare", "Review starting space storage", Prepare);
        Add(accountSetup, "setup", "Create my agent and starting space", Setup);
        Add(accountSetup, "resolve", "Check original outcomes", Resolve);
        root.AddChild(toolsPanel);
        Add(toolsPanel, "inspect", "Source / inspection", OpenTools);
        Add(toolsPanel,"local-controllers","Connected controllers",()=>{OpenControllers();return Task.CompletedTask;});
        Add(toolsPanel,"start-xr","Start OpenXR",()=>{xr.Start();return Task.CompletedTask;});
        Add(toolsPanel,"stop-xr","Stop OpenXR",()=>{xr.StopSession();return Task.CompletedTask;});
        scene = new() { Name = "space-scene" };
        models=new(async (asset,cancellation)=> {
            var consumer=session??throw new InvalidOperationException("Connect before requesting controller resources.");
            using var deadline=CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            ulong until=consumer.Deadline;if(until<=SignedSession.Now)throw new TimeoutException("Asset deadline expired.");
            deadline.CancelAfter(TimeSpan.FromMilliseconds(until-SignedSession.Now));
            return await consumer.Transport.Model(asset.Digest,asset.Allowed[0],deadline.Token);
        });
        xr=new() { Name="openxr-input" };scene.Viewport.AddChild(xr);
        xr.Configure(scene,gui,models,()=>controls,()=>GuiOpen || gui.NativePressed,WorkspaceMenuEntries);
        xr.Changed+=()=>{UpdateWorkspace();UpdateControllerStatus();};
        gui.NativeCaptureChanged+=()=>{if(gui.NativePressed){xr.Router.Cancel();scene.ReleaseInput();}xr.ContextChanged();};
        GetWindow().VisibilityChanged+=()=>xr.Visibility(GetWindow().Visible);
        scene.Drive += (direction,_) => controls?.Drive(direction.X,direction.Y,direction.Z);
        scene.Selected += exact => {
            if (accounts?.Human == null || session == null) return;
            OverlayChanging();
            EnsureRepresentations().Open(session,accounts,store!,exact);
        };
        root.AddChild(workspaceControls);workspaceControls.Hide();
        root.AddChild(workspaceAppearance);workspaceAppearance.Hide();
        void Presentation(string name,string text,Action change)=>Add(workspaceControls,name,text,()=>{change();return Task.CompletedTask;});
        void Appearance(string name,string text,Action change)=>Add(workspaceAppearance,name,text,()=>{change();return Task.CompletedTask;});
        Presentation("workspace-show","Recenter workspace",xr.ShowWorkspace);
        Presentation("workspace-move","Move panel",xr.MoveWorkspace);
        Presentation("workspace-hide","Hide workspace",xr.HideWorkspace);
        Add(header,"workspace-settings","Appearance",()=>{workspaceAppearance.Visible=!workspaceAppearance.Visible;return Task.CompletedTask;});
        Appearance("workspace-text-larger","Larger text",()=>gui.TextSize(4));
        Appearance("workspace-text-smaller","Smaller text",()=>gui.TextSize(-4));
        Appearance("workspace-nearer","Nearer · same visual scale",()=>xr.WorkspaceDistance(-.2f));
        Appearance("workspace-farther","Farther · same visual scale",()=>xr.WorkspaceDistance(.2f));
        Appearance("workspace-opaque","Opaque / tinted",gui.ToggleOpacity);
        var actions = accountActions;root.AddChild(actions);
        Add(actions, "open-gui", "Account operations", OpenGui);
        Add(actions, "create-operations", "Create / operations", OpenStorage);
        Add(actions, "location-operations", "Current space", OpenLocation);
        root.AddChild(body);root.AddChild(scene);
        endpoint.TextChanged += _ => SettingsChanged(); ca.TextChanged += _ => SettingsChanged();
        try {
            string profile = Argument("--profile") ?? ProjectSettings.GlobalizePath("user://identity");
            store = new LocalStore(profile);
            if (store.Snapshot is LocalState saved) {
                key = Identity.FromPayload(saved.Payload); endpoint.Text = saved.Endpoint; ca.Text = saved.CaFile;
                status.Text = "Your saved key is ready. Connect explicitly.";
            } else status.Text = "Not signed in.";
            if (Argument("--node") is string node) endpoint.Text = node;
            if (Argument("--ca") is string caPath) ca.Text = caPath;
        } catch (Exception error) { state = "storage-error"; status.Text = error.Message; }
        UpdateButtons(); Notify();
        if (OS.GetCmdlineUserArgs().Contains("--qualification")) {
            var checks = new ExportChecks(); AddChild(checks); checks.Begin(this);
        }
    }
    static string? Argument(string name)
    {
        var args = OS.GetCmdlineUserArgs(); int index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }
    static HFlowContainer Row(Godot.Container parent) { var row = new HFlowContainer(); parent.AddChild(row); return row; }
    internal (string,Func<bool>,Action)[] WorkspaceMenuEntries()=>new[]{"workspace-show","workspace-move","workspace-hide","workspace-text-larger","workspace-nearer","open-gui","create-operations","location-operations","inspect","local-controllers","stop-xr"}.Select(name=> {
        var button=buttons[name];return(button.Text,(Func<bool>)(()=>!button.Disabled),(Action)(()=>button.EmitSignal(BaseButton.SignalName.Pressed)));
    }).ToArray();
    void Add(Godot.Container row, string name, string text, Func<Task> operation)
    {
        var button = SpatialGui.ActionButton(text,name); buttons.Add(name, button); row.AddChild(button);
        button.Pressed += () => {
            if (name == "disconnect") { Disconnect(); return; }
            activeAction = Run(operation);
        };
    }
    async Task Run(Func<Task> operation)
    {
        if (busy || disposed || closing) return;
        busy = true; action = new(TimeSpan.FromMinutes(5)); var running = action; UpdateButtons(); Notify();
        try { await operation(); }
        catch (Exception error) { if (!running.IsCancellationRequested) status.Text = error.Message + (accounts?.Uncertain == true ? " Original work retained; resolve its outcome." : ""); }
        finally { busy = false; running.Dispose(); if (ReferenceEquals(action, running)) action = null;
            if (!disposed) { UpdateButtons(); Notify(); } }
    }
    CancellationToken Cancellation => action?.Token ?? CancellationToken.None;
    Task CreateKey()
    {
        if (key != null || store == null) throw new InvalidOperationException("Local identity storage is unavailable or already occupied.");
        using var created = Identity.Create(); store.Create(created.Payload(), true); key = Identity.FromPayload(store.Snapshot!.Payload);
        status.Text = "Key saved on this device. Connect when you are ready."; return Task.CompletedTask;
    }
    async Task Connect()
    {
        if (key == null || store == null) throw new InvalidOperationException("Create/import a key first.");
        CloseSession(); long expected = incarnation;
        await ViewsDisposed;
        if (disposed || closing || expected!=incarnation) return;
        store.Update(s => { s.Endpoint = endpoint.Text; s.CaFile = ca.Text; });
        var connecting = new SignedSession(key, store, new Transport(endpoint.Text, ca.Text));
        session = connecting; status.Text = "Authenticating the exact saved key…"; Notify();
        connecting.Expired+=()=>{
            if(!ReferenceEquals(session,connecting)||disposed||closing)return;
            Disconnect();state="sign-in-expired";
            status.Text="Sign-in expired. Sign in again with the same key. Drafts and original work are retained.";
            UpdateButtons();Notify();
        };
        try {
            await connecting.Authenticate(Cancellation);
            if (disposed || expected != incarnation) return;
            var discovered = new Accounts(connecting, store); await discovered.Discover(Cancellation);
            if (disposed || expected != incarnation) return;
            accounts = discovered;
        } catch { if (ReferenceEquals(session, connecting)) CloseSession(); throw; }
        state = accounts.Human == null ? "signed-in-no-account" : accounts.Setup == null ? "setup-pending" : "account-ready";
        status.Text = accounts.Uncertain ? "Original work is unresolved. Check its original outcome." : "Signed in with your saved key. Your account's next action is shown below.";
        if (accounts.Setup != null) await PresentAccount();
    }
    async Task Register()
    {
        RequireSession(); long expected = incarnation; await accounts!.Register(Cancellation);
        if (disposed || expected != incarnation) return;
        state = accounts.Human == null ? "signup-uncertain" : "setup-pending";
        status.Text = accounts.Human == null ? "Signup outcome is unknown; check the original operation." : "Your account is created. Review its starting space storage before completing setup.";
    }
    async Task Prepare()
    {
        RequireSession(); long expected = incarnation; await accounts!.Prepare(Cancellation);
        if (disposed || expected != incarnation) return;
        status.Text = accounts.StorageDescription.Length == 0 ? "Original account setup is complete." : "Storage reviewed. Your agent and starting space are not created yet.";
        if (accounts.Setup != null) await PresentAccount();
    }
    async Task Setup()
    {
        RequireSession(); long expected = incarnation; await accounts!.FinishSetup(Cancellation);
        if (disposed || expected != incarnation) return;
        if (accounts.Setup != null) { state = "account-ready"; await PresentAccount(); }
        else status.Text = "Setup is unresolved. Check the exact original operation.";
    }
    async Task Resolve()
    {
        RequireSession(); long expected = incarnation; await accounts!.Resolve(Cancellation);
        if (disposed || expected != incarnation) return;
        state = accounts.Human == null ? "signed-in-no-account" : accounts.Setup == null ? "setup-pending" : "account-ready";
        status.Text = accounts.Uncertain ? "The original outcome is still unknown. No operation was resubmitted." : "Original outcomes resolved without submission.";
        if (accounts.Setup != null && views.Count == 0) await PresentAccount();
    }
    void RequireSession()
    { if (session == null || accounts == null) throw new InvalidOperationException("Connect first."); }
    async Task PresentAccount()
    {
        RequireSession(); var human = accounts!.Human!;
        var setup = accounts.Setup!.Require("account", 6); var space = Actor.FromTerm(setup[2]);
        var personal = Actor.FromTerm(setup[1]);
        string Reference(Actor a) => $"{a.Namespace} / {a.InstanceText} @ {a.Anchor}";
        location.Text = $"U: {Reference(human)}\nA: {Reference(personal)}\nS0: {Reference(space)}\nS0 storage: the existing account ontology {human.Namespace} @ {human.Anchor}";
        var consumer = session!;
        controls?.Dispose(); controls=new(consumer,human);
        controls.Suspended += reason => { status.Text="Control suspended: "+reason; Notify(); };
        foreach (var view in views) view.Dispose(); views.Clear();
        var route = new SignedView(consumer,human,human,"navigation",SignedSession.ViewGoal(human,Term.Call("account_navigation",Term.Variable("View")))); views.Add(route);
        route.Projection += message => {
            var next = Navigation.Decode(message);
            if (navigation != null && next.Revision < navigation.Revision) return;
            if (navigation?.Revision == next.Revision && navigation.Location.ToString() != next.Location.ToString())
                throw new FormatException("Conflicting committed location.");
            bool same = navigation?.Revision == next.Revision && navigation.Location.ToString() == next.Location.ToString();
            bool wasAvailable = navigationAvailable; navigation = next; navigationAvailable=true;
            location.Text = $"U: {Reference(human)}\nA: {Reference(personal)}\nS0: {Reference(space)}\nCurrent location: {next.Location} (assignment {next.Revision})";
            if (!same || !wasAvailable || (next.Space != null && worldView == null)) OpenWorld(consumer,human,next.Space);
            UpdateButtons(); Notify();
        };
        route.Withdrawn += reason => { navigationAvailable=false; SuspendWorld(); location.Text = "Location unavailable: " + reason; UpdateButtons(); Notify(); };
        _ = route.Start();
        var preferences = new SignedView(consumer, human, human, "controller_preferences", SignedSession.ViewGoal(human,
            Term.Call("controller_preferences_view", Term.Parse(human.InstanceText.TrimEnd('.')), Term.Variable("View")))); views.Add(preferences);
        preferences.Projection += message => {
            var value=Term.Parse(Json.S(message,"value"));var mapping=ControllerMapping.Decode(value);xr.Install(mapping);
            controllers.Text="Keyboard/mouse available. "+(mapping==null ? "Stored controller settings are invalid; use the offered Reset operation." : "Controller mapping revision "+mapping.Revision+".");Notify();
        };
        preferences.Withdrawn += reason => { xr.Install(null);controllers.Text = "Controller mapping unavailable: " + reason; Notify(); };
        _ = preferences.Start();
        questions?.Dispose(); questions = new(consumer, accounts, store!, body, Notify); questions.Start();
        if(representations?.Resume(consumer,accounts,store!)!=true)await OpenGui();
    }
    void RetireWorld()
    {
        worldIncarnation++;
        var completion = worldView?.Completion ?? Task.CompletedTask; worldView?.Dispose(); worldView=null;
        retiredWorld = retiredWorld.IsCompleted ? completion : Task.WhenAll(retiredWorld,completion);
        projection=null; controls?.Withdraw(); worldAccepted=false; xr?.InvalidateWorld();scene?.Withdraw();
    }
    void OpenWorld(SignedSession consumer,Actor human,Actor? space)
    {
        if (space == null) { SuspendWorld(); status.Text="Unplaced. Open an explicitly selected existing space's offered operations to enter it."; return; }
        if (worldView?.Completion?.IsCompleted==true) RetireWorld();
        if (worldView != null) { ScheduleWorldChange(false); return; }
        long expected = worldIncarnation;
        async Task<(Actor Target,string Goal)?> WorldGoal(CancellationToken cancellation) {
            var read = await consumer.Read(human,"account_navigation(Navigation).",cancellation);
            var route=Json.Binding(read,"Navigation").Require("navigation",3);
            if(route[1].Kind=="atom" && route[1].Name=="unplaced") return null;
            var selected = Actor.FromTerm(route[1].Require("placed",2)[0]);
            if (!route[2].Items.Any(t => t.Name == "playing")) throw new FormatException("Playing view unavailable.");
            var dependencies = read["dependencies"]?.AsArray() ?? throw new FormatException("Missing navigation dependencies.");
            var terms = dependencies.Select(row => Term.Call("dependency",Term.Text(Json.S(row,"ns")),
                Term.Binary(Identity.Decode(Json.S(row,"genesis_anchor"))),Term.Number(Json.S(row,"height")))).ToArray();
            return (selected,SignedSession.ViewGoal(selected,Term.Call("client_world_view",Term.Parse(selected.InstanceText.TrimEnd('.')),Term.Atom("playing"),Term.List(terms),Term.Variable("View"))));
        }
        var view = new SignedView(consumer,human,space,"world","") { BeforeOpen=WorldGoal }; worldView=view;
        view.Projection += message => {
            if (expected != worldIncarnation) return;
            try {
                if (!navigationAvailable || navigation?.Space != view.Target) { WithdrawWorld("Committed location changed."); return; }
                var next = scene.ApplyProjection(message,view.Target,human,ack=>_ = view.Send(ack)); projection=next; worldAccepted=true;
                controls?.Present(next);
                status.Text="Current committed space. Click a subject for its offered operations; focus the scene for WASD/QE and right-drag viewing.";
            } catch (Exception error) { WithdrawWorld(error.Message); }
            UpdateButtons(); Notify();
        };
        view.Message += message => {
            if (expected != worldIncarnation || Json.S(message,"type") != "simulation_frame" || projection == null) return;
            try { if (scene.ApplyFrame(message,ack=>_ = view.Send(ack))) { controls?.Present(projection); Notify(); } }
            catch (Exception error) { WithdrawWorld(error.Message); Notify(); }
        };
        view.Withdrawn += reason => { if (expected == worldIncarnation) { WithdrawWorld(reason); Notify(); } };
        _ = view.Start();
    }
    void SuspendWorld() { WithdrawWorld("Location is being verified."); if (worldView != null) ScheduleWorldChange(true); }
    void ScheduleWorldChange(bool suspend)
    { var next=ChangeWorld(suspend); worldChanges=worldChanges.IsCompleted ? next : Task.WhenAll(worldChanges,next); }
    async Task ChangeWorld(bool suspend)
    {
        try { if (worldView is SignedView view) { if (suspend) await view.Suspend(); else await view.Reopen(); } }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!disposed && !closing) { WithdrawWorld(error.Message); Notify(); } }
    }
    void WithdrawWorld(string reason)
    { projection=null; controls?.Withdraw();xr.InvalidateWorld(); scene.Withdraw(); worldAccepted=false; status.Text="Space unavailable: " + reason; UpdateButtons(); }
    bool GuiOpen=>representations?.IsVisibleInTree()==true || backupDialog!=null || (localControllers?.IsVisibleInTree()??false) || body.GetChildren().Any(n=>n is QuestionPanel c && c.IsVisibleInTree());
    void UpdateWorkspace()
    {
        workspaceContent.Visible=!gui.Spatial || xr.WorkspaceVisible;
        connectionShell.Visible=showConnection || accounts?.Setup==null || accounts.Uncertain || session?.IsExpired==true;workspaceControls.Visible=gui.Spatial;
        location.Visible=controllers.Visible=connectionShell.Visible;
        accountSetup.Visible=accounts!=null;
        if(!scene.Viewport.UseXR)scene.Visible=worldAccepted;
        foreach(var (name,button) in buttons.Where(p=>p.Key.StartsWith("workspace-")))button.Disabled=busy ||
            (!gui.Spatial && name is not ("workspace-settings" or "workspace-connection" or "workspace-text-larger" or "workspace-text-smaller" or "workspace-opaque"));
        buttons["workspace-hide"].Disabled|=backupDialog!=null;
        buttons["workspace-move"].Text=xr.MovingWorkspace ? "Place panel" : "Move panel";
    }
    void OverlayChanging() { gui.Cancel();xr.Router.Cancel();scene.ReleaseInput();if(gui.Spatial&&!xr.WorkspaceVisible)xr.ShowWorkspace(); }
    public override void _Process(double delta) { xr.ContextChanged();scene.NavigationBlocked=GuiOpen || xr.Running;controls?.Tick(delta); }
    Task OpenGui()
    {
        OverlayChanging();
        RequireSession(); if (accounts!.Human == null) throw new InvalidOperationException("No human account reference.");
        EnsureRepresentations().Open(session!,accounts,store!,accounts.Human.Entity);return Task.CompletedTask;
    }
    Task OpenStorage()
    {
        OverlayChanging();
        RequireSession();
        if (accounts!.Setup == null) throw new InvalidOperationException("Complete account setup first.");
        EnsureRepresentations().OpenStorage(session!,accounts,store!,navigationAvailable ? navigation?.Space : null);return Task.CompletedTask;
    }
    Task OpenLocation()
    {
        OverlayChanging();
        RequireSession(); var space = navigationAvailable ? navigation?.Space : null;
        if (space==null) throw new InvalidOperationException("Current location is unavailable or unplaced.");
        EnsureRepresentations().Open(session!,accounts!,store!,space.Entity);return Task.CompletedTask;
    }
    Task OpenTools()
    {
        OverlayChanging();
        RequireSession(); if (accounts!.Human == null) throw new InvalidOperationException("No account.");
        EnsureRepresentations().Open(session!,accounts,store!,accounts.Human.Ontology);return Task.CompletedTask;
    }
    EidolonPanel EnsureRepresentations()
    {
        if(representations!=null)return representations;
        representations=new() { Name="representations",CurrentLocation=()=>navigationAvailable ? navigation?.Space : null };body.AddChild(representations);
        operations=representations.Operations;representations.Changed+=Notify;return representations;
    }
    void SettingsChanged()
    { if (session != null) Disconnect(); }
    void CloseSession(bool retainDrafts=true)
    {
        incarnation++;
        xr?.Install(null);xr?.StopSession();gui?.Cancel();
        RetireWorld(); navigation=null; navigationAvailable=false;
        var completions = views.Select(v => v.Completion ?? Task.CompletedTask).ToList();
        if(xr!=null)completions.Add(xr.Completion);
        completions.Add(retiredWorld);
        completions.Add(worldChanges);
        if(controls!=null) { controls.Dispose(); completions.Add(controls.Completion); controls=null; }
        if (questions != null) completions.Add(questions.Completion);
        if (representations != null) {
            if(retainDrafts)representations.Disconnect();else representations.DisposeView();
            completions.Add(representations.Completion);
        }
        questions?.Dispose(); questions = null;
        foreach (var view in views) view.Dispose(); views.Clear();
        if(!retainDrafts){operations=null;representations=null;}
        foreach (var node in body.GetChildren()) {
            if(retainDrafts&&node==representations)continue;
            body.RemoveChild(node); node.QueueFree();
        }
        var closing = session; session = null;
        async Task Finish() {
            try { await Task.WhenAll(completions); }
            finally { closing?.Dispose(); }
        }
        ViewsDisposed = ViewsDisposed.IsCompleted ? Finish() : Task.WhenAll(ViewsDisposed, Finish());
        accounts = null; worldAccepted = false; location.Text = controllers.Text = "";localControllers=null;localControllerStatus=null;sourceChoices.Clear();sourceSchema="";
        scene?.Withdraw();
    }
    public void Disconnect()
    {
        action?.Cancel(); CloseSession(); state = "offline"; status.Text = "Disconnected. Unsent forms remain in this window. Saved identity, source drafts and original signed work remain local."; UpdateButtons(); Notify();
    }
    public override void _UnhandledKeyInput(InputEvent @event)
    {
        if (@event is InputEventKey { Pressed: true, Keycode: Key.Escape }) {
            if (representations?.Visible == true) representations.Cancel(); else action?.Cancel();
            GetViewport().SetInputAsHandled(); Notify();
        }
    }
    public override void _Notification(int what)
    {
        if (what == NotificationWMCloseRequest) _ = CloseApplication();
        if (what == NotificationApplicationFocusOut) { GetViewport()?.GuiReleaseFocus();scene?.ReleaseInput();gui?.Cancel();xr?.DesktopFocusLost(); }
    }
    void UpdateButtons()
    {
        identityLabel.Text = key == null ? "No unlocked identity" : "Public identity: " + key.PublicText+(session==null ? "" : "\nNetwork: "+session.Network)+
            (accounts?.StorageDescription is {Length:>0} storage ? "\n"+storage : "");
        if (buttons.Count == 0) return;
        foreach (var button in buttons.Values) button.Disabled = busy;
        buttons["disconnect"].Disabled = session == null && !busy;
        buttons["create-key"].Disabled |= key != null || store == null;
        buttons["import-backup"].Disabled |= key != null || store == null;
        buttons["export-backup"].Disabled |= key == null;
        buttons["connect"].Disabled |= key == null || session is {IsExpired:false};
        buttons["register"].Disabled |= accounts == null || !accounts.CanRegister;
        buttons["prepare"].Disabled |= accounts?.Human == null || accounts.Uncertain;
        buttons["setup"].Disabled |= accounts?.Prepared == null || accounts.Uncertain;
        buttons["resolve"].Disabled |= accounts == null;
        buttons["open-gui"].Disabled |= accounts?.Setup == null;
        buttons["create-operations"].Disabled |= accounts?.Setup == null;
        buttons["location-operations"].Disabled |= accounts?.Setup == null || !navigationAvailable || navigation?.Space == null || !worldAccepted;
        buttons["inspect"].Disabled |= accounts?.Human == null;
        buttons["local-controllers"].Disabled|=accounts?.Human==null;
        buttons["start-xr"].Disabled|=accounts?.Human==null || xr.Running;
        buttons["stop-xr"].Disabled|=!xr.Running;
        UpdateOnboarding();
        UpdateWorkspace();
        xr.RefreshMenu();
    }
    void UpdateOnboarding()
    {
        bool signed=session is {IsExpired:false} && accounts!=null, ready=signed&&accounts!.Setup!=null;
        bool uncertain=signed&&accounts!.Uncertain;
        string? next=store==null ? null : key==null ? "create-key" : !signed ? "connect" : uncertain ? "resolve" :
            accounts!.CanRegister ? "register" : accounts.Human!=null&&accounts.Setup==null ? (accounts.Prepared==null ? "prepare" : "setup") : null;
        connectionTitle.Text=key==null ? "Welcome to Quod" : !signed ? "Sign in with your saved key" : uncertain ? "Check your original work" :
            accounts!.CanRegister ? "Create your account" : accounts.Human==null ? "Account unavailable" : !ready ? "Set up your starting space" : "Account ready";
        connectionHelp.Text=store==null ? "Local identity storage is unavailable. Your files have not been replaced." : key==null ?
            "New here? Create a key on this device. Already have a key? Import your encrypted backup instead." : !signed ?
            "Connect to recover this key's existing account. Server and trust settings are in the details below." : uncertain ?
            "An earlier action has no confirmed outcome. Check that original action; do not submit it again." : accounts!.CanRegister ?
            "This new key has no account on this network. Creating an account is a separate, explicit action." : accounts.Human==null ?
            "No account reference was recovered for this imported key. Registration cannot replace an unavailable original account." : !ready ?
            accounts.Prepared==null ? "Review the policy-selected storage first. This read creates neither your agent nor your starting space." :
            "Create your personal agent and empty starting space together in your account storage." :
            "Your existing account is available. Account and space actions use the offered forms below.";
        buttons["connect"].Text=state=="sign-in-expired" || session?.IsExpired==true ? "Sign in again" : "Connect";
        foreach(string name in new[]{"create-key","import-backup","connect","disconnect","register","prepare","setup","resolve"}) {
            var button=buttons[name];button.ThemeTypeVariation=name==next ? "PrimaryAction" : "";
            button.Visible=name switch {"create-key" or "import-backup"=>key==null,"connect"=>key!=null&&!signed,
                "disconnect"=>session!=null||busy,"resolve"=>uncertain, _=>name==next};
        }
        accountActions.Visible=ready;
        buttons["workspace-connection"].Visible=ready;
        buttons["client-tools"].Visible=ready;
        SpatialGui.SetEditable(endpoint,!busy);SpatialGui.SetEditable(ca,!busy);
    }
    void Notify() { if(!disposed){UpdateOnboarding();UpdateWorkspace();representations?.RefreshContext();}xr?.ContextChanged();if (!disposed && IsInsideTree()) EmitSignal(SignalName.Changed); }
    public string Inspect() => JsonSerializer.Serialize(new { state, busy, public_key = key?.PublicText,
        network = session?.Network, human = accounts?.Human, setup = accounts?.Setup?.ToString(),
        pending = store?.Snapshot?.Pending.Count, world_accepted = worldAccepted, live_sockets = SignedView.LiveSockets, ignored_projections = SignedView.IgnoredProjections, question_receiver_ready = questions?.Ready,
        current_location = navigationAvailable ? navigation?.Location.ToString() : null, assignment_revision = navigationAvailable ? navigation?.Revision.ToString() : null,
        physical_selection = projection?.Selection, physical_tick = projection?.Sample?.Tick, scene_count = scene?.Count,
        operation_available = operations?.Available, operation_status = operations?.StatusText, status = status.Text,
        controller_status=xr?.Router?.Status,controller_metrics=xr?.Metrics });
    internal LocalStore ActiveStore => store ?? throw new InvalidOperationException("No active store.");
    internal SignedSession ActiveSession => session ?? throw new InvalidOperationException("No active session.");
    internal Accounts ActiveAccounts => accounts ?? throw new InvalidOperationException("No active account.");
    void BackupDialog(bool export)
    {
        OverlayChanging();
        if (backupDialog != null && IsInstanceValid(backupDialog) && !backupDialog.IsQueuedForDeletion()) { backupDialog.GrabFocus(); return; }
        var cancelled = new CancellationTokenSource();
        var dialog = new Window { Name = "backup-dialog", Title = export ? "Export encrypted backup" : "Import encrypted backup", Size = new(620, 250), Transient = true, Exclusive = true };
        backupDialog = dialog; backupCancellation = cancelled;
        AddChild(dialog); var pane = new VBoxContainer(); dialog.AddChild(pane); pane.SetAnchorsAndOffsetsPreset(LayoutPreset.FullRect);
        pane.AddChild(new Label { Text = export ? "Backup passphrase (at least 12 characters). Active key storage is separate." : "Import into this empty local profile. A wrong passphrase never replaces an identity.", AutowrapMode = TextServer.AutowrapMode.WordSmart });
        var path = new LineEdit { Name = "backup-path", PlaceholderText = "Backup file path" }; pane.AddChild(path);
        var phrase = new LineEdit { Name = "backup-passphrase", Secret = true, PlaceholderText = "Backup passphrase" }; pane.AddChild(phrase);
        var result = new Label { Name = "backup-result", AutowrapMode = TextServer.AutowrapMode.WordSmart }; pane.AddChild(result);
        var apply = new Button { Name = "backup-apply", Text = export ? "Export" : "Import" }; pane.AddChild(apply);
        async Task Apply()
        {
            apply.Disabled = true;
            try {
                string passphrase = phrase.Text, file = path.Text;
                if (export) {
                    string payload = store!.PortablePayload();
                    string encrypted = await Task.Run(() => Backup.Export(key!, passphrase, payload));
                    cancelled.Token.ThrowIfCancellationRequested();
                    using var output = new FileStream(file, new FileStreamOptions { Mode = System.IO.FileMode.CreateNew, Access = System.IO.FileAccess.Write,
                        UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite });
                    var bytes = System.Text.Encoding.UTF8.GetBytes(encrypted); output.Write(bytes); output.Flush(true); result.Text = "Encrypted backup saved.";
                } else {
                    string contents = await File.ReadAllTextAsync(file);
                    string payload = await Task.Run(() => Backup.Decrypt(contents, passphrase));
                    cancelled.Token.ThrowIfCancellationRequested();
                    store!.Create(payload); key = Identity.FromPayload(store.Snapshot!.Payload); result.Text = "Original key and account references restored."; UpdateButtons(); Notify();
                }
                phrase.Text = "";
            } catch (OperationCanceledException) when (cancelled.IsCancellationRequested) { }
            catch (Exception error) { if (IsInstanceValid(result)) result.Text = error.Message; }
            finally { if (IsInstanceValid(apply)) apply.Disabled = false; Notify(); }
        }
        apply.Pressed += () => { if (!apply.Disabled) backupWork = Apply(); };
        dialog.TreeExiting += () => cancelled.Cancel();
        dialog.TreeExited += () => { if (ReferenceEquals(backupDialog, dialog)) backupDialog = null; };
        dialog.CloseRequested += () => { cancelled.Cancel(); dialog.QueueFree(); }; dialog.PopupCentered(); phrase.GrabFocus();
    }
    void ReleaseIdentity()
    { if (released) return; released = true; key?.Dispose(); store?.Dispose(); }
    internal async Task CloseApplication(int exitCode=0)
    {
        if (closing) return; closing = true; action?.Cancel(); backupCancellation?.Cancel(); backupDialog?.QueueFree(); CloseSession(false);
        await Task.WhenAll(ViewsDisposed, activeAction, backupWork,xr.Completion);
        models.Dispose();await models.Completion;
        bool xrStopped=await xr.Shutdown(SignedSession.Now+5000);
        disposed = true; ReleaseIdentity(); GetTree().Quit(xrStopped ? exitCode : 1);
    }
    public override void _ExitTree()
    {
        disposed = true; action?.Cancel(); backupCancellation?.Cancel(); CloseSession(false);
        // On an external engine quit, keep the writer lease until cancelled
        // work finishes or the process closes it. Never release it under I/O.
        if (ViewsDisposed.IsCompleted && activeAction.IsCompleted && backupWork.IsCompleted) ReleaseIdentity();
    }
    void OpenControllers()
    {
        OverlayChanging();
        if(localControllers!=null){localControllers.Show();UpdateControllerStatus();return;}
        localControllers=new() { Name="local-controllers-panel" };body.AddChild(localControllers);
        localControllerStatus=new() { AutowrapMode=TextServer.AutowrapMode.WordSmart };localControllers.AddChild(localControllerStatus);
        foreach(string role in new[]{"navigation","menu"}) {
            localControllers.AddChild(new Label { Text=role=="navigation" ? "Movement source for this session" : "Menu source for this session" });
            var choice=new OptionButton();localControllers.AddChild(choice);sourceChoices.Add(role,choice);
            choice.ItemSelected+=index=> {
                string id=choice.GetItemMetadata((int)index).AsString();
                if(!xr.Router.Choose(role,id))localControllerStatus.Text="Movement and menu require distinct sources.";
            };
        }
        var row=Row(localControllers);var settings=new Button { Text="Edit saved bindings" };row.AddChild(settings);settings.Pressed+=()=>activeAction=Run(OpenGui);
        var close=new Button { Text="Close" };row.AddChild(close);close.Pressed+=()=>{localControllers.Hide();Notify();};
        sourceSchema="";UpdateControllerStatus();
    }
    void UpdateControllerStatus()
    {
        controllers.Text="Keyboard/mouse available. "+xr.Status+"\n"+xr.Router.Description;
        if(localControllerStatus!=null) {
            localControllerStatus.Text=xr.Status+"\n"+xr.Router.Description;
            var sources=xr.Router.SourceChoices;string schema=string.Join(',',sources.Select(s=>s.Id));
            foreach(var choice in sourceChoices.Values) {
                if(schema!=sourceSchema || choice.ItemCount==0) {
                    choice.Clear();choice.AddItem("Use saved hand preference");choice.SetItemMetadata(0,"");
                    foreach(var source in sources){choice.AddItem(source.Id+": "+source.Hand+" "+source.Profile);choice.SetItemMetadata(choice.ItemCount-1,source.Id);}
                } else for(int i=0;i<sources.Length;i++)choice.SetItemText(i+1,sources[i].Id+": "+sources[i].Hand+" "+sources[i].Profile);
            }
            foreach(var (role,choice) in sourceChoices) {
                string? selected=xr.Router.Choice(role);
                choice.Select(selected==null ? 0 : Array.FindIndex(sources,s=>s.Id==selected)+1);
            }
            sourceSchema=schema;
        }
        UpdateButtons();Notify();
    }
}
