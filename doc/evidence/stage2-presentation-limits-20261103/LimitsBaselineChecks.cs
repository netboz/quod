using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks {
 async Task LimitsBaselineChecks() {
  await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
  await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
  var human=app.ActiveAccounts.Human!;
  var made=await SpaceControl(new(){["composition_target"]=new System.Text.Json.Nodes.JsonObject{["namespace"]=human.Namespace,["anchor"]=human.Anchor}});
  var owner=new Actor(Json.S(made,"namespace"),Json.S(made,"anchor"),"me.");
  var counts=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,Term.Call("ontology_predicates",Term.Variable("View"))),CancellationToken.None);
  int count=Json.Binding(counts,"View").Items.Length;Check(count*2>512,"complete authoritative catalogue requires more than 512 ordinary marks");
  var indicator=Term.Call("/",Term.Atom("predicate_with_a_complete_long_descriptive_name"),Term.Number("2"));
  var model=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,Term.Call("eidolon",Term.Atom("predicate_model"),Term.Call("predicate",indicator),Term.Variable("View"))),CancellationToken.None);
  string label=Json.Binding(model,"View").Items[0].Require("part",6)[4].Require("label",2)[0].TextValue;
  bool fullLabel=label.Contains("predicate_with_a_complete_long_descriptive_name");
  string sceneResult;bool fullScene=false;
  try {var reply=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,Term.Call("space_projection",owner.Ontology,Term.Atom("playing"),Term.Variable("View"))),CancellationToken.None);
   sceneResult=reply.ToJsonString();if(Json.Committed(reply))fullScene=Json.Binding(reply,"View").Require("scene",2)[0].Items.Length==count*2;
  }catch(Exception ex){sceneResult=ex.GetType().FullName+": "+ex.Message;}
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".observations.json",System.Text.Json.JsonSerializer.Serialize(new{count,marks=count*2,label,fullLabel,fullScene,sceneResult}));
  Console.WriteLine("PRESENTATION_BASELINE "+System.Text.Json.JsonSerializer.Serialize(new{count,marks=count*2,label,fullLabel,fullScene}));
  await Press("disconnect");await app.ViewsDisposed;
  Check(fullLabel&&fullScene,"full contents and complete authored label must both survive the shared presentation owner");
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
