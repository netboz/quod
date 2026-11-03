using Godot;
using Quod.Client;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task Workbench()
    {
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true && State["operation_available"]?.GetValue<bool>()==true);
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        pane.Changed+=()=>Console.WriteLine("WORKBENCH_PRIVATE_STATUS "+System.Text.Json.JsonSerializer.Serialize(new {pane.StatusText,pane.Available,source=(pane.FindChild("source-tools",true,false) as SourcePanel)?.Status}));
        pane.Open(app.ActiveSession,app.ActiveAccounts,app.ActiveStore,app.ActiveAccounts.Human!.Ontology);
        await Until(()=>pane.Available);
        Check(pane.Offered.Any(e=>e.Style=="workbench"),"exact owned ontology offers its authored graphical workbench");
        var choice=pane.Offered.Single(e=>e.Style=="workbench");
        var direct=await app.ActiveSession.Read(app.ActiveAccounts.Human!,SignedSession.ViewGoal(pane.Current!.Target,choice.Read(pane.Current.Local)),CancellationToken.None);
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".recipe.json",direct.ToJsonString());
        Check(Json.Committed(direct),"actual workbench recipe query completes under its normal signed target boundary");
        pane.Choose(choice);
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        var graph=(WorkbenchPanel)pane.FindChild("ontology-workbench",true,false);
        var scene=(ScenePanel)pane.FindChild("representation-scene",true,false);
        await Until(()=>graph.Visible&&source.CanEdit&&source.Content.Length>0);
        Check(scene.Count>0,"actual authored graph enters the existing shared scene adapter");
        if(System.Environment.GetEnvironmentVariable("WORKBENCH_ONLY")=="draft-fault")await WorkbenchDraftFault(source);
        else if(System.Environment.GetEnvironmentVariable("WORKBENCH_ONLY")=="controls")await WorkbenchControls(pane,source,graph,scene,Json.Binding(direct,"View"));
        else if(System.Environment.GetEnvironmentVariable("WORKBENCH_ONLY")=="generation")await WorkbenchGeneration(pane,source);
        else await WorkbenchActions(pane,source,graph,scene);
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0,"workbench consumers retire through ordinary disconnect");
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { passed=true,checks }));
        Console.WriteLine("WORKBENCH_PASS "+checks.Count);Console.Out.Flush();await app.CloseApplication();
    }
    async Task WorkbenchControls(EidolonPanel pane,SourcePanel source,WorkbenchPanel graph,ScenePanel scene,Term representation)
    {
        graph.Select(app.ActiveAccounts.Human!.Entity);
        var form=(FormPanel)graph.FindChild("workbench-form",true,false);var facts=(OptionButton)form.Input("fact")!;
        facts.Select(1);facts.EmitSignal(OptionButton.SignalName.ItemSelected,1L);
        string fact=facts.GetItemText(1);var field=(LineEdit)form.Input("class_name")!;
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var reveal=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);SpatialGui.Reveal(field,()=>GodotObject.IsInstanceValid(field),()=>reveal.TrySetResult());await reveal.Task.WaitAsync(TimeSpan.FromSeconds(10));
        gui.Move(field.GetGlobalRect().GetCenter());await Frame();gui.Press();await Frame();gui.Release();await Frame();
        Check(field.HasFocus()&&gui.Captures==0,"ordinary native pointer focuses the workbench text input");
        field.SelectAll();foreach(char character in "unsubmitted_class"){using var key=new InputEventKey {Pressed=true,Unicode=character};gui.Surface.PushInput(key,true);}await Frame();
        Check(field.Text=="unsubmitted_class"&&form.Draft["class_name"]==field.Text,"native text input reaches the single existing FormPanel draft owner");
        var selected=graph.Selected;int updates=graph.Updates,rebuilt=scene.Rebuilt,reads=source.SnapshotReads;
        var editor=((FormPanel)source.FindChild("source-form",true,false)).Input("source");
        byte[] bytes=System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"));
        var original=representation.Require("workbench",6);var c=original[4].Require("component",4);
        var properties=c[2].Items.Select(p=>p.Require("property",2)[0].Name=="label" ? Term.Call("property",Term.Atom("label"),Term.Text("Ontology workbench - compatible label")) : p).ToArray();
        var controls=Term.Call("component",c[0],c[1],Term.List(properties),c[3]);
        graph.Install(app.ActiveAccounts.Human!,original[3],controls);
        Check(((OptionButton)form.Input("node")!).ItemCount>1&&((OptionButton)form.Input("fact")!).Selected>0,"same authorized graph plus changed controls repopulates the real native catalogues");
        Check(((LineEdit)form.Input("class_name")!).Text=="unsubmitted_class"&&graph.Selected?.ToString()==selected?.ToString(),"same-scope compatible field/selection inputs survive native control reconstruction");
        Check(graph.Updates==updates&&scene.Rebuilt==rebuilt&&source.SnapshotReads==reads&&bytes.SequenceEqual(System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"))),"descriptor-only native update does not rebuild graph/scene/source or persist a draft");
        var reply=await SpaceControl(new(){["workbench_controls"]=true});Check(reply["controls_changed"]!.GetValue<bool>(),"ordinary fixture administrator commits a controls-only recipe change");
        await Until(()=>form.Descriptor.Tree.Label.Contains("updated controls"));
        Check(((OptionButton)form.Input("node")!).ItemCount>1&&((OptionButton)form.Input("fact")!).GetItemText(((OptionButton)form.Input("fact")!).Selected)==fact&&graph.Selected==selected,"same graph plus changed authored controls retains usable exact node/fact catalogues and selection");
        Check(((LineEdit)form.Input("class_name")!).Text=="unsubmitted_class"&&ReferenceEquals(editor,((FormPanel)source.FindChild("source-form",true,false)).Input("source")),"compatible workbench fields and the single source editor survive a descriptor-only change");
        Check(bytes.SequenceEqual(System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"))),"actual recipe refresh preserves the local draft store while retaining its authorization withdrawal fence");
    }
    async Task WorkbenchDraftFault(SourcePanel source)
    {
        byte[] before=System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"));bool failed=false;
        app.ActiveStore.DurabilityBoundary=point=>{if(point=="before-rename"){failed=true;throw new System.IO.IOException("Controlled workbench draft storage failure.");}};
        try {source.PrepareFact(Term.Call("add",Term.Call("isa",Term.Atom("workbench_visible_failure"),Term.Atom("thing"))));await source.Completion;}
        finally{app.ActiveStore.DurabilityBoundary=null;}
        Check(failed&&source.Status.Contains("Controlled workbench draft storage failure")&&source.Content.Contains("workbench_visible_failure"),"failed draft persistence reports the failure and keeps the actual prepared text visible");
        Check(before.SequenceEqual(System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json")))&&!app.ActiveStore.Snapshot!.Pending.Any(),"draft persistence failure commits no invisible source or signed pending work");
    }
    async Task WorkbenchGeneration(EidolonPanel pane,SourcePanel source)
    {
        // Reuse Stage2's single real-continuation seam on the original executor.
        var context=SynchronizationContext.Current!;var held=new HeldPrepareContinuation(context);bool released=false;
        byte[] before=System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"));
        SynchronizationContext.SetSynchronizationContext(held);
        try{source.PrepareFact(Term.Call("add",Term.Call("isa",Term.Atom("workbench_cancelled_scope"),Term.Atom("thing"))));}
        finally{SynchronizationContext.SetSynchronizationContext(context);}
        try {
            await held.Arrived.WaitAsync(TimeSpan.FromSeconds(10));
            pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="prolog"&&e.Style=="source"));
            await Until(()=>source.Visible&&pane.StatusText.StartsWith("Authorized inspection"));
            held.Release();released=true;await source.Completion;
            Check(!source.Content.Contains("workbench_cancelled_scope")&&!app.ActiveStore.Snapshot!.SourceDrafts.Values.Any(d=>d.Text.Contains("workbench_cancelled_scope")),"completed predicate read cannot apply an old graph preparation after representation replacement");
            Check(before.SequenceEqual(System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json")))&&!app.ActiveStore.Snapshot!.Pending.Any(),"cancelled graph preparation leaves profile bytes and original signed work unchanged");
        }finally{if(!released&&held.Arrived.IsCompletedSuccessfully)held.Release();}
    }
    sealed class HeldPrepareContinuation(SynchronizationContext owner) : SynchronizationContext
    {
        readonly TaskCompletionSource arrived=new(TaskCreationOptions.RunContinuationsAsynchronously);
        SendOrPostCallback? callback;object? state;int held;
        public Task Arrived=>arrived.Task;
        public override void Post(SendOrPostCallback next,object? value)
        {
            if(value is Action action&&action.Target?.GetType().FullName?.Contains("PrepareFact")==true&&Interlocked.CompareExchange(ref held,1,0)==0){callback=next;state=value;arrived.TrySetResult();}
            else owner.Post(next,value);
        }
        public void Release(){var next=callback??throw new InvalidOperationException("No real continuation arrived.");callback=null;owner.Post(next,state);}
    }
    async Task WorkbenchActions(EidolonPanel pane,SourcePanel source,WorkbenchPanel graph,ScenePanel scene)
    {
        var session=app.ActiveSession;var accounts=app.ActiveAccounts;var human=accounts.Human!;
        var tools=accounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);gui.Surface.GuiEmbedSubwindows=true;
        var graphForm=(FormPanel)graph.FindChild("workbench-form",true,false);
        var sourceForm=(FormPanel)source.FindChild("source-form",true,false);
        async Task Reveal(Control c){var done=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>done.TrySetResult());await done.Task.WaitAsync(TimeSpan.FromSeconds(10));}
        async Task Pixel(Vector2 pixel){gui.Move(pixel);await Frame();gui.Press();await Frame();gui.Release();await Frame();Check(gui.Captures==0,"native Control gesture releases its actual capture");}
        async Task Click(Control c){await Reveal(c);
            if(!c.IsVisibleInTree()||!new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(c.GetGlobalRect()))
                await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".click-target.json",System.Text.Json.JsonSerializer.Serialize(new {visible=c.IsVisibleInTree(),rect=c.GetGlobalRect().ToString(),surface=gui.Surface.Size.ToString(),source_visible=source.Visible,source_in_tree=source.IsVisibleInTree(),graph_visible=graph.Visible,pane.Available}));
            Check(c.IsVisibleInTree()&&new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(c.GetGlobalRect()),"workbench action is enclosed by the actual shared surface");
            int pressed=0;void Got()=>pressed++;if(c is BaseButton button)button.Pressed+=Got;
            try{await Pixel(c.GetGlobalRect().GetCenter());}finally{if(c is BaseButton b)b.Pressed-=Got;}
            if(c is BaseButton)Check(pressed==1,"actual native button receives exactly one Pressed at its displayed target");}
        IEnumerable<Node> Children(Node n){foreach(Node c in n.GetChildren(true)){yield return c;foreach(var d in Children(c))yield return d;}}
        async Task Select(OptionButton c,int i){
            Check(i>=0&&i<c.ItemCount,"actual authored workbench option exists");await Click(c);await Frame();var p=c.GetPopup();
            Check(p.Visible,"real workbench native menu opens");
            await System.IO.File.AppendAllTextAsync(Env("M1B_RESULT")+".popups.jsonl",System.Text.Json.JsonSerializer.Serialize(new {position=p.Position.ToString(),size=p.Size.ToString(),maximum=p.MaxSize.ToString(),surface=gui.Surface.Size.ToString(),font=p.GetThemeFontSize("font_size","PopupMenu"),items=p.ItemCount})+"\n");
            Check(new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(new Rect2((Vector2)p.Position,(Vector2)p.Size)),"opened workbench native menu stays within the actual surface");p.ScrollToItem(i);await Frame();
            var scroll=Children(p).OfType<ScrollContainer>().Single(v=>v.IsVisibleInTree());
            var items=scroll.GetChildren(true).OfType<Control>().Single(v=>v.GetClass()=="PopupMenuItems");
            int font=p.GetThemeFontSize("font_size","PopupMenu"),gap=p.GetThemeConstant("v_separation","PopupMenu");
            float h=Math.Max(p.GetThemeFont("font","PopupMenu").GetHeight(font),p.GetThemeIcon("radio_checked","PopupMenu").GetHeight());
            await Pixel((Vector2)p.Position+items.GlobalPosition+new Vector2(60,i*(h+gap)+gap+h/2));
            Check(c.Selected==i&&!p.Visible,"real native popup selects the exact workbench item once");
        }
        async Task PickNode(Term exact){var c=(OptionButton)graphForm.Input("node")!;int i=Enumerable.Range(1,c.ItemCount-1).Single(i=>c.GetItemTooltip(i)==exact.ToString());await Select(c,i);Check(graph.Selected?.ToString()==exact.ToString(),"graph/list selection retains the exact anchored subject");}
        async Task<string> Saved()=>await session.ReadSource(human,tools,human,CancellationToken.None);
        async Task Prepare(string role,string text){
            if(text.Length>0) {
                var fact=Term.Parse(text);
                if(fact.Name=="isa") {
                    ((LineEdit)graphForm.Input("class_name")!).Text=fact.Args[0].Name;
                    var parent=(OptionButton)graphForm.Input("parent")!;await Select(parent,Enumerable.Range(1,parent.ItemCount-1).Single(i=>Subject.Decode(Term.Parse(parent.GetItemTooltip(i))).Local.ToString()==fact.Args[1].ToString()));
                    if(role=="add_fact")role="add_class";
                } else {
                    if(role=="add_fact") {await PickNode(Term.Call("entity_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),fact.Args[0]));role="add_attribute";}
                    ((LineEdit)graphForm.Input("attribute_name")!).Text=fact.Args[1].Name;
                    ((LineEdit)graphForm.Input("attribute_value")!).Text=fact.Args[2].TextValue;
                }
            }
            var before=new {role,selectedFact=typeof(WorkbenchPanel).GetField("selectedFact",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance)!.GetValue(graph)?.ToString(),source=source.Content,source.Status,source.CanEdit};
            await Click(graphForm.Input(role)!);await source.Completion;
            await System.IO.File.AppendAllTextAsync(Env("M1B_RESULT")+".preparations.jsonl",System.Text.Json.JsonSerializer.Serialize(new {before,after=new {source=source.Content,source.Status,source.CanEdit}})+"\n");
        }
        bool HasFact(Term fact)=>((Term[])typeof(WorkbenchPanel).GetField("facts",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance)!.GetValue(graph)!).Any(f=>f.ToString()==fact.ToString());
        async Task Save(Term? present=null,Term? absent=null){
            await Click(sourceForm.Input("run")!);await source.Completion;Check(!((Button)sourceForm.Input("accept")!).Disabled,"prepared workbench draft uses the existing proof Preview");
            await Click(sourceForm.Input("accept")!);await source.Completion;
            await Until(()=>pane.Available&&graph.Visible&&(source.CanEdit||app.ActiveStore.Snapshot!.Pending.Count>0&&sourceForm.Input("resolve") is Button {Disabled:false}));
            if(app.ActiveStore.Snapshot!.Pending.SingleOrDefault() is SignedWork original) {
                Check(original.SourceDraft!=null,"an uncertain workbench Save retains its original submitted source metadata");
                await Click(sourceForm.Input("resolve")!);await source.Completion;
                Check(!app.ActiveStore.Snapshot!.Pending.Any(w=>w.Id==original.Id),"existing original-outcome action settles the retained Save without a second submission");
                await Click((Control)source.FindChild("source-reload",true,false));await source.Completion;
            }
            Check(!app.ActiveStore.Snapshot!.Pending.Any(),"explicit Save settles the original signed work once");
            await Until(()=>pane.Available&&graph.Visible&&source.CanEdit&&(present==null||HasFact(present))&&(absent==null||!HasFact(absent)));
            Check(true,"current accepted graph delivers the committed fact change before the next native gesture");
        }
        Term Class(string c)=>Term.Call("class_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom(c));
        if(System.Environment.GetEnvironmentVariable("WORKBENCH_ONLY")=="framing"){await WorkbenchFraming(scene);return;}
        if(System.Environment.GetEnvironmentVariable("WORKBENCH_ONLY")=="layout"){await WorkbenchLayout(gui,graph,graphForm,source,Select);return;}
        string location=State["current_location"]!.ToString(),assignment=State["assignment_revision"]!.ToString();
        var ids=scene.SubjectIds(Class("space"));Check(ids.Length==1,"authored class mark is the same exact class_ref used by offered operations");
        var labels=scene.SceneRoot.FindChildren("*","Label3D",true,false).OfType<Label3D>().ToArray();
        Check(labels.Length==((OptionButton)graphForm.Input("node")!).ItemCount-1&&labels.All(l=>l.FontSize==32&&Math.Abs(l.PixelSize-.005f)<.000001f),"each authored graph node has exactly one readable native scene label");
        string fakeNs="workbench-scene-example";var fakeAnchor=Term.Binary(new byte[32]);
        var wrongClass=Term.Call("class_ref",Term.Text("other-owner"),fakeAnchor,Term.Atom("thing"));
        var fakeMark=Term.Call("mark",Term.Text("example"),Term.Text("group"),Term.List(),Term.Parse("transform(0,0,0,0,0,0)"),Term.Atom("no_surface"),Term.Atom("unlabelled"),Term.Call("depicts",Term.Text(fakeNs),fakeAnchor,wrongClass));
        Check(SceneMark.Decode(Term.List(fakeMark)).Single().Subject?.Name=="entity_ref","class mark decoding never unwraps a mismatched owner namespace");
        if(DisplayServer.GetName()!="headless") {
            await Reveal(scene);await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            var path=Env("M4_MORNING_IMAGES");System.IO.Directory.CreateDirectory(path);
            using var image=scene.GetChildren().OfType<SubViewport>().Single().GetTexture().GetImage();
            Check(image.SavePng(System.IO.Path.Combine(path,"workbench-scene.png"))==Error.Ok,"actual shared graph raster retained for visual inspection");
        }
        await WorkbenchFraming(scene);
        var corners=scene.WorldCorners(ids[0]);var centre=(corners[0]+corners[^1])/2;
        Check(scene.PickRay(centre+Vector3.Back*10,Vector3.Forward)?.ToString()==Class("space").ToString(),"shared real scene picker preserves the class/history identity");
        int updates=graph.Updates,rebuilt=scene.Rebuilt,reads=source.SnapshotReads;
        byte[] before=System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"));
        using(var probe=new System.Net.Sockets.TcpClient()) {
            using var stop=new CancellationTokenSource(TimeSpan.FromSeconds(30));await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),stop.Token);
            using var stream=probe.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),stop.Token);
            Check(System.Text.Json.Nodes.JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!["ready"]!.GetValue<bool>(),"real owner work observation precedes unchanged workbench renewals");
            var view=(SignedView)typeof(EidolonPanel).GetField("representation",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance)!.GetValue(pane)!;
            for(int i=0;i<3;i++){var received=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Got(System.Text.Json.Nodes.JsonNode _)=>received.TrySetResult();view.Projection+=Got;try{await view.Renew();await received.Task.WaitAsync(stop.Token);}finally{view.Projection-=Got;}}
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),stop.Token);var work=System.Text.Json.Nodes.JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!;
            await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".work.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0,"unchanged workbench renewals perform zero watched history/rebuild/write/sync work");
        }
        Check(graph.Updates==updates&&scene.Rebuilt==rebuilt&&source.SnapshotReads==reads&&before.SequenceEqual(System.IO.File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"))),"unchanged workbench retains graph, scene, source snapshot and local storage bytes");
        string committed=await Saved();await Prepare("add_fact","isa(workbench_demo,thing)");
        Check(source.Content.Contains("workbench_demo")&&await Saved()==committed&&!app.ActiveStore.Snapshot!.Pending.Any(),"graph preparation changes only the same local draft before Preview/Save");
        await Click(sourceForm.Input("run")!);await source.Completion;await Click(sourceForm.Input("stop")!);await source.Completion;
        Check(await Saved()==committed&&source.Content.Contains("workbench_demo"),"Cancel Preview retains graph draft without a commit");
        await Save(Term.Parse("isa(workbench_demo,thing)"));await Until(()=>((OptionButton)graphForm.Input("node")!).ItemCount>1&&Enumerable.Range(1,((OptionButton)graphForm.Input("node")!).ItemCount-1).Any(i=>((OptionButton)graphForm.Input("node")!).GetItemTooltip(i)==Class("workbench_demo").ToString()));
        Check((await Saved()).Contains("isa(workbench_demo, thing)"),"explicit guarded class creation reads back through the same committed text owner");
        await Prepare("add_fact","attribute(me,workbench_note,<<\"one\">>)");await Save(Term.Parse("attribute(me,workbench_note,<<\"one\">>)"));
        Check((await Saved()).Contains("workbench_note"),"ground attribute creation commits through the same guarded source compiler");
        await PickNode(human.Entity);var factChoice=(OptionButton)graphForm.Input("fact")!;
        int fact=Enumerable.Range(1,factChoice.ItemCount-1).Single(i=>factChoice.GetItemText(i).Contains("workbench_note"));await Select(factChoice,fact);
        await Prepare("replace_fact","attribute(me,workbench_note,<<\"two\">>)");await Save(Term.Parse("attribute(me,workbench_note,<<\"two\">>)"));
        Check((await Saved()).Contains("<<\"two\">>"),"selected attribute replacement is visible in the sibling text representation");
        await PickNode(human.Entity);factChoice=(OptionButton)graphForm.Input("fact")!;await Select(factChoice,Enumerable.Range(1,factChoice.ItemCount-1).Single(i=>factChoice.GetItemText(i).Contains("workbench_note")));
        await Prepare("replace_fact","attribute(me,workbench_note,<<\"local\">>)");
        Check(Json.Committed(await ExecuteComplete(session,app.ActiveStore,human,"transaction((retract(attribute(me,workbench_note,<<\"two\">>)),assertz(attribute(me,workbench_note,<<\"concurrent\">>)))).",CancellationToken.None)),"a deliberate independent commit establishes a real stale-baseline race");
        await Until(()=>pane.Available&&graph.Visible&&source.CanEdit&&HasFact(Term.Parse("attribute(me,workbench_note,<<\"concurrent\">>)")));
        Check(source.Visible&&source.IsVisibleInTree(),"same-representation committed refresh retains the already opened source editor");await Click(sourceForm.Input("run")!);await source.Completion;
        Check(((Button)sourceForm.Input("accept")!).Disabled&&source.Content.Contains("local")&&(await Saved()).Contains("concurrent"),"stale graph draft cannot replace a concurrent committed change and is retained");
        await Click((Control)source.FindChild("source-discard",true,false));await source.Completion;
        await PickNode(human.Entity);factChoice=(OptionButton)graphForm.Input("fact")!;await Select(factChoice,Enumerable.Range(1,factChoice.ItemCount-1).Single(i=>factChoice.GetItemText(i).Contains("workbench_note")));
        await Prepare("remove_fact","");await Save(null,Term.Parse("attribute(me,workbench_note,<<\"concurrent\">>)"));
        Check(!(await Saved()).Contains("workbench_note"),"explicit fact removal has exact committed readback without cascade or replacement identity");
        Check(State["current_location"]!.ToString()==location&&State["assignment_revision"]!.ToString()==assignment,"graph picking and source edits create no containing-space assignment or domain placement");
        // Normal instance construction remains the existing class-offered action,
        // not a caller-chosen ID smuggled into the source-draft transformer.
        await PickNode(Class("space"));await Click(graphForm.Input("open_subject")!);
        await Until(()=>pane.Operations.Available&&pane.Operations.Current!=null);
        Check(pane.Current!.Exact.ToString()==Class("space").ToString(),"graph class action opens the identical anchored class through the existing dispatcher");
        var operations=pane.Operations;
        if(operations.Current!.Name!="create")pane.Choose(pane.Offered.Single(e=>e.Operation&&e.Style=="create"));
        await Until(()=>operations.Current?.Name=="create"&&operations.Available);
        var placement=operations.Current!.Form.Tree.Leaves.Single(c=>c.Role=="space_placement");
        await Select((OptionButton)operations.FormPanel.Input("space_placement")!,Array.FindIndex(placement.Options,o=>o.Value.Name=="unplaced"));
        var name=(LineEdit)operations.FormPanel.Input("space_name")!;await Click(name);name.SelectAll();
        foreach(char character in "Workbench object"){using var key=new InputEventKey {Pressed=true,Unicode=character};gui.Surface.PushInput(key,true);}await Frame();
        Check(operations.FormPanel.Draft["space_name"]=="Workbench object","native instance-name input reaches the actual offered form draft");
        int instructions=Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length;
        int clicks=0;var submit=(Button)operations.FormPanel.Input(operations.Current.Form.Submit.ToString())!;void Clicked()=>clicks++;submit.Pressed+=Clicked;
        try{await Click(submit);await Until(()=>!operations.IsWorking);}finally{submit.Pressed-=Clicked;}
        Check(clicks==1&&operations.LastOutcome!=null&&Json.Committed(operations.LastOutcome),"one native Create press commits through the actual governed personal-agent action");
        var created=Result(SpaceResults(operations.LastOutcome!),"space");
        Check(Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length==instructions+1&&!app.ActiveStore.Snapshot!.Pending.Any(),"normal offered creation adds exactly one original instruction with no replay");
        pane.Open(session,accounts,app.ActiveStore,human.Ontology);await Until(()=>pane.Available);pane.Choose(pane.Offered.Single(e=>e.Style=="workbench"));await Until(()=>graph.Visible&&source.CanEdit);
        Check((await Saved()).Contains(Subject.Decode(created).Local.ToString()),"generated instance identity is read back through the same ontology source");
        await WorkbenchLayout(gui,graph,graphForm,source,Select);
        await PickNode(created);factChoice=(OptionButton)graphForm.Input("fact")!;await Select(factChoice,Enumerable.Range(1,factChoice.ItemCount-1).Single(i=>factChoice.GetItemText(i).StartsWith("instance_of(")));
        await Prepare("remove_fact","");await Save(null,Term.Call("instance_of",Term.Atom("space"),Subject.Decode(created).Local));
        await Until(()=>!Enumerable.Range(1,((OptionButton)graphForm.Input("node")!).ItemCount-1).Any(i=>((OptionButton)graphForm.Input("node")!).GetItemTooltip(i)==created.ToString()));
        graph.Select(created);Check(graph.Selected==null&&scene.SubjectIds(created).Length==0,"membership removal retires the deleted node and stale picks cannot revive it");
        Check((await Saved()).Contains(Subject.Decode(created).Local.ToString())&&State["current_location"]!.ToString()==location,"raw membership removal has no cascade, history deletion or containing-space mutation");
        var system=accounts.Catalogue.Single(a=>a.Namespace=="quod:controllers");
        pane.Open(session,accounts,app.ActiveStore,system.Ontology);await Until(()=>pane.Available);pane.Choose(pane.Offered.Single(e=>e.Style=="workbench"));
        await Until(()=>graph.Visible&&source.Content.Length>0);
        Check(!source.CanEdit&&((Button)graphForm.Input("add_class")!).Disabled&&scene.Count>0,"system read-only ontology uses the same graph and native controls without edit authority");
        await Transition(new(){["source_access"]="deny"});await Until(()=>!graph.Visible&&source.Content.Length==0);
        Check(scene.Count==0&&!source.CanEdit&&State["world_accepted"]?.GetValue<bool>()==true,"actual source denial withdraws only its graph/scene/editor while the independent world remains accepted");
        await Transition(new(){["source_access"]="restore"});
        var wrong=system with {Anchor=Identity.Encode(new byte[32])};pane.Open(session,accounts,app.ActiveStore,wrong.Ontology);await Until(()=>pane.StatusText.StartsWith("Unavailable"));
        Check(!pane.Available&&scene.Count==0&&source.Content.Length==0,"wrong history anchor cannot show another ontology graph");
        await Press("disconnect");await app.ViewsDisposed;await Press("connect");await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
        var retired=pane;pane=(EidolonPanel)app.FindChild("representations",true,false);
        source=(SourcePanel)pane.FindChild("source-tools",true,false);graph=(WorkbenchPanel)pane.FindChild("ontology-workbench",true,false);
        Check(!ReferenceEquals(retired,pane),"ordinary reconnect supplies the new Main-owned representation consumer");
        pane.Open(app.ActiveSession,app.ActiveAccounts,app.ActiveStore,human.Ontology);await Until(()=>pane.Available);pane.Choose(pane.Offered.Single(e=>e.Style=="workbench"));await Until(()=>graph.Visible&&source.CanEdit);
        Check(source.Content.Contains("workbench_demo")&&!source.Content.Contains("workbench_note"),"ordinary reconnect observes the original committed workbench state without replay");
    }
    async Task WorkbenchFraming(ScenePanel scene)
    {
        await Frame();
        var viewport=scene.Viewport;var camera=viewport.GetChildren().OfType<Camera3D>().Single();
        var corners=scene.Ids.SelectMany(scene.WorldCorners).Select(camera.UnprojectPosition).ToArray();
        var min=corners.Aggregate((a,b)=>a.Min(b));var max=corners.Aggregate((a,b)=>a.Max(b));var rect=new Rect2(min,max-min);
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".framing.json",System.Text.Json.JsonSerializer.Serialize(new {viewport=viewport.Size.ToString(),bounds=rect.ToString(),horizontal=rect.Size.X/viewport.Size.X,vertical=rect.Size.Y/viewport.Size.Y}));
        Check(new Rect2(Vector2.Zero,viewport.Size).Encloses(rect),"shared scene framing encloses the actual graph in its current viewport");
        Check(Math.Max(rect.Size.X/viewport.Size.X,rect.Size.Y/viewport.Size.Y)>=.7f,"shared scene framing uses the available viewport rather than a tiny diameter-based preview");
        var labelRects=new List<Rect2>();
        foreach(var label in scene.SceneRoot.FindChildren("*","Label3D",true,false).OfType<Label3D>()) {
            var pixel=label.GenerateTriangleMesh()!.GetFaces().Select(p=>camera.UnprojectPosition(label.GlobalPosition+camera.Basis*p)).ToArray();
            var lo=pixel.Aggregate((a,b)=>a.Min(b));var hi=pixel.Aggregate((a,b)=>a.Max(b));
            var bounds=new Rect2(lo,hi-lo);labelRects.Add(bounds);
            Check(new Rect2(Vector2.Zero,viewport.Size).Encloses(bounds),"native shaped graph label remains inside its actual viewport");
        }
        await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".label-bounds.json",System.Text.Json.JsonSerializer.Serialize(labelRects.Select(r=>r.ToString())));
        Check(!labelRects.Where((a,i)=>labelRects.Skip(i+1).Any(b=>a.Intersects(b))).Any(),"native graph captions do not overlap neighbouring captions");
    }
    async Task WorkbenchLayout(SpatialGui gui,WorkbenchPanel graph,FormPanel form,SourcePanel source,Func<OptionButton,int,Task> select)
    {
        int originalFont=gui.Appearance.DefaultFontSize;var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var world=(ScenePanel)app.FindChild("space-scene",true,false);bool worldVisible=world.Visible;world.Hide();xr.PresentWorkspace(true);
        Check(!app.FindChild("endpoint",true,false).Get("visible").AsBool()||!((Control)app.FindChild("endpoint",true,false)).IsVisibleInTree(),"the actual workspace owner hides the desktop connection shell for spatial presentation");
        bool Enclosed(Control c){var r=c.GetGlobalRect();if(!new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(r))return false;for(Node? n=c.GetParent();n!=null&&n!=gui.Surface;n=n.GetParent())if(n is Control {ClipContents:true} clip&&!clip.GetGlobalRect().Encloses(r))return false;return true;}
        foreach(int font in new[]{26,48}) {
            gui.TextSize(font-gui.Appearance.DefaultFontSize);await Frame();await Frame();
            foreach(string role in new[]{"node","fact","class_name","parent","attribute_name","attribute_value","add_class","add_attribute","replace_fact","remove_fact","open_subject","show_source"}) {
                var c=form.Input(role)!;var done=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>done.TrySetResult());await done.Task.WaitAsync(TimeSpan.FromSeconds(10));
                if(!Enclosed(c))await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".layout-target.json",System.Text.Json.JsonSerializer.Serialize(new {font,role,rect=c.GetGlobalRect().ToString(),surface=gui.Surface.Size.ToString(),form_min=form.GetCombinedMinimumSize().ToString(),buttons=form.FindChildren("*","Button",true,false).OfType<Button>().Select(b=>new {role=b.HasMeta("role")?b.GetMeta("role").ToString():"",minimum=b.GetCombinedMinimumSize().ToString(),rect=b.GetGlobalRect().ToString()}).ToArray()}));
                Check(Enclosed(c)&&c.Size.Y>=44,"workbench native target is enclosed by real clipping owners at text size "+font);
                gui.Move(c.GetGlobalRect().GetCenter());await Frame();var hit=gui.Surface.GuiGetHoveredControl();Check(hit==c||hit!=null&&c.IsAncestorOf(hit),"workbench hit-test matches displayed action at text size "+font);
            }
            var node=(OptionButton)form.Input("node")!;string text=source.Content;await select(node,Math.Max(1,node.Selected));
            Check(source.Content==text&&!app.ActiveStore.Snapshot!.Pending.Any(),"large-text native node selection changes no source draft or signed work");
            if(DisplayServer.GetName()!="headless") {var path=Env("M4_MORNING_IMAGES");System.IO.Directory.CreateDirectory(path);await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng(System.IO.Path.Combine(path,"workbench-"+font+".png"))==Error.Ok,"actual workbench raster retained at text size "+font);}
        }
        xr.PresentWorkspace(false);world.Visible=worldVisible;gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);gui.Size=new(600,900);await Frame();await Frame();
        var field=form.Input("node")!;var ready=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);SpatialGui.Reveal(field,()=>GodotObject.IsInstanceValid(field),()=>ready.TrySetResult());await ready.Task.WaitAsync(TimeSpan.FromSeconds(10));
        if(!Enclosed(field))await System.IO.File.WriteAllTextAsync(Env("M1B_RESULT")+".narrow-target.json",System.Text.Json.JsonSerializer.Serialize(new {rect=field.GetGlobalRect().ToString(),surface=gui.Surface.Size.ToString(),world_min=world.GetCombinedMinimumSize().ToString(),preview_min=((ScenePanel)graph.GetParent().FindChild("representation-scene",true,false)).GetCombinedMinimumSize().ToString()}));
        Check(Enclosed(field),"same workbench reflows on narrow desktop without shrinking text");
        gui.TextSize(originalFont-gui.Appearance.DefaultFontSize);gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);
    }
}
