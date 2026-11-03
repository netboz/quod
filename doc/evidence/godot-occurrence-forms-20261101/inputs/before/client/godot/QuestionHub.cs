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
    readonly ScrollContainer attention = new() { Name="attention-list",HorizontalScrollMode=ScrollContainer.ScrollMode.Disabled,SizeFlagsVertical=Control.SizeFlags.ExpandFill };
    readonly VBoxContainer choices = new() {SizeFlagsHorizontal=Control.SizeFlags.ExpandFill};
    readonly Label notice = new() {AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly Action presentationChanging;
    string? receiver, selected;
    bool disposed;
    Task selecting = Task.CompletedTask, receiving = Task.CompletedTask, retired = Task.CompletedTask;
    public bool Ready { get; private set; }
    public bool Showing => host.Visible;
    public string Caption => "Your attention · "+panels.Count;
    public Task Completion => Task.WhenAll(new[] { hud.Completion ?? Task.CompletedTask, selecting, receiving, retired }.Concat(panels.Values.Select(p => p.Completion)));
    public QuestionHub(SignedSession session, Accounts accounts, LocalStore store, VBoxContainer host, Action changed, Action presentationChanging)
    {
        this.session = session; this.accounts = accounts; this.store = store; this.host = host; this.changed = changed;
        this.presentationChanging=presentationChanging;
        host.Hide();host.AddChild(attention);attention.AddChild(choices);choices.AddChild(notice);
        var later=SpatialGui.ActionButton("Hide attention","hide-attention");choices.AddChild(later);later.Pressed+=Hide;
        var human = accounts.Human!;
        hud = new(session, human, human, "gui_hud", SignedSession.ViewGoal(human, Term.Call("gui_pending_questions", Term.Variable("View"))));
        hud.Projection += projection => {
            receiver = Json.S(projection["receiver"], "token");
            var references = Term.Parse(Json.S(projection, "value")); references.Ground(); var keep = new HashSet<string>();
            foreach (var q in references.Items) {
                q.Require("question_ref", 3); string id = q.ToString(); keep.Add(id);
                if (!panels.ContainsKey(id)) {
                    var panel = new QuestionPanel {Visible=false,SizeFlagsVertical=Control.SizeFlags.ExpandFill};host.AddChild(panel);panels[id]=panel;
                    choices.AddChild(panel.Choice);panel.Choice.TooltipText=id;
                    panel.Choice.Pressed+=()=>{if(!disposed&&panels.GetValueOrDefault(id)==panel)Present(panel);};
                    panel.HiddenByUser+=()=>{ShowAttention();panel.Choice.GrabFocus();};
                    panel.Open(session,accounts,q,changed);
                }
            }
            foreach (var id in panels.Keys.Except(keep).ToArray()) {
                var panel = panels[id];bool active=panel.Visible;panel.DisposeView();retired=Task.WhenAll(retired,panel.Completion);
                panel.Hide();panel.Choice.QueueFree();panel.QueueFree();panels.Remove(id);
                if(active)attention.Show();
            }
            notice.Text=panels.Count==0 ? "Nothing needs your attention." : "Choose a request. Opening or hiding it sends no answer.";
            if (selecting.IsCompleted) selecting = SelectReceiver(projection["receiver"]!); changed();
        };
        hud.Withdrawn += _ => { receiver = null; Ready = false;notice.Text="Attention unavailable while authorization is being verified.";foreach (var p in panels.Values) p.Withdraw(); changed(); };
        hud.Message += message => { var handling = Receive(message); receiving = receiving.IsCompleted ? handling : Task.WhenAll(receiving, handling); };
    }
    void Present(QuestionPanel? selectedPanel)
    {
        if(disposed)return;presentationChanging();host.Show();attention.Visible=selectedPanel==null;
        foreach(var panel in panels.Values)panel.Visible=panel==selectedPanel;
        changed();
    }
    public void ShowAttention()=>Present(null);
    public void Hide(){if(disposed)return;presentationChanging();host.Hide();changed();}
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
        catch (Exception error) { notice.Text="Question receiver unavailable: "+error.Message;changed(); }
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
            } catch (Exception error) { notice.Text="Question presentation refused: "+error.Message;changed(); }
            await hud.Send(new() { ["type"] = "gui_prepared", ["token"] = token, ["accepted"] = accepted });
        } catch (Exception error) { if (!disposed) { notice.Text=error.Message;changed(); } }
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
        foreach (var panel in panels.Values) { panel.DisposeView(); retired = retired.IsCompleted ? panel.Completion : Task.WhenAll(retired, panel.Completion);panel.Choice.QueueFree();panel.QueueFree(); } panels.Clear();attention.QueueFree();host.Hide();
    }
}

