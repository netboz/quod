using Godot;
using Quod.Client;
using System.Text.Json.Nodes;
using Json = Quod.Client.Json;

public sealed class QuestionHub : IDisposable
{
    readonly SignedSession session;
    readonly Accounts accounts;
    readonly LocalStore store;
    readonly VBoxContainer host;
    readonly Action changed;
    readonly SignedView hud;
    readonly CancellationTokenSource lifetime = new();
    readonly Dictionary<string, QuestionPanel> panels = [];
    readonly Dictionary<string, (FormPanel Form, ulong Expires)> provisional = [];
    string? receiver, selected;
    bool disposed;
    Task selecting = Task.CompletedTask, receiving = Task.CompletedTask, retired = Task.CompletedTask;
    public bool Ready { get; private set; }
    public Task Completion => Task.WhenAll(new[] { hud.Completion ?? Task.CompletedTask, selecting, receiving, retired }.Concat(panels.Values.Select(p => p.Completion)));
    public QuestionHub(SignedSession session, Accounts accounts, LocalStore store, VBoxContainer host, Action changed)
    {
        this.session = session; this.accounts = accounts; this.store = store; this.host = host; this.changed = changed;
        var human = accounts.Human!;
        hud = new(session, human, human, "gui_hud", SignedSession.ViewGoal(human, Term.Call("gui_pending_questions", Term.Variable("View"))));
        hud.Projection += projection => {
            receiver = Json.S(projection["receiver"], "token");
            var references = Term.Parse(Json.S(projection, "value")); references.Ground(); var keep = new HashSet<string>();
            foreach (var q in references.Items) {
                q.Require("question_ref", 3); string id = q.ToString(); keep.Add(id);
                if (!panels.ContainsKey(id)) {
                    var panel = new QuestionPanel(); host.AddChild(panel); panels[id] = panel; panel.Open(session, accounts, q, changed);
                }
            }
            foreach (var id in panels.Keys.Except(keep).ToArray()) {
                var panel = panels[id]; panel.DisposeView(); retired = Task.WhenAll(retired, panel.Completion); panel.QueueFree(); panels.Remove(id);
            }
            if (selecting.IsCompleted) selecting = SelectReceiver(projection["receiver"]!); changed();
        };
        hud.Withdrawn += _ => { receiver = null; Ready = false; foreach (var p in panels.Values) p.Withdraw(); changed(); };
        hud.Message += message => { var handling = Receive(message); receiving = receiving.IsCompleted ? handling : Task.WhenAll(receiving, handling); };
    }
    public void Start() => _ = hud.Start();
    async Task SelectReceiver(JsonNode descriptor)
    {
        string token = Json.S(descriptor, "token"), node = Json.S(descriptor, "node");
        if (disposed) return;
        if (token == selected) { Ready = true; changed(); return; }
        try {
            if (store.Snapshot!.Pending.Any(w => w.Network == session.Network && w.Flow == "receiver")) return;
            var goal = Term.Call("gui_select_receiver", Term.Parse(accounts.Human!.InstanceText.TrimEnd('.')),
                Term.Binary(Identity.Decode(node)), Term.Binary(Identity.Decode(token)));
            var reply = await session.Execute(accounts.Human, SignedSession.ViewGoal(accounts.Human, goal), "receiver", lifetime.Token);
            if (!disposed && Json.Committed(reply)) { selected = token; Ready = receiver == token; changed(); }
        } catch (Exception) when (disposed || lifetime.IsCancellationRequested) { }
        catch (Exception error) { host.AddChild(new Label { Text = "Question receiver unavailable: " + error.Message }); changed(); }
    }
    async Task Receive(JsonNode message)
    {
        if (disposed) return;
        try {
            string type = Json.S(message, "type");
            if (type is not ("gui_prepare" or "gui_activate" or "gui_expired")) return;
            string token = Json.S(message, "token");
            if (Identity.Decode(token).Length != 32) throw new FormatException("Invalid presentation token.");
            if (type == "gui_expired") { Retire(token); return; }
            if (type == "gui_activate") {
                bool active = provisional.TryGetValue(token, out var value) && value.Expires > SignedSession.Now;
                if (!active) Retire(token);
                await hud.Send(new() { ["type"] = "gui_activated", ["token"] = token, ["status"] = active ? "active" : "expired" }); return;
            }
            bool accepted = false;
            try {
                ulong expiry = Json.U(message, "expires_ms");
                if (Json.S(message, "connection") != receiver || expiry <= SignedSession.Now) throw new FormatException("Stale receiver incarnation.");
                var form = QuestionDescriptor.Decode(Term.Parse(Json.S(message, "descriptor"))).Form;
                if (provisional.TryGetValue(token, out var previous)) accepted = previous.Expires > SignedSession.Now;
                else if ((ulong)provisional.Count < Json.U(message, "capacity")) {
                    var panel = new FormPanel { Visible = false }; host.AddChild(panel); panel.Present(form); panel.Lock(true);
                    provisional[token] = (panel, expiry); accepted = true; _ = Expire(token, expiry);
                }
            } catch (Exception error) { host.AddChild(new Label { Text = "Question presentation refused: " + error.Message }); changed(); }
            await hud.Send(new() { ["type"] = "gui_prepared", ["token"] = token, ["accepted"] = accepted });
        } catch (Exception error) { if (!disposed) { host.AddChild(new Label { Text = error.Message }); changed(); } }
    }
    async Task Expire(string token, ulong expiry)
    {
        try { ulong now = SignedSession.Now; await Task.Delay(TimeSpan.FromMilliseconds(expiry > now ? expiry - now : 0), lifetime.Token); if (!disposed) Retire(token); }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }
    void Retire(string token) { if (provisional.Remove(token, out var item)) { item.Form.Clear(); item.Form.QueueFree(); } }
    public void Dispose()
    {
        if (disposed) return; disposed = true; lifetime.Cancel(); hud.Dispose();
        foreach (var token in provisional.Keys.ToArray()) Retire(token);
        foreach (var panel in panels.Values) { panel.DisposeView(); retired = retired.IsCompleted ? panel.Completion : Task.WhenAll(retired, panel.Completion); panel.QueueFree(); } panels.Clear();
    }
}

