using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks {
 async Task CompositionProbe() {
  await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
  await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
  var human=app.ActiveAccounts.Human!;var gui=app.ActiveAccounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
  async Task<Term> Read(Actor owner,Term goal,string label) {
   var timer=System.Diagnostics.Stopwatch.StartNew();var reply=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,goal),CancellationToken.None);
   Console.WriteLine("PASS observation "+label+" ms="+timer.ElapsedMilliseconds+" committed="+Json.Committed(reply));
   Check(Json.Committed(reply),label);return Json.Binding(reply,"View");
  }
  var catalogue=await Read(gui,Term.Call("prolog_predicates",human.Ontology,Term.Variable("View")),"catalogue");
  Console.WriteLine("PASS observation catalogue_count="+catalogue.Items.Length);
  var exposure=await Read(human,Term.Call("space_contents_projection",human.Ontology,Term.Variable("View")),"contents exposure");
  Console.WriteLine("PASS observation exposure_count="+exposure.Args[2].Items.Length);
  var local=Term.Call("predicate",Term.Call("/",Term.Atom("isa"),Term.Number("2")));
  await Read(human,Term.Call("entity_scene",local,Term.Atom("playing"),Term.Variable("View")),"single entity scene");
  await Read(human,Term.Call("eidolon",Term.Atom("predicate_model"),local,Term.Variable("View")),"single model");
  foreach(int count in new[]{1,10,50}) {
   var subset=Term.Call("exposure",exposure.Args[0],exposure.Args[1],Term.List(exposure.Args[2].Items.Take(count).ToArray()));
   var call=Term.Call(",",Term.Call("space_exposure_projection",subset,Term.Atom("playing"),Term.Variable("Marks"),Term.Variable("Exposures")),Term.Call("length",Term.Variable("Marks"),Term.Variable("View")));
   var projected=await Read(human,call,"projection subset "+count);Console.WriteLine("PASS observation marks="+projected);
  }
  var full=await app.ActiveSession.Read(human,SignedSession.ViewGoal(human,Term.Call("space_projection",human.Ontology,Term.Atom("playing"),Term.Variable("View"))),CancellationToken.None);
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".full-projection.json",full.ToJsonString());
  Check(!Json.Committed(full)&&full.ToJsonString().Contains("scene_mark_allowance"),"full ontology projection identifies the existing scene mark policy limit");
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
