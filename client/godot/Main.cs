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
    readonly VBoxContainer panelColumn=new() {Name="subject-and-preview"};
    readonly PanelContainer subjectPanel=new() {Name="subject-panel",Visible=false},attentionPanel=new() {Name="attention-panel",Visible=false},
        localPanel=new() {Name="local-panel",Visible=false};
    // Plain opaque text on tinted glass, the house panel tokens.
    readonly StyleBoxFlat glass=new() {BgColor=new(0x19/255f,0x2B/255f,0x32/255f,.92f),BorderColor=new(0x84/255f,0x8F/255f,0xA5/255f,.5f),
        BorderWidthLeft=1,BorderWidthTop=1,BorderWidthRight=1,BorderWidthBottom=1,CornerRadiusTopLeft=12,CornerRadiusTopRight=12,
        CornerRadiusBottomLeft=12,CornerRadiusBottomRight=12,ContentMarginLeft=16,ContentMarginRight=16,ContentMarginTop=12,ContentMarginBottom=12};
    bool dockLeft;
    readonly VBoxContainer visualHost=new() {Name="subject-visual-host",SizeFlagsHorizontal=SizeFlags.ExpandFill,SizeFlagsVertical=SizeFlags.ExpandFill,Visible=false};
    readonly VBoxContainer subjectHost=new() {Name="subject-form-host",SizeFlagsHorizontal=SizeFlags.ExpandFill,SizeFlagsVertical=SizeFlags.ExpandFill,Visible=false};
    readonly VBoxContainer connectionShell=new() {Name="login-steps"};
    // The opening screen: one centred card over the house teal (#0B3954). The same
    // account steps as before, one primary action at a time; also the Account overlay.
    readonly PanelContainer loginView=new() {Name="login"};
    readonly StyleBoxFlat loginBackdrop=new() {BgColor=new(11f/255,57f/255,84f/255),ExpandMarginLeft=28,ExpandMarginRight=28,ExpandMarginTop=22,ExpandMarginBottom=22};
    readonly Label loginStatus=new() {Name="login-status",HorizontalAlignment=HorizontalAlignment.Center,AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly Label endpointLabel=new() {Text="Node address"};
    Control workspaceShell=null!;
    readonly VBoxContainer connectionDetails=new() { Visible=false };
    readonly VBoxContainer accountSetup=new();
    readonly HBoxContainer place=new() {Name="current-place",MouseFilter=MouseFilterEnum.Ignore};
    readonly Label placeTitle=new() {Name="current-place-title",ThemeTypeVariation="Heading",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    bool home=true;
    readonly Label connectionTitle=new() {Name="connection-title",ThemeTypeVariation="Heading",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly Label connectionHelp=new() {Name="connection-help",AutowrapMode=TextServer.AutowrapMode.WordSmart};
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
    readonly LineEdit endpoint = new() { Name = "endpoint", PlaceholderText = "e.g. quod-0.service.consul or IP:port", SizeFlagsHorizontal = SizeFlags.ExpandFill };
    readonly VBoxContainer attentionHost=new() {Name="attention-host",SizeFlagsHorizontal=SizeFlags.ExpandFill};
    readonly VBoxContainer body = new() { Name = "body", SizeFlagsHorizontal = SizeFlags.ExpandFill };
    OperationsPanel? operations;
    EidolonPanel? representations;
    ScenePanel scene = null!;
    public Task ViewsDisposed { get; private set; } = Task.CompletedTask;
    QuestionHub? questions;
    readonly PieMenu pie=new();
    readonly HudBar hud=new() {AnchorLeft=0,AnchorRight=1,AnchorTop=1,AnchorBottom=1,OffsetTop=-60,Visible=false};
    readonly Label pointerLabel=new() {Name="pointer-label",Visible=false,MouseFilter=MouseFilterEnum.Ignore};
    ScenePanel.Selection? hovered;
    Vector2? hoverPoint;
    SignedView? pieView;
    ScenePanel.Selection? pieOccurrence;
    Vector2? pieAt;
    long pieGeneration;
    Task retiredPie=Task.CompletedTask;
    readonly Dictionary<string, Button> buttons = [];
    public override void _Ready()
    {
        GetTree().AutoAcceptQuit = false;
        gui=new() { Name="shared-gui" };AddChild(gui);gui.Surface.AddChild(pie);
        // Fullscreen: the world fills the window. The only chrome is the corner
        // cue, the HUD strip, floating panels and, when needed, the login card.
        var margin = new MarginContainer { AnchorRight = 1, AnchorBottom = 1 };
        gui.SetContent(margin);workspaceContent=margin;
        var shell=new Control {Name="workspace",MouseFilter=MouseFilterEnum.Ignore};workspaceShell=shell;margin.AddChild(shell);
        var icon=GD.Load<Texture2D>("res://assets/quod-icon.png");
        place.AddChild(new TextureRect {Name="quod-logo",Texture=icon,
            CustomMinimumSize=new(28,28),ExpandMode=TextureRect.ExpandModeEnum.IgnoreSize,
            StretchMode=TextureRect.StretchModeEnum.KeepAspectCentered,MouseFilter=MouseFilterEnum.Ignore});
        place.AddChild(placeTitle);
        foreach(var panel in new[]{subjectPanel,attentionPanel,localPanel})panel.AddThemeStyleboxOverride("panel",glass);
        subjectPanel.AddChild(panelColumn);panelColumn.AddChild(visualHost);panelColumn.AddChild(subjectHost);
        attentionPanel.AddChild(attentionHost);localPanel.AddChild(body);
        loginView.AddThemeStyleboxOverride("panel",loginBackdrop);margin.AddChild(loginView);
        var centre=new CenterContainer();loginView.AddChild(centre);
        var card=new PanelContainer {Name="login-card",CustomMinimumSize=new(400,0)};centre.AddChild(card);
        card.AddThemeStyleboxOverride("panel",new StyleBoxFlat {BgColor=new(1,1,1,.06f),BorderColor=new(1,1,1,.14f),
            BorderWidthLeft=1,BorderWidthTop=1,BorderWidthRight=1,BorderWidthBottom=1,
            CornerRadiusTopLeft=16,CornerRadiusTopRight=16,CornerRadiusBottomLeft=16,CornerRadiusBottomRight=16,
            ContentMarginLeft=30,ContentMarginRight=30,ContentMarginTop=26,ContentMarginBottom=20});
        card.AddChild(connectionShell);connectionShell.AddThemeConstantOverride("separation",10);
        connectionShell.AddChild(new TextureRect {Name="login-logo",Texture=icon,CustomMinimumSize=new(96,96),ExpandMode=TextureRect.ExpandModeEnum.IgnoreSize,
            StretchMode=TextureRect.StretchModeEnum.KeepAspectCentered,MouseFilter=MouseFilterEnum.Ignore});
        connectionTitle.ThemeTypeVariation="Title";connectionTitle.HorizontalAlignment=HorizontalAlignment.Center;
        connectionHelp.HorizontalAlignment=HorizontalAlignment.Center;connectionHelp.Modulate=new(1,1,1,.8f);
        connectionShell.AddChild(connectionTitle);connectionShell.AddChild(connectionHelp);
        connectionShell.AddChild(endpointLabel);connectionShell.AddChild(endpoint);
        var primary=new VBoxContainer();connectionShell.AddChild(primary);
        Add(primary, "create-key", "Create my key", CreateKey); Add(primary, "connect", "Sign in", Connect);
        connectionShell.AddChild(accountSetup);
        loginStatus.Modulate=new(1,1,1,.85f);connectionShell.AddChild(loginStatus);
        var links=new HBoxContainer {Alignment=BoxContainer.AlignmentMode.Center};connectionShell.AddChild(links);
        Add(links, "import-backup", "Import a backup", () => { BackupDialog(false); return Task.CompletedTask; });
        Add(links, "disconnect", "Disconnect", () => { Disconnect(); return Task.CompletedTask; });
        Add(links, "close-account", "Close", () => { showConnection=false; UpdateWorkspace(); return Task.CompletedTask; });
        Add(links,"connection-details","Details",()=>{connectionDetails.Visible=!connectionDetails.Visible;return Task.CompletedTask;});
        foreach(var link in links.GetChildren().OfType<Button>())link.Flat=true;
        foreach(var step in primary.GetChildren().OfType<Button>())step.CustomMinimumSize=new(0,42);
        connectionShell.AddChild(connectionDetails);connectionDetails.AddChild(identityLabel);
        connectionDetails.AddChild(new Label { Text="Active keys use private local files, not a backup passphrase. Encrypted backups have a separate passphrase.",AutowrapMode=TextServer.AutowrapMode.WordSmart });
        Add(connectionDetails, "forget-node-key", "Forget this node's key", ForgetNodeKey);
        Add(connectionDetails, "export-backup", "Export encrypted backup", () => { BackupDialog(true); return Task.CompletedTask; });
        connectionDetails.AddChild(location);connectionDetails.AddChild(controllers);
        Add(accountSetup, "register", "Create my account", Register);
        Add(accountSetup, "prepare", "Review my starting space", Prepare);
        Add(accountSetup, "setup", "Create my starting space", Setup);
        Add(accountSetup, "resolve", "Check earlier actions", Resolve);
        foreach(var step in accountSetup.GetChildren().OfType<Button>())step.CustomMinimumSize=new(0,42);
        scene = new() { Name = "space-scene" };
        models=new(async (asset,cancellation)=> {
            var consumer=session??throw new InvalidOperationException("Connect before requesting controller resources.");
            using var deadline=CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            ulong until=consumer.Deadline;if(until<=SignedSession.Now)throw new TimeoutException("Asset deadline expired.");
            deadline.CancelAfter(TimeSpan.FromMilliseconds(until-SignedSession.Now));
            return await consumer.Transport.Model(asset.Digest,asset.Allowed[0],deadline.Token);
        });
        xr=new() { Name="openxr-input" };scene.Viewport.AddChild(xr);
        xr.Configure(scene,gui,models,()=>controls,()=>GuiOpen || gui.NativePressed,pie,hit=>OpenPie(hit,null));
        pie.Selected+=chosen=>{var occurrence=pieOccurrence;var at=pieAt;ClosePie();Activate(chosen,occurrence,at);};
        gui.Surface.AddChild(hud);hud.Theme=gui.Appearance;
        hud.Activated+=(command,control)=>{
            if(hud.Commands is not {} commands||!OpenPie(null,control.GetGlobalRect().GetCenter(),local:commands))return;
            if(pie.Choose(command.Slot))pie.Commit();
        };
        hud.DeviceRequested+=control=>OpenPie(null,control.GetGlobalRect().GetCenter(),local:DeviceMenu());
        pie.Dismissed+=ClosePie;
        scene.MenuGesture+=(step,hit,point)=>{
            var at=point+scene.GlobalPosition;
            if(step==ScenePanel.MenuStep.Open){if(!pie.IsOpen)OpenPie(hit,at);}
            else if(step==ScenePanel.MenuStep.Move){if(pie.IsOpen)pie.PointerAt(at);}
            else if(pie.IsOpen&&pie.Navigator?.Hovered>0)pie.Commit();
        };
        scene.Hovered+=(hit,point)=>{
            hovered=hit;scene.Outline(hit);
            string? text=float.IsNaN(point.X)||pie.IsOpen ? null : TargetLabel(hit);
            pointerLabel.Visible=text!=null;if(text==null)return;
            pointerLabel.Text=text;pointerLabel.Position=point+scene.GlobalPosition+new Vector2(18,18);hoverPoint=point+scene.GlobalPosition;
        };
        gui.Surface.AddChild(pointerLabel);pointerLabel.Theme=gui.Appearance;
        scene.PresentationChanged+=()=>{
            if(pie.IsOpen&&pieOccurrence!=null&&pieOccurrence.Pose==null){ClosePie();status.Text="That thing is no longer here.";Notify();}
        };
        xr.Changed+=UpdateControllerStatus;xr.TargetLabel=TargetLabel;
        gui.NativeCaptureChanged+=()=>{if(gui.NativePressed){xr.Router.Cancel();scene.ReleaseInput();}xr.ContextChanged();};
        GetWindow().VisibilityChanged+=()=>xr.Visibility(GetWindow().Visible);
        scene.Drive += (direction,_) => controls?.Drive(direction.X,direction.Y,direction.Z);
        scene.Selected += selected => {
            if (accounts?.Human == null || session == null) return;
            if(operations?.IsWorking==true)return;
            if(hoverPoint is Vector2 point)dockLeft=point.X>workspaceShell.Size.X/2;
            EnsureRepresentations().OpenOccurrence(session,accounts,store!,selected);ShowInspector();
        };
        // The scene is the background; panels float over it, the login card above all.
        shell.AddChild(scene);scene.SetAnchorsAndOffsetsPreset(LayoutPreset.FullRect);
        shell.AddChild(place);shell.AddChild(subjectPanel);shell.AddChild(attentionPanel);shell.AddChild(localPanel);
        subjectHost.AddChild(gui.FormMirror);
        gui.Resized+=UpdateWorkspace;
        gui.Appearance.Changed+=UpdateWorkspace;
        shell.Resized+=UpdateWorkspace;
        endpoint.TextChanged += _ => SettingsChanged();
        try {
            string profile = Argument("--profile") ?? ProjectSettings.GlobalizePath("user://identity");
            store = new LocalStore(profile);
            if (store.Snapshot is LocalState saved) {
                key = Identity.FromPayload(saved.Payload); endpoint.Text = saved.Endpoint;
                status.Text = "Signing in…";
            } else status.Text = "";
            if (Argument("--node") is string node) endpoint.Text = node;
        } catch (Exception error) { state = "storage-error"; status.Text = error.Message; }
        UpdateButtons(); Notify();
        if(key!=null)activeAction=Run(Connect);
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
    // A chosen wedge or HUD command: its subject's sub-pie, the question list,
    // a local device action, or exactly that offered Eidolon choice.
    void Activate(MenuTarget chosen,ScenePanel.Selection? occurrence,Vector2? at)
    {
        if(chosen.Subject is {Kind:"atom",Name:"this_device"}){DeviceAction(chosen.Choice.Name);return;}
        if(session==null||accounts?.Human==null||store==null)return;
        var purpose=chosen.Choice.Require("eidolon",3)[0];
        if(purpose is {Kind:"atom",Name:"menu"}){OpenPie(null,at,chosen.Subject);return;}
        if(purpose is {Kind:"atom",Name:"attention"}){if(questions!=null){OverlayChanging();questions.Show();Notify();}return;}
        if(at is Vector2 point)dockLeft=point.X>workspaceShell.Size.X/2;
        EnsureRepresentations().OpenChoice(session,accounts,store,chosen,occurrence);ShowInspector();
    }
    // "This device" is the one client-authored command (decision 3).
    MenuNode DeviceMenu()
    {
        MenuNode Item(int slot,string id,string label,int wedges=8)=>new(Term.Atom("device_"+id),label,"",true,slot,wedges,0,
            new MenuTarget(Term.Atom("this_device"),Term.Atom(id)),false,[]);
        var workspace=new MenuNode(Term.Atom("device_workspace"),"Workspace",gui.Spatial ? "" : "In VR only.",gui.Spatial,7,8,3,null,false,
            [Item(1,"workspace_show","Recenter"),Item(2,"workspace_move",xr.MovingWorkspace ? "Place panel" : "Move panel"),
             Item(5,"workspace_hide","Hide"),Item(7,"workspace_nearer","Nearer"),Item(8,"workspace_farther","Farther")]);
        var tools=new MenuNode(Term.Atom("device_tools"),"Tools","",true,6,8,2,null,false,
            [Item(1,"create","Create in a storage"),Item(3,"account_source","My account's source"),
             Item(4,"account_controls","Account controls"),Item(5,"controllers","Connected controllers")]);
        return new(Term.Atom("device"),"This device","",true,0,8,0,null,false,
            [Item(1,"text_larger","Larger text"),Item(2,"opaque",gui.OpaquePanels ? "Tinted panels" : "Opaque panels"),
             Item(3,"vr",xr.Running ? "Return to 3D" : "Enter VR"),Item(4,"account","Account and keys"),
             Item(5,"text_smaller","Smaller text"),tools,workspace]);
    }
    internal void DeviceAction(string action)
    {
        switch(action) {
            case "text_larger": gui.TextSize(4);break;
            case "text_smaller": gui.TextSize(-4);break;
            case "opaque": gui.ToggleOpacity();break;
            case "vr": if(xr.Running)xr.StopSession();else xr.Start();break;
            case "workspace_show": representations?.PlacePersonal();xr.ShowWorkspace();break;
            case "workspace_move": representations?.PlacePersonal();xr.MoveWorkspace();break;
            case "workspace_hide": xr.HideWorkspace();break;
            case "workspace_nearer": xr.WorkspaceDistance(-.2f);break;
            case "workspace_farther": xr.WorkspaceDistance(.2f);break;
            case "account": showConnection=true;break;
            case "create": activeAction=Run(OpenStorage);break;
            case "account_source": activeAction=Run(OpenTools);break;
            case "account_controls": activeAction=Run(OpenGui);break;
            case "controllers": OpenControllers();break;
        }
        Notify();
    }
    // The target rule: the pointed occurrence, else the space the agent is
    // placed in, else the agent itself. What each offers comes from its menu.
    bool OpenPie(ScenePanel.Selection? hit,Vector2? at,Term? target=null,MenuNode? local=null)
    {
        if(session is not {IsExpired:false} consumer||accounts?.Human is not Actor human||accounts.Setup is not Term setup||operations?.IsWorking==true)return false;
        Term subject;string name;
        if(local!=null){subject=Term.Atom("this_device");name=local.Label;}
        else if(target!=null){subject=target;name="this";}
        else if(hit!=null){subject=hit.Subject;name=hit.Label??"this";}
        else if(navigationAvailable&&navigation?.Space is Actor space){subject=space.Entity;name=projection?.Name is {Length:>0} n ? n : "this space";}
        else {subject=Actor.FromTerm(setup.Require("account",6)[1]).Entity;name="you";}
        ClosePie();
        var surface=gui.Spatial ? xr.PieSurface : gui.Surface;
        if(pie.GetParent()!=surface){pie.GetParent()?.RemoveChild(pie);surface.AddChild(pie);}else surface.MoveChild(pie,-1);
        var size=(Vector2)surface.Size;
        pie.ShowDigits=!gui.Spatial;
        pie.Open(at??size/2,gui.Spatial ? 300 : Math.Clamp(Math.Min(size.X,size.Y)*.22f,130,240),"Reading "+name+"…");
        pieOccurrence=hit;pieAt=gui.Spatial ? null : at;long expected=++pieGeneration;
        // A HUD sub-pie or the device menu is already in hand; nothing to read.
        if(local!=null){if(gui.Spatial&&at is Vector2 origin)xr.PlacePieAtHud(origin);pie.Present(local,"");Notify();return true;}
        Subject exact;
        try{exact=Subject.Decode(subject);}catch(FormatException){pie.Close();return false;}
        var view=new SignedView(consumer,human,exact.Target,"menu",SignedSession.ViewGoal(exact.Target,Term.Call("client_menu",exact.Local,Term.Variable("View"))));
        pieView=view;
        view.Projection+=message=>{
            if(expected!=pieGeneration)return;
            try{pie.Present(MenuNode.Decode(Term.Parse(Json.S(message,"value"))),"Nothing is offered here.");}
            catch(Exception error){ClosePie();status.Text="This menu is unavailable: "+error.Message;}
            Notify();
        };
        view.Withdrawn+=reason=>{
            if(expected!=pieGeneration||view.Updating)return;
            bool shown=pie.Navigator!=null;ClosePie();
            status.Text=shown ? "That thing is no longer here." : "This menu is unavailable: "+reason;Notify();
        };
        _=view.Start();Notify();return true;
    }
    // The occurrence's authored label, else the containing space; nothing for
    // an unlabelled mark. Never a Prolog term.
    string? TargetLabel(ScenePanel.Selection? hit)=>hit!=null ? hit.Label
        : !navigationAvailable||accounts?.Setup==null ? null
        : navigation?.Space==null ? "You are nowhere yet"
        : "Space · "+(projection?.Name is {Length:>0} name ? name : "unnamed");
    // A subject's own pie, centred; with no subject, the target rule's.
    internal bool OpenSubjectPie(Term? subject=null)=>OpenPie(null,null,subject);
    void ClosePie()
    {
        pieGeneration++;pieOccurrence=null;pie.Close();
        var previous=pieView;pieView=null;previous?.Dispose();
        var completion=previous?.Completion??Task.CompletedTask;
        retiredPie=retiredPie.IsCompleted ? completion : Task.WhenAll(retiredPie,completion);
    }
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
        status.Text = "Key saved on this device."; return Connect();
    }
    async Task Connect()
    {
        if (key == null || store == null) throw new InvalidOperationException("Create/import a key first.");
        CloseSession(); long expected = incarnation;
        await ViewsDisposed;
        if (disposed || closing || expected!=incarnation) return;
        string origin = Transport.NodeOrigin(endpoint.Text), pinned = store.Snapshot!.NodeKey(origin);
        store.Update(s => s.Endpoint = origin);
        var connecting = new SignedSession(key, store, new Transport(origin, pinned));
        session = connecting; status.Text = "Signing in…"; Notify();
        connecting.Expired+=()=>{
            if(!ReferenceEquals(session,connecting)||disposed||closing)return;
            Disconnect();state="sign-in-expired";
            status.Text="Your sign-in expired. Sign in again; nothing was lost.";
            UpdateButtons();Notify();
        };
        try {
            try { await connecting.Authenticate(Cancellation); }
            catch (HttpRequestException) when (connecting.Transport.KeyChanged) {
                throw new InvalidOperationException("This node's key is not the one remembered for " + origin +
                    ". If the node was deliberately re-founded, use \"Forget this node's key\" and connect again.");
            }
            if (disposed || expected != incarnation) return;
            if (pinned.Length == 0) store.Update(s => s.NodeKeys[origin] = connecting.Transport.NodeKey);
            var discovered = new Accounts(connecting, store); await discovered.Discover(Cancellation);
            if (disposed || expected != incarnation) return;
            accounts = discovered;
        } catch { if (ReferenceEquals(session, connecting)) CloseSession(); throw; }
        state = accounts.Human == null ? "signed-in-no-account" : accounts.Setup == null ? "setup-pending" : "account-ready";
        status.Text = accounts.Uncertain ? "An earlier action has no confirmed result yet. Check it before continuing." : "Signed in.";
        if (accounts.Setup != null) await PresentAccount();
    }
    async Task Register()
    {
        RequireSession(); long expected = incarnation; await accounts!.Register(Cancellation);
        if (disposed || expected != incarnation) return;
        state = accounts.Human == null ? "signup-uncertain" : "setup-pending";
        status.Text = accounts.Human == null ? "We could not confirm your account yet. Use “Check earlier actions”." : "Your account is ready. Next, set up your starting space.";
    }
    async Task Prepare()
    {
        RequireSession(); long expected = incarnation; await accounts!.Prepare(Cancellation);
        if (disposed || expected != incarnation) return;
        status.Text = accounts.StorageDescription.Length == 0 ? "Your starting space is ready." : accounts.StorageDescription + " Nothing is created until you confirm.";
        if (accounts.Setup != null) await PresentAccount();
    }
    async Task Setup()
    {
        RequireSession(); long expected = incarnation; await accounts!.FinishSetup(Cancellation);
        if (disposed || expected != incarnation) return;
        if (accounts.Setup != null) { state = "account-ready"; await PresentAccount(); }
        else status.Text = "We could not confirm the setup yet. Use “Check earlier actions”.";
    }
    async Task Resolve()
    {
        RequireSession(); long expected = incarnation; await accounts!.Resolve(Cancellation);
        if (disposed || expected != incarnation) return;
        state = accounts.Human == null ? "signed-in-no-account" : accounts.Setup == null ? "setup-pending" : "account-ready";
        status.Text = accounts.Uncertain ? "The result is still unknown. Nothing was sent again." : "Earlier actions checked. Nothing was sent again.";
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
        route.Withdrawn += reason => { navigationAvailable=false; SuspendWorld(route.Updating); location.Text = "Location unavailable: " + reason; UpdateButtons(); Notify(); };
        _ = route.Start();
        var preferences = new SignedView(consumer, human, human, "controller_preferences", SignedSession.ViewGoal(human,
            Term.Call("controller_preferences_view", Term.Parse(human.InstanceText.TrimEnd('.')), Term.Variable("View")))); views.Add(preferences);
        preferences.Projection += message => {
            var value=Term.Parse(Json.S(message,"value"));var mapping=ControllerMapping.Decode(value);xr.Install(mapping);
            controllers.Text="Keyboard/mouse available. "+(mapping==null ? "Stored controller settings are invalid; use the offered Reset operation." : "Controller mapping revision "+mapping.Revision+".");Notify();
        };
        preferences.Withdrawn += reason => { xr.Install(null);controllers.Text = "Controller mapping unavailable: " + reason; Notify(); };
        _ = preferences.Start();
        questions?.Dispose(); questions = new(consumer, accounts, store!, attentionHost, Notify); questions.Start();
        var commands=new SignedView(consumer,human,human,"hud_commands",SignedSession.ViewGoal(human,Term.Call("hud_commands",Term.Variable("View")))); views.Add(commands);
        commands.Projection+=message=>{
            try{hud.Present(MenuNode.Decode(Term.Call("menu",Term.Parse(Json.S(message,"value")).Require("hud",1)[0])));}
            catch(Exception error){hud.Present(null);status.Text="Your commands are unavailable: "+error.Message;}
            Notify();
        };
        commands.Withdrawn+=reason=>{if(!commands.Updating){hud.Present(null);Notify();}};
        _=commands.Start();
        bool returnHome=home;
        if(representations?.Resume(consumer,accounts,store!)!=true)home=true;
        else home=returnHome;
        UpdateWorkspace();await Task.CompletedTask;
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
        if (space == null) { SuspendWorld(); status.Text="You are not in a space yet."; return; }
        if (worldView?.Completion?.IsCompleted==true) RetireWorld();
        if (worldView != null) {
            bool same=worldView.Target==space;
            if(!same)scene.Withdraw();
            ScheduleWorldChange(false,same);return;
        }
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
                status.Text="";
            } catch (Exception error) { WithdrawWorld(error.Message); }
            UpdateButtons(); Notify();
        };
        view.Message += message => {
            if (expected != worldIncarnation || Json.S(message,"type") != "simulation_frame" || projection == null) return;
            try { if (scene.ApplyFrame(message,ack=>_ = view.Send(ack))) { controls?.Present(projection); Notify(); } }
            catch (Exception error) { WithdrawWorld(error.Message); Notify(); }
        };
        view.Withdrawn += reason => { if (expected == worldIncarnation) { WithdrawWorld(reason,view.Updating); Notify(); } };
        _ = view.Start();
    }
    void SuspendWorld(bool refreshing=false) { WithdrawWorld("Location is being verified.",refreshing); if (worldView != null) ScheduleWorldChange(true,refreshing); }
    void ScheduleWorldChange(bool suspend,bool refreshing)
    { var next=ChangeWorld(suspend,refreshing); worldChanges=worldChanges.IsCompleted ? next : Task.WhenAll(worldChanges,next); }
    async Task ChangeWorld(bool suspend,bool refreshing)
    {
        try { if (worldView is SignedView view) { if (suspend) await view.Suspend(refreshing); else await view.Reopen(refreshing); } }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!disposed && !closing) { WithdrawWorld(error.Message); Notify(); } }
    }
    void WithdrawWorld(string reason,bool refreshing=false)
    { projection=null; controls?.Withdraw();xr.InvalidateWorld();if(refreshing)scene.Suspend();else scene.Withdraw();worldAccepted=false; status.Text="Space unavailable: " + reason; UpdateButtons(); }
    bool GuiOpen=>pie.IsOpen || representations?.IsVisibleInTree()==true || backupDialog!=null || (localControllers?.IsVisibleInTree()??false) || questions?.Expanded==true;
    void UpdateWorkspace()
    {
        workspaceContent.Visible=!gui.Spatial || xr.WorkspaceVisible;
        // In VR the strip lives on its own body-locked surface.
        var strip=gui.Spatial ? (Node)xr.HudSurface : gui.Surface;
        if(hud.GetParent()!=strip){hud.GetParent()?.RemoveChild(hud);strip.AddChild(hud);}
        bool ready=accounts?.Setup!=null&&session is {IsExpired:false};
        loginView.Visible=showConnection || accounts?.Setup==null || accounts.Uncertain || session?.IsExpired==true;
        loginBackdrop.BgColor=loginBackdrop.BgColor with {A=ready ? .94f : 1};
        loginStatus.Text=status.Text;loginStatus.Visible=status.Text.Length>0;
        location.Visible=controllers.Visible=loginView.Visible;
        accountSetup.Visible=accounts!=null;
        // Status is one plain sentence in the HUD strip, never a permanent panel.
        hud.Visible=ready&&!loginView.Visible;hud.Status=status.Text;
        hud.Attention=System.Text.RegularExpressions.Regex.Match(questions?.Caption??"",@"\d+").Value;
        bool attention=ready&&questions?.Expanded==true;
        bool form=!attention&&!home&&ready&&representations!=null;
        bool subjectOnly=gui.Spatial&&form;
        bool preview=form&&representations!.Preview.Visible;
        bool previewNear=subjectOnly&&representations!.NearOccurrence&&ReferenceEquals(representations.Occurrence?.Owner,representations.Preview);
        loginView.Visible&=!subjectOnly;
        attentionPanel.Visible=attention;
        place.Visible=ready&&!subjectOnly;
        placeTitle.Text=!navigationAvailable ? "Verifying where you are…" : navigation?.Space==null ? "You are nowhere yet"
            : projection?.Name is {Length:>0} placeName ? placeName : "Unnamed space";
        placeTitle.TooltipText=navigationAvailable ? navigation?.Location.ToString()??"" : "";
        if(!scene.Viewport.UseXR)scene.Visible=worldAccepted;
        subjectPanel.Visible=subjectHost.Visible=form&&!previewNear;
        visualHost.Visible=preview&&(!gui.Spatial||previewNear||representations!.Selected?.Operation!=true);
        localPanel.Visible=!subjectOnly&&body.GetChildren().OfType<Control>().Any(c=>c.Visible);
        if(representations!=null){representations.Visible=form&&workspaceContent.Visible;representations.Preview.CustomMinimumSize=new(0,260);}
        Layout();
        xr.PresentForm(form&&!previewNear&&(!preview||representations!.Selected?.Operation==true));
        xr.BindOccurrence(form&&representations!.NearOccurrence ? representations.Occurrence : null);
    }
    // Floating glass panels: the subject panel docks to the side farther from
    // its target; the attention list and local tools open on the left.
    void Layout()
    {
        var size=workspaceShell.Size;const float edge=16,strip=72,corner=48;
        place.Position=new(edge+4,edge);
        float width=Math.Min(size.X-2*edge,Math.Clamp(size.X*.42f,420,760));
        subjectPanel.Position=new(dockLeft ? edge : size.X-width-edge,edge);
        subjectPanel.Size=new(width,Math.Max(1,size.Y-edge-strip));
        foreach(var panel in new[]{attentionPanel,localPanel}) {
            panel.Position=new(edge,edge+corner);
            panel.Size=new(Math.Min(size.X-2*edge,Math.Clamp(size.X*.34f,360,560)),Math.Max(1,size.Y-edge-corner-strip));
        }
    }
    void OverlayChanging() { gui.Cancel();xr.Router.Cancel();scene.ReleaseInput();if(gui.Spatial&&!xr.WorkspaceVisible)xr.ShowWorkspace(); }
    void ShowHome(){questions?.Close();OverlayChanging();home=true;UpdateWorkspace();}
    void ShowInspector(){questions?.Close();OverlayChanging();home=false;UpdateWorkspace();}
    void SelectSubject(Term exact)
    {if(accounts?.Human==null||session==null||operations?.IsWorking==true)return;var panel=EnsureRepresentations();panel.Open(session,accounts,store!,exact);panel.PlacePersonal();ShowInspector();}
    public override void _Process(double delta) { xr.ContextChanged();scene.NavigationBlocked=GuiOpen || xr.Running;controls?.Tick(delta); }
    Task OpenGui()
    {
        OverlayChanging();
        RequireSession(); if (accounts!.Human == null) throw new InvalidOperationException("No human account reference.");
        SelectSubject(accounts.Human.Entity);return Task.CompletedTask;
    }
    Task OpenStorage()
    {
        OverlayChanging();
        RequireSession();
        if (accounts!.Setup == null) throw new InvalidOperationException("Complete account setup first.");
        EnsureRepresentations().OpenStorage(session!,accounts,store!,navigationAvailable ? navigation?.Space : null);ShowInspector();return Task.CompletedTask;
    }
    Task OpenTools()
    {
        OverlayChanging();
        RequireSession(); if (accounts!.Human == null) throw new InvalidOperationException("No account.");
        SelectSubject(accounts.Human.Ontology);return Task.CompletedTask;
    }
    EidolonPanel EnsureRepresentations()
    {
        if(representations!=null)return representations;
        representations=new() { Name="representations",CurrentLocation=()=>navigationAvailable ? navigation?.Space : null,
            SubjectLabel=exact=>navigationAvailable&&navigation?.Space?.Entity.ToString()==exact.ToString() ? projection?.Name : scene.SubjectLabel(exact) };
        visualHost.AddChild(representations.Preview);gui.SetForm(representations);
        gui.PreviewFormHit=point=>representations?.NearOccurrence==true&&gui.Spatial&&ReferenceEquals(representations.Occurrence?.Owner,representations.Preview) ? representations.Preview.FormHit(point) : null;
        operations=representations.Operations;operations.ClassChosen+=subject=>OpenSubjectPie(subject);representations.Changed+=Notify;representations.HiddenByUser+=ShowHome;return representations;
    }
    void SettingsChanged()
    { if (session != null) Disconnect(); }
    Task ForgetNodeKey()
    {
        if (store == null) throw new InvalidOperationException("Local identity storage is unavailable.");
        string origin = Transport.NodeOrigin(endpoint.Text);
        Disconnect(); store.Update(s => s.NodeKeys.Remove(origin));
        status.Text = "Forgot the key remembered for " + origin + ". The next connection trusts the key that node presents.";
        return Task.CompletedTask;
    }
    void CloseSession(bool retainDrafts=true)
    {
        bool returnHome=home;
        incarnation++;
        ClosePie();
        xr?.Install(null);xr?.StopSession();gui?.Cancel();
        RetireWorld(); navigation=null; navigationAvailable=false;
        var completions = views.Select(v => v.Completion ?? Task.CompletedTask).ToList();
        if(xr!=null)completions.Add(xr.Completion);
        completions.Add(retiredWorld);
        completions.Add(retiredPie);
        completions.Add(worldChanges);
        if(controls!=null) { controls.Dispose(); completions.Add(controls.Completion); controls=null; }
        if (questions != null) completions.Add(questions.Completion);
        if (representations != null) {
            if(retainDrafts)representations.Disconnect();else representations.DisposeView();
            completions.Add(representations.Completion);
        }
        questions?.Dispose(); questions = null;
        foreach (var view in views) view.Dispose(); views.Clear();
        if(!retainDrafts){if(representations!=null){visualHost.RemoveChild(representations.Preview);representations.Preview.QueueFree();gui.RemoveForm(representations);representations.QueueFree();}operations=null;representations=null;}
        foreach (var node in body.GetChildren()) {
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
        home=returnHome;
    }
    public void Disconnect()
    {
        action?.Cancel(); CloseSession(); state = "offline"; status.Text = "Disconnected. Your key and unsent work stay on this device."; UpdateButtons(); Notify();
    }
    public override void _UnhandledKeyInput(InputEvent @event)
    {
        if (@event is InputEventKey { Pressed:true, Echo:false, Keycode:Key.F9 } && accounts?.Human!=null && xr.Available && !xr.Running) {
            xr.Start();GetViewport().SetInputAsHandled();Notify();return;
        }
        // The Menu key opens the pointed target's pie where it is, or the space's at the centre.
        if (@event is InputEventKey { Pressed:true, Echo:false, Keycode:Key.Menu } && !pie.IsOpen) {
            if(OpenPie(hovered,hovered==null ? null : hoverPoint))GetViewport().SetInputAsHandled();return;
        }
        if (@event is InputEventKey { Pressed: true, Keycode: Key.Escape } && pie.IsOpen) { ClosePie();GetViewport().SetInputAsHandled();return; }
        if (@event is InputEventKey { Pressed: true, Keycode: Key.Escape }) {
            if (representations?.Visible == true) { representations.Cancel();ShowHome(); } else action?.Cancel();
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
        UpdateOnboarding();
        UpdateWorkspace();
    }
    void UpdateOnboarding()
    {
        bool signed=session is {IsExpired:false} && accounts!=null, ready=signed&&accounts!.Setup!=null;
        bool uncertain=signed&&accounts!.Uncertain;
        string? next=store==null ? null : key==null ? "create-key" : !signed ? "connect" : uncertain ? "resolve" :
            accounts!.CanRegister ? "register" : accounts.Human!=null&&accounts.Setup==null ? (accounts.Prepared==null ? "prepare" : "setup") : null;
        connectionTitle.Text=key==null ? "Welcome to Quod" : !signed ? "Welcome back" : uncertain ? "Check your earlier action" :
            accounts!.CanRegister ? "Create your account" : accounts.Human==null ? "Account unavailable" : !ready ? "Set up your starting space" : "Your account";
        connectionHelp.Text=store==null ? "Local identity storage is unavailable. Your files have not been replaced." : key==null ?
            "Your key stays on this device." : !signed ?
            "Sign in with the key saved on this device." : uncertain ?
            "An earlier action has no confirmed outcome. Check it; do not submit it again." : accounts!.CanRegister ?
            "This key has no account on this network yet." : accounts.Human==null ?
            "No account was recovered for this imported key. A new registration cannot replace it." : !ready ?
            accounts.Prepared==null ? "See where your starting space will be saved. Nothing is created yet." :
            "This creates your agent (you, in Quod) and your empty starting space." :
            "You are signed in.";
        endpointLabel.Visible=endpoint.Visible=store!=null && !signed;
        buttons["close-account"].Visible=ready;
        buttons["connect"].Text=state=="sign-in-expired" || session?.IsExpired==true ? "Sign in again" : "Sign in";
        foreach(string name in new[]{"create-key","import-backup","connect","disconnect","register","prepare","setup","resolve"}) {
            var button=buttons[name];button.ThemeTypeVariation=name==next ? "PrimaryAction" : "";
            button.Visible=name switch {"create-key" or "import-backup"=>key==null,"connect"=>key!=null&&!signed,
                "disconnect"=>session!=null||busy,"resolve"=>uncertain, _=>name==next};
        }
        SpatialGui.SetEditable(endpoint,!busy);
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
        dialog.TreeExited += () => {
            if (ReferenceEquals(backupDialog, dialog)) backupDialog = null;
            if (!export && key!=null && session==null && !closing && !disposed) activeAction=Run(Connect);
        };
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
        ShowHome();
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
