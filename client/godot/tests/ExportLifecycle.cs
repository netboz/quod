using Godot;
using Quod.Client;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json = Quod.Client.Json;
using File = System.IO.File;

public partial class ExportChecks
{
    async Task CloseDuringConnect()
    {
        ((Button)app.FindChild("create-key",true,false)).EmitSignal(BaseButton.SignalName.Pressed);
        await Until(()=>Busy);
        Check(app.ActiveStore.Snapshot!.Pending.Count==0,"closing a pending sign-in has no durable domain submission");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new { armed=true,checks }));
        // The driver delivers this real window close only after its TLS peer
        // observes the actual challenge request. It never supplies a reply.
        Console.WriteLine("M4_PENDING_CONNECT");
        Console.WriteLine("M2_NATIVE_CLOSE "+JsonSerializer.Serialize(new { title=GetWindow().Title }));Console.Out.Flush();
    }
    async Task Tls()
    {
        bool expected = Env("M1B_TLS_EXPECT") == "accept";
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        using var transport = new Transport(Env("M1B_TLS_URL"), Env("M1B_TLS_PIN"));
        bool http = false, websocket = false;
        try { http = (await transport.Send("/", null, timeout.Token))["tls"]?.ToString() == "ok"; }
        catch (HttpRequestException) when (!expected) { }
        using var socket = transport.Socket();
        try { await socket.ConnectAsync(transport.SocketUri, timeout.Token); websocket = true; }
        catch (System.Net.WebSockets.WebSocketException) when (!expected) { }
        bool remembered = !expected || transport.NodeKey == Env("M1B_TLS_KEY");
        Check(http == expected && websocket == expected && remembered,
            "actual exported HTTPS and WSS accept only the first or remembered node key: " + Env("M1B_TLS_CASE"));
        Console.WriteLine("M1B_TLS_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }
    async Task Mouse(OperationsPanel operations, Offer offered)
    {
        string role = offered.Form.Tree.Leaves.First(c => c.Family == "boolean").Role;
        var control = operations.FormPanel.Input(role) as CheckButton ?? throw new Exception("Boolean pointer adapter");
        if (control.Size.Y <= 0) await ToSignal(control, Control.SignalName.Resized);
        bool before = control.ButtonPressed;
        if (DisplayServer.GetName() != "headless") await NativePress(control);
        else {
            for (Node? node = control.GetParent(); node != null; node = node.GetParent())
                if (node is ScrollContainer scroll) scroll.EnsureControlVisible(control);
            await Frame();
            var toggled = new TaskCompletionSource(); void Changed(bool _) => toggled.TrySetResult();
            control.Toggled += Changed;
            try {
                var position = control.GetGlobalRect().GetCenter(); var viewport = control.GetViewport();
                viewport.PushInput(new InputEventMouseMotion { Position = position, GlobalPosition = position }, true);
                viewport.PushInput(new InputEventMouseButton { Position = position, GlobalPosition = position, ButtonIndex = MouseButton.Left, Pressed = true }, true);
                viewport.PushInput(new InputEventMouseButton { Position = position, GlobalPosition = position, ButtonIndex = MouseButton.Left, Pressed = false }, true);
                await toggled.Task.WaitAsync(TimeSpan.FromSeconds(5));
            } finally { control.Toggled -= Changed; }
        }
        Check(control.ButtonPressed != before && operations.FormPanel.Draft[role] == (!before ? "true" : "false"), "native mouse click edits offered boolean");
    }
    async Task Transition(JsonObject command)
    {
        using var socket = new TcpClient(); await socket.ConnectAsync("127.0.0.1", int.Parse(Env("M1B_CONTROL_PORT")));
        using var stream = socket.GetStream();
        await stream.WriteAsync(Encoding.UTF8.GetBytes(command.ToJsonString() + "\n"));
        using var input = new StreamReader(stream); var reply = JsonNode.Parse((await input.ReadLineAsync())!)!;
        Check(reply.ToJsonString() == command.ToJsonString(), "actual permission-owner transition completed");
    }
    async Task<JsonNode> ExecuteComplete(SignedSession session, LocalStore store, Actor human, string goal, CancellationToken cancellation)
    {
        var reply = await session.Execute(human, goal, "qualification", cancellation);
        if (!Json.Terminal(reply)) {
            var work = store.Snapshot!.Pending.Single();
            using var socket = new TcpClient(); await socket.ConnectAsync("127.0.0.1", int.Parse(Env("M1B_CONTROL_PORT")), cancellation);
            using var stream = socket.GetStream();
            await stream.WriteAsync(Encoding.UTF8.GetBytes(new JsonObject { ["request"] = work.Request }.ToJsonString() + "\n"), cancellation);
            using var input = new StreamReader(stream); var settled = JsonNode.Parse((await input.ReadLineAsync(cancellation))!)!;
            Check(settled["terminal"]?.ToString() == "true", "original authored operation owner completed");
            reply = await session.Resolve(work, cancellation);
            if (Json.Terminal(reply)) session.Forget(work.Id);
        }
        Console.WriteLine("AUTHORED_OUTCOME " + reply.ToJsonString()); Console.Out.Flush(); return reply;
    }
    async Task CompletedAccountRecovery(JsonObject original)
    {
        var saved = app.ActiveStore.Snapshot!;
        using var key = Identity.FromPayload(saved.Payload);
        using var store = new LocalStore(profile + "-completed-account-recovery"); store.Create(saved.Payload);
        using var session = new SignedSession(key, store, new Transport(saved.Endpoint, saved.NodeKey(saved.Endpoint)));
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5)); await session.Authenticate(timeout.Token);
        var human = JsonSerializer.Deserialize<Actor>(original["human"]!.ToJsonString())!;
        using var socket = new TcpClient(); await socket.ConnectAsync("127.0.0.1", int.Parse(Env("M1B_CONTROL_PORT")), timeout.Token);
        using var stream = socket.GetStream();
        await stream.WriteAsync(Encoding.UTF8.GetBytes(new JsonObject { ["vector_target"] = new JsonObject { ["namespace"] = human.Namespace, ["anchor"] = human.Anchor } }.ToJsonString() + "\n"), timeout.Token);
        using var input = new StreamReader(stream); var target = JsonNode.Parse((await input.ReadLineAsync(timeout.Token))!)!;
        string Vector(string tag) => "independent((assertz(m1b_vector_mark(" + tag + "))," + Term.Text(Json.S(target,"namespace")) + "::(current_ontology_identity(" + Term.Text(Json.S(target,"namespace")) + "," + Term.Binary(Identity.Decode(Json.S(target,"anchor"))) + "),m1b_vector_write(" + tag + "))))";
        var accounts = new Accounts(session, store);
        foreach (string flow in new[] { "signup", "setup" }) {
            string binding = flow == "signup" ? ",Account=" + Term.Call("agent_instance_ref", human.Entity.Args) : ",<<\"quod:user\">>::account_setup_state(Setup)";
            await session.Execute(human, Vector(flow) + binding + ".", flow, timeout.Token);
            var work = store.Snapshot!.Pending.Single();
            using var owner = new TcpClient(); await owner.ConnectAsync("127.0.0.1", int.Parse(Env("M1B_CONTROL_PORT")), timeout.Token);
            using var channel = owner.GetStream(); await channel.WriteAsync(Encoding.UTF8.GetBytes(new JsonObject { ["request"] = work.Request }.ToJsonString() + "\n"), timeout.Token);
            using var fence = new StreamReader(channel); Check(JsonNode.Parse((await fence.ReadLineAsync(timeout.Token))!)!["terminal"]!.GetValue<bool>(), "real independent account-binding operation completes");
            var outcome = await session.Resolve(work, timeout.Token);
            Console.WriteLine("COMPLETED_ACCOUNT_OUTCOME " + outcome.ToJsonString()); Console.Out.Flush();
            Check(outcome["result"]?.ToString() == "operation_outcome" && outcome["status"]?.ToString() == "completed" && outcome["aggregate"]?.ToString() == "all_applied", "real original-outcome seam returns completed all_applied for " + flow);
            await accounts.Resolve(timeout.Token);
            Check(accounts.Human == human && !store.Snapshot!.Pending.Any(), "completed recovery installs exact original reference and consumes signed work for " + flow);
        }
        Check(accounts.Setup!.ToString() == original["setup"]!.ToString(), "completed recovery retains original distinct U A S0 keys and pins");
    }
    async Task Sources(JsonObject original)
    {
        var saved = app.ActiveStore.Snapshot!;
        using var key = Identity.FromPayload(saved.Payload);
        using var store = new LocalStore(profile + "-source-observer"); store.Create(saved.Payload);
        var human = JsonSerializer.Deserialize<Actor>(original["human"]!.ToJsonString())!;
        store.Update(s => s.Accounts[Env("M1B_NETWORK")] = new(human, original["setup"]!.ToString()));
        using var session = new SignedSession(key, store, new Transport(saved.Endpoint, saved.NodeKey(saved.Endpoint)));
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        await session.Authenticate(timeout.Token);
        var accounts = new Accounts(session, store); await accounts.Discover(timeout.Token);
        var panel=new EidolonPanel();app.AddChild(panel.Preview);app.AddChild(panel);panel.Changed+=()=>app.EmitSignal(Main.SignalName.Changed);
        var target=accounts.Catalogue.Single(x=>x.Namespace=="quod:gui");
        async Task Inspect(Actor chosen){panel.Open(session,accounts,store,chosen.Ontology);await Until(()=>panel.Available);panel.Choose(panel.Offered.Single(e=>e.Purpose.Name=="prolog"));}
        await Inspect(target);var source=(SourcePanel)panel.FindChild("source-tools",true,false);
        await Until(()=>source.Content.Length>0);
        Check(source.Content.Contains("gui_"),"real exported source tools assemble complete authorized cursor");
        string content=source.Content;
        var traffic=await session.Transport.Send("/qualification/traffic",null,timeout.Token);
        await Renew(panel,"representation");
        var renewedTraffic=await session.Transport.Send("/qualification/traffic",null,timeout.Token);
        Check(source.Content==content && traffic["cursor_opens"]!.ToString()==renewedTraffic["cursor_opens"]!.ToString(),"unchanged real authorization renewal retains complete snapshot with zero new source cursors");
        await Transition(new(){["source_access"]="deny"});await Until(()=>source.Content.Length==0);
        Check(!source.CanEdit,"revoked source grant withdraws exported content and edit authority");
        await Transition(new(){["source_access"]="restore"});await Inspect(target);await Until(()=>source.Content.Length>0);
        Check(source.Content==content,"explicit reopen restores exact authorized source");
        await Inspect(human);await Until(()=>source.Content.Length>0 && source.Content!=content);
        var beforeUpdate=await session.Transport.Send("/qualification/traffic",null,timeout.Token);
        Check(Json.Committed(await ExecuteComplete(session,store,human,"assertz(m1b_source_changed(1)).",timeout.Token)),"source update commits through its actual owner");
        await Until(()=>source.Content.Contains("m1b_source_changed(1)"));
        var afterUpdate=await session.Transport.Send("/qualification/traffic",null,timeout.Token);
        Check(Json.U(afterUpdate,"cursor_opens")==Json.U(beforeUpdate,"cursor_opens")+1,"real source update invalidates and reads exactly one replacement cursor");
        panel.Open(session,accounts,store,(target with {Anchor=Identity.Encode(new byte[32])}).Ontology);
        await Until(()=>panel.StatusText.StartsWith("Unavailable"));
        Check(source.Content.Length==0,"denied source never becomes a valid empty snapshot");
        panel.Open(session,accounts,store,target.Ontology);panel.DisposeView();await panel.Completion;
        Check(source.Content.Length==0,"cancelled opening reader cannot publish after disposal");panel.QueueFree();
    }

    static async Task Renew(Node consumer,string fieldName="view")
    {
        // Exercise the existing signed renewal path without waiting for its
        // protocol timer. No projection or authority is fabricated here.
        var field = consumer.GetType().GetField(fieldName, System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!;
        var view = (SignedView)field.GetValue(consumer)!;
        var projected = new TaskCompletionSource(); void Project(JsonNode _) => projected.TrySetResult();
        view.Projection += Project;
        try {
            await view.Renew();
            await projected.Task.WaitAsync(TimeSpan.FromSeconds(10));
        } finally { view.Projection -= Project; }
    }
    void DisabledAncestor()
    {
        var form = Form.Decode(Term.Parse("component(f,form,[property(label,f)],[component(g,group,[property(label,g),property(enabled,false)],[component(t,text_box,[property(label,t),property(enabled,true)],[])]),component(save,button,[property(label,save)],[])])"), Term.Parse("[field(t,<<\"Original\">>)]"), Term.Atom("save"));
        var panel = new FormPanel(); app.AddChild(panel); panel.Present(form); panel.Lock(true); panel.Lock(false); panel.Edit("t", "Forbidden edit");
        Check(!((LineEdit)panel.Input("t")!).Editable && panel.Draft["t"] == "Original", "native unlock and edit preserve disabled ancestor state");
        panel.QueueFree();
    }
    async Task Questions(JsonObject original)
    {
        await Until(() => State["question_receiver_ready"]?.GetValue<bool>() == true);
        var saved = app.ActiveStore.Snapshot!;
        using var key = Identity.FromPayload(saved.Payload);
        using var store = new LocalStore(profile + "-question-author"); store.Create(saved.Payload);
        using var session = new SignedSession(key, store, new Transport(saved.Endpoint, saved.NodeKey(saved.Endpoint)));
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5)); await session.Authenticate(timeout.Token);
        var human = JsonSerializer.Deserialize<Actor>(original["human"]!.ToJsonString())!;
        var setup = Term.Parse(original["setup"]!.ToString()).Require("account", 6);
        var actor = Actor.FromTerm(setup[1]);
        string source = Term.Call("form_ref", Term.Text(human.Namespace), Term.Binary(Identity.Decode(human.Anchor)), Term.Atom("m1b_question")).ToString();
        // Computed control declarations follow the production controller form;
        // they do not request construction of fixed-named material instances.
        string[] declarations = [
            "instance_of(quod:gui:form,m1b_question):-instance_of(quod:user:human_user,me)", "instance_of(quod:gui:group,m1b_group):-instance_of(quod:user:human_user,me)",
            "instance_of(quod:gui:text_box,m1b_answer):-instance_of(quod:user:human_user,me)", "instance_of(quod:gui:button,m1b_apply):-instance_of(quod:user:human_user,me)",
            "instance_of(quod:gui:checkbox,m1b_confirm):-instance_of(quod:user:human_user,me)", "instance_of(quod:gui:selectable_list,m1b_choices):-instance_of(quod:user:human_user,me)",
            "attribute(m1b_confirm,label,<<\"Confirm\">>)", "attribute(m1b_confirm,required,true)",
            "attribute(m1b_choices,label,<<\"Choices\">>)", "attribute(m1b_choices,required,true)", "attribute(m1b_choices,multiple,true)", "attribute(m1b_choices,options,[option(a,<<\"A\">>),option(b,<<\"B\">>)])",
            "gui_children(m1b_question,[m1b_group,m1b_apply])", "gui_children(m1b_group,[m1b_answer,m1b_confirm,m1b_choices])",
            "attribute(m1b_question,label,<<\"Deferred production question\">>)", "attribute(m1b_group,label,<<\"Nested fields\">>)",
            "attribute(m1b_answer,label,<<\"Answer\">>)", "attribute(m1b_answer,required,true)", "attribute(m1b_answer,max_bytes,32)",
            "attribute(m1b_apply,label,<<\"Submit answer\">>)", "gui_initial(m1b_question,m1b_answer,<<\"Original typed default\">>)",
            "gui_form(m1b_question,[field(m1b_answer,Answer),field(m1b_confirm,Confirm),field(m1b_choices,Choices)],submit(m1b_apply,assertz(m1b_received(Answer,Confirm,Choices))))",
            $"gui_question_policy(m1b_question,{setup[0]},{setup[1]})",
            $"gui_responder_policy(personal,{source},{setup[0]})",
            "gui_pending_allowance(personal,4)", "gui_completion_allowance(personal,300000)"
        ];
        var installed = await ExecuteComplete(session, store, human, "transaction((" + string.Join(",", declarations.Select(d => "assertz((" + d + "))")) + ")).", timeout.Token);
        Check(Json.Committed(installed), "authored deferred form uses existing account ontology");
        for (int occurrence = 0; occurrence < 2; occurrence++) {
            var opened = await ExecuteComplete(session, store, human, $"<<\"quod:gui\">>::gui_open({source},Reference).", timeout.Token);
            Check(Json.Committed(opened), "genuine deferred opening commits with actual HUD preparation");
            QuestionPanel? panel = null;
            await Until(() => { panel = FindQuestion(app); return panel?.Available == true; });
            Check(panel!.FormPanel.Descriptor.Tree.Children.Any(c => c.Kind == "group"), "nested deferred descriptor rendered from source");
            Check(panel.FormPanel.Draft["m1b_answer"] == "Original typed default", "deferred typed default preserved");
            Check(panel.FormPanel.Draft["m1b_confirm"] == "false" && panel.FormPanel.Draft["m1b_choices"] == "[]" && !panel.FormPanel.Validate(), "real offered required false and empty defaults render and show validation");
            var pendingBefore = Json.Binding(await session.Read(human, "<<\"quod:gui\">>::gui_pending_questions(Questions).", timeout.Token), "Questions");
            Check(pendingBefore.Items.Length == 1, "real question remains deferred before user input");
            if (occurrence == 0) {
                ((CheckButton)panel.FormPanel.Input("m1b_confirm")!).ButtonPressed = true;
                var choices = (ItemList)panel.FormPanel.Input("m1b_choices")!; choices.Select(1); choices.EmitSignal(ItemList.SignalName.MultiSelected, 1, true);
                Check(panel.FormPanel.Validate(), "native edits satisfy actual required boolean and selection binder");
                var button = panel.FormPanel.Input("m1b_apply") as Button ?? throw new Exception("Deferred submit control");
                button.EmitSignal(BaseButton.SignalName.Pressed);
            } else (panel.FindChild("cancel-question", true, false) as Button)!.EmitSignal(BaseButton.SignalName.Pressed);
            await Until(() => FindQuestion(app) == null);
            var pendingAfter = Json.Binding(await session.Read(human, "<<\"quod:gui\">>::gui_pending_questions(Questions).", timeout.Token), "Questions");
            Check(pendingAfter.Items.Length == 0, occurrence == 0 ? "submitted deferred question completes through existing A reaction" : "cancelled deferred question removes original HUD reference");
            if (State["pending"]!.GetValue<int>() > 0) {
                var work = app.ActiveStore.Snapshot!.Pending.Single();
                using var socket = new TcpClient(); await socket.ConnectAsync("127.0.0.1", int.Parse(Env("M1B_CONTROL_PORT")), timeout.Token);
                using var stream = socket.GetStream();
                await stream.WriteAsync(Encoding.UTF8.GetBytes(new JsonObject { ["request"] = work.Request }.ToJsonString() + "\n"), timeout.Token);
                using var input = new StreamReader(stream); var settled = JsonNode.Parse((await input.ReadLineAsync(timeout.Token))!)!;
                Check(settled["terminal"]?.ToString() == "true", "original question action reached its existing completion owner");
                await Press("resolve");
            }
            Check(State["pending"]!.GetValue<int>() == 0, "terminal deferred action leaves no uncertain local work");
        }
        var result = await session.Read(human, "findall(answer(Value,Confirm,Choices),m1b_received(Value,Confirm,Choices),Values).", timeout.Token);
        Check(Json.Binding(result, "Values").ToString() == "[answer(<<\"Original typed default\">>,true,[b])]", "question continuation executes exactly once with edited required fields in responsible ontology");
        string unsupportedSource = Term.Call("form_ref", Term.Text(human.Namespace), Term.Binary(Identity.Decode(human.Anchor)), Term.Atom("m1b_image_question")).ToString();
        string[] unsupported = ["instance_of(quod:gui:form,m1b_image_question):-instance_of(quod:user:human_user,me)", "instance_of(quod:gui:image,m1b_image):-instance_of(quod:user:human_user,me)",
            "attribute(m1b_image_question,label,<<\"Unsupported descriptor test\">>)", "attribute(m1b_image,label,<<\"Image\">>)",
            "attribute(m1b_image,image,image(asset(<<\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\">>,<<\"image/jpeg\">>),resources(1,1)))",
            "gui_children(m1b_image_question,[m1b_image,m1b_apply])", "gui_form(m1b_image_question,[],submit(m1b_apply,true))",
            $"gui_question_policy(m1b_image_question,{setup[0]},{setup[1]})", $"gui_responder_policy(personal,{unsupportedSource},{setup[0]})"];
        Check(Json.Committed(await ExecuteComplete(session, store, human, "transaction((" + string.Join(",", unsupported.Select(d => "assertz((" + d + "))")) + ")).", timeout.Token)), "authored unsupported descriptor installed in private test account");
        var refused = await ExecuteComplete(session, store, human, $"<<\"quod:gui\">>::gui_open({unsupportedSource},Reference).", timeout.Token);
        Check(refused["result"]?.ToString() == "fail" && app.FindChildren("*", "Label", true, false).OfType<Label>().Any(label => label.Text.Contains("Unsupported GUI component: image")), "unsupported genuine question visibly refuses preparation without an empty form");
        Check(Json.Binding(await session.Read(human, "<<\"quod:gui\">>::gui_pending_questions(Questions).", timeout.Token), "Questions").Items.Length == 0, "refused unsupported preparation leaves no committed empty question");
        Check(Json.Committed(await ExecuteComplete(session, store, human, $"<<\"quod:gui\">>::gui_open({source},Reference).", timeout.Token)), "uncertain-submission case opens genuine deferred question");
        QuestionPanel? uncertainPanel = null; await Until(() => { uncertainPanel = FindQuestion(app); return uncertainPanel?.Available == true; });
        ((CheckButton)uncertainPanel!.FormPanel.Input("m1b_confirm")!).ButtonPressed = true;
        var selection = (ItemList)uncertainPanel.FormPanel.Input("m1b_choices")!; selection.Select(0); selection.EmitSignal(ItemList.SignalName.MultiSelected, 0, true);
        await app.ActiveSession.Transport.Send("/qualification/arm-question-error", new(), timeout.Token);
        ((Button)uncertainPanel.FormPanel.Input("m1b_apply")!).EmitSignal(BaseButton.SignalName.Pressed);
        await ((Task)typeof(QuestionPanel).GetField("working", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(uncertainPanel)!).WaitAsync(TimeSpan.FromSeconds(10));
        Check(app.ActiveStore.Snapshot!.Pending.Any(w => w.Flow == "question") && !uncertainPanel.Available, "unknown HTTP failure retains original signed question and locks awaiting view");
        var before = await app.ActiveSession.Transport.Send("/qualification/traffic", null, timeout.Token);
        await Renew(uncertainPanel);
        ((Button)uncertainPanel.FormPanel.Input("m1b_apply")!).EmitSignal(BaseButton.SignalName.Pressed);
        ((Button)uncertainPanel.FindChild("cancel-question", true, false)).EmitSignal(BaseButton.SignalName.Pressed);
        var after = await app.ActiveSession.Transport.Send("/qualification/traffic", null, timeout.Token);
        Check(before["questions"]!.ToString() == after["questions"]!.ToString() && !uncertainPanel.Available, "real awaiting renewal cannot resubmit or cancel uncertain original work");
        var pendingQuestion = Json.Binding(await session.Read(human, "<<\"quod:gui\">>::gui_pending_questions(Questions).", timeout.Token), "Questions").Items.Single();
        var reopened = new QuestionPanel(); app.AddChild(reopened); app.AddChild(reopened.Choice);
        var owningAccounts = (Accounts)typeof(QuestionPanel).GetField("accounts", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(uncertainPanel)!;
        reopened.Open(app.ActiveSession, owningAccounts, pendingQuestion, () => app.EmitSignal(Main.SignalName.Changed));
        var streamView = (SignedView)typeof(QuestionPanel).GetField("view", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(reopened)!;
        var projected = new TaskCompletionSource(); streamView.Projection += _ => projected.TrySetResult();
        await projected.Task.WaitAsync(TimeSpan.FromSeconds(10));
        ((Button)reopened.FormPanel.Input("m1b_apply")!).EmitSignal(BaseButton.SignalName.Pressed);
        ((Button)reopened.FindChild("cancel-question", true, false)).EmitSignal(BaseButton.SignalName.Pressed);
        var reopenTraffic = await app.ActiveSession.Transport.Send("/qualification/traffic", null, timeout.Token);
        Check(!reopened.Available && before["questions"]!.ToString() == reopenTraffic["questions"]!.ToString(), "reopened genuine question retains original journal barrier without another dispatch");
        reopened.DisposeView(); await reopened.Completion; reopened.Choice.QueueFree(); reopened.QueueFree();
        var originalWork = app.ActiveStore.Snapshot!.Pending.Single(w => w.Flow == "question");
        var unknown = await app.ActiveSession.Resolve(originalWork, timeout.Token);
        Check(!Json.Terminal(unknown) && app.ActiveStore.Snapshot!.Pending.Any(w => w.Id == originalWork.Id), "original question absence remains uncertain after portable lookup");
    }
    // The question the hub still lists as pending. A retired one stays on
    // screen with its last-known outcome until Later, but is no longer pending.
    static QuestionPanel? FindQuestion(Node root)
    {
        foreach (var child in root.GetChildren()) {
            if (child is QuestionPanel { Discovered: true } panel && !panel.IsQueuedForDeletion()) return panel;
            if (FindQuestion(child) is QuestionPanel found) return found;
        }
        return null;
    }
    async Task BackupWidget(bool export, string file, string passphrase, bool expectSuccess)
    {
        await Press(export ? "export-backup" : "import-backup");
        var dialog = app.FindChild("backup-dialog", true, false) as Control ?? throw new Exception("Backup dialog");
        var path = (LineEdit)dialog.FindChild("backup-path", true, false); path.Text = file;
        var phrase = (LineEdit)dialog.FindChild("backup-passphrase", true, false); phrase.Text = passphrase;
        var apply = (Button)dialog.FindChild("backup-apply", true, false);
        await NativePress(apply); await Until(() => !apply.Disabled);
        string result = ((Label)dialog.FindChild("backup-result", true, false)).Text;
        Console.WriteLine("BACKUP_STATUS " + result); Console.Out.Flush();
        Check(expectSuccess == (result is "Encrypted backup saved." or "Original key and account references restored."), expectSuccess ? "actual encrypted-backup widget succeeded" : "actual encrypted-backup widget refused invalid input");
        var removed = new TaskCompletionSource(); dialog.TreeExited += () => removed.TrySetResult();
        await NativePress((Button)dialog.FindChild("backup-close",true,false));
        await removed.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }
    async Task LocalQualification(string phase)
    {
        if (phase.StartsWith("crash-")) {
            var store = app.ActiveStore;
            string original = Env("M1B_CRASH_ORIGINAL");
            if (phase == "crash-recover") {
                var before = JsonSerializer.Deserialize<LocalState>(await File.ReadAllTextAsync(original))!;
                var after = store.Snapshot!;
                Check(after.Payload == before.Payload && JsonSerializer.Serialize(after.Accounts) == JsonSerializer.Serialize(before.Accounts) && JsonSerializer.Serialize(after.Pending) == JsonSerializer.Serialize(before.Pending), "SIGKILL recovery retains exact original key accounts pins and signed outbox");
                Check(after.Endpoint == Env("M1B_EXPECT_ENDPOINT"), "SIGKILL recovers atomic old or new store at selected boundary");
                await app.CloseApplication(); return;
            }
            await File.WriteAllTextAsync(original, JsonSerializer.Serialize(store.Snapshot));
            string boundary = phase[6..];
            store.DurabilityBoundary = point => {
                if (point != boundary) return;
                Console.WriteLine("M1B_CRASH_SEAM " + point); Console.Out.Flush();
                // Deliberate test crash seam inside the real active-store owner.
                new TaskCompletionSource().Task.GetAwaiter().GetResult();
            };
            store.Update(s => s.Endpoint = "https://atomic-boundary.example:14570");
            throw new Exception("External SIGKILL did not occur");
        }
        var corpus = JsonNode.Parse(await File.ReadAllTextAsync(Env("M1B_CORPUS")))!;
        string phrase = Json.S(corpus, "passphrase");
        string browserBackup = Env("M1B_BROWSER_BACKUP");
        if (phase == "backup-cancel") {
            await File.WriteAllTextAsync(browserBackup, Json.S(corpus, "bundle"));
            await Press("import-backup");
            var dialog = (Control)app.FindChild("backup-dialog", true, false);
            ((LineEdit)dialog.FindChild("backup-path", true, false)).Text = browserBackup;
            ((LineEdit)dialog.FindChild("backup-passphrase", true, false)).Text = phrase;
            var apply = (Button)dialog.FindChild("backup-apply", true, false); await NativePress(apply);
            Check(apply.Disabled, "backup processing started through actual UI");
            await app.CloseApplication();
            using var reopened = new LocalStore(profile);
            Check(reopened.Snapshot == null && !File.Exists(Path.Combine(profile, "active.json")), "close cancels opening import before installation and awaits writer-lease handoff");
            Console.WriteLine("M1B_LOCAL_PASS"); Console.Out.Flush(); return;
        }
        if (phase == "backup-import") {
            await BackupWidget(false, Env("M1B_ACCOUNT_BACKUP"), "wrong passphrase", false);
            Check(State["public_key"] == null, "failed import leaves empty active profile intact");
            await BackupWidget(false, Env("M1B_ACCOUNT_BACKUP"), phrase, true);
            if (Busy) await Until(() => !Busy);
            if (State["network"] == null) await Press("connect");
            await Until(() => State["world_accepted"]!.GetValue<bool>() && State["operation_available"]?.GetValue<bool>() == true);
            var expected = JsonNode.Parse(await File.ReadAllTextAsync(Env("M1B_ORIGINAL")))!;
            Check(State["public_key"]!.ToString() == expected["public_key"]!.ToString() && State["human"]!.ToJsonString() == expected["human"]!.ToJsonString() && State["setup"]!.ToString() == expected["setup"]!.ToString(), "encrypted account backup restores same U A S0 key pins and original results");
            if(System.Environment.GetEnvironmentVariable("M3_ROUTE") is string routePath) {
                var route=JsonNode.Parse(await File.ReadAllTextAsync(routePath))!;var space=Term.Parse(Json.S(route,"s1"));
                Check(State["current_location"]?.ToString()==Term.Call("placed",space,Term.Parse("transform(0,0,0,0,0,0)")).ToString(),"fresh-device native encrypted backup reopens committed S1 instead of original setup S0");
                Check(app.ActiveStore.Snapshot!.Pending.Count==0 && app.ActiveAccounts.Outcomes.Any(o=>o["bindings"]?.AsArray().Any(b=>b?["Results"]!=null)==true),"fresh installed device recovers original results from server associations without an originating journal");
            }
        } else {
            await File.WriteAllTextAsync(browserBackup, Json.S(corpus, "bundle"));
            await BackupWidget(false, browserBackup, "wrong passphrase", false);
            Check(State["public_key"] == null, "wrong phrase cannot create replacement identity");
            var tampered = JsonNode.Parse(Json.S(corpus, "bundle"))!;
            var bytes = Identity.Decode(Json.S(tampered, "ciphertext")); bytes[0] ^= 1; tampered["ciphertext"] = Identity.Encode(bytes);
            string damaged = browserBackup + "-damaged"; await File.WriteAllTextAsync(damaged, tampered.ToJsonString());
            await BackupWidget(false, damaged, phrase, false);
            Check(State["public_key"] == null, "GCM tamper cannot install an active identity");
            await BackupWidget(false, browserBackup, phrase, true);
            Check(State["public_key"]!.ToString() == Json.S(corpus, "public_key"), "actual export imports exact browser public identity");
            using var key = Identity.FromPayload(app.ActiveStore.Snapshot!.Payload);
            foreach (var row in corpus["requests"]!.AsArray()) {
                var account = row!["account"]!;
                byte[] encoded = Wire.Encode(Identity.Decode(Json.S(account, "network")), key.PublicKey, Identity.Decode(Json.S(row, "operation")),
                    new(Json.S(account, "namespace"), Json.S(account, "anchor"), Json.S(account, "instanceText")), 0, Json.U(row, "deadline"), Json.S(row, "goal"));
                Check(Identity.Encode(encoded) == Json.S(row, "bytes") && Identity.Encode(key.Sign(encoded)) == Json.S(row, "signature"), "actual export exact integer binary codec and Ed25519 signature");
            }
            using var random1 = Identity.Create(); using var random2 = Identity.Create();
            Check(random1.PublicText != random2.PublicText, "actual export OS secure randomness produces distinct identities");
            int verified = 0;
            foreach (string file in new[] { "production-protocol-fixtures.json", "production-controller-reset-fixtures.json" }) {
                var fixture = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(Env("M1B_PROTOCOL_FIXTURES"), file)))!;
                foreach (var row in fixture["requests"]!.AsArray()) {
                    var request = Identity.Decode(Json.S(row, "request_bytes"));
                    var reconstructed = Wire.Encode(request.AsSpan(Encoding.UTF8.GetByteCount("quod.agent.goal.v1\0"), 32).ToArray(), Identity.Decode(Json.S(row, "public_key")), Identity.Decode(Json.S(row, "operation_id")),
                        new(Json.S(row, "namespace"), Json.S(row, "anchor"), Json.S(row, "actor")), Json.S(row, "mode") == "read" ? (byte)0 : (byte)1, Json.U(row, "not_after_ms"), Json.S(row, "goal"));
                    if (!request.SequenceEqual(reconstructed) || !Identity.Verify(Identity.Decode(Json.S(row, "public_key")), request, Identity.Decode(Json.S(row, "signature")))) throw new Exception("Production wire fixture mismatch");
                    verified++;
                }
            }
            Check(verified == 100, "actual export all 100 production request and signature fixtures including Reset");
            await BackupWidget(true, Env("M1B_EXPORTED_BACKUP"), phrase, true);
        }
        if (State["network"] != null) await Press("disconnect"); else app.Disconnect();
        await app.ViewsDisposed;
        await File.WriteAllTextAsync(Env("M1B_RESULT"), JsonSerializer.Serialize(new { passed = true, phase, checks }));
        Console.WriteLine("M1B_LOCAL_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }
}
