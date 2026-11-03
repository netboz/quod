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
    readonly VBoxContainer surface=new() {Name="question-attention",SizeFlagsHorizontal=Control.SizeFlags.ExpandFill};
    readonly VBoxContainer workingHost=new() {SizeFlagsVertical=Control.SizeFlags.ExpandFill};
    readonly VBoxContainer choices=new() {SizeFlagsHorizontal=Control.SizeFlags.ExpandFill};
    readonly ScrollContainer list=new() {Name="attention-list",HorizontalScrollMode=ScrollContainer.ScrollMode.Disabled,SizeFlagsVertical=Control.SizeFlags.ExpandFill};
    readonly Button attention=SpatialGui.ActionButton("Your attention · 0","attention");
    readonly Button close=SpatialGui.ActionButton("Back","hide-attention");
    readonly Label notice=new() {Visible=false,AutowrapMode=TextServer.AutowrapMode.WordSmart};
    string? active;
    public bool Expanded {get;private set;}
    public bool Working => Expanded && active!=null;
    public string Caption=>attention.Text;
    public void Show(){if(disposed)return;Expanded=true;list.Visible=active==null;UpdatePresentation();}
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
        host.AddChild(surface);var navigation=new HFlowContainer();surface.AddChild(navigation);navigation.AddChild(attention);navigation.AddChild(close);surface.AddChild(list);list.AddChild(choices);surface.AddChild(workingHost);surface.AddChild(notice);
        attention.Pressed+=()=>{Expanded=true;list.Visible=!list.Visible;UpdatePresentation();};
        close.SizeFlagsHorizontal=Control.SizeFlags.Fill;close.Pressed+=Close;list.Hide();workingHost.Hide();close.Hide();
        var human = accounts.Human!;
        hud = new(session, human, human, "gui_hud", SignedSession.ViewGoal(human, Term.Call("gui_pending_questions", Term.Variable("View"))));
        hud.Projection += projection => {
            receiver = Json.S(projection["receiver"], "token");
            var references = Term.Parse(Json.S(projection, "value")); references.Ground(); var keep = new HashSet<string>();
            foreach (var q in references.Items) {
                q.Require("question_ref", 3); string id = q.ToString(); keep.Add(id);
                if (!panels.ContainsKey(id)) {
                    var panel = new QuestionPanel {Visible=false,SizeFlagsVertical=Control.SizeFlags.ExpandFill}; workingHost.AddChild(panel); panels[id] = panel;
                    choices.AddChild(panel.Choice);panel.Choice.Pressed+=()=>Choose(id);panel.Later+=()=>{active=null;if(!panel.Discovered&&!accounts.Uncertain){panel.DisposeView();retired=Task.WhenAll(retired,panel.Completion);panel.Choice.QueueFree();panel.QueueFree();panels.Remove(id);}list.Show();UpdatePresentation();if(panels.ContainsKey(id))panel.Choice.GrabFocus();else attention.GrabFocus();};
                    panel.Open(session, accounts, q, ()=>{RefreshCount();changed();});
                }
            }
            foreach (var id in panels.Keys.Except(keep).ToArray()) {
                panels[id].RetireQuestion();
            }
            foreach(var id in keep)panels[id].Discovered=true;
            RefreshCount();if (selecting.IsCompleted) selecting = SelectReceiver(projection["receiver"]!); changed();
        };
        hud.Withdrawn += _ => { receiver = null; Ready = false; foreach (var p in panels.Values) p.Withdraw(); changed(); };
        hud.Message += message => { var handling = Receive(message); receiving = receiving.IsCompleted ? handling : Task.WhenAll(receiving, handling); };
    }
    public void Start() => _ = hud.Start();
    void RefreshCount() { attention.Text="Your attention · "+panels.Values.Count(p=>p.Discovered); }
    void Choose(string id) { active=id;Expanded=true;list.Hide();UpdatePresentation(); }
    public void Close() { Expanded=false;UpdatePresentation();attention.GrabFocus(); }
    void UpdatePresentation()
    {
        if(surface.GetViewport().GetParent() is SpatialGui gui)gui.AppearanceLayoutChanging();
        foreach(var (id,panel) in panels)panel.Visible=Expanded&&id==active;
        workingHost.Visible=Expanded&&active!=null;
        list.Visible=Expanded&&(list.Visible||active==null);close.Visible=Expanded;
        surface.SizeFlagsVertical=Expanded ? Control.SizeFlags.ExpandFill : Control.SizeFlags.Fill;
        changed();
    }
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
        catch (Exception error) { notice.Show();notice.Text = "Question receiver unavailable: " + error.Message; changed(); }
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
            } catch (Exception error) { notice.Show();notice.Text = "Question presentation refused: " + error.Message; changed(); }
            await hud.Send(new() { ["type"] = "gui_prepared", ["token"] = token, ["accepted"] = accepted });
        } catch (Exception error) { if (!disposed) { notice.Show();notice.Text = error.Message; changed(); } }
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
        foreach (var panel in panels.Values) { panel.DisposeView(); retired = retired.IsCompleted ? panel.Completion : Task.WhenAll(retired, panel.Completion); panel.Choice.QueueFree(); panel.QueueFree(); } panels.Clear();surface.Hide();surface.QueueFree();
    }
}

