using Godot;
using Quod.Client;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task ControllerLive(OperationsPanel operations)
    {
        var human=app.ActiveAccounts.Human!;var session=app.ActiveSession;
        var adapter=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var flags=System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic;
        var views=(IEnumerable<SignedView>)typeof(Main).GetField("views",flags)!.GetValue(app)!;
        var view=views.Single(v=>(string)typeof(SignedView).GetField("kind",flags)!.GetValue(v)! == "controller_preferences");
        await Until(()=>State["controller_status"]?["available"]?.GetValue<bool>()==true);
        var original=Json.Binding(await session.Read(human,Term.Call("::",Term.Text("quod:user"),Term.Call("controller_preferences_view",human.Entity,Term.Variable("View")))+".",CancellationToken.None),"View");
        var baseline=ControllerMapping.Decode(original)!;
        Check(baseline.Profiles.Single().Model.Digest=="bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94","actual signed Prolog projection selects the pinned licensed controller appearance");
        adapter.AttachSources();
        var tracker=new XRControllerTracker { Name="m4_live_source",Type=XRServer.TrackerType.Controller,Profile="/interaction_profiles/htc/vive_controller",Hand=XRPositionalTracker.TrackerHand.Left };
        tracker.SetInput("trigger_press",false);tracker.SetInput("trigger_value",0.0);tracker.SetInput("squeeze_press",false);tracker.SetInput("pad_press",false);tracker.SetInput("pad_touch",false);tracker.SetInput("pad_axes",Vector2.Zero);
        tracker.SetPose("aim",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);tracker.SetPose("grip",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
        var installed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void SourceInstalled(){if(adapter.Router.Count==1)installed.TrySetResult();}
        adapter.Changed+=SourceInstalled;
        try { XRServer.AddTracker(tracker);await installed.Task.WaitAsync(TimeSpan.FromSeconds(30)); }
        finally { adapter.Changed-=SourceInstalled; }
        await adapter.Completion;adapter.Advance(1,true,true,true,Frame90);
        var resources=JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(adapter.Metrics))!["resources"]!;
        Check(resources["Decodes"]!.GetValue<int>()==1 && resources["LiveLeases"]!.GetValue<int>()==1,"real HTTPS asset bytes pass digest/profile/cost admission and instantiate in the production scene owner");
        using var probe=new System.Net.Sockets.TcpClient();await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")));
        using var stream=probe.GetStream();using var reader=new StreamReader(stream);
        await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"));
        Check(JsonNode.Parse((await reader.ReadLineAsync())!)!["ready"]!.GetValue<bool>(),"production owner work probe is armed before mapping renewal");
        async Task Renew()
        {
            var received=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Projection(JsonNode _)=>received.TrySetResult();view.Projection+=Projection;
            try { await view.Renew();await received.Task.WaitAsync(TimeSpan.FromSeconds(30)); }finally { view.Projection-=Projection; }
        }
        for(int i=0;i<3;i++){await Renew();adapter.Advance((ulong)i+2,true,true,true,Frame90);}
        await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"));var work=JsonNode.Parse((await reader.ReadLineAsync())!)!;
        Check(work["work"]!["calls"]!.AsArray().Count==0,"unchanged signed mapping renewals perform zero watched history/reader/install/write/sync calls");
        var after=JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(adapter.Metrics))!["resources"]!;
        Check(after.ToJsonString()==resources.ToJsonString(),"unchanged signed mapping renewals perform zero acquisition/decode/node/texture/release work");
        var revision=baseline.Revision+1;
        // U owns source editing separately from the normal preference operation.
        // This signed, revision-fenced edit creates only the disposable test's
        // invalid row; repair below must use the real offered U-to-A action.
        string invalid=$"transaction((<<\"quod:user\">>::controller_preferences_view({human.Entity},controller_view({baseline.Revision},{original.Args[1]},_)),retract(attribute(me,controller_preferences,preferences({baseline.Revision},Previous))),assertz(attribute(me,controller_preferences,preferences({revision},settings([],removed_binding_set,[])))))).";
        using var deadline=new CancellationTokenSource(TimeSpan.FromMinutes(5));
        var edited=await ExecuteComplete(session,app.ActiveStore,human,invalid,deadline.Token);
        Check(Json.Committed(edited),"explicit owner source edit installs a revision-valid invalid preference row");
        await Until(()=>State["controller_status"]?["available"]?.GetValue<bool>()==false && operations.Current?.Form.Submit.Name=="controller_restore" && operations.Available);
        Check(view.Completion?.IsCompleted==false && adapter.Router.Count==1,"authorized invalid-settings state retains its original signed subscription and source consumer");
        await Renew();Check(view.Completion?.IsCompleted==false,"ordinary invalid-state renewal retains the repair subscription");
        var repair=operations.Current!;
        Console.WriteLine("M4_REPAIR_OFFER "+repair.Availability+" "+repair.Form.Submit+" "+repair.Revision);
        Check(repair.Form.Submit.Name=="controller_restore" && repair.Form.Defaults.Count==0,"actual generic offered operation supplies explicit Reset with exact invalid-value/revision fence");
        await operations.Submit();
        if(operations.LastOutcome!=null && !Json.Terminal(operations.LastOutcome)) {
            var pending=app.ActiveStore.Snapshot!.Pending.Single(p=>p.Flow=="instruction");
            using var owner=new System.Net.Sockets.TcpClient();await owner.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")));
            using var channel=owner.GetStream();using var fence=new StreamReader(channel);
            await channel.WriteAsync(System.Text.Encoding.UTF8.GetBytes(new JsonObject { ["request"]=pending.Request }.ToJsonString()+"\n"));
            Check(JsonNode.Parse((await fence.ReadLineAsync())!)!["terminal"]!.GetValue<bool>(),"original repair instruction reaches its existing applied owner");await Press("resolve-original");await Until(()=>!operations.IsWorking);
        }
        Check(operations.LastOutcome!=null && Json.Committed(operations.LastOutcome),"explicit Reset submits through the ordinary governed U-to-A operation and commits once");
        await Until(()=>State["controller_status"]?["available"]?.GetValue<bool>()==true && State["controller_status"]?["revision"]?.ToString()==(revision+1).ToString());
        after=JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(adapter.Metrics))!["resources"]!;
        Check(after.ToJsonString()==resources.ToJsonString(),"real invalidation and Reset restore input without reacquiring/redecoding/rebuilding unchanged controller resources");
        var repaired=ControllerMapping.Decode(Json.Binding(await session.Read(human,Term.Call("::",Term.Text("quod:user"),Term.Call("controller_preferences_view",human.Entity,Term.Variable("View")))+".",deadline.Token),"View"))!;
        Check(repaired.Revision==revision+1 && repaired.Digest==baseline.Digest,"committed repair advances preference revision while retaining exact shared-default mapping");
        XRServer.RemoveTracker(tracker);tracker.Dispose();adapter.StopSession();await adapter.Completion;
        Check(adapter.Subscriptions==0 && adapter.Router.Count==0,"real signed-consumer source removal releases all input subscriptions");
        await File.WriteAllTextAsync(Env("M1B_RESULT")+".m4.json",System.Text.Json.JsonSerializer.Serialize(new { passed=true,checks,work,mapping=original.ToString(),repaired_revision=repaired.Revision.ToString(),metrics=adapter.Metrics,physical_acceptance=false }));
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"account disconnect releases mapping GUI navigation and question subscriptions");
        Console.WriteLine("M4_LIVE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
