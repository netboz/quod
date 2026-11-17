using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks {
 async Task LabelChecks() {
  await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
  await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
  var human=app.ActiveAccounts.Human!;string location=State["current_location"]!.ToString();
  var made=await SpaceControl(new(){["composition_target"]=new System.Text.Json.Nodes.JsonObject{["namespace"]=human.Namespace,["anchor"]=human.Anchor}});
  var owner=new Actor(Json.S(made,"namespace"),Json.S(made,"anchor"),"me.");var ids=owner.Ontology.Args;
  Term Predicate(string name)=>Term.Call("entity_ref",ids[0],ids[1],Term.Call("predicate",Term.Call("/",Term.Atom(name),Term.Number("2"))));
  async Task Read(Term goal,string label) {
   var timer=System.Diagnostics.Stopwatch.StartNew();var reply=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,goal),CancellationToken.None);
   await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+"."+label+".json",reply.ToJsonString());
   Check(Json.Committed(reply),label);
   Console.WriteLine("PASS observed "+label+" ms="+timer.ElapsedMilliseconds+" value="+Json.Binding(reply,"View"));
  }
  await Read(Term.Call("$quod_program_source",Term.List(Term.Call("/",Term.Atom("sample"),Term.Number("2"))),Term.Variable("View")),"format");
  await Read(Term.Call("eidolon",Term.Atom("predicate_model"),Term.Call("predicate",Term.Call("/",Term.Atom("sample"),Term.Number("2"))),Term.Variable("View")),"model");
  await Read(Term.Call(",",Term.Call("ontology_predicates",Term.Variable("Indicators")),Term.Call("length",Term.Variable("Indicators"),Term.Variable("View"))),"catalogue-count");
  var first=Term.Call(",",Term.Call("ontology_predicates",Term.Variable("Indicators")),Term.Call("append",Term.List(Term.Variable("Indicator")),Term.Variable("Rest"),Term.Variable("Indicators")));
  await Read(Term.Call(",",first,Term.Call("$quod_program_source",Term.List(Term.Variable("Indicator")),Term.Variable("View"))),"first-format");
  await Read(Term.Call(",",first,Term.Call("eidolon",Term.Atom("predicate_model"),Term.Call("predicate",Term.Variable("Indicator")),Term.Variable("View"))),"first-model");
  await Press("disconnect");await app.ViewsDisposed;
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
