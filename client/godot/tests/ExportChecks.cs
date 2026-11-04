using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Security.Cryptography;
using Json = Quod.Client.Json;
using File = System.IO.File;
using Environment = System.Environment;

// Explicit qualification scene. Every interaction drives the exported main
// application or the same production signed client; no fake server answers.
public partial class ExportChecks : Node
{
    Main app = null!;
    readonly List<string> checks = [];
    string profile = "";
    string Env(string name) => Environment.GetEnvironmentVariable(name) ?? throw new Exception(name);
    JsonNode State => JsonNode.Parse(app.Inspect())!;
    bool Busy => State["busy"]!.GetValue<bool>();
    void Check(bool yes, string name) { if (!yes) throw new Exception(name + ": " + State["status"]?.ToString()); checks.Add(name); Console.WriteLine("PASS " + name); Console.Out.Flush(); }
    async Task Until(Func<bool> predicate)
    {
        long deadline = System.Diagnostics.Stopwatch.GetTimestamp() + 60 * System.Diagnostics.Stopwatch.Frequency;
        while (true) {
            var changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            void Changed() => changed.TrySetResult();
            app.Changed += Changed;
            try { if (predicate()) return;
                double seconds = (deadline - System.Diagnostics.Stopwatch.GetTimestamp()) / (double)System.Diagnostics.Stopwatch.Frequency;
                if (seconds <= 0) throw new TimeoutException("Absolute qualification deadline expired.");
                await changed.Task.WaitAsync(TimeSpan.FromSeconds(seconds)); }
            finally { app.Changed -= Changed; }
        }
    }
    async Task Frame() => await ToSignal(GetTree(), SceneTree.SignalName.ProcessFrame);
    async Task Press(string name)
    {
        var button = app.FindChild(name, true, false) as Button ?? throw new Exception("Missing button " + name);
        Check(!button.Disabled, "enabled action " + name);
        button.EmitSignal(BaseButton.SignalName.Pressed); await Until(() => !Busy);
    }
    public async void Begin(Main application)
    {
        try {
            var args = OS.GetCmdlineUserArgs(); profile = args[Array.IndexOf(args, "--profile") + 1];
            app = application;
            if(DisplayServer.GetName()=="headless")GetTree().Root.Size=new(1200,800);
            app.Changed += () => {
                var state = State.AsObject(); state.Remove("setup"); state.Remove("human"); state.Remove("public_key"); state.Remove("network");
                Console.WriteLine("M1B_STATE " + state.ToJsonString()); Console.Out.Flush();
                TraceOperationView();
            };
            await Frame();
            string phase = Env("M1B_PHASE");
            if (phase is "startup-new" or "startup-saved") { await Startup(phase); return; }
            if (phase == "menu") { await NativeMenu(); return; }
            if (phase == "scene") { await SceneAdapter(); return; }
            if (phase == "controller-input") { await ControllerAdapter(); return; }
            if (phase == "presentation") { await PresentationAdapter(); return; }
            if (phase is "workspace" or "workspace-render") { await WorkspaceAdapter(); return; }
            if (phase is "openxr" or "openxr-input") { await OpenXRRuntime(); return; }
            if (phase == "shutdown-connect") { await CloseDuringConnect(); return; }
            if (phase == "physics") { await PhysicsJourney(); return; }
            bool fresh = phase is "fresh" or "questions" or "m2-fresh" or "m3-fresh";
            if (phase == "tls") { await Tls(); return; }
            if (phase is "crypto" or "backup-import" or "backup-cancel" or "crash-before-rename" or "crash-after-rename" or "crash-recover") {
                await LocalQualification(phase); return;
            }
            if (fresh) {
                await Press("create-key"); Check(State["public_key"] != null, "offline durable identity created");
            } else Check(State["public_key"] != null, "saved active key restored without backup passphrase");
            if (Busy) await Until(() => !Busy);
            if (State["network"]?.ToString() != Env("M1B_NETWORK")) await Press("connect");
            Check(State["network"]?.ToString() == Env("M1B_NETWORK"), "real challenge and authenticated network");
            if (fresh) {
                await Press("register");
                if (State["human"] == null) { Check(State["pending"]!.GetValue<int>() > 0, "lost signup response retains original signed work"); await Press("resolve"); }
                Check(State["human"] != null, "original fresh human recovered");
                await Press("prepare"); Check(State["status"]!.ToString().Contains("existing account ontology"), "policy-selected existing S0 storage explained");
                await Press("setup");
                if (State["setup"] == null) { Check(State["pending"]!.GetValue<int>() > 0, "lost setup response retains original signed work"); await Press("resolve"); }
            }
            await Until(() => (State["world_accepted"]!.GetValue<bool>() || (phase=="m3-left" && State["current_location"]?.ToString()=="unplaced")) && State["operation_available"]?.GetValue<bool>() == true);
            var original = new JsonObject { ["public_key"] = State["public_key"]!.DeepClone(), ["human"] = State["human"]!.DeepClone(), ["setup"] = State["setup"]!.DeepClone() };
            string previousPath = Env("M1B_ORIGINAL");
            if (fresh) await File.WriteAllTextAsync(previousPath, original.ToJsonString());
            else Check(original.ToJsonString() == await File.ReadAllTextAsync(previousPath), "restart preserves exact U A S0 keys storage and pins");
            Check(State["world_accepted"]!.GetValue<bool>() || (phase=="m3-left" && State["scene_count"]!.GetValue<int>()==0), "current committed placed or explicitly unplaced location is presented");
            Check(((Button)app.FindChild("setup", true, false)).Disabled && ((Button)app.FindChild("register", true, false)).Disabled, "recovered complete account retires signup and consumed setup actions");
            var operations = app.FindChild("operations", true, false) as OperationsPanel ?? throw new Exception("Missing generic operations panel");
            if (phase.StartsWith("m3-")) { await SpaceNavigation(phase,original); return; }
            if (operations.Current == null) {
                var human = app.ActiveAccounts.Human!;
                Console.WriteLine("M2_EMPTY_OFFER_SCOPE " + ((Label)operations.FindChild("operation-scope",true,false)).Text);
                foreach (string goal in new[] { "controller_preferences_current(me,R,S),controller_preferences_basis(S,D,State).", $"gui_operations({human.Entity},View)." }) {
                    Console.WriteLine("M2_EMPTY_OFFER_READ " + goal);
                    Console.WriteLine((await app.ActiveSession.Read(human,goal,CancellationToken.None)).ToJsonString());
                }
            }
            var offered = operations.Current ?? throw new Exception("No offered operation");
            Check(offered.Name == "controller_settings", "actual offered controller-preference operation");
            Check(offered.Form.Tree.Leaves.Count(c => c.Input) > 2, "generic typed offered inputs rendered");
            if(phase=="m4-live") { await ControllerLive(operations);return; }
            if (phase.StartsWith("m2-")) { await SpaceCreation(phase, original); return; }
            if (phase == "closing") {
                await Press("inspect");
                await app.CloseApplication();
                Check(SignedView.LiveSockets == 0, "normal application close awaits opening consumer disposal");
                using var reopened = new LocalStore(profile);
                Check(reopened.Snapshot!.Payload == app.ActiveStore.Snapshot!.Payload, "normal close transfers writer lease only after original I/O finishes");
                Console.WriteLine("M1B_CLOSE_PASS"); Console.Out.Flush(); return;
            }
            if (phase is "tools" or "questions") {
                await Sources(original); await Questions(original);
                await Press("disconnect"); await app.ViewsDisposed;
                Check(SignedView.LiveSockets == 0, "source and deferred-question consumers dispose every socket");
                Console.WriteLine("M1B_TOOLS_PASS"); Console.Out.Flush(); await app.CloseApplication(); return;
            }
            if (phase == "input") {
                await Keyboard(operations, offered);
                operations.Defaults(); await Mouse(operations, offered);
                if (Environment.GetEnvironmentVariable("M1B_SCREENSHOT") is string screenshot) {
                    Check(DisplayServer.GetName() != "headless", "rendered capture uses actual desktop display");
                    await ToSignal(RenderingServer.Singleton, RenderingServer.SignalName.FramePostDraw);
                    Check(GetViewport().GetTexture().GetImage().SavePng(screenshot) == Error.Ok, "actual exported GUI rendered to evidence image");
                }
                Console.WriteLine("M1B_INPUT_PASS"); Console.Out.Flush(); await app.CloseApplication(); return;
            }
            if (phase is "fresh" or "reset") {
                if (phase == "fresh") {
                    await File.WriteAllTextAsync(Env("M1B_OLD_OFFER"), JsonSerializer.Serialize(new { revision = offered.Revision.ToString(), fields = offered.Form.Fields(offered.Form.Defaults).ToString() }));
                    await Keyboard(operations, offered);
                    operations.Defaults();
                    await Mouse(operations, offered);
                    var choice = offered.Form.Tree.Leaves.FirstOrDefault(c => c.Family == "choice");
                    if (choice != null && operations.FormPanel.Input(choice.Role) is OptionButton selection) {
                        int index = (selection.Selected + 1) % selection.ItemCount;
                        selection.Select(index); selection.EmitSignal(OptionButton.SignalName.ItemSelected, index);
                        Check(operations.FormPanel.Draft[choice.Role] == choice.Options[index].Value.ToString(), "offered selection edits exact typed value");
                    }
                    operations.Defaults();
                    // Cancellation is local and never dispatches an unsent form.
                    int pending = State["pending"]!.GetValue<int>(); operations.Cancel();
                    await Press("open-gui"); await Until(() => State["operation_available"]?.GetValue<bool>() == true);
                    Check(State["pending"]!.GetValue<int>() == pending, "unsent cancel/reopen does not dispatch");
                } else {
                    var reset = operations.FormPanel.Input("controller_reset") as CheckButton ?? throw new Exception("Offered Reset checkbox");
                    reset.ButtonPressed = true;
                    Check(operations.FormPanel.Draft["controller_reset"] == "true", "offered Reset selection uses the generic boolean control");
                }
                await operations.Submit();
                Check(State["pending"]!.GetValue<int>() > 0, "lost instruction response retains exact original U and A work");
                Console.WriteLine("M1B_KILL_READY " + phase); Console.Out.Flush();
                // The external harness SIGKILLs this process at the observed seam.
                await new TaskCompletionSource().Task;
            } else {
                Check(State["pending"]!.GetValue<int>() == 0, "restart resolves original Save and Reset without dispatch");
                await CompletedAccountRecovery(original);
                DisabledAncestor();
                await Sources(original);
                await Questions(original);
                await NegativeAndRecovery(original);
                Check(State["ignored_projections"]!.GetValue<long>() >= 3 && State["world_accepted"]!.GetValue<bool>(), "duplicate and late prior-incarnation projections cannot replace current view");
                var corpus = JsonNode.Parse(await File.ReadAllTextAsync(Env("M1B_CORPUS")))!;
                await BackupWidget(true, Env("M1B_ACCOUNT_BACKUP"), Json.S(corpus, "passphrase"), true);
                await Press("disconnect");
                // Disposal completion, not a timer, is the resource-release fence.
                await app.ViewsDisposed;
                Check(State["live_sockets"]!.GetValue<int>() == 0, "disposed view consumers release every socket");
                var report = new JsonObject { ["passed"] = true, ["phase"] = phase, ["checks"] = JsonSerializer.SerializeToNode(checks), ["original"] = original };
                await File.WriteAllTextAsync(Env("M1B_RESULT"), report.ToJsonString());
                Console.WriteLine("M1B_EXPORT_PASS"); Console.Out.Flush(); await app.CloseApplication();
            }
        } catch (Exception error) { Console.Error.WriteLine(error.ToString()); Console.Error.WriteLine(app.Inspect()); Console.Error.Flush(); await app.CloseApplication(1); }
    }
    async Task Startup(string phase)
    {
        var logo=app.FindChild("quod-logo",true,false) as TextureRect;
        Check(logo?.Texture?.ResourcePath=="res://assets/quod-logo.png", "opening screen uses packaged Quod logo");
        var mode=app.FindChild("presentation-mode",true,false) as Button;
        Check(mode is {Visible:false}, "VR entry hidden without initialized runtime");
        if (phase=="startup-new") {
            Check(State["public_key"]==null && !((Button)app.FindChild("create-key",true,false)).Disabled, "empty profile offers key creation");
            await Press("create-key");
            Check(State["public_key"]!=null && app.ActiveStore.Snapshot!=null, "new key saved before connection attempt");
            Check(State["status"]!.ToString()!="Key saved on this device.", "key creation continues into authentication");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new { key=State["public_key"]!.ToString(), checks }));
        } else {
            var original=JsonNode.Parse(await File.ReadAllTextAsync(Env("M1B_RESULT")))!;
            if(Busy) await Until(()=>!Busy);
            Check(State["public_key"]!.ToString()==original["key"]!.ToString(), "startup restores exact saved key");
            Check(State["status"]!.ToString()!="Signing in with your saved key…", "startup attempts authentication without a click");
            Check(!((Button)app.FindChild("connect",true,false)).Disabled && State["pending"]!.GetValue<int>()==0,
                "failed sign-in leaves retry and no signed domain work");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new { passed=true, key=State["public_key"]!.ToString(), checks }));
        }
        await app.CloseApplication();
    }

    readonly HashSet<SignedView> tracedOperationViews = [];
    void TraceOperationView()
    {
        // Qualification-only observation of the actual consumer. Do not open a
        // second view, alter authorization or repair an empty projection.
        var panel=app.FindChild("operations",true,false) as OperationsPanel;
        if(panel==null) return;
        var flags=System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic;
        var view=(SignedView?)typeof(OperationsPanel).GetField("view",flags)?.GetValue(panel);
        if(view==null || !tracedOperationViews.Add(view)) return;
        string Field(string name)=>typeof(SignedView).GetField(name,flags)!.GetValue(view)!.ToString()!;
        Console.WriteLine("M2_OPERATION_VIEW principal="+Field("human")+" target="+Field("target")+" goal="+Field("goal"));
        view.Projection+=message=>Console.WriteLine("M2_OPERATION_PROJECTION "+message.ToJsonString());
        view.Withdrawn+=reason=>Console.WriteLine("M2_OPERATION_WITHDRAWN "+reason);
    }
    async Task Keyboard(OperationsPanel operations, Offer offered)
    {
        string role = offered.Form.Tree.Leaves.First(c => c.Family == "number").Role;
        var line = operations.FormPanel.Input(role) as LineEdit ?? throw new Exception("Numeric keyboard adapter");
        line.GrabFocus(); await Frame(); Check(line.HasFocus(), "keyboard focus reaches offered control");
        Console.WriteLine($"INPUT_BEFORE text={line.Text} editable={line.Editable} visible={line.IsVisibleInTree()} focus={line.HasFocus()}"); Console.Out.Flush();
        var edited = new TaskCompletionSource<string>(); void Changed(string value) => edited.TrySetResult(value);
        line.TextChanged += Changed;
        try {
            line.SelectAll();
            GetViewport().PushInput(new InputEventKey { Keycode = Key.Backspace, PhysicalKeycode = Key.Backspace, Pressed = true }, true);
            GetViewport().PushInput(new InputEventKey { Keycode = Key.Backspace, PhysicalKeycode = Key.Backspace, Pressed = false }, true);
            await edited.Task.WaitAsync(TimeSpan.FromSeconds(5));
        } finally { line.TextChanged -= Changed; }
        Console.WriteLine($"INPUT_AFTER text={line.Text} draft={operations.FormPanel.Draft[role]}"); Console.Out.Flush();
        Check(operations.FormPanel.Draft[role] == "", "keyboard edit preserves invalid intermediate numeric draft");
        Check(!operations.FormPanel.Validate(), "invalid draft produces visible validation without dispatch");
    }
    async Task NegativeAndRecovery(JsonObject original)
    {
        // A second authorized device uses the original key/reference with an
        // empty journal. Test credentials remain only in owner-private fixtures.
        var saved = JsonSerializer.Deserialize<LocalState>(await File.ReadAllTextAsync(Path.Combine(profile, "active.json")))!;
        using var key = Identity.FromPayload(saved.Payload);
        string secondPath = profile + "-second-device";
        using var store = new LocalStore(secondPath); store.Create(saved.Payload);
        var human = JsonSerializer.Deserialize<Actor>(original["human"]!.ToJsonString())!;
        using var session = new SignedSession(key, store, new Transport(saved.Endpoint, saved.CaFile));
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        await session.Authenticate(timeout.Token);
        var instructions = Json.Binding(await session.Read(human, "personal_instructions(Instructions).", timeout.Token), "Instructions").Items;
        int expected=Environment.GetEnvironmentVariable("M4_REPAIR")=="1" ? 3 : 2;
        Check(instructions.Length == expected, "server retains exactly original Save and Reset associations plus any explicitly qualified repair");
        foreach (var row in instructions) Check(Json.Committed(await session.ResolveInstruction(human, Identity.Encode(row.Require("instruction", 3)[0].Bytes), timeout.Token)), "original result recovered without originating journal");
        using var stranger = Identity.Create();
        using var strangerStore = new LocalStore(profile + "-stranger"); strangerStore.Create(stranger.Payload());
        using var wrong = new SignedSession(stranger, strangerStore, new Transport(saved.Endpoint, saved.CaFile)); await wrong.Authenticate(timeout.Token);
        bool denied = false;
        try { denied = (await wrong.Read(human, "account_setup_state(State).", timeout.Token))["result"]?.ToString() == "fail"; }
        catch (ApiError) { denied = true; }
        Check(denied, "wrong identity refuses private account data");
        denied = false;
        try { denied = (await session.Read(human with { Anchor = Identity.Encode(new byte[32]) }, "account_setup_state(State).", timeout.Token))["result"]?.ToString() == "fail"; }
        catch (ApiError) { denied = true; }
        Check(denied, "wrong history anchor refuses");
        var offers = Offer.Decode(Json.Binding(await session.Read(human, Term.Call("gui_operations", human.Entity, Term.Variable("Offers")) + ".", timeout.Token), "Offers").ToString(), human.Entity);
        var form = offers.Single(); var personal = await session.Read(human, "personal_agent(Agent,Key).", timeout.Token);
        var agent = Actor.FromTerm(Json.Binding(personal, "Agent")); var publicKey = Json.Binding(personal, "Key").Bytes;
        async Task Refuses(string goal, string label) {
            var reply = await session.Personal(human, agent, publicKey, human, goal, timeout.Token);
            Check(reply["result"]?.ToString() == "fail" || (reply["terminal"]?.ToString() == "true" && !Json.Committed(reply)), label);
        }
        var fields = form.Form.Fields(form.Form.Defaults);
        denied = false;
        try {
            var response = await wrong.Execute(human, form.Goal(form.Form.Defaults), "qualification", timeout.Token);
            denied = response["result"]?.ToString() == "fail";
        } catch (ApiError error) { denied = error.Status is 401 or 403; }
        Check(denied, "wrong signing identity cannot execute the offered operation");
        Check(!strangerStore.Snapshot!.Pending.Any(), "definitive installed pre-submission refusal clears unsent original work");
        await Refuses(Term.Call("gui_operation", human.Entity, Term.Atom("not_offered"), form.Revision, form.Form.Submit, fields, Term.Variable("Results")) + ".", "denied operation explicit production outcome");
        var number = form.Form.Tree.Leaves.First(c => c.Family == "number");
        Term Replace(Term value) => Term.List(fields.Items.Select(row => row.Args[0].ToString() == number.Role ? Term.Call("field", row.Args[0], value) : row).ToArray());
        string Goal(Term values, Term revision) => Term.Call("gui_operation", human.Entity, Term.Atom(form.Name), revision, form.Form.Submit, values, Term.Variable("Results")) + ".";
        await Refuses(Goal(Replace(Term.Text("invalid type")), form.Revision), "invalid type refused by production offered binder");
        await Refuses(Goal(Replace(Term.Number((number.Range.Max + number.Range.Step).ToString())), form.Revision), "invalid range refused by production offered binder");
        var oldOffer = JsonNode.Parse(await File.ReadAllTextAsync(Env("M1B_OLD_OFFER")))!;
        var oldRevision = Term.Parse(oldOffer["revision"]!.ToString());
        Check(oldRevision.ToString() != form.Revision.ToString(), "actual prior offered revision changed after Save and Reset");
        await Refuses(Goal(Term.Parse(oldOffer["fields"]!.ToString()), oldRevision), "stale prior offered revision refused by production binder");
    }
}
