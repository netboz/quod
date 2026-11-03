using Godot;
using Quod.Client;
using Json=Quod.Client.Json;

// The authored workspace adapts the existing source lenses and proof cursor.
// A local draft keeps its original baseline; only explicit Accept can commit.
public partial class SourcePanel : VBoxContainer
{
    readonly FormPanel form=new() { Name="source-form" };
    readonly Label status=new() { Name="source-status",AutowrapMode=TextServer.AutowrapMode.WordSmart };
    readonly HFlowContainer actions=new();
    SignedSession session=null!;Accounts accounts=null!;LocalStore store=null!;
    Actor target=null!,tools=null!;
    Component? descriptor;
    string scope="",descriptorKey="",selected="all";
    Term[] catalogue=[];
    SourceDraft? draft;
    ProofPreview? preview;
    CancellationTokenSource? work;
    Task working=Task.CompletedTask,retired=Task.CompletedTask;
    long generation;
    bool authorized,editable,busy,loading,disposed,lens;
    public event Action? Changed;
    public string Content=>Editor?.Text??"";
    public string Status=>status.Text;
    public string? RetirementError { get; private set; }
    public int SnapshotReads { get; private set; }
    public bool CanEdit=>authorized&&editable&&!busy&&preview==null&&!Pending().Any();
    public Task Completion=>Task.WhenAll(working,retired);
    TextEdit? Editor=>form.Input("source") as TextEdit;
    OptionButton? Catalogue=>form.Input("predicate") as OptionButton;
    TextEdit? Results=>form.Input("results") as TextEdit;
    string Key=>scope+"\n"+selected;
    IEnumerable<SignedWork> Pending()=>store==null ? [] : store.Snapshot!.Pending.Where(w=>w.Network==session.Network && w.Flow.StartsWith(scope+"\n",StringComparison.Ordinal));
    public override void _Ready()
    {
        AddChild(status);AddChild(actions);AddChild(form);
        void Local(string name,string text,Action action){var b=new Button { Name=name,Text=text };actions.AddChild(b);b.Pressed+=action;}
        Local("source-reload","Reload saved source",()=>Run(()=>Read(false)));
        Local("source-discard","Discard local draft and reload",()=>Run(()=>Read(true)));
        form.Invoked+=role=>{
            if(role=="resolve"){Run(Resolve);return;}
            if(!authorized||!editable)return;
            if(role=="run")Run(Preview);
            if(role=="accept")Run(Accept);
            if(role=="stop")Run(Stop);
            if(role=="create")AddPredicate();
        };
    }
    public void Install(SignedSession session,Accounts accounts,LocalStore store,Subject subject,Eidolon choice,Term representation)
    {
        representation.Ground();bool nextLens=representation.Name=="lens_view";
        var a=representation.Require(nextLens ? "lens_view" : "workspace",5);
        int offset=nextLens ? 0 : 1;
        if(!nextLens && a[0].Name!="prolog_editor")throw new FormatException("Unsupported workspace controller.");
        if(a[offset].ToString()!=subject.Target.Ontology.ToString() || a[offset+1].ToString()!=subject.Local.ToString())throw new FormatException("Representation names another target or entity.");
        var tool=Subject.Decode(a[offset+2]).Target;
        if(tool.Namespace!=choice.Recipe.Namespace || tool.Anchor!=choice.Recipe.Anchor)throw new FormatException("Representation names another recipe owner.");
        string nextScope=string.Join("\n",session.Network,session.Key.PublicText,accounts.Human!.Entity,subject.Target.Ontology,tool.Ontology);
        string nextDescriptor=representation.ToString();
        if(authorized&&scope==nextScope&&descriptorKey==nextDescriptor)return;
        var tree=nextLens ? null : Component.Decode(a[4]);
        if(tree!=null)Validate(tree);
        Withdraw();this.session=session;this.accounts=accounts;this.store=store;target=subject.Target;tools=tool;
        if(scope!=nextScope){scope=nextScope;selected="all";draft=null;}
        bool same=descriptorKey==nextDescriptor;descriptorKey="";lens=nextLens;
        if(lens){authorized=true;editable=false;Run(()=>ReadLens(a[3],a[4],nextDescriptor),true);return;}
        if(!same)Build(tree!);
        editable=descriptor!.Leaves.Any(c=>c.Role=="accept") &&
            !descriptor.Leaves.Single(c=>c.Role=="source").Flag("readonly") && Editor!.GetMeta("offered_enabled").AsBool();
        descriptorKey=nextDescriptor;authorized=true;Run(()=>Read(false),true);
    }
    static void Validate(Component tree)
    {
        if(tree.Kind!="form" || tree.Leaves.SingleOrDefault(c=>c.Role=="source")?.Kind!="editor" || tree.Leaves.SingleOrDefault(c=>c.Role=="predicate")?.Kind!="catalogue_selection")throw new FormatException("Unsupported source workspace contract.");
    }
    void Build(Component tree)
    {
        Validate(tree);form.Present(tree);descriptor=tree;
        Catalogue!.ItemSelected+=i=>{if(busy||preview!=null||Pending().Any()||!authorized)return;selected=i==0 ? "all" : catalogue[(int)i-1].ToString();draft=null;Run(()=>Read(false));};
        Editor!.TextChanged+=()=>{
            if(loading||!CanEdit||draft==null)return;
            draft=draft with { Text=Editor.Text };
            try{Persist();}catch(Exception error){status.Text=error.Message;}Update();
        };
    }
    void Persist()
    {
        if(draft==null)return;var value=draft;string key=Key;
        store.Update(s=>{if(value.Text==value.Baseline)s.SourceDrafts.Remove(key);else s.SourceDrafts[key]=value;});
    }
    async Task Read(bool discard)
    {
        if(!authorized||preview!=null)return;
        if(Pending().Any()){status.Text="An original saved edit is pending. Check its outcome before editing; do not submit it again.";Reveal("resolve");return;}
        long expected=generation;var cancellation=work!.Token;var consumer=session;var actor=accounts.Human!;
        var owner=tools;var subject=target;var localStore=store;string key=Key,selection=selected,sourceScope=scope;bool mayEdit=editable;
        var reply=await consumer.Read(actor,SignedSession.ViewGoal(owner,Term.Call("prolog_predicates",subject.Ontology,Term.Variable("Predicates"))),cancellation);
        if(expected!=generation||!authorized||cancellation.IsCancellationRequested)return;
        var next=Json.Binding(reply,"Predicates");next.Ground();var catalogue=next.Items;
        var snapshot=localStore.Snapshot!;
        var local=(mayEdit ? snapshot.SourceDrafts.Keys.AsEnumerable() : Enumerable.Empty<string>()).Where(k=>k.StartsWith(sourceScope+"\n",StringComparison.Ordinal))
            .Select(k=>k[(sourceScope.Length+1)..]).Where(k=>k!="all").Select(Term.Parse);
        catalogue=catalogue.Concat(local).DistinctBy(c=>c.ToString()).ToArray();
        foreach(var indicator in catalogue){var p=indicator.Require("/",2);if(p[0].Kind!="atom"||p[1].Integer<0)throw new FormatException("Invalid predicate catalogue.");}
        if(!mayEdit && selection!="all" && !catalogue.Any(c=>c.ToString()==selection)){selection=selected="all";key=sourceScope+"\nall";}
        SnapshotReads++;
        string text=selection=="all" ? await consumer.ReadSource(actor,owner,subject,cancellation) :
            Json.Binding(await consumer.Read(actor,SignedSession.ViewGoal(owner,Term.Call("prolog_source",subject.Ontology,Term.Parse(selection),Term.Variable("Source"))),cancellation),"Source").TextValue;
        if(expected!=generation||!authorized||cancellation.IsCancellationRequested)return;
        var saved=snapshot.SourceDrafts.GetValueOrDefault(key);
        if(discard){localStore.Update(s=>s.SourceDrafts.Remove(key));saved=null;draft=null;}
        if(selection!="all"&&!catalogue.Any(c=>c.ToString()==selection))catalogue=[..catalogue,Term.Parse(selection)];
        this.catalogue=catalogue;Catalogue!.Clear();Catalogue.AddItem("Complete source");
        foreach(var indicator in catalogue)Catalogue.AddItem(indicator.Args[0]+"/"+indicator.Args[1]);
        Catalogue.Select(selection=="all" ? 0 : Array.FindIndex(catalogue,c=>c.ToString()==selection)+1);
        draft=mayEdit && saved!=null && saved.Text!=saved.Baseline ? saved : new(text,text);
        loading=true;Editor!.Text=draft.Text;loading=false;
        status.Text=mayEdit ? (draft.Baseline!=text ? "Saved source changed. Your original draft baseline is retained; reload/discard explicitly or inspect the guarded refusal." : "Local draft. Preview stages changes; Save changes explicitly accepts them.") : "Authorized read-only source. This grants no editing or spatial membership.";
    }
    async Task ReadLens(Term view,Term parameters,string nextDescriptor)
    {
        long expected=generation;var consumer=session;var actor=accounts.Human!;var owner=tools;var cancellation=work!.Token;
        var tree=Json.Binding(await consumer.Read(actor,SignedSession.ViewGoal(owner,Term.Call("gui_view",Term.Atom("prolog_source"),Term.Variable("Tree"))),cancellation),"Tree");
        if(expected!=generation||!authorized||cancellation.IsCancellationRequested)return;
        var text=await consumer.ReadSource(actor,SignedSession.ViewGoal(owner,Term.Call("view",view,parameters,Term.Variable("Rows"))),"Rows",cancellation);
        if(expected!=generation||!authorized||cancellation.IsCancellationRequested)return;
        Build(Component.Decode(tree));descriptorKey=nextDescriptor;Catalogue!.Hide();loading=true;Editor!.Text=text;loading=false;
        status.Text="Authorized inspection · "+view.TextValue.Replace('_',' ')+". Exact committed data; read only.";
    }
    void AddPredicate()
    {
        if(!CanEdit || !form.Validate() || form.Input("new_predicate") is not LineEdit input)return;
        try {
            string value=input.Text;int slash=value.LastIndexOf('/');
            if(slash<1 || !System.Numerics.BigInteger.TryParse(value[(slash+1)..],out var arity)||arity<0)throw new FormatException("Use a predicate name/arity.");
            var name=Term.Parse(value[..slash]);if(name.Kind!="atom")throw new FormatException("Use an atom predicate name.");
            selected=Term.Call("/",name,Term.Number(arity.ToString())).ToString();draft=null;Run(()=>Read(false));
        }catch(Exception e){status.Text=e.Message;Changed?.Invoke();}
    }
    async Task Preview()
    {
        if(!authorized||draft==null||preview!=null||Pending().Any()||draft.Text==draft.Baseline)return;
        long expected=generation;var consumer=session;var actor=accounts.Human!;var cancellation=work!.Token;string key=Key;var submitted=draft;
        var compiled=Json.Binding(await consumer.Read(actor,SignedSession.ViewGoal(tools,
            Term.Call("prolog_edit_goal",target.Ontology,Term.Parse(selected),Term.Text(draft.Baseline),Term.Text(draft.Text),Term.Variable("Edit"))),cancellation),"Edit");
        if(expected!=generation||!authorized||cancellation.IsCancellationRequested)return;
        var made=await consumer.Preview(actor,compiled+".",key,submitted,cancellation);
        if(expected!=generation||!authorized||cancellation.IsCancellationRequested){await consumer.Stop(made);return;}
        preview=made;
        if(Results!=null)Results.Text=preview.Reply.ToJsonString();
        status.Text="Preview staged. Nothing committed. Save changes once, or Cancel preview.";
        Reveal("accept");
    }
    async Task Accept()
    {
        if(!authorized||preview==null||Pending().Any())return;
        var original=preview;preview=null;var consumer=session;long expected=generation;
        var submitted=draft;var cancellation=work!.Token;
        var reply=await consumer.Accept(original,cancellation);
        if(expected!=generation||!authorized)return;
        if(Results!=null)Results.Text=reply.ToJsonString();
        if(Json.Committed(reply)){if(draft==submitted)draft=null;await Read(false);status.Text="Saved through the original guarded transaction; committed source read back.";}
        else status.Text=Json.Terminal(reply) ? "Edit did not commit. The original local draft is retained." : "Original saved edit is pending. Check its outcome; do not submit it again.";
    }
    async Task Stop()
    {long expected=generation;var consumer=session;var old=preview;preview=null;if(old!=null)await consumer.Stop(old);if(expected==generation)status.Text="Preview cancelled; local draft retained without commit.";}
    async Task Resolve()
    {
        long expected=generation;var consumer=session;var cancellation=work!.Token;
        foreach(var original in Pending().ToArray()) {
            var reply=await consumer.Resolve(original,cancellation);
            consumer.Finish(original,reply);
            if(expected!=generation||!authorized)return;
            if(Results!=null)Results.Text=reply.ToJsonString();
            status.Text=Json.Terminal(reply) ? "Original edit outcome resolved. Inspect saved source before starting another edit." : "Original edit remains unresolved. No write was resubmitted.";
        }
    }
    void Run(Func<Task> operation,bool replacement=false)
    {
        if(disposed||busy&&!replacement)return;
        ulong until=session.Deadline;if(preview!=null)until=Math.Min(until,preview.Deadline);
        ulong now=SignedSession.Now;
        if(until<=now){status.Text="Source operation expired; reconnect explicitly.";Changed?.Invoke();return;}
        var previous=working;work?.Cancel();busy=true;work=new(TimeSpan.FromMilliseconds(until-now));var running=work;long expected=generation;Update();
        async Task Execute(){try{await previous;if(expected==generation&&!running.IsCancellationRequested)await operation();}
            catch(Exception e){if(expected==generation&&!disposed)status.Text=e.Message;}
            finally{running.Dispose();if(ReferenceEquals(work,running)){work=null;busy=false;}if(!disposed)Update();}}
        working=Execute();
    }
    void Update()
    {
        if(Editor!=null)Editor.Editable=CanEdit&&!lens;
        if(Catalogue!=null)Catalogue.Disabled=!authorized||busy||preview!=null||Pending().Any();
        foreach(string role in new[]{"run","accept","stop","create","resolve"})if(form.Input(role) is Button button)button.Disabled=!authorized||busy||!button.GetMeta("offered_enabled").AsBool()||
            role=="run"&&(draft==null||draft.Text==draft.Baseline)||
            (role=="resolve" ? !Pending().Any() : !editable||Pending().Any()||(role=="accept"||role=="stop" ? preview==null : preview!=null));
        foreach(var button in actions.GetChildren().OfType<Button>())button.Disabled=!authorized||busy||preview!=null||Pending().Any()||lens;
        Changed?.Invoke();
    }
    void Reveal(string role)
    {long expected=generation;if(form.Input(role) is Control control)SpatialGui.Reveal(control,()=>!disposed&&authorized&&generation==expected);}
    public void Withdraw()
    {
        generation++;authorized=false;work?.Cancel();
        var old=preview;preview=null;
        if(old!=null){var consumer=session;async Task Close(){try{await consumer.Stop(old);}catch(Exception e){RetirementError=e.GetType().Name;}}retired=Task.WhenAll(retired,Close());}
        if(Editor!=null){loading=true;Editor.Text="";loading=false;}if(Results!=null)Results.Text="";
        Update();
    }
    public void DisposeView(){if(disposed)return;Withdraw();disposed=true;}
    public override void _ExitTree()=>DisposeView();
}
