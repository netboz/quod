using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks {
 async Task SceneAllowanceChecks() {
  await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
  await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
  var human=app.ActiveAccounts.Human!;var gui=app.ActiveAccounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
  var marks=Term.List(Enumerable.Repeat(Term.Atom("invalid_mark"),513).ToArray());
  var reply=await app.ActiveSession.Read(human,SignedSession.ViewGoal(gui,Term.Call("well_formed_scene",marks)),CancellationToken.None);
  Check(!Json.Committed(reply)&&reply.ToJsonString().Contains("scene_mark_allowance"),"scene owner reports its existing mark policy allowance before validating individual marks");
  await Press("disconnect");await app.ViewsDisposed;
  await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
  Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
 }
}
