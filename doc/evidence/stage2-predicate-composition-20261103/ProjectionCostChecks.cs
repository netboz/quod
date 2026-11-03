using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks {
 async Task ProjectionCostChecks() {
  await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
  await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
  var human=app.ActiveAccounts.Human!;string location=State["current_location"]!.ToString();
  var made=await SpaceControl(new(){["composition_target"]=new System.Text.Json.Nodes.JsonObject{["namespace"]=human.Namespace,["anchor"]=human.Anchor}});
  var owner=new Actor(Json.S(made,"namespace"),Json.S(made,"anchor"),"me.");var ids=owner.Ontology.Args;
  Term Predicate(string name)=>Term.Call("entity_ref",ids[0],ids[1],Term.Call("predicate",Term.Call("/",Term.Atom(name),Term.Number("2"))));
  foreach(int n in new[]{1,10,50}) {
   using var stop=new CancellationTokenSource(TimeSpan.FromSeconds(30));using var probe=new System.Net.Sockets.TcpClient();
   await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),stop.Token);using var stream=probe.GetStream();using var reader=new System.IO.StreamReader(stream);
   await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure_catalogue\":true}\n"),stop.Token);await reader.ReadLineAsync(stop.Token);
   var exposure=Term.Call("exposure",Term.Variable("Frame"),Term.Variable("Revision"),Term.Variable("Subjects"));
   var subset=Term.Call("exposure",Term.Variable("Frame"),Term.Variable("Revision"),Term.Variable("Subset"));
   var goals=new[]{Term.Call("space_contents_projection",owner.Ontology,exposure),Term.Call("length",Term.Variable("Subset"),Term.Number(n.ToString())),Term.Call("append",Term.Variable("Subset"),Term.Variable("Rest"),Term.Variable("Subjects")),Term.Call("space_exposure_projection",subset,Term.Atom("playing"),Term.Variable("Marks"),Term.Variable("Exposures")),Term.Call("length",Term.Variable("Marks"),Term.Variable("View"))};
   var timer=System.Diagnostics.Stopwatch.StartNew();var reply=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,goals.Aggregate((l,r)=>Term.Call(",",l,r))),CancellationToken.None);
   await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),stop.Token);var work=(await reader.ReadLineAsync(stop.Token))!;
   await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".subset-"+n+".json",reply.ToJsonString());await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".work-"+n+".json",work);
   Console.WriteLine("PASS observation subset="+n+" ms="+timer.ElapsedMilliseconds+" counts="+work);
   Check(Json.Committed(reply),"local signed subset "+n);Check(Json.Binding(reply,"View").Integer==n*2,"each normal occurrence contributes its group and labelled geometry "+n);
  }
  await Press("disconnect");await app.ViewsDisposed;
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
