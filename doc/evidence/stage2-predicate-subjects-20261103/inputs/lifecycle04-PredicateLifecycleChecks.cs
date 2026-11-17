using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks
{
    async Task PredicateLifecycleChecks()
    {
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
        var human=app.ActiveAccounts.Human!;var identity=human.Ontology.Require("ontology_ref",2);
        string originalAccount=app.ActiveAccounts.Setup!.ToString(),originalLocation=State["current_location"]!.ToString();
        Term Indicator(string name)=>Term.Call("/",Term.Atom(name),Term.Number("2"));
        Term Predicate(string name)=>Term.Call("predicate_ref",identity[0],identity[1],Indicator(name));
        async Task Commit(string goal,string label)=>Check(Json.Committed(await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,goal,CancellationToken.None)),label);
        async Task<string> Saved(string name) {
            var tools=app.ActiveAccounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
            return Json.Binding(await app.ActiveSession.Read(human,SignedSession.ViewGoal(tools,Term.Call("prolog_source",human.Ontology,Indicator(name),Term.Variable("Source"))),CancellationToken.None),"Source").TextValue;
        }
        await Commit("transaction((assertz(predicate_lifecycle(a,first)),assertz(predicate_lifecycle(a,second)))).","actual owner creates the displayed two-clause predicate");
        await Press("inspect");var pane=(EidolonPanel)app.FindChild("representations",true,false);
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        pane.Changed+=()=>Console.WriteLine("PREDICATE_PRIVATE_STATUS "+System.Text.Json.JsonSerializer.Serialize(new{pane.StatusText,pane.Available,source=source.Status}));
        var exact=Predicate("predicate_lifecycle");pane.Open(app.ActiveSession,app.ActiveAccounts,app.ActiveStore,exact);
        await Until(()=>pane.Available&&source.CanEdit&&source.Content.Contains("predicate_lifecycle"));
        string baseline=await Saved("predicate_lifecycle");
        Check(source.Content==baseline,"currently selected predicate displays its own committed clauses before reconnect");
        var form=(FormPanel)source.FindChild("source-form",true,false);var editor=(TextEdit)form.Input("source")!;
        const string draft="predicate_lifecycle(a,local).\n";editor.Text=draft;editor.EmitSignal(TextEdit.SignalName.TextChanged);
        var savedDraft=app.ActiveStore.Snapshot!.SourceDrafts.Single(d=>d.Value.Text==draft);
        Check(savedDraft.Value.Baseline==baseline,"local predicate draft retains the actual committed baseline");
        var oldSession=app.ActiveSession;
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&source.Content.Length==0&&!source.CanEdit,"disconnect retires the old predicate consumers and withdraws source authority");
        await Press("connect");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&pane.Available&&source.CanEdit&&source.Content==draft);
        Check(!ReferenceEquals(oldSession,app.ActiveSession)&&pane.Current!.Exact.ToString()==exact.ToString(),"ordinary reconnect restores the same exact authorized predicate in a new signed session");
        Check(app.ActiveAccounts.Human==human&&app.ActiveAccounts.Setup!.ToString()==originalAccount&&State["current_location"]!.ToString()==originalLocation,"predicate reconnect preserves U A storage and exclusive containing-space assignment");
        Check(app.ActiveStore.Snapshot!.SourceDrafts[savedDraft.Key]==savedDraft.Value&&await Saved("predicate_lifecycle")==baseline,"reconnect preserves draft and original guard without committing or replaying it");
        await Commit("transaction(abolish(predicate_lifecycle/2)).","actual owner commits abolish of the currently displayed editable predicate");
        var tool=app.ActiveAccounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        var catalogue=Json.Binding(await app.ActiveSession.Read(human,SignedSession.ViewGoal(tool,Term.Call("prolog_predicates",human.Ontology,Term.Variable("Predicates"))),CancellationToken.None),"Predicates");
        var currentSource=await Saved("predicate_lifecycle");
        var currentChoices=Json.Binding(await app.ActiveSession.Read(human,SignedSession.ViewGoal(human,Term.Call("entity_eidolons",exact,Term.Variable("View"))),CancellationToken.None),"View");
        var deletionObservation=new{catalogue_retains_name=catalogue.Items.Any(i=>i.ToString()==Indicator("predicate_lifecycle").ToString()),stored_source_bytes=System.Text.Encoding.UTF8.GetByteCount(currentSource),current_choice_count=currentChoices.Items.Length};
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".deletion.json",System.Text.Json.JsonSerializer.Serialize(deletionObservation));
        Check(currentSource.Length==0,"signed committed source confirms abolish removed all displayed clauses");
        Check(currentChoices.Items.Length==0,"abolished predicate definition withdraws signed source choices");
        Check(!deletionObservation.catalogue_retains_name,"shared source catalogue excludes the abolished definition");
        await Until(()=>pane.Available&&pane.Offered.Length==0&&source.Content.Length==0);
        Check(!source.CanEdit&&pane.Current!.Exact.ToString()==exact.ToString(),"committed deletion withdraws the displayed predicate editor instead of showing complete source");
        Check(app.ActiveStore.Snapshot!.SourceDrafts[savedDraft.Key]==savedDraft.Value,"withdrawal preserves the private unsent draft without making it an authorized predicate");
        var absent=await app.ActiveSession.Read(human,SignedSession.ViewGoal(human,Term.Call("entity_eidolons",exact,Term.Variable("View"))),CancellationToken.None);
        Check(Json.Committed(absent)&&Json.Binding(absent,"View").Items.Length==0,"deleted predicate is absent from signed current subject discovery");
        pane.Open(app.ActiveSession,app.ActiveAccounts,app.ActiveStore,human.Ontology);await Until(()=>pane.Available&&source.CanEdit&&pane.Current!.Exact.Name=="ontology_ref");
        form=(FormPanel)source.FindChild("source-form",true,false);var drafts=(OptionButton)form.Input("predicate")!;
        int draftIndex=Enumerable.Range(1,drafts.ItemCount-1).Single(i=>drafts.GetItemText(i)=="predicate_lifecycle/2");
        drafts.Select(draftIndex);drafts.EmitSignal(OptionButton.SignalName.ItemSelected,(long)draftIndex);await source.Completion;
        Check(pane.Current!.Exact.Name=="ontology_ref"&&source.Content==draft&&app.ActiveStore.Snapshot!.SourceDrafts[savedDraft.Key]==savedDraft.Value,"unpublished retained draft remains editable through its existing ontology workspace without inventing a current predicate subject");
        await Commit("transaction((assertz(predicate_readonly(a,first)),assertz(predicate_readonly(a,second)),abolish(ontology_source_mode/1),assertz(ontology_source_mode(read_only)))).","ordinary owner creates a distinct predicate and selects the existing read-only presentation mode");
        var readonlyExact=Predicate("predicate_readonly");pane.Open(app.ActiveSession,app.ActiveAccounts,app.ActiveStore,readonlyExact);
        await Until(()=>pane.Available&&source.Content.Contains("predicate_readonly"));
        Check(!source.CanEdit&&source.Content==await Saved("predicate_readonly"),"read-only exact predicate is displayed before its independent deletion");
        await Commit("transaction(abolish(predicate_readonly/2)).","authorized owner abolishes the currently displayed read-only predicate");
        await Until(()=>pane.Available&&pane.Offered.Length==0&&source.Content.Length==0);
        Check(!source.CanEdit&&pane.Current!.Exact.ToString()==readonlyExact.ToString(),"read-only deletion withdraws the selected consumer without the whole-ontology fallback");
        Check(State["current_location"]!.ToString()==originalLocation&&!app.ActiveStore.Snapshot!.Pending.Any(),"predicate deletions leave location unchanged with no uncertain operation replay");
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0,"follow-up predicate consumers retire through the existing disconnect owner");
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
        Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
    }
}
