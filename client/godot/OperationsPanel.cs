using Godot;
using Quod.Client;
using Json = Quod.Client.Json;

public partial class OperationsPanel : VBoxContainer
{
    public FormPanel FormPanel { get; private set; } = null!;
    public Offer? Current { get; private set; }
    public Actor? SelectedStorage { get; private set; }
    public bool Available { get; private set; }
    public bool IsWorking => busy;
    public IReadOnlyList<Offer> Offered=>offers;
    public string SubjectLabel { get; private set; }="Selected subject";
    public string StatusText => status.Text;
    public System.Text.Json.Nodes.JsonNode? LastOutcome { get; private set; }
    public event Action? Changed;
    public event Action<Actor,Term>? SubjectOpened;
    // A kind of thing was chosen in the storage catalogue: its pie chooses the action.
    public event Action<Term>? ClassChosen;
    public event Action? Cancelled;
    SignedSession session = null!;
    Accounts accounts = null!;
    Actor human = null!, target = null!;
    Term? subject;
    SignedView? view;
    Task retired = Task.CompletedTask, working = Task.CompletedTask;
    public Task Completion => Task.WhenAll(working, retired, view?.Completion ?? Task.CompletedTask);
    sealed class Buffer(string revision, Form form)
    {
        public string Revision = revision;
        public Form Form = form;
        public Dictionary<string, string> Draft = new(form.Defaults);
        public bool Settled;
    }
    readonly Dictionary<string, Buffer> drafts = [];
    readonly List<Actor> targets = [];
    Offer[] offers = [];
    Term[] classes = [];
    readonly Label status = new() { AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly Label scope = new() { Name = "operation-scope", AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly Label context = new() { Name = "operation-context", AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly VBoxContainer targeting = new() { Name = "operation-targeting" };
    readonly VBoxContainer exactTargeting = new() { Name="operation-advanced-target",Visible=false };
    readonly OptionButton storage = FormPanel.Choice("operation-storage");
    readonly OptionButton classSelector = FormPanel.Choice("operation-class");
    readonly VBoxContainer results = new() { Name = "operation-results" };
    readonly HFlowContainer actions = new() { Name="operation-recovery" };
    readonly ScrollContainer details = new() { Name = "operation-exact-details", CustomMinimumSize = new(0,220), HorizontalScrollMode = ScrollContainer.ScrollMode.Disabled, Visible = false };
    readonly VBoxContainer detailContents = new() { SizeFlagsHorizontal = SizeFlags.ExpandFill };
    readonly LineEdit exactNamespace = new() { Name = "exact-storage-namespace", PlaceholderText = "Existing storage namespace" };
    readonly LineEdit exactAnchor = new() { Name = "exact-storage-anchor", PlaceholderText = "Exact genesis anchor (base64url)" };
    readonly LineEdit exactEntity = new() { Name="exact-subject-instance",PlaceholderText="Existing entity (functional term)",Text="me" };
    Button defaults = null!, exactTarget = null!;
    CancellationTokenSource? work;
    long generation;
    bool disposed, busy;
    string? requested;
    bool revealPending,submitPending;
    string DraftKey(Offer offer) => string.Join("\n",session.Network,session.Key.PublicText,human.Entity,offer.Subject,offer.Name);
    Buffer Draft(Offer offer) => drafts[DraftKey(offer)];
    public override void _Ready()
    {
        AddChild(targeting);
        targeting.AddChild(new Label { Text = "Choose where to work",ThemeTypeVariation="Heading" });
        targeting.AddChild(new Label { Text = "Choose the storage, then the kind of thing. Its available actions appear below.", AutowrapMode = TextServer.AutowrapMode.WordSmart });
        targeting.AddChild(new Label {Text="Storage"});targeting.AddChild(storage);
        targeting.AddChild(new Label {Text="Kind of thing"});targeting.AddChild(classSelector);
        Button(targeting,"advanced-target-toggle","Use an exact existing identity…",()=>{exactTargeting.Visible=!exactTargeting.Visible;});
        targeting.AddChild(exactTargeting);
        var exact = exactTargeting; exact.AddChild(exactNamespace); exact.AddChild(exactAnchor);
        exactTarget = Button(exact, "add-exact-storage", "Use exact existing target", () => {
            if (busy || disposed) return;
            try {
                var bytes = Identity.Decode(exactAnchor.Text);
                if (bytes.Length != 32 || exactNamespace.Text.Length == 0) throw new FormatException("An exact namespace and 32-byte genesis anchor are required.");
                var chosen = new Actor(exactNamespace.Text, Identity.Encode(bytes), "me."); AddTarget(chosen);
                storage.Select(targets.IndexOf(chosen) + 1); _ = ChooseStorage(chosen);
            } catch (Exception error) { status.Text = error.Message; Changed?.Invoke(); }
        });
        var instance = exactTargeting; instance.AddChild(exactEntity);
        Button(instance,"open-exact-subject","Open existing subject operations",() => {
            if (busy || disposed) return;
            try {
                var entity=Term.Parse(exactEntity.Text.TrimEnd('.')); entity.Ground();
                var chosen=new Actor(exactNamespace.Text,Identity.Encode(Identity.Decode(exactAnchor.Text)),entity+".");
                if (chosen.Namespace.Length==0 || Identity.Decode(chosen.Anchor).Length!=32) throw new FormatException("An exact existing namespace and anchor are required.");
                PresentSubject(chosen,chosen.Entity);
            } catch (Exception error) { status.Text=error.Message; Changed?.Invoke(); }
        });
        storage.ItemSelected += index => { if (index > 0) _ = ChooseStorage(targets[(int)index - 1]); };
        classSelector.ItemSelected += index => {
            if (index <= 0) return;
            var chosen = Term.Call("class_ref", Term.Text(target.Namespace), Term.Binary(Identity.Decode(target.Anchor)), classes[(int)index - 1]);
            PresentSubject(target, chosen, true); ClassChosen?.Invoke(chosen);
        };
        AddChild(status);AddChild(results);
        FormPanel = new() { Name = "offered-form" }; AddChild(FormPanel);
        FormPanel.Invoked += role => { if (Current != null && role == Current.Form.Submit.ToString()) _ = Submit(); };
        FormPanel.Edited += () => Changed?.Invoke();
        Button(this,"operation-details-toggle","Exact identity / outcome details",()=>{details.Visible=!details.Visible;Reveal(details.Visible ? details : results);Changed?.Invoke();});
        AddChild(details);details.AddChild(detailContents);detailContents.AddChild(context);detailContents.AddChild(scope);
        AddChild(actions);
        defaults = Button(actions, "current-defaults", "Use current fields and defaults", Defaults);
        Button(actions, "resolve-original", "Check original outcomes", () => _ = Resolve());
        Button(actions, "cancel-operation", "Cancel / close", Cancel);
    }
    static Button Button(Godot.Container row, string name, string text, Action action)
    { var button = SpatialGui.ActionButton(text,name); row.AddChild(button); button.Pressed += action; return button; }
    void Initialize(SignedSession session, Accounts accounts)
    {
        if(this.session!=null && (this.session.Network!=session.Network || this.session.Key.PublicText!=session.Key.PublicText || human!=accounts.Human)) {
            LastOutcome=null;status.Text=scope.Text=context.Text="";details.Hide();
            foreach(var child in results.GetChildren()){results.RemoveChild(child);child.QueueFree();}
            foreach(var child in detailContents.GetChildren())if(child!=scope&&child!=context){detailContents.RemoveChild(child);child.QueueFree();}
        }
        this.session = session; this.accounts = accounts; human = accounts.Human!; Show();
    }
    void SetBusy(bool value)
    {
        busy = value;
        if (disposed) return;
        storage.Disabled = classSelector.Disabled = exactTarget.Disabled = value;
        foreach(var field in new[]{exactNamespace,exactAnchor,exactEntity})SpatialGui.SetEditable(field,!value);
    }
    public void Open(SignedSession session, Accounts accounts)
    { OpenSubject(session, accounts, accounts.Human!, accounts.Human!.Entity); }
    public void OpenSubject(SignedSession session, Accounts accounts, Actor chosen, Term exact)
    { if (busy || disposed) return; Initialize(session, accounts); targeting.Hide(); PresentSubject(chosen, exact); }
    public void OpenStorage(SignedSession session, Accounts accounts,Actor? currentSpace=null)
    {
        if (busy || disposed) return;
        Initialize(session, accounts); Invalidate(); SelectedStorage=null;targeting.Show(); targets.Clear(); storage.Clear(); storage.AddItem("Choose storage ontology");
        foreach (var choice in accounts.Catalogue.Append(human)) AddTarget(choice with { InstanceText = "me." });
        if (accounts.Setup is Term setup) AddTarget(Actor.FromTerm(setup.Require("account", 6)[2]) with { InstanceText = "me." });
        if (currentSpace != null) AddTarget(currentSpace with { InstanceText="me." });
        classSelector.Clear(); classSelector.AddItem("Choose a class");
        scope.Text = context.Text = "No storage selected."; status.Text = "Choose a storage to see its available kinds and actions.";
    }
    void AddTarget(Actor chosen)
    {
        if (targets.Contains(chosen)) return;
        targets.Add(chosen);
        storage.AddItem(chosen.Namespace==human.Namespace && chosen.Anchor==human.Anchor ? "Your account storage" : chosen.Namespace);
        storage.SetItemTooltip(storage.ItemCount-1,chosen.Namespace+" @ "+chosen.Anchor);
    }
    async Task ChooseStorage(Actor chosen)
    {
        if (busy || disposed) return;
        Invalidate(); target = chosen; SelectedStorage=chosen;long expected = generation; SetBusy(true); work = new(); var running = work;
        scope.Text = "Storage: " + chosen.Ontology; status.Text = "Reading this exact target's offered classes…";
        context.Text = StorageTitle(chosen);
        classSelector.Clear(); classSelector.AddItem("Choose a class"); Changed?.Invoke();
        async Task Read()
        {
            try {
                var reply = await session.Read(human, SignedSession.ViewGoal(chosen, Term.Call("gui_operation_classes", Term.Variable("Classes"))), running.Token);
                var next = Json.Binding(reply, "Classes"); next.Ground();
                if (disposed || expected != generation) return;
                classes = next.Items;
                if (classes.Select(c => c.ToString()).Distinct().Count() != classes.Length) throw new FormatException("Duplicate offered class.");
                foreach (var item in classes) classSelector.AddItem(item.ToString());
                status.Text = classes.Length == 0 ? "This storage offers no class operations." : "Choose a kind of thing to see its available actions.";
            } catch (Exception error) { if (!disposed && expected == generation) status.Text = "Target unavailable: " + error.Message; }
            finally { SetBusy(false); running.Dispose(); if (ReferenceEquals(work, running)) work = null; Changed?.Invoke(); }
        }
        working = Read(); await working;
    }
    void PresentSubject(Actor chosen, Term exact,bool reveal=false,string label="Selected subject")
    {
        if (busy || disposed) return;
        if (exact.Name != "class_ref") targeting.Hide();
        Invalidate(); target = chosen; subject = exact; requested=null;revealPending=reveal; long expected = generation;
        SubjectLabel=label;SubjectOpened?.Invoke(chosen,exact);
        scope.Text = "Storage: " + chosen.Ontology + "\nSubject: " + exact;
        context.Text = StorageTitle(chosen)+" · "+(exact.Name=="class_ref" ? "Class: "+exact.Args[2] : "Selected subject");
        view = new(session, human, chosen, "gui_operations", SignedSession.ViewGoal(chosen, Term.Call("gui_operations", exact, Term.Variable("View"))));
        view.Projection += message => {
            if (disposed || expected != generation) return;
            var next = Offer.Decode(Json.S(message, "value"), exact); string? previous = Current?.Name;
            offers = next;
            Available = true; FormPanel.Show();
            var selected = next.FirstOrDefault(o => o.Name == (requested??previous)) ?? (next.Length == 1 ? next[0] : null);
            if (selected != null) Select(selected);
            else { Current = null; FormPanel.Clear(); status.Text = next.Length == 0 ? "No offered operations for this subject." : "Choose an offered operation."; }
            Changed?.Invoke();
        };
        view.Withdrawn += reason => { if (expected != generation) return; Available = false; FormPanel.Lock(true); FormPanel.Hide(); status.Text = reason; Changed?.Invoke(); };
        _ = view.Start();
    }
    // A chosen action without input fields is submitted as soon as its current
    // offer is selected; with fields it only opens the form for editing.
    public void Choose(string name,bool reveal=false,bool submit=false)
    { requested=name;revealPending|=reveal;submitPending=submit;if(Available && offers.SingleOrDefault(o=>o.Name==name) is Offer offered)Select(offered); }
    void Select(Offer offer)
    {
        targeting.Hide();
        string key = DraftKey(offer), revision = offer.Revision.ToString();
        bool changedSelection = Current == null || DraftKey(Current) != key;
        bool same = !changedSelection && Current!.Revision.ToString() == revision;
        Current = offer;
        if (!drafts.TryGetValue(key, out var draft)) { draft = new(revision, offer.Form); drafts[key] = draft; }
        if(draft.Revision==revision)draft.Form=draft.Form with {Tree=offer.Form.Tree};
        if (!same || FormPanel.Descriptor == null) FormPanel.Present(draft.Form, draft.Draft);
        else if(draft.Revision==revision)FormPanel.RefreshAppearance(offer.Form.Tree);
        bool stale = draft.Revision != revision;
        defaults.Text = stale ? "Adopt current fields, keeping draft" : "Use current fields and defaults";
        // Discovery is a U read; the existing U-to-A instruction evaluates the
        // executing actor's guard. Advisory availability cannot replace it.
        FormPanel.Lock(stale || busy || draft.Settled || accounts.Uncertain);
        status.Text = stale ? "The offered schema changed. Your draft is retained. Adopt current fields explicitly before submitting."
            : accounts.Uncertain ? "Original work is unresolved. Check its outcome; do not submit again."
            : draft.Settled ? "This draft was submitted. Choose current defaults explicitly for another operation." : "Unsubmitted local draft";
        if(revealPending)Reveal(FormPanel);
        revealPending=false;
        bool submit=submitPending&&offer.Name==requested;submitPending=false;
        if(submit&&!stale&&!draft.Settled&&!accounts.Uncertain&&!offer.Form.Tree.Leaves.Any(c=>c.Input))_=Submit();
        Changed?.Invoke();
    }
    public void Defaults()
    {
        if (Current == null || !Available || busy || accounts.Uncertain) return;
        var old = Draft(Current); bool stale = old.Revision != Current.Revision.ToString();
        var next = new Buffer(Current.Revision.ToString(), Current.Form);
        if (stale) {
            var previous = old.Form.Tree.Leaves.Where(c => c.Input).ToDictionary(c => c.Role);
            foreach (var field in next.Form.Tree.Leaves.Where(c => c.Input && !c.Flag("readonly")))
                if (previous.TryGetValue(field.Role, out var prior) && prior.Family == field.Family && old.Draft.TryGetValue(field.Role, out var value)) next.Draft[field.Role] = value;
            next.Settled = old.Settled;
        }
        drafts[DraftKey(Current)] = next; FormPanel.Present(next.Form, next.Draft); Select(Current);
    }
    public Task Submit() => busy ? working : working = SubmitWork();
    async Task SubmitWork()
    {
        if (Current == null || !Available || busy || Draft(Current).Settled || accounts.Uncertain || !FormPanel.Validate() ||
            Draft(Current).Revision != Current.Revision.ToString()) return;
        var offered = Current; var buffer = Draft(offered); string goal = offered.Goal(FormPanel.Draft); long expected = generation;
        LastOutcome=null;
        var consumer = session; var owner = human; var selectedTarget = target;
        SetBusy(true); work = new(); var running = work; FormPanel.Lock(true); status.Text = "Checking the governed personal agent…"; Changed?.Invoke();
        try {
            var personal = await consumer.Read(owner, "personal_agent(Agent,Key).", running.Token);
            var agent = Actor.FromTerm(Json.Binding(personal, "Agent")); var key = Json.Binding(personal, "Key");
            running.Token.ThrowIfCancellationRequested(); buffer.Settled = true;
            var reply = await consumer.Personal(owner, agent, key.Bytes, selectedTarget, goal, running.Token);
            if (disposed || expected != generation) return;
            ShowOutcome(reply);
            if (Json.Terminal(reply)) Renew(offered, buffer);
        } catch (Exception error) { if (!disposed && expected == generation) status.Text = error.Message + (accounts.Uncertain ? " Original work retained; check its outcome." : ""); }
        finally { SetBusy(false); running.Dispose(); if (ReferenceEquals(work, running)) work = null;
            if (!disposed && Current != null) {
                if (expected != generation) Select(Current);
                else { FormPanel.Lock(!Available || accounts.Uncertain || Draft(Current).Settled || Draft(Current).Revision != Current.Revision.ToString()); Changed?.Invoke(); }
            } }
    }
    // A settled draft protects an unknown outcome from a blind resubmission.
    // Once the outcome is known, the same fields stand ready for another
    // operation; nobody has to hunt for a reset.
    void Renew(Offer offer, Buffer settled)
    {
        var next = new Buffer(settled.Revision, settled.Form) { Draft = new(settled.Draft) };
        drafts[DraftKey(offer)] = next;
        if (Current != null && DraftKey(Current) == DraftKey(offer)) FormPanel.Present(next.Form, next.Draft);
    }
    void ShowOutcome(System.Text.Json.Nodes.JsonNode reply)
    {
        LastOutcome = reply.DeepClone();
        status.Text = Json.Committed(reply) ? "Operation committed. Open a returned subject to inspect its offered operations."
            : Json.Terminal(reply) ? "Operation finished without a commit. Inspect the exact outcome details."
            : "Outcome unknown. Check the original operation; do not resubmit.";
        var outcome=new Label { Text="Received outcome · "+status.Text,Name="operation-outcome",AutowrapMode=TextServer.AutowrapMode.WordSmart };
        results.AddChild(outcome);results.MoveChild(outcome,0);
        detailContents.AddChild(new Label { Text = reply.ToJsonString(), AutowrapMode = TextServer.AutowrapMode.WordSmart });
        if (!Json.Committed(reply)) { Reveal(outcome);return; }
        foreach (var bindings in reply["bindings"]!.AsArray()) {
            if (bindings?["Results"] is not System.Text.Json.Nodes.JsonValue value) continue;
            foreach (var row in Term.Parse(value.GetValue<string>()).Items) {
                var result = row.Require("result", 2);
                if (result[1].Kind != "compound" || result[1].Name != "entity_ref") continue;
                var returned = Actor.FromTerm(result[1]);
                var open = Button(results, "open-returned-subject", "View result: " + result[0], () => PresentSubject(returned, returned.Entity,false,"Result · "+result[0]));
                open.TooltipText = result[1].ToString();
                results.MoveChild(open,1);
                Reveal(open);
            }
        }
    }
    void Reveal(Control control)
    {long expected=generation;SpatialGui.Reveal(control,()=>!disposed&&generation==expected);}
    string StorageTitle(Actor chosen)=>chosen.Namespace==human.Namespace && chosen.Anchor==human.Anchor ? "Your account storage" : "Selected storage";
    Task Resolve() => busy ? working : working = ResolveWork();
    async Task ResolveWork()
    {
        if (busy || disposed) return; SetBusy(true); work = new(); var running = work;
        long expected = generation; var owner = accounts;
        try { await owner.Resolve(running.Token); if (!disposed && expected == generation) {
            foreach (var reply in owner.Outcomes) ShowOutcome(reply);
            status.Text = owner.Uncertain ? "Original outcome remains unknown." : "Original outcomes recovered without submission."; }
        } catch (Exception error) { if (!disposed && expected == generation) status.Text = error.Message; }
        finally { SetBusy(false); running.Dispose(); if (ReferenceEquals(work, running)) work = null; if (!disposed) { if (Current != null) FormPanel.Lock(!Available || accounts.Uncertain || Draft(Current).Settled || Draft(Current).Revision != Current.Revision.ToString()); Changed?.Invoke(); } }
    }
    void RetireView()
    { var completion = view?.Completion ?? Task.CompletedTask; view?.Dispose(); view = null; retired = retired.IsCompleted ? completion : Task.WhenAll(retired, completion); }
    void Invalidate()
    { generation++;revealPending=false;submitPending=false; RetireView(); Available = false; Current = null; subject = null; offers = []; FormPanel.Clear(); }
    public void Suspend() { if(busy)return;Invalidate();Hide(); }
    public void Cancel() { generation++;revealPending=false; work?.Cancel(); RetireView(); Available = false; Hide(); Cancelled?.Invoke();Changed?.Invoke(); }
    public void DisposeView()
    { if (disposed) return; disposed = true; generation++; work?.Cancel(); RetireView(); Available = false; FormPanel.Clear(); }
    public override void _ExitTree() => DisposeView();
}
