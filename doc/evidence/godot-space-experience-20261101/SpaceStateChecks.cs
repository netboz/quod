using Godot;
using Quod.Client;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

// Finite metadata/denial checks through the same signed owners. All writes are
// explicit authorized changes in this disposable account, never UI selection.
public partial class ExportChecks
{
    async Task SpaceState()
    {
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&!Busy);
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;var store=app.ActiveStore;
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        var title=(Label)app.FindChild("current-place-title",true,false);
        var contents=(Label)app.FindChild("contents-status",true,false);
        var placed=Term.Parse(State["current_location"]!.ToString());var exact=placed.Args[0];var target=Actor.FromTerm(exact);
        string entity=target.InstanceText.TrimEnd('.'),location=State["current_location"]!.ToString();
        SignedView World()=>(SignedView)typeof(Main).GetField("worldView",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(app)!;
        var seen=new List<object>();void Projection(JsonNode value)=>seen.Add(new{name=value["name"]?.ToString(),height=value["height"]?.ToString(),target=value["target"]?.ToString()});
        World().Projection+=Projection;
        async Task Edit(string goal){using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(60));Check(Json.Committed(await ExecuteComplete(session,store,human,goal,limit.Token)),"explicit authorized fixture source change committed");}
        async Task FreshWorld(){var view=World();var installed=new TaskCompletionSource();void Accepted(JsonNode _)=>installed.TrySetResult();view.Projection+=Accepted;try{await view.Renew();await installed.Task.WaitAsync(TimeSpan.FromSeconds(60));}finally{view.Projection-=Accepted;}}
        await Edit($"transaction((retract(attribute({entity},name,<<\"Space\">>)),assertz(attribute({entity},name,<<\"Reading room\">>)))).");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&title.Text=="Current space · Reading room");
        Check(State["current_location"]!.ToString()==location&&scene.Count==0,"actual committed name refresh preserves exact location and empty interior");
        await Edit($"retract(attribute({entity},name,<<\"Reading room\">>)).");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&title.Text=="Current space");
        Check(!title.Text.Contains(target.InstanceText)&&contents.Text=="No visible contents in this space.","missing authored name is explicit absence, never an invented identifier or denied view");
        await Edit($"assertz(attribute({entity},name,17)).");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==false&&contents.Text.Contains("unavailable",StringComparison.OrdinalIgnoreCase));
        Check(!scene.Visible&&scene.Count==0&&!contents.Text.Contains("No visible contents"),"invalid authored name withdraws presentation instead of claiming an empty space");
        await Edit($"transaction((retract(attribute({entity},name,17)),assertz(attribute({entity},name,<<\"Reading room\">>)),assertz(attribute({entity},name,<<\"Other\">>)))).");
        var refused=await session.Read(human,$"client_subject_name({entity},Name).",CancellationToken.None);
        Check(refused["result"]?.ToString()!="ok","ambiguous authored names are explicitly refused by the shared Prolog owner");
        await Edit($"retract(attribute({entity},name,<<\"Other\">>)).");await FreshWorld();
        Check(State["world_accepted"]!.GetValue<bool>()&&title.Text=="Current space · Reading room","explicit accepted refresh restores the same world after the actual corrected metadata");
        int rebuilt=scene.Rebuilt,writes=0;store.DurabilityBoundary=_=>writes++;
        using(var socket=new System.Net.Sockets.TcpClient()){
            using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),limit.Token);Check(JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!["ready"]!.GetValue<bool>(),"real unchanged-view work watcher installed");
            for(int i=0;i<3;i++)await FreshWorld();
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),limit.Token);var work=JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!;await File.WriteAllTextAsync("/work/unchanged-world.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0&&writes==0&&scene.Rebuilt==rebuilt,"three accepted unchanged world renewals perform no watched history/rebuild/write/sync or native scene rebuild");
        }
        store.DurabilityBoundary=null;
        World().Projection-=Projection;
        await Press("location-operations");var pane=(EidolonPanel)app.FindChild("representations",true,false);await Until(()=>pane.Available);
        var wrong=target with{Anchor=Identity.Encode(new byte[32])};pane.Open(session,app.ActiveAccounts,store,wrong.Entity);
        await Until(()=>pane.Operations.StatusText.StartsWith("Unavailable:"));
        Check(!pane.Available&&pane.Selected==null&&pane.Operations.Current==null,"wrong-anchor selection stays unavailable, with no accepted empty choice or authority");
        await FreshWorld();Check(State["world_accepted"]!.GetValue<bool>()&&State["current_location"]!.ToString()==location,"fresh accepted current world survives wrong-anchor selected occurrence");
        pane.Open(session,app.ActiveAccounts,store,human.Ontology);await Until(()=>pane.Available);
        var choice=pane.Offered.Single(e=>e.Purpose.Name=="workspace"&&e.Style=="workbench");pane.Choose(choice);
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);var graph=(WorkbenchPanel)pane.FindChild("ontology-workbench",true,false);
        await Until(()=>source.CanEdit&&graph.Visible);
        Check(pane.Current!.Exact.ToString()==human.Ontology.ToString()&&source.Content.Length>0,"deliberate authored Workbench and source preserve the exact flat ontology identity");
        await Transition(new(){["source_access"]="deny"});await Until(()=>!source.CanEdit&&!graph.Visible&&source.Content.Length==0);
        Check(!source.IsVisibleInTree()||source.Content.Length==0,"source denial revokes selected inspector content and edit ability");
        await FreshWorld();Check(State["world_accepted"]!.GetValue<bool>()&&State["current_location"]!.ToString()==location,"fresh accepted independent world after selected source denial preserves current location");
        await File.WriteAllTextAsync("/work/name-projections.json",JsonSerializer.Serialize(seen));
        await Press("space-home");await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&scene.Count==0,"ordinary disconnect retires world and all negative-case consumers");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("SPACE_EXPERIENCE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
