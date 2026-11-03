using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks {
 async Task SceneProfileChecks() {
  await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
  await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
  var human=app.ActiveAccounts.Human!;string location=State["current_location"]!.ToString();
  var made=await SpaceControl(new(){["composition_target"]=new System.Text.Json.Nodes.JsonObject{["namespace"]=human.Namespace,["anchor"]=human.Anchor}});
  var owner=new Actor(Json.S(made,"namespace"),Json.S(made,"anchor"),"me.");var ids=owner.Ontology.Args;
  Term Predicate(string name)=>Term.Call("entity_ref",ids[0],ids[1],Term.Call("predicate",Term.Call("/",Term.Atom(name),Term.Number("2"))));
  var catalogue=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,Term.Call("ontology_inspect",Term.Atom("predicates"),Term.Variable("View"))),CancellationToken.None);
  var indicators=Json.Binding(catalogue,"View").Items;
  Check(indicators.Length*2>512,"authoritative whole catalogue exceeds the retired scene ceiling");
  await Press("inspect");var pane=(EidolonPanel)app.FindChild("representations",true,false);
  using(var probe=new System.Net.Sockets.TcpClient()) {
   await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")));
   using var stream=probe.GetStream();using var reader=new System.IO.StreamReader(stream);
   await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"profile_renewal\":true}\n"));
   Check(System.Text.Json.Nodes.JsonNode.Parse((await reader.ReadLineAsync())!)!["ready"]!.GetValue<bool>(),"profile ready before initial scene proof");
   pane.Open(app.ActiveSession,app.ActiveAccounts,app.ActiveStore,owner.Ontology);
   var work=System.Text.Json.Nodes.JsonNode.Parse((await reader.ReadLineAsync())!)!;
   await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".work.json",work.ToJsonString());
   Console.WriteLine("INITIAL_SCENE_PROFILE "+work.ToJsonString());
   Console.WriteLine("INITIAL_SCENE_AVAILABLE "+pane.Available);
  }
  await Press("disconnect");await app.ViewsDisposed;
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,diagnosticOnly=true,initialSceneOnly=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