public sealed record QuestionDescriptor(Form Form, Term Opened, Term Revision, string Interaction, Term Source, Actor Responsible)
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
        return new(Form.Decode(view[1], view[3], view[4]), a[2], view[0], interaction,a[0],Actor.FromTerm(a[1]));
    }
}

public partial class QuestionPanel : VBoxContainer
{
    readonly Label status = new() { AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly FormPanel panel = new() {BodyMinimumHeight=0,SizeFlagsVertical=SizeFlags.ExpandFill};
    readonly Label source = new() {AutowrapMode=TextServer.AutowrapMode.WordSmart,SizeFlagsHorizontal=SizeFlags.ExpandFill};
    readonly Button cancel = SpatialGui.ActionButton("Cancel request","cancel-question");
    public Button Choice { get; }=SpatialGui.ActionButton("Request loading…","attention-request");
    public event Action? HiddenByUser;
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
        var heading=new HFlowContainer();AddChild(heading);heading.AddChild(source);
        var hide=SpatialGui.ActionButton("Later","hide-question");heading.AddChild(hide);hide.Pressed+=()=>HiddenByUser?.Invoke();
        AddChild(panel);var strip=new PanelContainer {ThemeTypeVariation="StatusPanel"};AddChild(strip);strip.AddChild(status);
        var cancellation=new HFlowContainer();AddChild(cancellation);cancellation.AddChild(cancel);
        view = new(session, human, target, "gui_question", SignedSession.ViewGoal(target, Term.Call("gui_question_form", a[2], Term.Variable("View"))));
        view.Projection += message => {
            generation++;
            var next = QuestionDescriptor.Decode(Term.Parse(Json.S(message, "value")));
            if (current == null || next.Interaction == "submitted" && current.Interaction!="submitted") panel.Present(next.Form);
            else if(current.Revision.ToString()==next.Revision.ToString())panel.RefreshAppearance(next.Form.Tree);
            current = next; available = true; panel.Show(); panel.Lock(Locked || next.Interaction != "editable");
            source.Text="Requested by "+next.Responsible.InstanceText.TrimEnd('.');source.TooltipText=next.Source+"\n"+next.Responsible;
            string state=next.Interaction switch {"editable"=>"Draft","stale"=>"Stale form — your earlier draft is retained","submitted"=>"Submitted — awaiting result",_=>next.Interaction};
            status.Text=Locked&&next.Interaction=="editable" ? "Original work unresolved. Check its outcome before answering." : state;
            Choice.Text=next.Form.Tree.Label+" · "+state;cancel.Disabled=Locked||next.Interaction=="submitted";changed();
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
                if (!disposed && available && expected == generation) status.Text = Json.Committed(reply)
                    ? answer ? "Submitted — awaiting result." : "Cancellation committed." : "Action not confirmed. Check its original outcome.";
            } catch (Exception error) {
                if (error is ApiError { Definite: true }) settled = false;
                if (!disposed && available && expected == generation) status.Text = error.Message + " Check any retained original operation.";
            }
            finally { busy = false; if (!disposed) { panel.Lock(Locked || !available || current?.Interaction != "editable");cancel.Disabled=Locked||!available||current?.Interaction=="submitted";changed(); } }
        }
        panel.Invoked += role => { if (!busy && current?.Form.Submit.ToString() == role) working = Write(true); };
        cancel.Pressed += () => { if (!busy) working = Write(false); }; _ = view.Start();
    }
    public void Withdraw() { generation++; available = false; status.Text = "Question unavailable.";Choice.Text="Request unavailable";source.Text="";source.TooltipText="";cancel.Disabled=true;panel.Hide(); panel.Lock(true); }
    public void DisposeView() { if (disposed) return; disposed = true; lifetime.Cancel(); view?.Dispose(); panel.Clear(); }
    public override void _ExitTree() => DisposeView();
}
