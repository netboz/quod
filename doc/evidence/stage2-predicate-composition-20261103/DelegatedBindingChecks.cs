using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks {
 async Task DelegatedBindingChecks() {
  await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
  await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
  var human=app.ActiveAccounts.Human!;string location=State["current_location"]!.ToString();
  var made=await SpaceControl(new(){["composition_target"]=new System.Text.Json.Nodes.JsonObject{["namespace"]=human.Namespace,["anchor"]=human.Anchor}});
  var owner=new Actor(Json.S(made,"namespace"),Json.S(made,"anchor"),"me.");var ids=owner.Ontology.Args;
  Term Predicate(string name)=>Term.Call("entity_ref",ids[0],ids[1],Term.Call("predicate",Term.Call("/",Term.Atom(name),Term.Number("2"))));
  async Task Commit(string body,string label) {
   string goal="in_ontology("+ids[0]+","+ids[1]+",transaction(("+body+"))).";
   Check(Json.Committed(await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,goal,CancellationToken.None)),label);
  }
  await Commit("assertz(isa(source_note,thing)),assertz((instance_of(source_note,document):-true)),"+
   "assertz((class_eidolon(source_note,prolog,source,recipe(N,A,note_source)):-current_ontology_identity(N,A))),"+
   "assertz((eidolon(note_source,subject(T,document),V):-quod:root::system_ontology(<<\"quod:gui\">>,A),in_ontology(<<\"quod:gui\">>,A,eidolon(prolog_editor(sample/2),subject(T,document),V))))","ordinary non-predicate class authors a delegated fixed source workspace");
  await Press("inspect");var pane=(EidolonPanel)app.FindChild("representations",true,false);var source=(SourcePanel)pane.FindChild("source-tools",true,false);
  var exact=Term.Call("entity_ref",ids[0],ids[1],Term.Atom("document"));pane.Open(app.ActiveSession,app.ActiveAccounts,app.ActiveStore,exact);
  await Until(()=>pane.Available&&source.CanEdit&&source.Content.Contains("sample"));
  var choice=pane.Selected!;var reply=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,choice.Read(Term.Atom("document"))),CancellationToken.None);
  var workspace=Json.Binding(reply,"View").Require("workspace",5);
  Check(workspace[1].ToString()==owner.Ontology.ToString()&&workspace[2].Name=="document"&&workspace[3].ToString()!=choice.Recipe.Ontology.ToString(),"signed class-local recipe delegates to a different exact tool owner while preserving target and subject");
  await Commit("retract((can_invoke(G,P,C,N):-composition_owner(P))),assertz((can_invoke(G,P,C,N):-composition_owner(P),\\+blocked_source(G))),assertz(blocked_source((current_ontology_identity(_,_),prolog_introspection(_,_))))","target commits source-only denial through its existing owner policy");
  await Until(()=>!source.CanEdit&&source.Content.Length==0);
  var refused=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,choice.Read(Term.Atom("document"))),CancellationToken.None);
  Check(Json.Terminal(refused)&&!Json.Committed(refused),"delegated signed workspace cannot bypass exact target source denial and stale choice is refused");
  await Commit("retract(blocked_source((current_ontology_identity(_,_),prolog_introspection(_,_))))","owner restores only the original source admission");
  await Until(()=>pane.Available&&source.CanEdit&&source.Content.Contains("sample"));
  Check(pane.Current!.Exact.ToString()==exact.ToString()&&State["current_location"]!.ToString()==location,"restored delegated source binding keeps the ordinary subject and A location");
  await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"delegated source consumers retire normally");
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
