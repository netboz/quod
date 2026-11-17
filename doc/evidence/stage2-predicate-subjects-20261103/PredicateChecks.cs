using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks
{
    async Task PredicateChecks()
    {
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
        var human=app.ActiveAccounts.Human!;var identity=human.Ontology.Require("ontology_ref",2);
        var exact=Term.Call("predicate_ref",identity[0],identity[1],Term.Call("/",Term.Atom("isa"),Term.Number("2")));
        var read=await app.ActiveSession.Read(human,SignedSession.ViewGoal(human,Term.Call("entity_eidolons",exact,Term.Variable("View"))),CancellationToken.None);
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".discovery.json",read.ToJsonString());
        Check(Json.Committed(read),"signed predicate subject discovery completes through the actual target owner");
        var choices=Eidolon.Decode(Json.Binding(read,"View").ToString());
        Check(choices.Any(e=>e.Purpose.Name=="prolog"&&e.Style=="source"),"authorized existing predicate offers its guarded source Eidolon");
        var session=app.ActiveSession;var accounts=app.ActiveAccounts;var store=app.ActiveStore;
        var tools=accounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        Term Indicator(string name,int arity)=>Term.Call("/",Term.Atom(name),Term.Number(arity.ToString()));
        Term Predicate(Actor owner,string name,int arity){var a=owner.Ontology.Require("ontology_ref",2);return Term.Call("predicate_ref",a[0],a[1],Indicator(name,arity));}
        async Task<System.Text.Json.Nodes.JsonNode> Discover(Actor owner,Term subject)=>await session.Read(human,SignedSession.ViewGoal(owner,Term.Call("entity_eidolons",subject,Term.Variable("View"))),CancellationToken.None);
        async Task<string> Saved()=>Json.Binding(await session.Read(human,SignedSession.ViewGoal(tools,Term.Call("prolog_source",human.Ontology,Indicator("predicate_note",2),Term.Variable("Source"))),CancellationToken.None),"Source").TextValue;
        Check(Json.Committed(await ExecuteComplete(session,store,human,"transaction((assertz(predicate_note(a,first)),assertz(predicate_note(a,second)))).",CancellationToken.None)),"real owner commits the two-clause predicate fixture");
        exact=Predicate(human,"predicate_note",2);
        await Press("inspect");var pane=(EidolonPanel)app.FindChild("representations",true,false);
        pane.Changed+=()=>Console.WriteLine("PREDICATE_PRIVATE_STATUS "+System.Text.Json.JsonSerializer.Serialize(new{pane.StatusText,pane.Available,source=(pane.FindChild("source-tools",true,false) as SourcePanel)?.Status}));
        await Until(()=>pane.Available);pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="prolog"&&e.Style=="source"));
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        await Until(()=>source.CanEdit&&source.Content.Length>0);
        FormPanel Form()=>(FormPanel)source.FindChild("source-form",true,false);
        var catalogue=(OptionButton)Form().Input("predicate")!;
        int index=Enumerable.Range(1,catalogue.ItemCount-1).Single(i=>catalogue.GetItemText(i)=="predicate_note/2");
        catalogue.Select(index);catalogue.EmitSignal(OptionButton.SignalName.ItemSelected,(long)index);
        await Until(()=>pane.Current?.Exact.ToString()==exact.ToString()&&source.CanEdit);
        Check(source.Content==await Saved()&&source.Content.IndexOf("first")<source.Content.IndexOf("second"),"native catalogue selects one exact predicate and opens all clauses in semantic order");
        Check(pane.Current!.Target.Ontology.ToString()==human.Ontology.ToString()&&pane.Current.Local.ToString()==exact.ToString(),"predicate selection retains exact namespace genesis and indicator");
        Check(((Button)Form().Input("create")!).Disabled,"a bound predicate editor cannot silently switch to another new predicate");
        var system=accounts.Catalogue.Single(a=>a.Namespace=="quod:gui");var systemPredicate=Predicate(system,"isa",2);
        pane.Open(session,accounts,store,Predicate(human,"isa",2));await Until(()=>source.CanEdit&&pane.Current!.Exact.ToString()==Predicate(human,"isa",2).ToString());
        pane.Open(session,accounts,store,systemPredicate);await Until(()=>pane.Available&&(source.Content.Length>0||source.Status=="The selected predicate is no longer available."));
        string systemSource=Json.Binding(await session.Read(human,SignedSession.ViewGoal(tools,Term.Call("prolog_source",system.Ontology,Indicator("isa",2),Term.Variable("Source"))),CancellationToken.None),"Source").TextValue;
        Check(source.Content==systemSource&&!source.CanEdit,"switching the same predicate indicator between exact owners reads only the selected predicate");
        pane.Open(session,accounts,store,exact);await Until(()=>source.CanEdit&&source.Content.Contains("predicate_note"));
        var scene=new ScenePanel();app.AddChild(scene);
        try {
            var mark=Term.Call("mark",Term.Text("predicate-occurrence"),Term.Text("box"),Term.List(new[]{"width","height","depth"}.Select(n=>Term.Call("f",Term.Text(n),Term.Number("1000"))).ToArray()),Term.Call("transform",Enumerable.Repeat(Term.Number("0"),6).ToArray()),Term.Call("surface",Term.Text("#FFFFFF"),Term.Number("0"),Term.Number("0"),Term.Number("0"),Term.List()),Term.Atom("unlabelled"),Term.Call("depicts",identity[0],identity[1],exact));
            scene.Apply(Term.List(mark));var pick=scene.PickRay(new Vector3(0,0,3),Vector3.Forward);
            Check(pick?.Subject.ToString()==exact.ToString(),"shared native scene picker preserves predicate subject and independent occurrence identity");
        } finally {scene.QueueFree();}
        int reads=source.SnapshotReads;byte[] bytes=System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"));
        using(var probe=new System.Net.Sockets.TcpClient()) {
            using var stop=new CancellationTokenSource(TimeSpan.FromSeconds(30));await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),stop.Token);
            using var stream=probe.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),stop.Token);
            Check(System.Text.Json.Nodes.JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!["ready"]!.GetValue<bool>(),"real owner observation precedes unchanged predicate renewals");
            var view=(SignedView)typeof(EidolonPanel).GetField("representation",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance)!.GetValue(pane)!;
            for(int i=0;i<3;i++){var received=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Got(System.Text.Json.Nodes.JsonNode _)=>received.TrySetResult();view.Projection+=Got;try{await view.Renew();await received.Task.WaitAsync(stop.Token);}finally{view.Projection-=Got;}}
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),stop.Token);var work=System.Text.Json.Nodes.JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!;
            await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".work.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0,"unchanged predicate renewals perform zero watched history rebuild write or sync work");
        }
        Check(reads==source.SnapshotReads&&bytes.SequenceEqual(System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"))),"unchanged predicate renewals reuse source snapshot and local profile bytes");
        async Task Invoke(string role){var b=(Button)Form().Input(role)!;Check(!b.Disabled,"enabled predicate editor action "+role);b.EmitSignal(BaseButton.SignalName.Pressed);await source.Completion;}
        void Draft(string text){var editor=(TextEdit)Form().Input("source")!;editor.Text=text;editor.EmitSignal(TextEdit.SignalName.TextChanged);}
        Draft("predicate_note(a,second).\npredicate_note(a,first).\n");await Invoke("run");await Invoke("accept");
        await Until(()=>source.CanEdit&&source.Content.IndexOf("second")<source.Content.IndexOf("first"));
        var order=await session.Read(human,"findall(V,predicate_note(a,V),Values).",CancellationToken.None);
        Check(Json.Binding(order,"Values").ToString()=="[second,first]"&&pane.Current!.Exact.ToString()==exact.ToString(),"guarded reorder commits semantic clause order while retaining the exact selected predicate");
        Draft("predicate_note(a,local).\n");
        Check(Json.Committed(await ExecuteComplete(session,store,human,"transaction((retract(predicate_note(a,first)),assertz(predicate_note(a,concurrent)))).",CancellationToken.None)),"independent real update establishes the stale source baseline");
        await Until(()=>source.CanEdit&&source.Status.StartsWith("Saved source changed"));
        await Invoke("run");
        Check(((Button)Form().Input("accept")!).Disabled&&source.Content.Contains("local")&&(await Saved()).Contains("concurrent"),"stale predicate draft is retained and cannot replace the concurrent committed source");
        ((Button)source.FindChild("source-discard",true,false)).EmitSignal(BaseButton.SignalName.Pressed);await source.Completion;
        Check(source.Content==await Saved()&&pane.Current!.Exact.ToString()==exact.ToString(),"explicit discard reloads current clauses without changing predicate selection");
        var choice=pane.Selected!;var representation=Json.Binding(await session.Read(human,SignedSession.ViewGoal(human,choice.Read(exact)),CancellationToken.None),"View");
        var other=Subject.Decode(Predicate(human,"isa",2));bool refused=false;
        try {source.Install(session,accounts,store,other,choice,representation,Term.List());}catch(FormatException){refused=true;}
        Check(refused&&pane.Current!.Exact.ToString()==exact.ToString()&&source.CanEdit,"stale representation for another predicate cannot replace the current exact selection");
        var missing=Predicate(human,"predicate_never_defined",2);
        pane.Open(session,accounts,store,missing);await Until(()=>pane.Available&&pane.Offered.Length==0);
        Check(source.Content.Length==0&&!source.CanEdit,"missing predicate selection cannot fall back to complete ontology source");
        var absent=await Discover(human,missing);Check(Json.Committed(absent)&&Json.Binding(absent,"View").Items.Length==0,"missing predicate has no current source Eidolon");
        var wrong=human with {Anchor=Identity.Encode(new byte[32])};
        var stale=await Discover(human,Predicate(wrong,"isa",2));Check(Json.Committed(stale)&&Json.Binding(stale,"View").Items.Length==0,"wrong genesis inside a predicate subject cannot bind to the current history");
        var malformed=await Discover(human,Predicate(human,"isa",3));Check(Json.Committed(malformed)&&Json.Binding(malformed,"View").Items.Length==0,"wrong predicate indicator cannot open a different arity");
        var foreign=await SpaceControl(new(){["vector_target"]=new System.Text.Json.Nodes.JsonObject{["namespace"]=human.Namespace,["anchor"]=human.Anchor}});
        var privateOwner=new Actor(Json.S(foreign,"namespace"),Json.S(foreign,"anchor"),"me.");
        var denied=await Discover(privateOwner,Predicate(privateOwner,"isa",2));
        Check(Json.Terminal(denied)&&!Json.Committed(denied),"another private owner denies signed predicate discovery without source disclosure");

        pane.Open(session,accounts,store,systemPredicate);await Until(()=>pane.Available&&source.Content.Length>0);
        Check(!source.CanEdit&&pane.Current!.Exact.ToString()==systemPredicate.ToString(),"system predicate inherits existing read-only source policy");
        var transition=await SpaceControl(new(){["source_access"]="deny"});Check(transition["source_access"]!.ToString()=="deny","ordinary policy owner commits actual source revocation");
        await Until(()=>source.Content.Length==0);Check(!source.CanEdit,"source revocation withdraws the selected predicate editor");
        var revoked=await Discover(system,systemPredicate);Check(!Json.Committed(revoked)||Json.Binding(revoked,"View").Items.Length==0,"revoked source policy cannot rediscover a predicate source choice");
        transition=await SpaceControl(new(){["source_access"]="restore"});Check(transition["source_access"]!.ToString()=="restore","ordinary policy owner restores the original source policy");
        pane.Open(session,accounts,store,systemPredicate);await Until(()=>source.Content.Length>0&&!source.CanEdit);
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0,"predicate consumers retire through ordinary disconnect");
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
        Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
    }
}
