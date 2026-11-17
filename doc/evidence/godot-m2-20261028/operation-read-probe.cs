using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
var old=JsonSerializer.Deserialize<LocalState>(File.ReadAllBytes(args[0]))!;
using var key=Identity.FromPayload(old.Payload);
using var store=new LocalStore(args[1]);store.Create(old.Payload);
using var session=new SignedSession(key,store,new Transport(args[2],args[3]));
using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(30));
await session.Authenticate(timeout.Token);
var human=old.Accounts.Single().Value.Human;
Console.WriteLine("READ_PRINCIPAL "+human.Entity+" TARGET "+human.Ontology);
var subject=human.Entity;
foreach(var goal in new[]{
 "findall(C,instance_of(C,me),Classes).",
 "controller_preferences_current(me,R,S),controller_preferences_basis(S,D,State).",
 "findall(E,class_eidolon(human_user,operation(instance),controller_settings,E),Recipes).",
 $"gui_operation_form({subject},controller_settings,Local,Recipe,Form).",
 $"gui_operations({subject},View)."}) {
 try { Console.WriteLine("READ_GOAL "+goal); Console.WriteLine((await session.Read(human,goal,timeout.Token)).ToJsonString()); }
 catch(Exception error) { Console.WriteLine("READ_ERROR "+error.GetType().Name+" "+error.Message); }
}
var done=new TaskCompletionSource();
using(var view=new SignedView(session,human,human,"gui_operations",SignedSession.ViewGoal(human,Term.Call("gui_operations",subject,Term.Variable("View"))))) {
 view.Projection+=m=>{Console.WriteLine("VIEW_PROJECTION "+m.ToJsonString());done.TrySetResult();};
 view.Withdrawn+=reason=>{Console.WriteLine("VIEW_WITHDRAWN "+reason);done.TrySetResult();};
 var completion=view.Start(); await done.Task.WaitAsync(timeout.Token); view.Dispose(); await completion;
}
Console.WriteLine("READ_PROBE_COMPLETE pending="+store.Snapshot!.Pending.Count);
