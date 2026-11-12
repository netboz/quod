using Godot;
using Quod.Client;
using Json = Quod.Client.Json;

public partial class OperationsPanel : VBoxContainer
{
    public FormPanel FormPanel { get; private set; } = null!;
    public Offer? Current { get; private set; }
    public Actor? SelectedStorage => target;
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
    // A form ends once: validated, it reports its authored label; cancelled, nothing.
    public event Action<string?>? Closed;
    SignedSession session = null!;
    Accounts accounts = null!;
    Actor human = null!, target = null!;
    Term? subject;
    SignedView? view;
    Task retired = Task.CompletedTask, working = Task.CompletedTask;
    public Task Completion => Task.WhenAll(working, retired, view?.Completion ?? Task.CompletedTask);
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
    readonly ScrollContainer details = new() { Name = "operation-exact-details", CustomMinimumSize = new(0,220), HorizontalScrollMode = ScrollContainer.ScrollMode.Disabled, Visible = false };
    readonly VBoxContainer detailContents = new() { SizeFlagsHorizontal = SizeFlags.ExpandFill };
    // An exact answer can be large: selectable and scrollable, never one wrapped label.
    readonly TextEdit answer = new() { Name="operation-outcome-details",Editable=false,CustomMinimumSize=new(0,220),Visible=false };
    readonly LineEdit exactNamespace = new() { Name = "exact-storage-namespace", PlaceholderText = "Existing storage namespace" };
    readonly LineEdit exactAnchor = new() { Name = "exact-storage-anchor", PlaceholderText = "Exact genesis anchor (base64url)" };
    readonly LineEdit exactEntity = new() { Name="exact-subject-instance",PlaceholderText="Existing entity (functional term)",Text="me" };
    Button exactTarget = null!, resolve = null!;
    CancellationTokenSource? work;
    long generation;
    bool disposed, busy;
    // The presented form was sent and its outcome is not known yet: it stays
    // as sent. Whether anything may be sent is the accounts owner's answer.
    bool sent;
    int answered;
    const string Unknown = "The answer did not arrive. Check what happened before sending anything else.";
    string? requested;
    bool revealPending,submitPending;
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
            var chosen = classes[(int)index - 1];
            PresentSubject(target, chosen, true); ClassChosen?.Invoke(chosen);
        };
        AddChild(status);
        FormPanel = new() { Name = "offered-form" }; AddChild(FormPanel);
        FormPanel.Invoked += role => { if (Current != null && role == Current.Form.Submit.ToString()) _ = Submit(); };
        FormPanel.Edited += () => Changed?.Invoke();
        resolve = Button(this, "resolve-original", "Check what happened", () => _ = Resolve());resolve.Hide();
        AddChild(details);details.AddChild(detailContents);detailContents.AddChild(context);detailContents.AddChild(scope);detailContents.AddChild(answer);
    }
    // The enclosing panel's one Details control also opens the exact storing
    // ontology, subject and last answer.
    internal void ShowDetails(bool visible) { details.Visible=visible;if(visible)Reveal(details); }
    static Button Button(Godot.Container row, string name, string text, Action action)
    { var button = SpatialGui.ActionButton(text,name); row.AddChild(button); button.Pressed += action; return button; }
    void Initialize(SignedSession session, Accounts accounts)
    {
        if(this.session!=null && (this.session.Network!=session.Network || this.session.Key.PublicText!=session.Key.PublicText || human!=accounts.Human)) {
            LastOutcome=null;status.Text=scope.Text=context.Text=answer.Text="";answer.Hide();details.Hide();
        }
        if(!ReferenceEquals(this.accounts,accounts)) { if(this.accounts!=null)this.accounts.Resolved-=Settle;accounts.Resolved+=Settle; }
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
        Initialize(session, accounts); Invalidate(); target=null!;targeting.Show(); targets.Clear(); storage.Clear(); storage.AddItem("Choose storage ontology");
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
        storage.AddItem(chosen.Namespace==human.Namespace && chosen.Anchor==human.Anchor ? "Your ontology" : chosen.Namespace);
        storage.SetItemTooltip(storage.ItemCount-1,chosen.Namespace+" @ "+chosen.Anchor);
    }
    async Task ChooseStorage(Actor chosen)
    {
        if (busy || disposed) return;
        Invalidate(); target = chosen;long expected = generation; SetBusy(true); work = new(); var running = work;
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
                foreach (var item in classes) {
                    var reference=item.Require("class_ref",3);
                    _=Subject.Decode(item);
                    classSelector.AddItem((reference[0].TextValue==chosen.Namespace ? "" : reference[0].TextValue+" : ")+reference[2]);
                }
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
            else if (!sent) { Current = null; FormPanel.Clear(); status.Text = next.Length == 0 ? "Nothing can be done here." : "Choose an action."; }
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
        bool shown = FormPanel.Descriptor != null && Current?.Name == offer.Name;
        if (!(shown && sent)) {
            if (!shown) { sent = false; status.Text = accounts.Uncertain ? Unknown : ""; FormPanel.Present(offer.Form); }
            else if (Current!.Revision.ToString() != offer.Revision.ToString()) FormPanel.Present(offer.Form, Carry(Current.Form, FormPanel.Draft, offer.Form));
            else FormPanel.RefreshAppearance(offer.Form.Tree);
            Current = offer;
        }
        Refresh();
        if(revealPending)Reveal(FormPanel);
        revealPending=false;
        bool submit=submitPending&&offer.Name==requested;submitPending=false;
        if(submit&&!offer.Form.Tree.Leaves.Any(c=>c.Input))_=Submit();
        Changed?.Invoke();
    }
    // A renewed offer replaces the open form. What the user typed stays where
    // the same field is still offered and still accepts it.
    static Dictionary<string, string>? Carry(Form old, IReadOnlyDictionary<string, string> typed, Form next)
    {
        Dictionary<string, string>? draft = null;
        var fields = old.Tree.Leaves.Where(c => c.Input).ToDictionary(c => c.Role);
        foreach (var field in next.Tree.Leaves.Where(c => c.Input && !c.Flag("readonly"))) {
            if (!fields.TryGetValue(field.Role, out var prior) || prior.Family != field.Family || typed[field.Role] == old.Defaults[field.Role]) continue;
            try { field.Draft(typed[field.Role], initial: true); } catch (Exception) { continue; }
            (draft ??= new(next.Defaults))[field.Role] = typed[field.Role];
        }
        return draft;
    }
    // Discovery is a U read; the existing U-to-A instruction evaluates the
    // executing actor's guard. Advisory availability cannot replace it.
    void Refresh()
    {
        resolve.Visible = accounts.Uncertain;
        if (Current != null) FormPanel.Lock(busy || sent || !Available || accounts.Uncertain);
    }
    public Task Submit() => busy ? working : working = SubmitWork();
    async Task SubmitWork()
    {
        if (Current == null || !Available || busy || sent || accounts.Uncertain || !FormPanel.Validate()) return;
        var offered = Current; string goal = offered.Goal(FormPanel.Draft); long expected = generation;
        LastOutcome=null; answered = accounts.Outcomes.Count;
        var consumer = session; var owner = human; var selectedTarget = target;
        SetBusy(true); work = new(); var running = work; sent = true; Refresh(); status.Text = "Sending…"; Changed?.Invoke();
        try {
            var personal = await consumer.Read(owner, "<<\"quod:user\">>::personal_agent(Agent,Key).", running.Token);
            var agent = Actor.FromTerm(Json.Binding(personal, "Agent")); var key = Json.Binding(personal, "Key");
            running.Token.ThrowIfCancellationRequested();
            var reply = await consumer.Personal(owner, agent, key.Bytes, selectedTarget, goal, running.Token);
            if (disposed || expected != generation) return;
            ShowOutcome(reply);
        } catch (Exception error) { if (!disposed && expected == generation) status.Text = error.Message + (accounts.Uncertain ? " " + Unknown : ""); }
        finally { SetBusy(false); running.Dispose(); if (ReferenceEquals(work, running)) work = null;
            if (!disposed) { if (expected == generation) Settle(); else Changed?.Invoke(); } }
    }
    // Once nothing is uncertain the sent form's outcome is known. Validated,
    // the form disappears; refused, it returns on the current offer.
    void Settle()
    {
        if (disposed || busy) return;
        if (!sent || accounts.Uncertain) { Refresh(); Changed?.Invoke(); return; }
        sent = false;
        if (LastOutcome == null || !Json.Terminal(LastOutcome)) {
            // Recovered later, by this panel or by the sign-in card.
            var recovered = accounts.Outcomes.Skip(answered).Where(Json.Terminal).ToArray();
            if ((recovered.FirstOrDefault(reply => !Json.Committed(reply)) ?? recovered.LastOrDefault()) is {} known) ShowOutcome(known);
        }
        if (LastOutcome is {} outcome && Json.Committed(outcome)) { Close(Current!.Form.Tree.Label); return; }
        if (offers.FirstOrDefault(o => o.Name == Current!.Name) is Offer latest) Select(latest);
        else { Current = null; FormPanel.Clear(); Refresh(); Changed?.Invoke(); }
    }
    void ShowOutcome(System.Text.Json.Nodes.JsonNode reply)
    {
        LastOutcome = reply.DeepClone();
        answer.Text = reply.ToJsonString(new() { WriteIndented=true }); answer.Show();
        if (Json.Committed(reply)) return;
        status.Text = Json.Terminal(reply) ? "Refused: nothing was changed. Details shows the full answer." : Unknown;
        Reveal(status);
    }
    void Reveal(Control control)
    {long expected=generation;SpatialGui.Reveal(control,()=>!disposed&&generation==expected);}
    string StorageTitle(Actor chosen)=>chosen.Namespace==human.Namespace && chosen.Anchor==human.Anchor ? "Your ontology" : "Selected storage";
    Task Resolve() => busy ? working : working = ResolveWork();
    async Task ResolveWork()
    {
        if (busy || disposed) return; SetBusy(true); work = new(); var running = work;
        long expected = generation; var owner = accounts;
        try { await owner.Resolve(running.Token); if (!disposed && expected == generation) status.Text = owner.Uncertain ? "Still unknown. Nothing was sent again." : "Checked. Nothing was sent again."; }
        catch (Exception error) { if (!disposed && expected == generation) status.Text = error.Message; }
        finally { SetBusy(false); running.Dispose(); if (ReferenceEquals(work, running)) work = null; Settle(); }
    }
    void RetireView()
    { var completion = view?.Completion ?? Task.CompletedTask; view?.Dispose(); view = null; retired = retired.IsCompleted ? completion : Task.WhenAll(retired, completion); }
    void Invalidate()
    { generation++;revealPending=false;submitPending=false; RetireView(); Available = false; sent = false; Current = null; subject = null; offers = []; FormPanel.Clear(); }
    public void Suspend() { if(busy)return;Invalidate();Hide(); }
    void Close(string? validated) { work?.Cancel(); Invalidate(); requested = null; status.Text = ""; Hide(); Closed?.Invoke(validated); Changed?.Invoke(); }
    public void Cancel() => Close(null);
    public void DisposeView()
    { if (disposed) return; disposed = true; generation++; work?.Cancel(); RetireView(); Available = false; FormPanel.Clear(); if (accounts != null) accounts.Resolved -= Settle; }
    public override void _ExitTree() => DisposeView();
}
