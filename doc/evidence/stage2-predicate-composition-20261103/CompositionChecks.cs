using Godot;
using Quod.Client;
using Json=Quod.Client.Json;
public partial class ExportChecks
{
    async Task CompositionChecks()
    {
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
        string originalLocation=State["current_location"]!.ToString();
        var human=app.ActiveAccounts.Human!;var identity=human.Ontology.Require("ontology_ref",2);
        var local=Term.Call("predicate",Term.Call("/",Term.Atom("isa"),Term.Number("2")));
        var exact=Term.Call("entity_ref",identity[0],identity[1],local);
        var read=await app.ActiveSession.Read(human,SignedSession.ViewGoal(human,Term.Call("entity_eidolons",local,Term.Variable("View"))),CancellationToken.None);
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".discovery.json",read.ToJsonString());
        Check(Json.Committed(read),"signed predicate subject discovery completes through the actual target owner");
        var choices=Eidolon.Decode(Json.Binding(read,"View").ToString());
        Check(choices.Any(e=>e.Purpose.Name=="prolog"&&e.Style=="source"),"authorized existing predicate offers its guarded source Eidolon");
        var session=app.ActiveSession;var accounts=app.ActiveAccounts;var store=app.ActiveStore;
        var tools=accounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        Term Indicator(string name,int arity)=>Term.Call("/",Term.Atom(name),Term.Number(arity.ToString()));
        Term Predicate(Actor owner,string name,int arity){var a=owner.Ontology.Require("ontology_ref",2);return Term.Call("entity_ref",a[0],a[1],Term.Call("predicate",Indicator(name,arity)));}
        async Task<System.Text.Json.Nodes.JsonNode> Discover(Actor owner,Term subject)=>await session.Read(human,SignedSession.ViewGoal(owner,Term.Call("entity_eidolons",Subject.Decode(subject).Local,Term.Variable("View"))),CancellationToken.None);
        async Task<string> Saved()=>Json.Binding(await session.Read(human,SignedSession.ViewGoal(tools,Term.Call("prolog_source",human.Ontology,Indicator("predicate_note",2),Term.Variable("Source"))),CancellationToken.None),"Source").TextValue;
        Check(Json.Committed(await ExecuteComplete(session,store,human,"transaction((assertz(predicate_note(a,first)),assertz(predicate_note(a,second)))).",CancellationToken.None)),"real owner commits the two-clause predicate fixture");
        exact=Predicate(human,"predicate_note",2);
        await Press("inspect");var pane=(EidolonPanel)app.FindChild("representations",true,false);
        pane.Changed+=()=>Console.WriteLine("PREDICATE_PRIVATE_STATUS "+System.Text.Json.JsonSerializer.Serialize(new{pane.StatusText,pane.Available,source=(pane.FindChild("source-tools",true,false) as SourcePanel)?.Status}));
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        FormPanel Form()=>(FormPanel)source.FindChild("source-form",true,false);
        async Task OpenEditor(Term subject) {
            pane.Open(session,accounts,store,subject);
            await Until(()=>pane.Available&&pane.Current!.Exact.ToString()==subject.ToString());
            pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="prolog"&&e.Style=="source"));
            await Until(()=>source.Content.Length>0&&!source.IsWorking);
        }
        var space=accounts.Setup!.Require("account",6)[2];
        string display="transaction(assertz(space_member("+space.Args[2]+","+exact+"))).";
        Check(Json.Committed(await ExecuteComplete(session,store,human,display,CancellationToken.None)),"ordinary display membership references the existing predicate without moving it");
        pane.Open(session,accounts,store,space);
        await Until(()=>pane.Available&&pane.Preview.SubjectIds(exact).Length==1);
        Check(pane.Selected!.Style=="contents","ordinary space contents composes the predicate class visual Eidolon");
        var occurrence=pane.Preview.SubjectIds(exact).Single();var pose=pane.Preview.WorldPose(occurrence);
        var pick=pane.Preview.PickRay(pose.Origin+new Vector3(0,0,3),Vector3.Forward);
        Check(pick?.Subject.ToString()==exact.ToString()&&pick.Id==occurrence,"real composed predicate occurrence is picked as an ordinary exact entity");
        pane.OpenOccurrence(session,accounts,store,pick!);
        await Until(()=>pane.Available&&pane.Current!.Exact.ToString()==exact.ToString());
        pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="prolog"&&e.Style=="source"));
        await Until(()=>source.CanEdit&&source.Content.Contains("predicate_note"));
        Check(source.Content==await Saved()&&source.Content.IndexOf("first")<source.Content.IndexOf("second"),"native ordinary entity selection opens authored source binding in semantic order");
        Check(pane.Current!.Target.Ontology.ToString()==human.Ontology.ToString()&&pane.Current.Local.ToString()==exact.Args[2].ToString(),"ordinary entity reference retains exact namespace genesis and local subject");
        Check(((Button)Form().Input("create")!).Disabled&&((OptionButton)Form().Input("predicate")!).Disabled,"a fixed authored source binding cannot switch its subject via catalogue or creation");
        var system=accounts.Catalogue.Single(a=>a.Namespace=="quod:gui");var systemPredicate=Predicate(system,"isa",2);
        await OpenEditor(Predicate(human,"isa",2));Check(source.CanEdit,"private owner ordinary source instance remains editable");
        await OpenEditor(systemPredicate);
        string systemSource=Json.Binding(await session.Read(human,SignedSession.ViewGoal(tools,Term.Call("prolog_source",system.Ontology,Indicator("isa",2),Term.Variable("Source"))),CancellationToken.None),"Source").TextValue;
        Check(source.Content==systemSource&&!source.CanEdit,"same source lens in another exact owner rebinds without displaying all source");
        await OpenEditor(exact);
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
        var choice=pane.Selected!;var representation=Json.Binding(await session.Read(human,SignedSession.ViewGoal(human,choice.Read(Subject.Decode(exact).Local)),CancellationToken.None),"View");
        var other=Subject.Decode(Predicate(human,"isa",2));bool refused=false;
        try {source.Install(session,accounts,store,other,choice,representation,Term.List());}catch(FormatException){refused=true;}
        Check(refused&&pane.Current!.Exact.ToString()==exact.ToString()&&source.CanEdit,"stale representation for another predicate cannot replace the current exact selection");
        var missing=Predicate(human,"predicate_never_defined",2);
        pane.Open(session,accounts,store,missing);await Until(()=>pane.Available&&pane.Offered.Length==0);
        Check(source.Content.Length==0&&!source.CanEdit,"missing predicate selection cannot fall back to complete ontology source");
        var absent=await Discover(human,missing);Check(Json.Committed(absent)&&Json.Binding(absent,"View").Items.Length==0,"missing predicate has no current source Eidolon");
        var wrong=human with {Anchor=Identity.Encode(new byte[32])};
        var stale=await Discover(wrong,Predicate(wrong,"isa",2));Check(!Json.Committed(stale),"ordinary exact owner routing refuses the wrong genesis");
        var malformed=await Discover(human,Predicate(human,"isa",3));Check(Json.Committed(malformed)&&Json.Binding(malformed,"View").Items.Length==0,"wrong predicate indicator cannot open a different arity");
        var foreign=await SpaceControl(new(){["vector_target"]=new System.Text.Json.Nodes.JsonObject{["namespace"]=human.Namespace,["anchor"]=human.Anchor}});
        var privateOwner=new Actor(Json.S(foreign,"namespace"),Json.S(foreign,"anchor"),"me.");
        var denied=await Discover(privateOwner,Predicate(privateOwner,"isa",2));
        Check(Json.Terminal(denied)&&!Json.Committed(denied),"another private owner denies signed predicate discovery without source disclosure");

        await OpenEditor(systemPredicate);
        Check(!source.CanEdit&&pane.Current!.Exact.ToString()==systemPredicate.ToString(),"system predicate inherits existing read-only source policy");
        var transition=await SpaceControl(new(){["source_access"]="deny"});Check(transition["source_access"]!.ToString()=="deny","ordinary policy owner commits actual source revocation");
        await Until(()=>source.Content.Length==0);Check(!source.CanEdit,"source revocation withdraws the selected predicate editor");
        var revoked=await Discover(system,systemPredicate);Check(!Json.Committed(revoked)||Json.Binding(revoked,"View").Items.Length==0,"revoked source policy cannot rediscover a predicate source choice");
        transition=await SpaceControl(new(){["source_access"]="restore"});Check(transition["source_access"]!.ToString()=="restore","ordinary policy owner restores the original source policy");
        await OpenEditor(systemPredicate);
        await OpenEditor(exact);
        Draft("predicate_note(a,reconnect_draft).\n");var oldSession=app.ActiveSession;
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"ordinary entity consumers fully retire on disconnect");
        await Press("connect");await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&pane.Available&&source.CanEdit&&source.Content.Contains("reconnect_draft"));
        session=app.ActiveSession;accounts=app.ActiveAccounts;store=app.ActiveStore;
        Check(!ReferenceEquals(oldSession,session)&&pane.Current!.Exact.ToString()==exact.ToString()&&State["current_location"]!.ToString()==originalLocation,"reconnect restores exact ordinary entity and guarded draft with unchanged A location");
        string note="transaction((assertz(isa(source_note,thing)),assertz((instance_of(source_note,document):-true)),"+
            "assertz((class_eidolon(source_note,prolog,source,recipe(N,A,note_source)):-current_ontology_identity(N,A))),"+
            "assertz((eidolon(note_source,subject(T,document),V):-quod:root::system_ontology(<<\"quod:gui\">>,A),in_ontology(<<\"quod:gui\">>,A,eidolon(prolog_editor(predicate_note/2),subject(T,document),V)))))).";
        Check(Json.Committed(await ExecuteComplete(session,store,human,note,CancellationToken.None)),"ordinary non-predicate class authors its own source lens recipe in the same ontology");
        var document=Term.Call("entity_ref",identity[0],identity[1],Term.Atom("document"));await OpenEditor(document);
        Check(source.CanEdit&&source.Content.Contains("reconnect_draft")&&pane.Current!.Local.Name=="document","non-predicate entity uses exactly the same authored workspace binding and draft owner");
        await OpenEditor(human.Ontology);
        Check(!((OptionButton)Form().Input("predicate")!).Disabled&&!((Button)Form().Input("create")!).Disabled,"whole ontology source retains its ordinary unbound catalogue and create controls");
        Check(State["current_location"]!.ToString()==originalLocation,"contents and source displays never enter the ontology or change exclusive assignment");
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0,"predicate consumers retire through ordinary disconnect");
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new{passed=true,checks}));
        Console.WriteLine("PREDICATE_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
    }
}