public sealed record QuestionDescriptor(Form Form, Term Opened, Term Revision, string Interaction)
{
    public static QuestionDescriptor Decode(Term value)
    {
        value.Ground(); var a = value.Require("question_form", 5); var source = a[0].Require("form_ref", 3);
        _ = Actor.FromTerm(a[1]); var view = a[4].Require("form_view", 5);
        if (a[2].Kind != "binary" || a[2].Bytes.Length != 32 || view[0].Kind != "binary" || view[0].Bytes.Length != 32 ||
            view[2].Kind != "binary" || view[2].Bytes.Length != 32 || view[1].Require("component", 4)[0].ToString() != source[2].ToString())
            throw new FormatException("Invalid question identity.");
        string interaction = a[3].Kind == "atom" && a[3].Name == "awaiting" ? a[2].ToString() == view[0].ToString() ? "editable" : "stale" : "submitted";
        if (interaction == "submitted") a[3].Require("submitted", 3);
        return new(Form.Decode(view[1], view[3], view[4]), a[2], view[0], interaction);
    }
}

public partial class QuestionPanel : VBoxContainer
{
    readonly Label status = new() { AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly FormPanel panel = new();
    readonly CancellationTokenSource lifetime = new();
    SignedView? view;
    QuestionDescriptor? current;
    bool busy, disposed, available, settled;
    Accounts accounts = null!;
    long generation;
    Task working = Task.CompletedTask;
    bool Locked => busy || settled || accounts.Uncertain;
    public bool Available => available && !Locked && current?.Interaction == "editable";
    public FormPanel FormPanel => panel;
    public Task Completion => Task.WhenAll(working, view?.Completion ?? Task.CompletedTask);
    public void Open(SignedSession session, Accounts accounts, Term reference, Action changed)
    {
        this.accounts = accounts; var human = accounts.Human!;
        var a = reference.Require("question_ref", 3); var target = new Actor(a[0].TextValue, Identity.Encode(a[1].Bytes), human.InstanceText);
        AddChild(status); AddChild(panel);
        var cancel = new Button { Name = "cancel-question", Text = "Cancel this deferred question" }; AddChild(cancel);
        view = new(session, human, target, "gui_question", SignedSession.ViewGoal(target, Term.Call("gui_question_form", a[2], Term.Variable("View"))));
        view.Projection += message => {
            generation++;
            var next = QuestionDescriptor.Decode(Term.Parse(Json.S(message, "value")));
            if (current == null || next.Interaction == "submitted") panel.Present(next.Form);
            current = next; available = true; panel.Show(); panel.Lock(Locked || next.Interaction != "editable");
            status.Text = "Deferred question: " + next.Interaction + "."; changed();
        };
        view.Withdrawn += reason => { Withdraw(); status.Text = reason; changed(); };
        async Task Write(bool answer) {
            if (disposed || Locked || !available || current == null || current.Interaction == "submitted" || (answer && (current.Interaction != "editable" || !panel.Validate()))) return;
            long expected = generation; busy = settled = true; panel.Lock(true);
            try {
                Term goal = answer ? Term.Call("gui_submit", a[2], current.Opened, current.Form.Submit, current.Form.Fields(panel.Draft)) : Term.Call("gui_cancel", a[2]);
                var reply = await session.Execute(human, SignedSession.ViewGoal(target, goal), "question", lifetime.Token);
                if (reply["result"]?.ToString() == "fail" || (Json.Terminal(reply) &&
                    (reply["status"]?.ToString() is "rejected" or "aborted" || reply["aggregate"]?.ToString() == "all_rejected"))) settled = false;
                if (!disposed && available && expected == generation) status.Text = reply.ToJsonString();
            } catch (Exception error) {
                if (error is ApiError { Definite: true }) settled = false;
                if (!disposed && available && expected == generation) status.Text = error.Message + " Check any retained original operation.";
            }
            finally { busy = false; if (!disposed) { panel.Lock(Locked || !available || current?.Interaction != "editable"); changed(); } }
        }
        panel.Invoked += role => { if (!busy && current?.Form.Submit.ToString() == role) working = Write(true); };
        cancel.Pressed += () => { if (!busy) working = Write(false); }; _ = view.Start();
    }
    public void Withdraw() { generation++; available = false; status.Text = "Question unavailable."; panel.Hide(); panel.Lock(true); }
    public void DisposeView() { if (disposed) return; disposed = true; lifetime.Cancel(); view?.Dispose(); panel.Clear(); }
    public override void _ExitTree() => DisposeView();
}
