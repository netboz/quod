using Godot;
using Quod.Client;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json = Quod.Client.Json;
using File = System.IO.File;

public partial class ExportChecks
{
    async Task<JsonNode> SpaceControl(JsonObject command)
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        using var socket = new TcpClient(); await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),cancellation.Token);
        using var stream=socket.GetStream(); await stream.WriteAsync(Encoding.UTF8.GetBytes(command.ToJsonString()+"\n"),cancellation.Token);
        using var input=new StreamReader(stream); return JsonNode.Parse((await input.ReadLineAsync(cancellation.Token))!)!;
    }
    async Task Choose(OptionButton control, int index)
    {
        Check(index >= 0 && index < control.ItemCount,"offered selection exists: "+control.Name);
        control.Select(index); control.EmitSignal(OptionButton.SignalName.ItemSelected,index); await Frame();
    }
    // Actions are chosen through the subject's own pie, as a user does: the
    // wedge path is found in the authored tree, then committed level by level.
    async Task ChooseOfferedOperation(OperationsPanel panel,string name,Term? subject=null)
    {
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        await Until(()=>pane.Available&&panel.Available);
        var pie=(PieMenu)app.FindChild("pie-menu",true,false);
        if(!pie.IsOpen)Check(app.OpenSubjectPie(subject??pane.Current!.Exact),"the subject's pie opens");
        await Until(()=>pie.Navigator!=null||!pie.IsOpen);
        Check(pie.Navigator!=null,"the subject's authored pie arrives: "+app.Inspect());
        List<MenuNode>? Path(MenuNode node)=>node.Leaf
            ? (node.Target!.Choice.Require("eidolon",3)[1].Name==name&&node.Target.Choice.Args[0].Name=="operation" ? [node] : null)
            : node.Children.Select(c=>Path(c) is {} p ? p.Prepend(node).ToList() : null).FirstOrDefault(p=>p!=null);
        var path=Path(pie.Navigator!.Root)??throw new Exception("No wedge offers "+name);
        foreach(var step in path.Skip(1)) {
            Check(pie.Choose(step.Slot),"wedge "+step.Label+" is on the current level");
            if(step.Leaf&&step.Confirm)pie.Commit();
            pie.Commit();
        }
        await Until(()=>panel.Current?.Name==name);
    }
    async Task ChooseNativeOption(OptionButton control,int index)
    {
        Check(index>0 && index<control.ItemCount,"offered choice has an explicit native menu item");
        for(Node? node=control.GetParent();node!=null;node=node.GetParent()) if(node is ScrollContainer scroll) scroll.EnsureControlVisible(control);
        control.GrabFocus(); await Frame();
        var selected=new TaskCompletionSource<long>(); void Selected(long value)=>selected.TrySetResult(value); control.ItemSelected+=Selected;
        try {
            var popup=control.GetPopup();
            var opened=new TaskCompletionSource(); void Opened()=>opened.TrySetResult(); popup.AboutToPopup+=Opened;
            try {
                Console.WriteLine("M2_NATIVE_KEY space"); Console.Out.Flush();
                await opened.Task.WaitAsync(TimeSpan.FromSeconds(5));
            } finally { popup.AboutToPopup-=Opened; }
            await Frame();
            Check(popup.Visible,"native keyboard opens the offered choice menu");
            popup.SetFocusedItem(index);
            Console.WriteLine("M2_NATIVE_KEY Return"); Console.Out.Flush();
            Check(await selected.Task.WaitAsync(TimeSpan.FromSeconds(5))==index && control.Selected==index,"native menu confirms the selected offered choice");
        } finally { control.ItemSelected-=Selected; }
        await Frame();
        Check(!control.GetPopup().Visible,"confirmed native choice menu is closed");
        var root=GetTree().Root;
        var received=new TaskCompletionSource();
        void InputReceived(InputEvent input) { if(input is InputEventKey { Keycode:Key.F24,Pressed:true } key && key.WindowId==root.GetWindowId()) received.TrySetResult(); }
        root.WindowInput+=InputReceived;
        try {
            Console.WriteLine("M2_NATIVE_KEY F24"); Console.Out.Flush();
            await received.Task.WaitAsync(TimeSpan.FromSeconds(5));
        } finally { root.WindowInput-=InputReceived; }
        Check(received.Task.IsCompletedSuccessfully,"after popup closure real native input reaches the exact root window");
    }
    void NativeInput(InputEventFromWindow input)
    { input.WindowId=GetTree().Root.GetWindowId(); Input.ParseInputEvent(input); }
    // A control's centre where the real pointer must go: through the shared
    // GUI's surfaces and mirrors when the control lives on one of them.
    Vector2 OnWindow(Control control)=>((SpatialGui)app.FindChild("shared-gui",true,false)).WindowPoint(control.GetViewport(),control.GetGlobalRect().GetCenter());
    void NativeClick(Vector2 point)
    { NativeClick(GetTree().Root,point); }
    void NativeClick(Window window,Vector2 point)
    { var size=window.GetVisibleRect().Size; Console.WriteLine("M2_NATIVE_CLICK "+System.Text.Json.JsonSerializer.Serialize(new { x=point.X,y=point.Y,width=size.X,height=size.Y,title=window.Title })); Console.Out.Flush(); }
    async Task NativePress(Button button)
    {
        var pressed=new TaskCompletionSource(); void Pressed()=>pressed.TrySetResult(); button.Pressed+=Pressed;
        // Scroll only once the panel has laid out what was just shown.
        await Frame();
        for(Node? node=button.GetParent();node!=null;node=node.GetParent()) if(node is ScrollContainer scroll) scroll.EnsureControlVisible(button);
        try { await Frame(); await Frame();
            NativeClick(button.GetWindow(),OnWindow(button)); await pressed.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
        catch(TimeoutException) {
            // Name what the real pointer reached instead of the intended control.
            string Hovered(Viewport v)=>v.GuiGetHoveredControl() is Control c ? c.GetPath().ToString() : "none";
            Console.WriteLine($"M2_NATIVE_MISS target={button.GetPath()} visible={button.IsVisibleInTree()} disabled={button.Disabled} rect={button.GetGlobalRect()} root={Hovered(GetTree().Root)} own={Hovered(button.GetViewport())}"); Console.Out.Flush();
            throw;
        }
        finally { button.Pressed-=Pressed; }
    }
    async Task PanelResponse(OperationsPanel panel,Action open,Func<bool> ready)
    {
        var done=new TaskCompletionSource(); void Changed(){if(ready()) done.TrySetResult();}
        panel.Changed+=Changed;
        try { open(); Changed(); await done.Task.WaitAsync(TimeSpan.FromSeconds(30)); }
        finally { panel.Changed-=Changed; }
    }
    async Task PickSpace(ScenePanel scene,string id,Vector3 local,Term expected)
    {
        for(Node? parent=scene.GetParent();parent!=null;parent=parent.GetParent()) if(parent is ScrollContainer scroll) scroll.EnsureControlVisible(scene);
        await Frame();
        var picked=new TaskCompletionSource<ScenePanel.Selection>(); void Selected(ScenePanel.Selection value)=>picked.TrySetResult(value); scene.Selected+=Selected;
        try {
            var viewport=scene.GetChildren().OfType<SubViewport>().Single();
            var point=((SpatialGui)app.FindChild("shared-gui",true,false)).WindowPoint(scene.GetViewport(),scene.GlobalPosition+scene.Project(id,local)*scene.Size/(Vector2)viewport.Size);
            NativeClick(point);
            Check((await picked.Task.WaitAsync(TimeSpan.FromSeconds(5))).Subject.ToString()==expected.ToString(),"normal mouse picking opens the exact rendered subject and anchor");
        } finally { scene.Selected-=Selected; }
    }
    async Task NativeMenu()
    {
        var menu=new OptionButton { Position=new(100,100),Size=new(300,40) };
        menu.AddItem("Choose an offered operation"); menu.AddItem("First offered operation"); menu.AddItem("Second offered operation"); app.AddChild(menu);
        menu.ItemSelected+=_=> {
            var fields=new VBoxContainer();
            for(int i=0;i<3;i++) {
                fields.AddChild(new LineEdit { Text="100" });
                var field=new OptionButton(); field.AddItem("New form choice"); fields.AddChild(field);
            }
            app.AddChild(fields);
        };
        await Frame(); await ChooseNativeOption(menu,1); await ChooseNativeOption(menu,2); await ChooseNativeOption(menu,1);
        var button=new Button { Position=new(100,300),Size=new(300,40),Text="Native pointer probe" }; app.AddChild(button); await Frame();
        var clicked=new TaskCompletionSource(); button.Pressed+=()=>clicked.TrySetResult(); NativeClick(OnWindow(button));
        await clicked.Task.WaitAsync(TimeSpan.FromSeconds(5)); Check(clicked.Task.IsCompletedSuccessfully,"real native pointer presses the offered control");
        Console.WriteLine("M2_MENU_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }
    async Task CreationTarget(OperationsPanel panel, Actor target, string operation)
    {
        await Device("create");
        var storage=(OptionButton)panel.FindChild("operation-storage",true,false);
        int index=Enumerable.Range(0,storage.ItemCount).FirstOrDefault(i=>storage.GetItemTooltip(i)==target.Namespace+" @ "+target.Anchor,-1);
        if(index<0) {
            var ns=(LineEdit)panel.FindChild("exact-storage-namespace",true,false); ns.Text=target.Namespace;
            var anchor=(LineEdit)panel.FindChild("exact-storage-anchor",true,false); anchor.Text=target.Anchor;
            ((Button)panel.FindChild("add-exact-storage",true,false)).EmitSignal(BaseButton.SignalName.Pressed);
        } else await Choose(storage,index);
        var classes=(OptionButton)panel.FindChild("operation-class",true,false);
        await Until(()=>!panel.IsWorking);
        await Choose(classes,Enumerable.Range(0,classes.ItemCount).FirstOrDefault(i=>classes.GetItemText(i)=="space",-1));
        await Until(()=>panel.Available);
        await ChooseOfferedOperation(panel,operation);
        Check(panel.Current!.Subject.ToString()==Term.Call("class_ref",Term.Text(target.Namespace),Term.Binary(Identity.Decode(target.Anchor)),Term.Atom("space")).ToString(),"selected target owns the actual local class and anchor");
    }
    // The storage catalogue with its collapsed exact-identity section open, as a user opens it.
    async Task OpenExactTarget(OperationsPanel panel,Func<Button,Task>? press=null)
    {
        await Device("create");
        var exact=(LineEdit)panel.FindChild("exact-storage-namespace",true,false);
        if(!exact.IsVisibleInTree())await (press??NativePress)((Button)panel.FindChild("advanced-target-toggle",true,false));
        Check(exact.IsVisibleInTree(),"the exact existing identity fields are open");
    }
    async Task Type(LineEdit line,string value)
    {
        for(Node? node=line.GetParent();node!=null;node=node.GetParent()) if(node is ScrollContainer scroll) scroll.EnsureControlVisible(line);
        line.GrabFocus(); await Frame(); line.SelectAll();
        NativeInput(new InputEventKey { Keycode=Key.Backspace,Pressed=true });
        NativeInput(new InputEventKey { Keycode=Key.Backspace,Pressed=false });
        foreach(char c in value) {
            NativeInput(new InputEventKey { Unicode=c,Pressed=true });
            NativeInput(new InputEventKey { Unicode=c,Pressed=false });
        }
        await Frame(); Check(line.Text==value,"keyboard enters exact offered text or integer");
    }
    async Task ClickSubmit(OperationsPanel panel)
    {
        var button=(Button)panel.FormPanel.Input(panel.Current!.Form.Submit.ToString())!;
        Check(!button.Disabled,"current offered Submit is enabled");
        button.GrabFocus(); await Frame();
        for(Node? node=button.GetParent();node!=null;node=node.GetParent()) if(node is ScrollContainer scroll) scroll.EnsureControlVisible(button);
        await Frame();
        var clicked=new TaskCompletionSource(); void Pressed()=>clicked.TrySetResult(); button.Pressed+=Pressed;
        try {
            var point=OnWindow(button);
            Console.WriteLine($"M2_SUBMIT_POINTER rect={button.GetGlobalRect()} viewport={GetViewport().GetVisibleRect()} focus={button.HasFocus()} visible={button.IsVisibleInTree()}");
            Check(GetViewport().GetVisibleRect().HasPoint(point),"offered Submit is inside the actual mouse viewport");
            NativeClick(point);
            await clicked.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check(panel.IsWorking && ((OptionButton)panel.FindChild("operation-storage",true,false)).Disabled &&
                ((OptionButton)panel.FindChild("operation-class",true,false)).Disabled &&
                !app.OpenSubjectPie() &&
                !((LineEdit)panel.FindChild("exact-storage-namespace",true,false)).Editable,
                "active creation locks its actual target and offered selection");
        } finally { button.Pressed-=Pressed; }
        await Until(()=>!panel.IsWorking);
    }
    static Term[] SpaceResults(JsonNode reply) => Json.Binding(reply,"Results").Items;
    static Term Result(Term[] results,string name)=>results.Single(t=>t.Require("result",2)[0].Name==name).Args[1];
    async Task<long> Writes()=>long.Parse((await app.ActiveSession.Transport.Send("/qualification/traffic",null,CancellationToken.None))["writes"]!.ToString());
    async Task FieldChoice(OperationsPanel panel,string role,Term value)
    {
        var field=panel.Current!.Form.Tree.Leaves.Single(c=>c.Role==role);
        await Choose((OptionButton)panel.FormPanel.Input(role)!,Array.FindIndex(field.Options,o=>o.Value.ToString()==value.ToString()));
        Check(panel.FormPanel.Draft[role]==value.ToString(),"offered choice binds exact typed value: "+role);
    }
    void NewDraft(OperationsPanel panel)
    {
        panel.Defaults();
        if(((Button)panel.FormPanel.Input(panel.Current!.Form.Submit.ToString())!).Disabled) panel.Defaults();
    }
    async Task SpaceCreation(string phase,JsonObject original)
    {
        var human=JsonSerializer.Deserialize<Actor>(original["human"]!.ToJsonString())!;
        var setup=Term.Parse(original["setup"]!.GetValue<string>()).Require("account",6); var s0=setup[2];
        var panel=(OperationsPanel)app.FindChild("operations",true,false); var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        if(phase=="m2-fresh") {
            await CreationTarget(panel,human,"create");
            Check(panel.FormPanel.Draft["space_name"]=="Space" && panel.FormPanel.Draft["space_length(width)"]=="100","normal creation presents the authored default name and100 metre extent");
            await Keyboard(panel,panel.Current!); Check(!panel.FormPanel.Validate(),"invalid creation draft remains local");
            await Type((LineEdit)panel.FormPanel.Input("space_length(width)")!,"101");
            await ClickSubmit(panel);
            Check(State["pending"]!.GetValue<int>()==1,"lost creation response retains exactly the original durable signed instruction");
            var pending=app.ActiveStore.Snapshot!.Pending.Single();
            Check(pending.Instruction!=null && pending.Request.Length>0 && pending.Signature.Length>0,"exact signed original work saved before dispatch");
            long writes=await Writes(); await panel.Submit();
            Check(await Writes()==writes,"uncertain creation cannot be submitted again");
            Console.WriteLine("M1B_KILL_READY m2-fresh"); Console.Out.Flush(); await new TaskCompletionSource().Task; return;
        }
        Check(State["pending"]!.GetValue<int>()==0,"process restart resolves the original creation without dispatch");
        var recoveredCopies=app.ActiveAccounts.Outcomes.Where(o=>o["bindings"]?.AsArray().Any(b=>b?["Results"]!=null)==true)
            .GroupBy(o=>Json.Binding(o,"Results").ToString()).Single();
        Check(recoveredCopies.All(Json.Committed),"journal and authoritative association recover one exact certified creation result");
        var recovered=recoveredCopies.First();
        var first=SpaceResults(recovered); var firstSpace=Result(first,"space");
        Check(Actor.FromTerm(firstSpace).Namespace==human.Namespace && Result(first,"owner").ToString()==setup[0].ToString(),"recovered generated reference and owner retain selected storage and distinct U identity");
        Check(Result(first,"location").Require("placed",2)[0].ToString()==s0.ToString(),"original result contains exact containing space and placement");
        Check(scene.Count==2,"original S1 appears in S0 through the selected shared exterior recipe");
        string firstId=scene.SubjectIds(firstSpace).Single();
        await PickSpace(scene,firstId,Vector3.Zero,firstSpace);
        await Until(()=>panel.Available);
        Check(((Label)panel.FindChild("operation-scope",true,false)).Text.Contains(firstSpace.ToString()) && panel.Offered.Any(o=>o.Name=="enter"),
            "reconnect-first picking selects the existing space, which offers its ordinary Enter before any account or creation button");
        var unopened=new OperationsPanel { Name="unopened-subject-probe" }; app.AddChild(unopened);
        var firstActor=Actor.FromTerm(firstSpace);
        await PanelResponse(unopened,()=>unopened.OpenSubject(app.ActiveSession,app.ActiveAccounts,firstActor,firstSpace),()=>unopened.Available);
        Check(unopened.Offered.Any(o=>o.Name=="enter") &&
            ((Label)unopened.FindChild("operation-scope",true,false)).Text.Contains(firstSpace.ToString()),
            "a newly constructed generic panel opens an exact picked subject without prior account/storage initialization");
        var wrongAnchor=firstActor with { Anchor=Identity.Encode(new byte[32]) };
        await PanelResponse(unopened,()=>unopened.OpenSubject(app.ActiveSession,app.ActiveAccounts,wrongAnchor,wrongAnchor.Entity),()=>unopened.StatusText.StartsWith("Unavailable:"));
        Check(!unopened.Available && unopened.Current==null,"wrong-anchor subject withdrawal stays unavailable rather than a valid empty offer projection");
        unopened.DisposeView(); await unopened.Completion; unopened.QueueFree();
        using(var key=Identity.FromPayload(app.ActiveStore.Snapshot!.Payload))
        using(var store=new LocalStore(profile+"-new-device")) {
            store.Create(app.ActiveStore.PortablePayload());
            using var session=new SignedSession(key,store,new Transport(app.ActiveStore.Snapshot.Endpoint,app.ActiveStore.Snapshot.NodeKey(app.ActiveStore.Snapshot.Endpoint)));
            using var cancellation=new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await session.Authenticate(cancellation.Token); var accounts=new Accounts(session,store); long writes=await Writes();
            await accounts.Discover(cancellation.Token);
            var recoveredResults=accounts.Outcomes.Where(o=>o["bindings"]?.AsArray().Any(b=>b?["Results"]!=null)==true).ToArray();
            Console.WriteLine($"M2_NEW_DEVICE recovered={recoveredResults.Length} distinct={recoveredResults.Select(o=>Json.Binding(o,"Results").ToString()).Distinct().Count()}");
            Check(store.Snapshot!.Pending.Count==0 && recoveredResults.Length>0 && recoveredResults.All(o=>Json.Committed(o) && Json.Binding(o,"Results").ToString()==Term.List(first).ToString()),"another authorized device with no journal recovers exact generated space owner and location bindings");
            Check(await Writes()==writes,"cross-device original-result discovery issues zero writes");
        }
        await CreationTarget(panel,human,"create"); panel.Defaults();
        long before=await Writes(); await Keyboard(panel,panel.Current!); await panel.Submit();
        Check(await Writes()==before,"invalid normal creation fields dispatch no instruction"); panel.Defaults();
        await Type((LineEdit)panel.FormPanel.Input("space_name")!,"Preserved draft");
        panel.Cancel(); await CreationTarget(panel,human,"create");
        Check(panel.FormPanel.Draft["space_name"]=="Preserved draft" && await Writes()==before,"local cancel and reopen preserve unsent input without submission");
        var prior=panel.Current!.Revision.ToString();
        using(var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(30))) {
            await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,"assertz(gui_validation_context(space_create(finite),m2_revision)).",timeout.Token);
        }
        await Until(()=>panel.Current!.Revision.ToString()!=prior);
        before=await Writes(); await panel.Submit(); Check(await Writes()==before,"changed offered revision locks and retains the old creation draft");
        panel.Defaults(); Check(panel.FormPanel.Draft["space_name"]=="Preserved draft","explicit current-revision adoption retains compatible edited fields");
        await ClickSubmit(panel); Check(Json.Committed(panel.LastOutcome!),"normal mouse creation commits through the current generic binder");
        var defaultResult=SpaceResults(panel.LastOutcome!); Check(Result(defaultResult,"owner").ToString()==setup[0].ToString(),"default creation result reports actual U ownership");
        await Until(()=>scene.Count>=4); Check(scene.Count==4,"creation remains in S0 and adds only the new exterior occurrence");
        await CreationTarget(panel,human,"create"); NewDraft(panel);
        await FieldChoice(panel,"space_exterior(finite)",Term.Atom("wireframe"));
        await ClickSubmit(panel); Check(Json.Committed(panel.LastOutcome!),"normal GUI selects the real finite wireframe recipe");
        var wire=Result(SpaceResults(panel.LastOutcome!),"space");
        await Until(()=>scene.Count>=6);
        string wireId=scene.SubjectIds(wire).Single();
        var corners=scene.WorldCorners(wireId);
        Check(Math.Abs(corners.Max(v=>v.X)-corners.Min(v=>v.X)-100)<.0001f,"actual created default wireframe has100 metre width");
        Check(scene.Pick(scene.Project(wireId,new Vector3(0,-50,-50)))?.Subject.ToString()==wire.ToString(),"picking the created wireframe resolves its actual generated reference");
        for(Node? parent=scene.GetParent();parent!=null;parent=parent.GetParent()) if(parent is ScrollContainer scroll) scroll.EnsureControlVisible(scene);
        await Frame();
        if(System.Environment.GetEnvironmentVariable("M2_SCREENSHOT") is string screenshot) {
            Check(DisplayServer.GetName()!="headless","M2 capture uses the actual desktop renderer");
            // WhenVisible SubViewports render after the parent has first used
            // their texture. Observe that frame, then their rendering frame.
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            var rendered=scene.GetChildren().OfType<SubViewport>().Single();
            using var pixels=rendered.GetTexture().GetImage();
            var face=scene.Project(wireId,new Vector3(50,0,0));
            var pixel=pixels.GetPixel((int)face.X,(int)face.Y);
            Check(pixels.SavePng(screenshot+".scene.png")==Error.Ok,"actual created wireframe viewport raster retained");
            Console.WriteLine($"M2_RASTER face={face} pixel={pixel} camera={rendered.GetChildren().OfType<Camera3D>().Single().Position}");
            foreach(var mesh in scene.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>()) {
                var surface=RenderingServer.MeshGetSurface(mesh.Mesh.GetRid(),0);
                Console.WriteLine($"M2_RASTER_MESH kind={mesh.Mesh.GetClass()} primitive={surface["primitive"]} vertices={surface["vertex_count"]} position={mesh.GlobalPosition}");
            }
            Check(pixel.R<.01f && pixel.G<.01f && pixel.B<.01f,"actual created wireframe leaves its projected face centre empty");
            // The parent composites the SubViewport's completed texture on its
            // next rendered frame; capture that explicit completion as well.
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            Check(GetViewport().GetTexture().GetImage().SavePng(screenshot)==Error.Ok,"actual created space and generic GUI rendered to evidence image");
        }
        await PickSpace(scene,wireId,new Vector3(0,-50,-50),wire);
        await Until(()=>panel.Available);
        Check(!panel.FindChild("operation-targeting",true,false).Get("visible").AsBool(),"an exact picked instance hides the unrelated class/storage chooser");
        await CreationTarget(panel,human,"create_exact"); NewDraft(panel);
        foreach(var (role,value) in new[] { ("space_length(width)","1"),("space_divisor(width)","3"),("space_length(height)","1001"),("space_divisor(height)","1"),("space_length(depth)","1001"),("space_divisor(depth)","2") })
            await Type((LineEdit)panel.FormPanel.Input(role)!,value);
        await FieldChoice(panel,"space_unit",Term.Text("mm"));
        await FieldChoice(panel,"space_placement",Term.Call("at",s0,Term.Call("transform",Term.Number("0"),Term.Number("0"),Term.Number("0"),Term.Number("0"),Term.Number("0"),Term.Number("0"))));
        await FieldChoice(panel,"space_exterior(exact)",Term.Atom("wireframe"));
        await ClickSubmit(panel); Check(Json.Committed(panel.LastOutcome!),"rational lengths create through the same authored generic form and constructor");
        Check(Result(SpaceResults(panel.LastOutcome!),"location").ToString()==Term.Call("placed",s0,Term.Call("transform",Term.Number("0"),Term.Number("0"),Term.Number("0"),Term.Number("0"),Term.Number("0"),Term.Number("0"))).ToString(),"normal GUI explicit placement preserves the selected exact destination and pose");
        var rational=Result(SpaceResults(panel.LastOutcome!),"space"); await Until(()=>scene.Count>=8);
        string rationalId=scene.SubjectIds(rational).Single();
        corners=scene.WorldCorners(rationalId);
        Check(Math.Abs(corners.Max(v=>v.X)-corners.Min(v=>v.X)-1f/3000)<.000001f &&
            Math.Abs(corners.Max(v=>v.Y)-corners.Min(v=>v.Y)-1.001f)<.000001f,"actual Prolog rational millimetres reach engine geometry without integer rounding");
        await CreationTarget(panel,human,"create_infinite"); NewDraft(panel);
        var exterior=panel.Current!.Form.Tree.Leaves.Single(c=>c.Role=="space_exterior(infinite)");
        Check(exterior.Options.All(o=>o.Value.Name!="wireframe") && exterior.Properties["help"].TextValue.Contains("no finite wireframe"),"infinite form explicitly explains wireframe unavailability and offers the real solid recipe");
        await FieldChoice(panel,"space_placement",Term.Atom("unplaced"));
        await ClickSubmit(panel); Check(Json.Committed(panel.LastOutcome!) && Result(SpaceResults(panel.LastOutcome!),"location").Name=="unplaced","normal GUI supports explicit infinite unplaced creation without placement fallback");
        var foreign=await SpaceControl(new() { ["m2_foreign_storage"]=JsonSerializer.SerializeToNode(human) });
        var target=new Actor(Json.S(foreign,"namespace"),Json.S(foreign,"anchor"),"me.");
        await CreationTarget(panel,target,"create"); NewDraft(panel); await ClickSubmit(panel);
        Check(Json.Committed(panel.LastOutcome!),"authorized existing foreign storage commits through the ordinary selected-target route");
        var foreignResults=SpaceResults(panel.LastOutcome!); var foreignSpace=Result(foreignResults,"space");
        Check(Actor.FromTerm(foreignSpace).Namespace==target.Namespace && Result(foreignResults,"owner").ToString()==setup[0].ToString() &&
            Result(foreignResults,"location").Args[0].ToString()==s0.ToString(),"foreign storage, U ownership and S0 placement remain distinct exact references");
        await Until(()=>scene.Count>=10); Check(scene.Count==10,"foreign-storage source appears through its authorized exact exterior recipe");
        var ids=scene.Ids.Order().ToArray();
        await SpaceRefusals(panel,human,s0,scene);
        await Until(()=>State["question_receiver_ready"]?.GetValue<bool>()==true);
        var beforeRestart=await app.ActiveSession.Transport.Send("/qualification/traffic",null,CancellationToken.None);
        await SpaceControl(new() { ["m2_restart"]=JsonSerializer.SerializeToNode(human) });
        await Press("disconnect"); await app.ViewsDisposed; await Press("connect");
        await Until(()=>State["world_accepted"]!.GetValue<bool>() && State["question_receiver_ready"]?.GetValue<bool>()==true);
        var afterRestart=await app.ActiveSession.Transport.Send("/qualification/traffic",null,CancellationToken.None);
        Check(scene.Ids.Order().SequenceEqual(ids),"server owner restart and reconnect recover every exact original space occurrence");
        Check(Json.U(afterRestart,"instructions")==Json.U(beforeRestart,"instructions") &&
            Json.U(afterRestart,"writes")==Json.U(beforeRestart,"writes")+1 &&
            Json.U(afterRestart,"receiver_selections")==Json.U(beforeRestart,"receiver_selections")+1,
            "reconnect writes only its new HUD receiver selection and submits no creation instruction");
        var navigation=Json.Binding(await app.ActiveSession.Read(human,"account_navigation(Space,Modes).",CancellationToken.None),"Space");
        Check(navigation.ToString()==s0.ToString(),"all creations leave the same A inside original parentless S0");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new { passed=true,checks,original=first.Select(t=>t.ToString()).ToArray(),wire=wire.ToString(),rational=rational.ToString(),foreign=foreignSpace.ToString() }));
        await Press("disconnect"); await app.ViewsDisposed; Check(SignedView.LiveSockets==0,"M2 view and operation consumers dispose all sockets");
        Console.WriteLine("M2_EXPORT_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }

    async Task SpaceRefusals(OperationsPanel panel,Actor human,Term s0,ScenePanel scene)
    {
        using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(30));
        async Task<string> StateOfSpaces()=>Json.Binding(await app.ActiveSession.Read(human,
            "findall(state(S,Owner,Location),(instance_of(space,S),attribute(S,owner,Owner),space_location(S,Location)),Spaces).",timeout.Token),"Spaces").ToString();
        string before=await StateOfSpaces();
        await CreationTarget(panel,human,"create"); NewDraft(panel);
        var offer=panel.Current!;
        using(var key=Identity.Create())
        using(var store=new LocalStore(profile+"-m2-stranger")) {
            store.Create(key.Payload());
            using var wrong=new SignedSession(key,store,new Transport(app.ActiveStore.Snapshot!.Endpoint,app.ActiveStore.Snapshot.NodeKey(app.ActiveStore.Snapshot.Endpoint)));
            await wrong.Authenticate(timeout.Token); bool denied=false;
            try { denied=!Json.Committed(await wrong.Execute(human,offer.Goal(offer.Form.Defaults),"m2-wrong-identity",timeout.Token)); }
            catch(ApiError error) { denied=error.Definite; }
            Check(denied,"wrong signing identity explicitly refuses the exact space creation operation");
        }
        string space=Actor.FromTerm(s0).InstanceText.TrimEnd('.');
        await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,$"assertz(instance_permission({space},space_admit,deny)).",timeout.Token);
        await CreationTarget(panel,human,"create"); NewDraft(panel); await ClickSubmit(panel);
        Check(Json.Terminal(panel.LastOutcome!) && !Json.Committed(panel.LastOutcome!),"normal mouse creation displays definitive destination-admission refusal");
        Check(await StateOfSpaces()==before && scene.Count==10,"denied construction leaves no generated space owner or assignment");
        await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,$"retract(instance_permission({space},space_admit,deny)).",timeout.Token);
        await OpenExactTarget(panel);
        await Type((LineEdit)panel.FindChild("exact-storage-namespace",true,false),human.Namespace);
        await Type((LineEdit)panel.FindChild("exact-storage-anchor",true,false),Identity.Encode(new byte[32]));
        long writes=await Writes();
        ((Button)panel.FindChild("add-exact-storage",true,false)).EmitSignal(BaseButton.SignalName.Pressed);
        await Until(()=>!panel.IsWorking);
        Check(!panel.Available && panel.StatusText.StartsWith("Target unavailable:") && await Writes()==writes,"wrong selected storage anchor refuses visibly before creation dispatch");
        Check(await StateOfSpaces()==before,"all M2 identity anchor and admission refusals preserve committed space state");
    }
}
