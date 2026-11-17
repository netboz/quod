using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File = System.IO.File;
using Json = Quod.Client.Json;

public partial class ExportChecks
{
    async Task ExactSubject(OperationsPanel panel,Term subject)
    {
        var actor=Actor.FromTerm(subject); await Press("create-operations");
        await Type((LineEdit)panel.FindChild("exact-storage-namespace",true,false),actor.Namespace);
        await Type((LineEdit)panel.FindChild("exact-storage-anchor",true,false),actor.Anchor);
        await Type((LineEdit)panel.FindChild("exact-subject-instance",true,false),actor.InstanceText.TrimEnd('.'));
        await NativePress((Button)panel.FindChild("open-exact-subject",true,false));
        await Until(()=>panel.Available);
        Check(((Label)panel.FindChild("operation-scope",true,false)).Text.Contains(subject.ToString()),"explicit existing subject retains its exact storage and anchor");
    }
    async Task Move(OperationsPanel panel,Term subject,bool leave=false,bool lose=false,bool open=true,bool denied=false)
    {
        if(open) await ExactSubject(panel,subject);
        var menu=(OptionButton)panel.FindChild("offered-operation",true,false);
        string label=leave ? "Leave space" : "Enter space";
        int index=Enumerable.Range(1,menu.ItemCount-1).Single(i=>menu.GetItemText(i)==label);
        if(menu.Selected!=index) await ChooseOperation(menu,index);
        else Check(panel.Current?.Name==(leave ? "leave" : "enter"),"the sole current travel offer is already selected by the ordinary panel");
        NewDraft(panel);
        if(lose) await app.ActiveSession.Transport.Send("/qualification/arm-instruction-drop",new() { ["operation"]=leave ? "leave" : "enter" },CancellationToken.None);
        await ClickSubmit(panel);
        if(denied) {
            Check(panel.LastOutcome!=null && Json.Terminal(panel.LastOutcome) && !Json.Committed(panel.LastOutcome),"ordinary GUI reports a definitive denied travel outcome");
            return;
        }
        if(lose) {
            Check(State["pending"]!.GetValue<int>()==1,"lost travel reply retains the original signed operation");
            long writes=await Writes(); await panel.Submit(); Check(await Writes()==writes,"uncertain travel cannot be submitted again");
            Console.WriteLine("M1B_KILL_READY "+(leave ? "m3-left" : "m3-entered")); Console.Out.Flush();
            await new TaskCompletionSource().Task;
        }
        Check(panel.LastOutcome!=null && Json.Committed(panel.LastOutcome),"ordinary offered "+label+" commits through U to the same A");
        var expected=leave ? Term.Atom("unplaced") : Term.Call("placed",subject,Term.Parse("transform(0,0,0,0,0,0)"));
        await Until(()=>State["current_location"]?.ToString()==expected.ToString() && (leave || State["world_accepted"]!.GetValue<bool>()));
    }
    async Task<Term> CreateNested(OperationsPanel panel,Actor storage)
    {
        await CreationTarget(panel,storage,"create"); NewDraft(panel); await ClickSubmit(panel);
        Check(panel.LastOutcome!=null && Json.Committed(panel.LastOutcome),"ordinary selected-storage creation works in the current nested space");
        return Result(SpaceResults(panel.LastOutcome!),"space");
    }
    async Task SpaceNavigation(string phase,JsonObject original)
    {
        var human=app.ActiveAccounts.Human!; var setup=Term.Parse(original["setup"]!.GetValue<string>()).Require("account",6);
        var s0=setup[2]; var panel=(OperationsPanel)app.FindChild("operations",true,false); var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        string routePath=Env("M3_ROUTE");
        if(phase=="m3-fresh") {
            await CreationTarget(panel,human,"create"); await ClickSubmit(panel);
            Check(State["pending"]!.GetValue<int>()==1,"lost S1 creation reply retains original signed bytes");
            Console.WriteLine("M1B_KILL_READY m3-fresh"); Console.Out.Flush(); await new TaskCompletionSource().Task; return;
        }
        Check(State["pending"]!.GetValue<int>()==0,"installed restart resolves original work without dispatch");
        Term s1;
        if(phase=="m3-created") {
            var creation=app.ActiveAccounts.Outcomes.First(o=>o["bindings"]?.AsArray().Any(b=>b?["Results"]!=null && Term.Parse(b["Results"]!.GetValue<string>()).Items.Any(t=>t.Args[0].Name=="space"))==true);
            s1=Result(SpaceResults(creation),"space");
            await File.WriteAllTextAsync(routePath,new JsonObject { ["s1"]=s1.ToString() }.ToJsonString());
            await Until(()=>scene.SubjectIds(s1).Length==1);
            await PickSpace(scene,scene.SubjectIds(s1).Single(),Vector3.Zero,s1);
            await Until(()=>panel.Available && panel.Current?.Name=="enter");
            await Move(panel,s1,lose:true,open:false); return;
        }
        var route=JsonNode.Parse(await File.ReadAllTextAsync(routePath))!.AsObject(); s1=Term.Parse(Json.S(route,"s1"));
        if(phase=="m3-entered") {
            Check(State["current_location"]?.ToString()==Term.Call("placed",s1,Term.Parse("transform(0,0,0,0,0,0)")).ToString(),"lost Enter reply reopens the committed S1 instead of setup S0");
            var s2=await CreateNested(panel,human);
            Check(Result(SpaceResults(panel.LastOutcome!),"location").Args[0].ToString()==s1.ToString(),"S2 creation places near the same A inside S1 without entering it");
            await Move(panel,s2);
            var leaf=await CreateNested(panel,human);
            await Move(panel,s1); await Move(panel,s0);
            route["s2"]=s2.ToString(); route["leaf"]=leaf.ToString(); await File.WriteAllTextAsync(routePath,route.ToJsonString());
            await RecursiveScene(scene,human,s0,s1,s2,leaf);
            await Press("location-operations"); await Until(()=>panel.Available);
            await Move(panel,s0,leave:true,lose:true,open:false); return;
        }
        if(phase=="m3-left") {
            Check(State["current_location"]?.ToString()=="unplaced" && scene.Count==0 && !State["world_accepted"]!.GetValue<bool>(),"lost Leave reply recovers explicit unplaced state with no stale scene");
            await Move(panel,s1);
            long before=await Writes();
            await Press("disconnect"); await app.ViewsDisposed; Check(SignedView.LiveSockets==0,"disconnect disposes navigation and all view consumers");
            await Press("connect"); await Until(()=>State["world_accepted"]!.GetValue<bool>());
            Check(State["current_location"]?.ToString()==Term.Call("placed",s1,Term.Parse("transform(0,0,0,0,0,0)")).ToString(),"reconnect restores current S1 independently of original S0");
            await SpaceControl(new() { ["m2_restart"]=JsonSerializer.SerializeToNode(human) });
            await Until(()=>State["world_accepted"]!.GetValue<bool>());
            await SpaceControl(new() { ["m3_restart_runtime"]=JsonSerializer.SerializeToNode(human) });
            var personal=await app.ActiveSession.Read(human,"personal_agent(Agent,Key).",CancellationToken.None);
            Check(Json.Binding(personal,"Agent").ToString()==setup[1].ToString() && Json.Binding(personal,"Key").ToString()==setup[4].ToString(),"runtime owner restart reuses the exact original A and custody key");
            await SpaceControl(new() { ["m3_restart_views"]=true });
            await Until(()=>!State["world_accepted"]!.GetValue<bool>());
            await Press("disconnect"); await app.ViewsDisposed; await Press("connect");
            await Until(()=>State["world_accepted"]!.GetValue<bool>());
            Check(State["current_location"]?.ToString()==Term.Call("placed",s1,Term.Parse("transform(0,0,0,0,0,0)")).ToString(),"actual server view-owner loss and explicit reconnect restore committed S1");
            Check(app.ActiveAccounts.Setup!.ToString()==original["setup"]!.GetValue<string>(),"server owner recovery preserves original U A S0 keys pins and setup result");
            var corpus=JsonNode.Parse(await File.ReadAllTextAsync(Env("M1B_CORPUS")))!;
            await BackupWidget(true,Env("M1B_ACCOUNT_BACKUP"),Json.S(corpus,"passphrase"),true);
            Check(await Writes()>=before,"connection receiver lifecycle recorded separately from domain instructions");
        } else if(phase=="m3-final") {
            Check(State["current_location"]?.ToString()==Term.Call("placed",s1,Term.Parse("transform(0,0,0,0,0,0)")).ToString(),"new installed process restores the last committed S1 with the same account");
            var replies=app.ActiveAccounts.Outcomes.Where(o=>o["bindings"]?.AsArray().Any(b=>b?["Results"]!=null)==true).ToArray();
            Check(replies.All(Json.Committed) && replies.Length>=7,"original creation Enter and Leave outcomes recover from authoritative associations");
            using var cancellation=new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var before=Json.Binding(await app.ActiveSession.Read(human,"personal_instructions(Instructions).",cancellation.Token),"Instructions").Items.Select(t=>t.Args[0].ToString()).ToHashSet();
            string entity=Actor.FromTerm(s0).InstanceText.TrimEnd('.');
            await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,$"assertz(instance_permission({entity},space_admit,deny)).",cancellation.Token);
            await Move(panel,s0,denied:true);
            Check(State["current_location"]?.ToString()==Term.Call("placed",s1,Term.Parse("transform(0,0,0,0,0,0)")).ToString() && State["assignment_revision"]?.ToString()=="11","denied GUI entry leaves the existing assignment and location unchanged");
            await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,$"retract(instance_permission({entity},space_admit,deny)).",cancellation.Token);
            var instruction=Json.Binding(await app.ActiveSession.Read(human,"personal_instructions(Instructions).",cancellation.Token),"Instructions").Items.Single(t=>!before.Contains(t.Args[0].ToString()));
            string id=Identity.Encode(instruction.Args[0].Bytes);route["negative_instruction"]=id;await File.WriteAllTextAsync(routePath,route.ToJsonString());
            var outcome=await app.ActiveSession.ResolveInstruction(human,id,cancellation.Token);
            Check(!Json.Terminal(outcome),"an unclaimed denied attempt remains an explicitly unresolved original outcome across devices");
            await File.WriteAllTextAsync(Env("M1B_RESULT")+".negative.json",outcome.ToJsonString());
        } else {
            Check(app.ActiveAccounts.Uncertain && State["pending"]!.GetValue<int>()==0,"fresh process retains the unknown-association barrier without an originating device journal");
            await ExactSubject(panel,s0);NewDraft(panel);
            long writes=await Writes();await panel.Submit();Check(await Writes()==writes,"unknown original association blocks another instructed write without resubmission or inferred rejection");
            Check(State["current_location"]?.ToString()==Term.Call("placed",s1,Term.Parse("transform(0,0,0,0,0,0)")).ToString(),"unknown outcome leaves the independently verified committed location intact");
        }
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new { passed=true,phase,checks,current_location=State["current_location"]?.ToString(),setup=app.ActiveAccounts.Setup!.ToString() }));
        await Press("disconnect"); await app.ViewsDisposed;
        Console.WriteLine("M3_EXPORT_PASS "+phase); Console.Out.Flush(); await app.CloseApplication();
    }
    async Task RecursiveScene(ScenePanel scene,Actor human,Term s0,Term s1,Term s2,Term leaf)
    {
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var t1=Term.Parse("transform(1300,-700,2900,17,43,89)");var t2=Term.Parse("transform(-1900,1100,2300,31,67,113)");
        var t3=Term.Parse("transform(300,500,-900,23,47,71)");
        foreach(var (subject,pose,style) in new[] { (s1,t1,"contents"),(s2,t2,"contents"),(leaf,t3,"solid") }) {
            var actor=Actor.FromTerm(subject);
            string goal=$"attribute({actor.InstanceText.TrimEnd('.')},exterior,Old),attribute({actor.InstanceText.TrimEnd('.')},transform,Pose),space_represent({actor.InstanceText.TrimEnd('.')},Old,Pose,{style},{pose}).";
            await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,goal,timeout.Token);
        }
        await Until(()=>State["world_accepted"]!.GetValue<bool>() && scene.SubjectIds(leaf).Length==1);
        Check(State["current_location"]?.ToString()==Term.Call("placed",s0,Term.Parse("transform(0,0,0,0,0,0)")).ToString(),"recursive contents display in S0 without entry into S1 or S2");
        var centre=scene.WorldPose(scene.SubjectIds(leaf).Single()).Origin;
        Check(centre.DistanceTo(new(1.4169198585f,-1.3171043603f,6.0266848584f))<.00001f,"nonidentity parent-first translation and rotation agree with independent matrix reference");
        await PickSpace(scene,scene.SubjectIds(leaf).Single(),Vector3.Zero,leaf);
        string Entity(Term subject)=>Actor.FromTerm(subject).InstanceText.TrimEnd('.');
        await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,
            $"transaction((assertz(space_member({Entity(s0)},{s2})),assertz(space_member({Entity(s1)},{leaf})),assertz(space_member({Entity(s2)},{s1})))).",timeout.Token);
        await Until(()=>State["world_accepted"]!.GetValue<bool>() && scene.SubjectIds(leaf).Length==4);
        Check(scene.SubjectIds(leaf).Distinct().Count()==4,"independent recursive paths preserve four occurrences of the same exact subject");
        Check(scene.FindChildren("*","Label3D",true,false).OfType<Label3D>().Count(l=>l.Text=="Contents cycle")==2,"exact ancestor cycles render explicit terminal occurrences on each independent branch");
        await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,$"space_represent({Entity(s2)},contents,{t2},wireframe,{t2}).",timeout.Token);
        await Until(()=>State["world_accepted"]!.GetValue<bool>() && scene.SubjectIds(leaf).Length==1 && scene.SubjectIds(s2).Length==2);
        Check(scene.SubjectIds(s2).Length==2,"wireframe terminates each selected S2 occurrence while the independent S1 leaf remains visible");
        await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,$"space_represent({Entity(s2)},wireframe,{t2},contents,{t2}).",timeout.Token);
        await Until(()=>State["world_accepted"]!.GetValue<bool>() && scene.SubjectIds(leaf).Length==4);
        int rebuilt=scene.Rebuilt;var ids=scene.Ids.ToArray();
        var view=(SignedView)typeof(Main).GetField("worldView",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!.GetValue(app)!;
        var navigation=((IEnumerable<SignedView>)typeof(Main).GetField("views",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!.GetValue(app)!).First();
        using var probe=new System.Net.Sockets.TcpClient();await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")));
        using var stream=probe.GetStream();using var reader=new StreamReader(stream);
        await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"));
        Check(JsonNode.Parse((await reader.ReadLineAsync())!)!["ready"]!.GetValue<bool>(),"real-owner work probe is armed before unchanged renewals");
        for(int i=0;i<3;i++) {
            var routed=new TaskCompletionSource();void NavigationProjection(JsonNode _)=>routed.TrySetResult();navigation.Projection+=NavigationProjection;
            try { await navigation.Renew();await routed.Task.WaitAsync(TimeSpan.FromSeconds(30)); }
            finally { navigation.Projection-=NavigationProjection; }
            var received=new TaskCompletionSource(); void Projection(JsonNode _)=>received.TrySetResult(); view.Projection+=Projection;
            try { await view.Renew(); await received.Task.WaitAsync(TimeSpan.FromSeconds(30)); }
            finally { view.Projection-=Projection; }
        }
        await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"));
        var work=JsonNode.Parse((await reader.ReadLineAsync())!)!;
        Check(work["work"]!["calls"]!.AsArray().Count==0,"unchanged actual signed view renewals create no reader/history/native install or file write/sync work");
        await File.WriteAllTextAsync(Env("M3_SCENE_CAPTURE")+".work.json",work.ToJsonString());
        Check(scene.Rebuilt==rebuilt && scene.Ids.SequenceEqual(ids),"unchanged real signed renewals retain every engine occurrence");
        if(DisplayServer.GetName()!="headless") {
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            using var raster=scene.GetChildren().OfType<SubViewport>().Single().GetTexture().GetImage();
            Check(raster.SavePng(Env("M3_SCENE_CAPTURE"))==Error.Ok,"GPU raster of recursive exact-subject hierarchy retained");
        }
    }
}
