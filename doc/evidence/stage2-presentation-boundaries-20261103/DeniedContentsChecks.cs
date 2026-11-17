using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks {
 async Task DeniedContentsChecks() {
  await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
  await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
  var human=app.ActiveAccounts.Human!;string location=State["current_location"]!.ToString();
  var made=await SpaceControl(new(){["composition_target"]=new System.Text.Json.Nodes.JsonObject{["namespace"]=human.Namespace,["anchor"]=human.Anchor}});
  var owner=new Actor(Json.S(made,"namespace"),Json.S(made,"anchor"),"me.");var ids=owner.Ontology.Args;
  Term Predicate(string name)=>Term.Call("entity_ref",ids[0],ids[1],Term.Call("predicate",Term.Call("/",Term.Atom(name),Term.Number("2"))));

  var choices=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,Term.Call("entity_eidolons",owner.Ontology,Term.Variable("View"))),CancellationToken.None);
  var selected=Eidolon.Decode(Json.Binding(choices,"View").ToString()).Single(e=>e.Purpose.Name=="playing"&&e.Style=="contents");
  string body="assertz((instance_of(space,empty_ordinary):-true)),retract((can_invoke(G,P,C,N):-composition_owner(P))),assertz((can_invoke(G,P,C,N):-composition_owner(P),\\+blocked_source(G))),assertz(blocked_source((current_ontology_identity(_,_),prolog_introspection(_,_))))";
  string goal="in_ontology("+ids[0]+","+ids[1]+",transaction(("+body+"))).";
  Check(Json.Committed(await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,goal,CancellationToken.None)),"owner revokes source through existing signed action");
  var refused=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,selected.Read(owner.Ontology)),CancellationToken.None);
  Console.WriteLine("STALE_CONTENTS_REPLY "+refused.ToJsonString());
  Check(Json.Terminal(refused)&&!Json.Committed(refused),"source-denied selected contents refuse rather than become empty success");
  var interior=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,Term.Call("space_projection",owner.Ontology,Term.Atom("playing"),Term.Variable("View"))),CancellationToken.None);
  Check(Json.Terminal(interior)&&!Json.Committed(interior),"ordinary interior uses the same source-authorized class contents recipe");
  var empty=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,Term.Call("space_projection",Term.Atom("empty_ordinary"),Term.Atom("playing"),Term.Variable("View"))),CancellationToken.None);
  Check(Json.Committed(empty)&&Json.Binding(empty,"View").Require("scene",2).All(x=>x.Items.Length==0),"authorized ordinary empty space remains an empty successful scene");
  await Press("disconnect");await app.ViewsDisposed;
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
