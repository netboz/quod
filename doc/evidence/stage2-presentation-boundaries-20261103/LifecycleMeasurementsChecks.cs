using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks {
 async Task LifecycleMeasurementsChecks() {
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
  pane.Open(app.ActiveSession,app.ActiveAccounts,app.ActiveStore,owner.Ontology);
  await Until(()=>pane.Available&&pane.Preview.SubjectIds(Predicate("sample")).Length==1);
  Check(pane.Selected!.Style=="contents"&&pane.Preview.Count==indicators.Length*2&&indicators.All(ind=>pane.Preview.SubjectIds(Term.Call("entity_ref",ids[0],ids[1],Term.Call("predicate",ind))).Length==1),"whole ontology uses ordinary contents composition without an authored space bundle or client domain dispatch");
  var label=pane.Preview.SubjectLabel(Predicate("sample"));
  Check(label!=null&&label.Contains("sample")&&label.Contains("2"),"predicate name and arity are an ordinary Prolog-authored visual label");
  Term Missing(string name,int arity)=>Term.Call("\\+",Term.Call("current_predicate",Term.Call("/",Term.Atom(name),Term.Number(arity.ToString()))));
  var absent=new[]{Missing("space_place",3),Missing("space_accept_placement",3),Missing("space_change_physics",3),Term.Call("\\+",Term.Call("class_eidolon",Term.Atom("space"),Term.Call("operation",Term.Atom("instance")),Term.Atom("enter"),Term.Variable("_")))}.Aggregate((left,right)=>Term.Call(",",left,right));
  var mutations=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,absent),CancellationToken.None);
  Check(Json.Committed(mutations),"reflection without the space bundle gains no assignment admission physical-transition or entry recipe implementation");
  var longSubject=Term.Call("entity_ref",ids[0],ids[1],Term.Call("predicate",Term.Call("/",Term.Atom("predicate_with_a_complete_long_descriptive_name"),Term.Number("2"))));
  var longLabel=pane.Preview.SubjectLabel(longSubject);
  Check(longLabel!=null&&longLabel=="predicate_with_a_complete_long_descriptive_name / 2"&&pane.Preview.SubjectIds(longSubject).Length==1,"complete long label retains exact full predicate identity");
  int count=pane.Preview.Count;var occurrence=pane.Preview.SubjectIds(Predicate("sample")).Single();var pose=pane.Preview.WorldPose(occurrence);
  var pick=pane.Preview.PickRay(pose.Origin+new Vector3(0,0,3),Vector3.Forward);
  Check(pick?.Subject.ToString()==Predicate("sample").ToString(),"native picking selects a predicate from actual full ontology contents");
  var view=(SignedView)typeof(EidolonPanel).GetField("representation",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance)!.GetValue(pane)!;
  int rebuilt=pane.Preview.Rebuilt;
  // Separate observations retain each original30s window and the driver180s deadline.
  // The earlier aggregate3-renewals-in30s failure remains a separate failed campaign.
  var originalView=view;
  for(int i=0;i<3;i++) {
   using var probe=new System.Net.Sockets.TcpClient();
   using var stop=new CancellationTokenSource(TimeSpan.FromSeconds(30));
   await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),stop.Token);
   using var stream=probe.GetStream();using var reader=new System.IO.StreamReader(stream);
   await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),stop.Token);
   Check(System.Text.Json.Nodes.JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!["ready"]!.GetValue<bool>(),"observation "+i+" precedes its renewal");
   view=(SignedView)typeof(EidolonPanel).GetField("representation",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance)!.GetValue(pane)!;
   Check(ReferenceEquals(view,originalView),"observation "+i+" keeps the same retained consumer");
   var received=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
   void Got(System.Text.Json.Nodes.JsonNode _) {Console.WriteLine("CONTENTS_RENEWAL_RECEIPT "+i);received.TrySetResult();}
   void Lost(string reason) {Console.WriteLine("CONTENTS_RENEWAL_WITHDRAWN "+reason);received.TrySetException(new Exception(reason));}
   view.Projection+=Got;view.Withdrawn+=Lost;var watch=System.Diagnostics.Stopwatch.StartNew();
   try{await view.Renew();await received.Task.WaitAsync(stop.Token);}finally{view.Projection-=Got;view.Withdrawn-=Lost;Console.WriteLine("RENEWAL_MS "+watch.ElapsedMilliseconds);}
   await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),stop.Token);
   var work=System.Text.Json.Nodes.JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!;
   await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".work-"+i+".json",work.ToJsonString());Console.WriteLine("RENEWAL_WORK "+work.ToJsonString());
   Check(work["work"]!["calls"]!.AsArray().Count==0&&pane.Preview.Rebuilt==rebuilt,"observation "+i+" reuses geometry with zero watched history rebuild write or sync work");
  }
  async Task Commit(string body,string label) {
   string goal="in_ontology("+ids[0]+","+ids[1]+",transaction(("+body+"))).";
   Check(Json.Committed(await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,goal,CancellationToken.None)),label);
  }
  await Commit("assertz(added_predicate(a,b))","real owner commits a new predicate through the existing transaction");
  await Until(()=>pane.Preview.SubjectIds(Predicate("added_predicate")).Length==1);
  Check(pane.Preview.Count==count+2&&pane.Preview.SubjectIds(Predicate("sample")).Single()==occurrence,"real catalogue update adds its ordinary occurrence and preserves existing occurrence identity");
  string self=Term.Call("entity_ref",ids[0],ids[1],owner.Ontology).ToString();
  int beforeCycle=pane.Preview.Rebuilt;
  await Commit("assertz(space_member("+owner.Ontology+","+self+"))","owner authors a normal display cycle without an assignment");
  await Until(()=>pane.Available&&pane.Preview.Rebuilt>beforeCycle&&pane.Preview.SubjectIds(Predicate("sample")).Length==1);
  var cycleReply=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,Term.Call("space_projection",owner.Ontology,Term.Atom("playing"),Term.Variable("View"))),CancellationToken.None);
  var exposures=Json.Binding(cycleReply,"View").Require("scene",2)[1];
  Check(exposures.Items.Any(x=>x.Args[^1].Name=="cycle")&&pane.Preview.SubjectIds(Predicate("sample")).Length==1,"ontology display cycles terminate through the unchanged recursive exposure owner");
  var stale=pane.Selected!;
  await Commit("retract((can_invoke(G,P,C,N):-composition_owner(P))),assertz((can_invoke(G,P,C,N):-composition_owner(P),\\+blocked_source(G))),assertz(blocked_source((current_ontology_identity(_,_),prolog_introspection(_,_))))","source policy revokes the visible full contents");
  await Until(()=>pane.Preview.Count==0&&pane.StatusText.StartsWith("Unavailable"));
  var refused=await app.ActiveSession.Read(human,SignedSession.ViewGoal(owner,stale.Read(owner.Ontology)),CancellationToken.None);
  Console.WriteLine("STALE_CONTENTS_REPLY "+refused.ToJsonString());
  Check(Json.Terminal(refused)&&!Json.Committed(refused),"stale selected contents cannot bypass target source denial");
  await Commit("retract(blocked_source((current_ontology_identity(_,_),prolog_introspection(_,_))))","owner restores original source permission");
  await Until(()=>pane.Available&&pane.Preview.SubjectIds(Predicate("sample")).Length==1);
  await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"ontology scene disconnect retires every consumer");
  await Press("connect");await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&pane.Available&&pane.Preview.SubjectIds(Predicate("sample")).Length==1);
  Check(pane.Current!.Exact.ToString()==owner.Ontology.ToString()&&State["current_location"]!.ToString()==location,"reconnect restores the exact ontology display with unchanged A containing space");
  await Press("disconnect");await app.ViewsDisposed;
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