public sealed record QuestionDescriptor(Form Form, Term Opened, Term Revision, string Interaction, Term Source, Actor Responsible)
{
    public static QuestionDescriptor Decode(Term value)
    {
        value.Ground(); var a = value.Require("question_form", 5); var source = a[0].Require("form_ref", 3);
        var responsible = Actor.FromTerm(a[1]); var view = a[4].Require("form_view", 5);
        if (a[2].Kind != "binary" || a[2].Bytes.Length != 32 || view[0].Kind != "binary" || view[0].Bytes.Length != 32 ||
            view[2].Kind != "binary" || view[2].Bytes.Length != 32 || view[1].Require("component", 4)[0].ToString() != source[2].ToString())
            throw new FormatException("Invalid question identity.");
        string interaction = a[3].Kind == "atom" && a[3].Name == "awaiting" ? a[2].ToString() == view[0].ToString() ? "editable" : "stale" : "submitted";
        if (interaction == "submitted") a[3].Require("submitted", 3);
        return new(Form.Decode(view[1], view[3], view[4]), a[2], view[0], interaction, a[0], responsible);
    }
}

public partial class QuestionPanel : VBoxContainer
{
    readonly Label source = new() {Name="question-source",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly Label status = new() {Name="question-status",AutowrapMode=TextServer.AutowrapMode.WordSmart};
    readonly FormPanel panel = new() {MinimumFieldHeight=80,SizeFlagsVertical=SizeFlags.ExpandFill};
    readonly Button cancel=SpatialGui.ActionButton("Cancel request","cancel-question");
    readonly Button later=SpatialGui.ActionButton("Later","hide-question");
    readonly Button resolve=SpatialGui.ActionButton("Check original outcome","resolve-question");
    readonly CancellationTokenSource lifetime = new();
    public Button Choice {get;}=SpatialGui.ActionButton("Loading question…");
    public event Action? Later;
    public bool Discovered {get;set;}=true;
    public string Status=>status.Text;
    public JsonNode? LastOutcome {get;private set;}
    SignedView? view;
    QuestionDescriptor? current;
    SignedSession session=null!;
    Actor target=null!;
    Term question=null!;
    Action changed=null!;
    bool busy, disposed, available, settled, cancelled;
    string? completionStatus;
    SignedWork? original;
    bool originalAnswer;
    Accounts accounts = null!;
    long generation;
    Task working = Task.CompletedTask, observing=Task.CompletedTask;
    bool Locked => busy || settled || accounts.Uncertain;
    public bool Available => available && !Locked && current?.Interaction == "editable";
    public FormPanel FormPanel => panel;
    public Task Completion => Task.WhenAll(working,observing, view?.Completion ?? Task.CompletedTask);
    public void Open(SignedSession session, Accounts accounts, Term reference, Action changed)
    {
        this.session=session;this.accounts = accounts;this.changed=changed; var human = accounts.Human!;
        var a = reference.Require("question_ref", 3);question=a[2];target = new Actor(a[0].TextValue, Identity.Encode(a[1].Bytes), human.InstanceText);
        var heading=new HBoxContainer();AddChild(heading);source.SizeFlagsHorizontal=SizeFlags.ExpandFill;heading.AddChild(source);later.SizeFlagsHorizontal=SizeFlags.Fill;heading.AddChild(later);AddChild(panel);
        var actions=new HBoxContainer();AddChild(actions);status.SizeFlagsHorizontal=SizeFlags.ExpandFill;actions.AddChild(status);actions.AddChild(resolve);actions.AddChild(cancel);
        later.Pressed+=()=>Later?.Invoke();
        view = new(session, human, target, "gui_question", SignedSession.ViewGoal(target, Term.Call("gui_question_form", question, Term.Variable("View"))));
        view.Projection += message => {
            generation++;
            var next = QuestionDescriptor.Decode(Term.Parse(Json.S(message, "value")));
            if (current == null) panel.Present(next.Form);
            else if(panel.Descriptor.Tree.Semantic.ToString()==next.Form.Tree.Semantic.ToString())panel.RefreshAppearance(next.Form.Tree);
            current = next; available = true; completionStatus=null;
            source.Text=next.Source.Require("form_ref",3)[2]+" · Agent: "+next.Responsible.InstanceText.TrimEnd('.');
            source.TooltipText=next.Source+"\nResponsible: "+next.Responsible+"\nQuestion: "+reference;
            panel.Show();
            if(!cancelled)status.Text=next.Interaction=="stale" ? "Stale form · Your draft is retained. Cancel or ask for a current question." :
                next.Interaction=="submitted" || LastOutcome!=null&&Json.Committed(LastOutcome) ? "Submitted · Input committed; waiting for the agent’s application result." :
                settled ? "Outcome unknown · Check the original operation; do not send again." : "Draft · Not sent.";
            Update();
            if(next.Interaction=="submitted")Observe();
        };
        view.Withdrawn += Withdraw;
        panel.Invoked += role => { if (!busy && current?.Form.Submit.ToString() == role) working = Write(true); };
        cancel.Pressed += () => { if (!busy) working = Write(false); };
        resolve.Pressed+=()=>{if(!busy)working=Resolve();};_ = view.Start();
    }
    void Update()
    {
        panel.Lock(Locked || !available || current?.Interaction!="editable");
        cancel.Disabled=busy||accounts.Uncertain||cancelled||!Discovered||
            !(available&&current?.Interaction is "editable" or "stale"&&!settled || completionStatus is "rejected" or "aborted" or "expired");
        cancel.TooltipText=cancel.Disabled ? "Cancellation needs a current authorized question or a certified negative original completion." : "Cancel this exact request in its owning ontology.";
        resolve.Visible=accounts.Uncertain||current?.Interaction=="submitted";
        resolve.Disabled=busy||(original==null&&(!Discovered||current?.Interaction!="submitted"));
        Choice.Text=(current?.Form.Tree.Label??"Question")+"\n"+(current==null ? "Checking source" : source.Text)+"\n"+status.Text;
        Choice.TooltipText=source.TooltipText;changed();
    }
    void Observe() { var task=CheckCompletion();observing=observing.IsCompleted ? task : Task.WhenAll(observing,task); }
    async Task CheckCompletion()
    {
        long expected=generation;
        try {
            var reply=await session.Read(accounts.Human!,SignedSession.ViewGoal(target,Term.Call("gui_question_status",question,Term.Variable("Status"))),lifetime.Token);
            if(disposed||expected!=generation||!available)return;
            completionStatus=Json.Binding(reply,"Status").Name;
            status.Text=completionStatus switch {
                "committed"=>"Applied · The original application result is committed.",
                "rejected" or "aborted" or "expired"=>"Needs attention · Original application "+completionStatus+". Cancellation is available.",
                "awaiting"=>"Draft · Awaiting your answer.",
                _=>throw new FormatException("Unsupported question outcome.")};Update();
        } catch(Exception) {if(!disposed&&expected==generation&&available){status.Text="Submitted · Application outcome unavailable; no refusal or success inferred.";Update();}}
    }
    async Task Write(bool answer)
    {
        if(disposed||busy||accounts.Uncertain||!Discovered||current==null||
            (answer ? !Available : cancel.Disabled))return;
        if(answer&&!panel.Validate()){status.Text="Invalid input · Check the marked fields; your edits are retained.";Update();return;}
        busy=settled=true;status.Text=answer ? "Sending answer…" : "Cancelling request…";Update();
        try {
            Term goal=answer ? Term.Call("gui_submit",question,current.Opened,current.Form.Submit,current.Form.Fields(panel.Draft)) : Term.Call("gui_cancel",question);
            var previous=accounts.Pending().Select(w=>w.Id).ToHashSet();
            originalAnswer=answer;var sending=session.Execute(accounts.Human!,SignedSession.ViewGoal(target,goal),"question",lifetime.Token);
            original=accounts.Pending().SingleOrDefault(w=>!previous.Contains(w.Id));
            var reply=await sending;
            if(disposed)return;LastOutcome=reply.DeepClone();
            if(Json.Committed(reply)) {cancelled=!answer;status.Text=answer ? "Submitted · Input committed. Application result is separate." : "Cancelled · This request was cancelled.";}
            else if(Json.Terminal(reply)){settled=false;status.Text="Needs attention · The original request was refused.";}
            else status.Text="Outcome unknown · Check the original operation; do not send again.";
        } catch(Exception error) {
            if(error is ApiError {Definite:true})settled=false;
            if(!disposed)status.Text=(settled ? "Outcome unknown · Check the original operation. " : "Needs attention · ")+error.Message;
        } finally {busy=false;if(!disposed)Update();}
    }
    async Task Resolve()
    {
        if(disposed||busy)return;busy=true;Update();
        try {
            if(original!=null) {
                var reply=await session.Resolve(original,lifetime.Token);
                if(disposed)return;LastOutcome=reply.DeepClone();
                if(Json.Terminal(reply)) {
                    session.Finish(original,reply);settled=Json.Committed(reply);cancelled=settled&&!originalAnswer;
                    status.Text=settled ? originalAnswer ? "Submitted · Original input commit verified." : "Cancelled · Original cancellation verified." : "Needs attention · Original request refused.";
                } else status.Text="Outcome unknown · Original work remains pending; do not send again.";
            }
            if(available&&current?.Interaction=="submitted")await CheckCompletion();
        }
        catch(Exception error){if(!disposed)status.Text="Original outcome unavailable: "+error.Message;}
        finally{busy=false;if(!disposed)Update();}
    }
    public void RetireQuestion()
    {
        if(!Discovered)return;Discovered=false;generation++;available=false;view?.Dispose();panel.Hide();panel.Lock(true);
        if(!busy)status.Text=cancelled ? "Cancelled · No answer will be sent." :
            LastOutcome!=null&&Json.Committed(LastOutcome) ? "Submitted · Original input commit retained. Application result is separate." :
            settled ? "Outcome unknown · Check the original operation; do not send again." :
            "No longer pending · The question was removed. No application result inferred.";
        Update();
    }
    public void Withdraw(string reason="Question unavailable.")
    {
        if(!Discovered)return;
        generation++;available=false;status.Text=reason;panel.Hide();panel.Lock(true);Update();
    }
    public void DisposeView() {if(disposed)return;disposed=true;lifetime.Cancel();view?.Dispose();panel.Clear();}
    public override void _ExitTree()=>DisposeView();
}
