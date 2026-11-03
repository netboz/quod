using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json=Quod.Client.Json;
using File=System.IO.File;
public partial class ExportChecks {
    async Task MovedContentsChecks()
    {
        var metadata=JsonNode.Parse(await File.ReadAllTextAsync(Env("M3_PHYSICS_META")))!;
        var human=Actor.FromTerm(Term.Parse(Json.S(metadata,"viewer")));var outer=Actor.FromTerm(Term.Parse(Json.S(metadata,"s0")));var leaf=Term.Parse(Json.S(metadata,"leaf"));
        using var identity=Identity.FromPayload(await File.ReadAllTextAsync(Env("M3_PHYSICS_KEY")));
        using var store=new LocalStore(profile+"-selected-contents");store.Create(identity.Payload());
        using var session=new SignedSession(identity,store,new Transport(Env("M3_NODE"),Env("M3_CA")));
        using var deadline=new CancellationTokenSource(TimeSpan.FromMinutes(3));await session.Authenticate(deadline.Token);
        // This existing M3 fixture has no GUI catalogue owner. Its actual
        // authored playing choices can be read without asking that absent
        // optional owner for unrelated Prolog representations.
        var choices=Json.Binding(await session.Read(human,SignedSession.ViewGoal(outer,Term.Call("entity_eidolons",Term.Parse(outer.InstanceText.TrimEnd('.')),Term.Atom("playing"),Term.Atom("contents"),Term.Variable("Choices"))),deadline.Token),"Choices");
        var choice=Eidolon.Decode(choices.ToString()).Single();
        var direct=await session.Read(human,SignedSession.ViewGoal(outer,choice.Read(Term.Parse(outer.InstanceText.TrimEnd('.')))),deadline.Token);
        Check(Json.Committed(direct),"the selected authored contents recipe is admitted independently of unrelated optional representations");
        var scene=new ScenePanel();app.AddChild(scene);WorldProjection? projection=null;string? failure=null;bool transitionExpected=false;string? withdrawal=null;
        using var motion=new PhysicsInput(session,human);
        var changed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Notice(){var old=changed;changed=new(TaskCreationOptions.RunContinuationsAsynchronously);old.TrySetResult();}
        async Task Wait(Func<bool> condition){while(!condition()){if(failure!=null)throw new Exception(failure);await changed.Task.WaitAsync(deadline.Token);}}
        using var view=new SignedView(session,human,outer,"eidolon_scene",SignedSession.ViewGoal(outer,choice.Read(Term.Parse(outer.InstanceText.TrimEnd('.')))));
        int frames=0;var streamed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        view.Projection+=m=>{try{projection=scene.ApplyProjection(m,outer,human,ack=>_ = view.Send(ack));motion.Present(projection);}catch(Exception e){failure=e.Message;}Notice();};
        view.Message+=m=>{if(m["type"]?.ToString()=="simulation_frame"){try{if(scene.ApplyFrame(m,ack=>_ = view.Send(ack))){motion.Present(projection!);if(++frames>=3)streamed.TrySetResult();}}catch(Exception e){failure=e.Message;}Notice();}};
        view.Withdrawn+=reason=>{projection=null;scene.Withdraw();withdrawal=reason;if(!transitionExpected)failure=reason;Notice();};
        _=view.Start();await Wait(()=>projection!=null && scene.SubjectIds(leaf).Length==3);
        Check(scene.SubjectIds(leaf).Length==3,"the shared selected-representation consumer renders the existing three recursive independent appearances");
        // The retained native world can sleep. One ordinary signed fixture
        // drive supplies actual activity; idle silence is not lost credit.
        motion.Drive(.1,0,0);await motion.Completion;
        bool sustained=true;try{await streamed.Task.WaitAsync(TimeSpan.FromSeconds(10));}catch(TimeoutException){sustained=false;}
        motion.Drive(0,0,0);await motion.Completion;
        Check(sustained,"selected physical representation returns frame credit through the same view owner and continues beyond the initial delivery");
        int rebuilt=scene.Rebuilt;using(var probe=new System.Net.Sockets.TcpClient()) {
            await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),deadline.Token);using var stream=probe.GetStream();using var reader=new StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),deadline.Token);
            Check(JsonNode.Parse((await reader.ReadLineAsync(deadline.Token))!)!["ready"]!.GetValue<bool>(),"existing owner work observation is installed before unchanged selected-view renewals");
            for(int i=0;i<3;i++) {
                var received=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Projected(JsonNode _)=>received.TrySetResult();view.Projection+=Projected;
                try{await view.Renew();await received.Task.WaitAsync(deadline.Token);}finally{view.Projection-=Projected;}
            }
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),deadline.Token);
            var work=JsonNode.Parse((await reader.ReadLineAsync(deadline.Token))!)!;await File.WriteAllTextAsync(Env("M1B_RESULT")+".work.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0 && scene.Rebuilt==rebuilt,"unchanged selected contents retain resources with zero watched history/install/write/sync work");
        }
        transitionExpected=true;await SpaceControl(new(){["mutate"]="source"});await Wait(()=>projection!=null && scene.Rebuilt>rebuilt);transitionExpected=false;
        Check(scene.SubjectIds(leaf).Length==3,"a real source update propagates without collapsing independent occurrences");
        var other=new ScenePanel();app.AddChild(other);var independent=Actor.FromTerm(Term.Parse(Json.S(metadata,"independent")));WorldProjection? otherProjection=null;int independentWithdrawals=0;
        using var independentView=new SignedView(session,human,independent,"world",SignedSession.ViewGoal(independent,Term.Call("client_world_view",Term.Parse(independent.InstanceText.TrimEnd('.')),Term.Atom("playing"),Term.List(),Term.Variable("View"))));
        independentView.Projection+=m=>{otherProjection=other.ApplyProjection(m,independent,human,ack=>_ = independentView.Send(ack));Notice();};
        independentView.Message+=m=>{if(m["frame"]!=null)other.ApplyFrame(m,ack=>_ = independentView.Send(ack));};
        independentView.Withdrawn+=_=>{independentWithdrawals++;otherProjection=null;other.Withdraw();Notice();};
        _=independentView.Start();await Wait(()=>otherProjection?.Sample!=null);string fence=otherProjection!.Sample!.Fence;
        transitionExpected=true;withdrawal=null;await SpaceControl(new(){["mutate"]="revoke"});
        using(var until=new CancellationTokenSource(TimeSpan.FromSeconds(30)))while(projection!=null || withdrawal?.StartsWith("Unavailable:")!=true)await changed.Task.WaitAsync(until.Token);
        var current=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Accepted(JsonNode _)=>current.TrySetResult();independentView.Projection+=Accepted;
        try{await independentView.Renew();await current.Task.WaitAsync(deadline.Token);}finally{independentView.Projection-=Accepted;}
        Check(otherProjection?.Sample?.Fence==fence && independentWithdrawals==0 && other.Count==0 && scene.Count==0,"dependency denial withdraws the selected consumer while a fresh accepted independent projection stays available");
        view.Dispose();await view.Completion;independentView.Dispose();await independentView.Completion;scene.Withdraw();other.Withdraw();scene.QueueFree();other.QueueFree();
        Check(SignedView.LiveSockets==0,"selected representation and independent view resources retire with their consumers");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks,physical=false}));Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
    }
}
