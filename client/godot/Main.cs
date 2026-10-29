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
    ScenePanel scene = null!;
    public Task ViewsDisposed { get; private set; } = Task.CompletedTask;
    QuestionHub? questions;
    readonly Dictionary<string, Button> buttons = [];
    public override void _Ready()
    {
        GetTree().AutoAcceptQuit = false;
        var margin = new MarginContainer { OffsetLeft = 28, OffsetTop = 22, AnchorRight = 1, AnchorBottom = 1, OffsetRight = -28, OffsetBottom = -22 };
        AddChild(margin);
        var scroll = new ScrollContainer { FollowFocus = true }; margin.AddChild(scroll);
        var root = new VBoxContainer { SizeFlagsHorizontal = SizeFlags.ExpandFill }; scroll.AddChild(root);
        root.AddChild(new Label { Text = "Quod", ThemeTypeVariation = "HeaderLarge" }); root.AddChild(identityLabel);
        var keys = Row(root); Add(keys, "create-key", "Create my key", CreateKey); Add(keys, "import-backup", "Import encrypted backup", () => { BackupDialog(false); return Task.CompletedTask; });
        Add(keys, "export-backup", "Export encrypted backup", () => { BackupDialog(true); return Task.CompletedTask; });
        var address = Row(root); address.AddChild(endpoint); address.AddChild(ca);
        Add(address, "connect", "Connect", Connect); Add(address, "disconnect", "Disconnect", () => { Disconnect(); return Task.CompletedTask; });
        root.AddChild(status); root.AddChild(location); root.AddChild(controllers);
        scene = new() { Name = "space-scene" }; root.AddChild(scene);
        scene.Drive += (direction,_) => controls?.Drive(direction.X,direction.Y,direction.Z);
        scene.Selected += exact => {
            if (accounts?.Human == null || session == null) return;
            if (operations == null) { operations = new() { Name = "operations" }; body.AddChild(operations); operations.Changed += Notify; }
            operations.OpenSubject(session, accounts, Actor.FromTerm(exact), exact);
        };
        var actions = Row(root);
        Add(actions, "register", "Register fresh human", Register);
        Add(actions, "prepare", "Describe account setup storage", Prepare);
        Add(actions, "setup", "Complete account setup", Setup);
        Add(actions, "resolve", "Check original outcomes", Resolve);
        Add(actions, "open-gui", "Account operations", OpenGui);
        Add(actions, "create-operations", "Create / operations", OpenStorage);
        Add(actions, "location-operations", "Current space operations", OpenLocation);
        Add(actions, "inspect", "Source / inspection", OpenTools);
        root.AddChild(body);
        endpoint.TextChanged += _ => SettingsChanged(); ca.TextChanged += _ => SettingsChanged();
        try {
            string profile = Argument("--profile") ?? ProjectSettings.GlobalizePath("user://identity");
            store = new LocalStore(profile);
            if (store.Snapshot is LocalState saved) {
                key = Identity.FromPayload(saved.Payload); endpoint.Text = saved.Endpoint; ca.Text = saved.CaFile;
                status.Text = "Saved active identity restored from private local storage. Connect explicitly.";
            } else status.Text = "Create or import a key offline, then connect. Active keys use private files; encrypted backups have a separate passphrase.";
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
    static HBoxContainer Row(Godot.Container parent) { var row = new HBoxContainer(); parent.AddChild(row); return row; }
    void Add(Godot.Container row, string name, string text, Func<Task> operation)
    {
        var button = new Button { Name = name, Text = text }; buttons.Add(name, button); row.AddChild(button);
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
        status.Text = "Identity saved durably. The active key is protected by private filesystem permissions. Export an encrypted backup separately."; return Task.CompletedTask;
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
        try {
            await connecting.Authenticate(Cancellation);
            if (disposed || expected != incarnation) return;
            var discovered = new Accounts(connecting, store); await discovered.Discover(Cancellation);
            if (disposed || expected != incarnation) return;
            accounts = discovered;
        } catch { if (ReferenceEquals(session, connecting)) CloseSession(); throw; }
        state = accounts.Human == null ? "signed-in-no-account" : accounts.Setup == null ? "setup-pending" : "account-ready";
        status.Text = accounts.Uncertain ? "Original work is unresolved. Check its original outcome." : "Authenticated. Network: " + connecting.Network;
        if (accounts.Setup != null) await PresentAccount();
    }
    async Task Register()
    {
        RequireSession(); long expected = incarnation; await accounts!.Register(Cancellation);
        if (disposed || expected != incarnation) return;
        state = accounts.Human == null ? "signup-uncertain" : "setup-pending";
        status.Text = accounts.Human == null ? "Signup outcome is unknown; check the original operation." : "The human account exists. Describe its policy-selected initial storage before completing setup.";
    }
    async Task Prepare()
    {
        RequireSession(); long expected = incarnation; await accounts!.Prepare(Cancellation);
        if (disposed || expected != incarnation) return;
        status.Text = accounts.StorageDescription.Length == 0 ? "Original account setup is complete." : accounts.StorageDescription;
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
            var value = Term.Parse(Quod.Client.Json.S(message, "value")); value.Ground(); var args = value.Require("controller_view", 3);
            controllers.Text = "Available local input: keyboard, mouse. Controller mapping revision " + args[0] + ". " +
                (args[2].Name == "invalid_settings" ? "Stored settings are invalid; use the offered repair operation." : "Hardware tracking and XR qualification remain separate."); Notify();
        };
        preferences.Withdrawn += reason => { controllers.Text = "Controller mapping unavailable: " + reason; Notify(); };
        _ = preferences.Start();
        questions?.Dispose(); questions = new(consumer, accounts, store!, body, Notify); questions.Start();
        await OpenGui();
    }
    void RetireWorld()
    {
        worldIncarnation++;
        var completion = worldView?.Completion ?? Task.CompletedTask; worldView?.Dispose(); worldView=null;
        retiredWorld = retiredWorld.IsCompleted ? completion : Task.WhenAll(retiredWorld,completion);
        projection=null; controls?.Withdraw(); worldAccepted=false; scene?.Withdraw();
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
                var next = new WorldProjection(message,view.Target,human); scene.Apply(next); projection=next; worldAccepted=true;
                controls?.Present(next);
                status.Text="Current committed space. Click a subject for its offered operations; focus the scene for WASD/QE and right-drag viewing.";
                if (next.Sample != null) _ = view.Send(next.Acknowledgement());
            } catch (Exception error) { WithdrawWorld(error.Message); }
            UpdateButtons(); Notify();
        };
        view.Message += message => {
            if (expected != worldIncarnation || Json.S(message,"type") != "simulation_frame" || projection == null) return;
            try { if (projection.Advance(message)) { scene.ApplyFrame(); controls?.Present(projection); _ = view.Send(projection.Acknowledgement()); Notify(); } }
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
    { projection=null; controls?.Withdraw(); scene.Withdraw(); worldAccepted=false; status.Text="Space unavailable: " + reason; UpdateButtons(); }
    public override void _Process(double delta) => controls?.Tick(delta);
    Task OpenGui()
    {
        RequireSession(); if (accounts!.Human == null) throw new InvalidOperationException("No human account reference.");
        if (operations != null) { operations.Show(); operations.Open(session!, accounts); return Task.CompletedTask; }
        operations = new() { Name = "operations" }; body.AddChild(operations); operations.Changed += Notify;
        operations.Open(session!, accounts); return Task.CompletedTask;
    }
    Task OpenStorage()
    {
        RequireSession();
        if (accounts!.Setup == null) throw new InvalidOperationException("Complete account setup first.");
        if (operations == null) { operations = new() { Name = "operations" }; body.AddChild(operations); operations.Changed += Notify; }
        operations.OpenStorage(session!, accounts,navigationAvailable ? navigation?.Space : null); return Task.CompletedTask;
    }
    Task OpenLocation()
    {
        RequireSession(); var space = navigationAvailable ? navigation?.Space : null;
        if (space==null) throw new InvalidOperationException("Current location is unavailable or unplaced.");
        if (operations == null) { operations=new() { Name="operations" }; body.AddChild(operations); operations.Changed+=Notify; }
        operations.OpenSubject(session!,accounts!,space,space.Entity); return Task.CompletedTask;
    }
    Task OpenTools()
    {
        RequireSession(); if (accounts!.Human == null) throw new InvalidOperationException("No account.");
        var tools = new SourcePanel { Name = "source-tools" }; body.AddChild(tools); tools.Open(session!, accounts); return Task.CompletedTask;
    }
    void SettingsChanged()
    { if (session != null) Disconnect(); }
    void CloseSession()
    {
        incarnation++;
        RetireWorld(); navigation=null; navigationAvailable=false;
        var completions = views.Select(v => v.Completion ?? Task.CompletedTask).ToList();
        completions.Add(retiredWorld);
        completions.Add(worldChanges);
        if(controls!=null) { controls.Dispose(); completions.Add(controls.Completion); controls=null; }
        if (questions != null) completions.Add(questions.Completion);
        if (operations != null) completions.Add(operations.Completion);
        questions?.Dispose(); questions = null;
        foreach (var view in views) view.Dispose(); views.Clear();
        operations?.DisposeView(); operations = null;
        foreach (var node in body.GetChildren()) {
            if (node is SourcePanel source) { source.DisposeView(); completions.Add(source.Completion); }
            body.RemoveChild(node); node.QueueFree();
        }
        var closing = session; session = null;
        async Task Finish() {
            try { await Task.WhenAll(completions); }
            finally { closing?.Dispose(); }
        }
        ViewsDisposed = ViewsDisposed.IsCompleted ? Finish() : Task.WhenAll(ViewsDisposed, Finish());
        accounts = null; worldAccepted = false; location.Text = controllers.Text = "";
        scene?.Withdraw();
    }
    public void Disconnect()
    {
        action?.Cancel(); CloseSession(); state = "offline"; status.Text = "Disconnected. Saved identity and original signed work remain local."; UpdateButtons(); Notify();
    }
    public override void _UnhandledKeyInput(InputEvent @event)
    {
        if (@event is InputEventKey { Pressed: true, Keycode: Key.Escape }) {
            if (operations?.Visible == true) operations.Cancel(); else action?.Cancel();
            GetViewport().SetInputAsHandled(); Notify();
        }
    }
    public override void _Notification(int what)
    {
        if (what == NotificationWMCloseRequest) _ = CloseApplication();
        if (what == NotificationApplicationFocusOut) GetViewport()?.GuiReleaseFocus();
        if (what == NotificationApplicationFocusOut) scene?.ReleaseInput();
    }
    void UpdateButtons()
    {
        identityLabel.Text = key == null ? "No unlocked identity" : "Public identity: " + key.PublicText;
        if (buttons.Count == 0) return;
        foreach (var button in buttons.Values) button.Disabled = busy;
        buttons["disconnect"].Disabled = session == null && !busy;
        buttons["create-key"].Disabled |= key != null || store == null;
        buttons["import-backup"].Disabled |= key != null || store == null;
        buttons["export-backup"].Disabled |= key == null;
        buttons["connect"].Disabled |= key == null || session != null;
        buttons["register"].Disabled |= accounts == null || !accounts.CanRegister;
        buttons["prepare"].Disabled |= accounts?.Human == null || accounts.Uncertain;
        buttons["setup"].Disabled |= accounts?.Prepared == null || accounts.Uncertain;
        buttons["resolve"].Disabled |= accounts == null;
        buttons["open-gui"].Disabled |= accounts?.Setup == null;
        buttons["create-operations"].Disabled |= accounts?.Setup == null;
        buttons["location-operations"].Disabled |= accounts?.Setup == null || !navigationAvailable || navigation?.Space == null || !worldAccepted;
        buttons["inspect"].Disabled |= accounts?.Human == null;
    }
    void Notify() { if (!disposed && IsInsideTree()) EmitSignal(SignalName.Changed); }
    public string Inspect() => JsonSerializer.Serialize(new { state, busy, public_key = key?.PublicText,
        network = session?.Network, human = accounts?.Human, setup = accounts?.Setup?.ToString(),
        pending = store?.Snapshot?.Pending.Count, world_accepted = worldAccepted, live_sockets = SignedView.LiveSockets, ignored_projections = SignedView.IgnoredProjections, question_receiver_ready = questions?.Ready,
        current_location = navigationAvailable ? navigation?.Location.ToString() : null, assignment_revision = navigationAvailable ? navigation?.Revision.ToString() : null,
        physical_selection = projection?.Selection, physical_tick = projection?.Sample?.Tick, scene_count = scene?.Count,
        operation_available = operations?.Available, operation_status = operations?.StatusText, status = status.Text });
    internal LocalStore ActiveStore => store ?? throw new InvalidOperationException("No active store.");
    internal SignedSession ActiveSession => session ?? throw new InvalidOperationException("No active session.");
    internal Accounts ActiveAccounts => accounts ?? throw new InvalidOperationException("No active account.");
    void BackupDialog(bool export)
    {
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
    internal async Task CloseApplication()
    {
        if (closing) return; closing = true; action?.Cancel(); backupCancellation?.Cancel(); backupDialog?.QueueFree(); CloseSession();
        await Task.WhenAll(ViewsDisposed, activeAction, backupWork);
        disposed = true; ReleaseIdentity(); GetTree().Quit();
    }
    public override void _ExitTree()
    {
        disposed = true; action?.Cancel(); backupCancellation?.Cancel(); CloseSession();
        // On an external engine quit, keep the writer lease until cancelled
        // work finishes or the process closes it. Never release it under I/O.
        if (ViewsDisposed.IsCompleted && activeAction.IsCompleted && backupWork.IsCompleted) ReleaseIdentity();
    }
}
