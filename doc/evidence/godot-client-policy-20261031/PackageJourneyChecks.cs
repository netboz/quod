using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

// Removable software companion. Identical production inputs to the package;
// explicit test dispatch is absent from the ordinary distributed composition.
public partial class ExportChecks
{
    async Task PackageJourney(bool reopen)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        // Software-only qualification: existing Control signals, no host input,
        // desktop/control focus, human-mode dispatch or alternate domain path.
        async Task ChooseOperation(OptionButton control,int index) {
            Check(index>0 && index<control.ItemCount,"existing authored choice is present");
            control.Select(index);control.EmitSignal(OptionButton.SignalName.ItemSelected,(long)index);
            await Frame();Check(control.Selected==index,"software selection reaches the existing authored-choice owner");
        }
        async Task Type(LineEdit line,string value) {
            line.Text=value;line.EmitSignal(LineEdit.SignalName.TextChanged,value);await Frame();
            Check(line.Text==value,"software text signal preserves the exact offered draft value");
        }
        async Task Reveal(Control target) {
            var installed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            SpatialGui.Reveal(target,()=>GodotObject.IsInstanceValid(target),()=>installed.TrySetResult());
            await installed.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Check(target.IsVisibleInTree() && GetViewport().GetVisibleRect().Encloses(target.GetGlobalRect()),"native action is visible inside the current ordinary desktop viewport");
        }
        async Task Action(string name) {
            var button=(Button)app.FindChild(name,true,false);Check(!button.Disabled,"enabled ordinary action "+name);
            await Reveal(button);await Activate(button);await Until(()=>!Busy);
        }
        async Task Activate(Button button) {
            int clicks=0;void Clicked(){clicks++;}button.Pressed+=Clicked;
            try {button.EmitSignal(BaseButton.SignalName.Pressed);await Frame();}
            finally {button.Pressed-=Clicked;}
            Check(clicks==1,"one software Control signal reaches the existing button owner");
        }
        async Task Submit(OperationsPanel panel) {
            var button=(Button)panel.FormPanel.Input(panel.Current!.Form.Submit.ToString())!;
            Check(!button.Disabled,"current signed offered Submit is enabled");await Reveal(button);await Activate(button);
            await Until(()=>!panel.IsWorking);Check(gui.Captures==0,"software Control Submit leaves no GUI pointer capture");
        }
        if(!reopen)await Action("create-key");
        else Check(State["public_key"]!=null,"separate installed process unlocks its original private active profile");
        await Action("connect");Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"real signed authentication uses the fresh fixture network");
        if(!reopen){await Action("register");await Action("prepare");await Action("setup");}
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true && State["operation_available"]?.GetValue<bool>()==true);
        var human=app.ActiveAccounts.Human!;var session=app.ActiveSession;
        async Task WorkbenchStep(bool readOnlyCheck)
        {
            await Action("inspect");
            var pane=(EidolonPanel)app.FindChild("representations",true,false);
            await Until(()=>pane.Available);
            Check(pane.Current!.Exact.ToString()==human.Ontology.ToString(),"ordinary Source / inspection keeps the exact current owned ontology");
            var choice=pane.Offered.Single(e=>e.Style=="workbench");
            var choices=(OptionButton)pane.FindChild("representation-choices",true,false);
            await Reveal(choices);await ChooseOperation(choices,Array.IndexOf(pane.Offered,choice)+1);
            var graph=(WorkbenchPanel)pane.FindChild("ontology-workbench",true,false);
            var source=(SourcePanel)pane.FindChild("source-tools",true,false);
            var scene=(ScenePanel)pane.FindChild("representation-scene",true,false);
            await Until(()=>pane.Available&&graph.Visible&&source.CanEdit&&source.Content.Length>0);
            var form=(FormPanel)graph.FindChild("workbench-form",true,false);
            var tools=app.ActiveAccounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
            async Task<string> Saved()=>await session.ReadSource(human,tools,human,CancellationToken.None);
            bool Present()=>Enumerable.Range(1,((OptionButton)form.Input("node")!).ItemCount-1).Any(i=>((OptionButton)form.Input("node")!).GetItemTooltip(i)==Term.Call("class_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom("package_checkpoint")).ToString());
            if(readOnlyCheck){Check(Present()&&(await Saved()).Contains("isa(package_checkpoint, thing)"),"reopened ordinary consumer sees the exact committed graphical and textual fact");return;}
            string location=State["current_location"]!.ToString(),assignment=State["assignment_revision"]!.ToString();
            int updates=graph.Updates,rebuilt=scene.Rebuilt,reads=source.SnapshotReads;
            byte[] before=await File.ReadAllBytesAsync(System.IO.Path.Combine(profile,"active.json"));
            using(var probe=new System.Net.Sockets.TcpClient()) {
                using var stop=new CancellationTokenSource(TimeSpan.FromSeconds(30));
                await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),stop.Token);
                using var stream=probe.GetStream();using var reader=new System.IO.StreamReader(stream);
                await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),stop.Token);
                Check(JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!["ready"]!.GetValue<bool>(),"named unchanged-work observation is installed before renewal");
                var view=(SignedView)typeof(EidolonPanel).GetField("representation",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance)!.GetValue(pane)!;
                var received=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Got(JsonNode _)=>received.TrySetResult();view.Projection+=Got;
                try{await view.Renew();await received.Task.WaitAsync(stop.Token);}finally{view.Projection-=Got;}
                await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),stop.Token);
                var work=JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!;
                await File.WriteAllTextAsync("/work/unchanged-work.json",work.ToJsonString());
                Check(work["work"]!["calls"]!.AsArray().Count==0,"unchanged accepted renewal has zero watched history/rebuild/write/sync calls");
            }
            byte[] after=await File.ReadAllBytesAsync(System.IO.Path.Combine(profile,"active.json"));
            Check(graph.Updates==updates&&scene.Rebuilt==rebuilt&&source.SnapshotReads==reads&&before.SequenceEqual(after),"unchanged renewal retains native graph/scene/source and private profile bytes");
            string committed=await Saved();
            var name=(LineEdit)form.Input("class_name")!;await Reveal(name);await Type(name,"package_checkpoint");
            Check(form.Draft["class_name"]=="package_checkpoint","existing Control text signal edits the single offered local form draft");
            var parents=(OptionButton)form.Input("parent")!;
            int parent=Enumerable.Range(1,parents.ItemCount-1).Single(i=>Subject.Decode(Term.Parse(parents.GetItemTooltip(i))).Local.Name=="thing");
            await Reveal(parents);await ChooseOperation(parents,parent);
            await Reveal(form.Input("add_class")!);await Activate((Button)form.Input("add_class")!);await source.Completion;
            Check(source.Content.Contains("package_checkpoint")&&await Saved()==committed&&!app.ActiveStore.Snapshot!.Pending.Any(),"native Prepare creates only the guarded local source draft");
            var editor=(FormPanel)source.FindChild("source-form",true,false);
            var preview=(Button)editor.Input("run")!;await Reveal(preview);await Activate(preview);await source.Completion;
            var save=(Button)editor.Input("accept")!;Check(!save.Disabled,"existing signed Preview enables explicit Save");
            await Reveal(save);await Activate(save);await source.Completion;
            await Until(()=>pane.Available&&graph.Visible&&source.CanEdit&&Present());
            Check(!app.ActiveStore.Snapshot!.Pending.Any()&&(await Saved()).Contains("isa(package_checkpoint, thing)"),"one explicit native Save has committed graphical/text readback and no pending work");
            Check(State["current_location"]!.ToString()==location&&State["assignment_revision"]!.ToString()==assignment,"ontology editing preserves the same current space and agent assignment");
        }
        async Task<string[]> Instructions()=>Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Select(t=>t.Args[0].ToString()).Order().ToArray();
        var contextPath=System.IO.Path.Combine("/work","journey-context.json");
        var identity=new JsonObject { ["public_key"]=State["public_key"]!.DeepClone(),["human"]=State["human"]!.DeepClone(),["setup"]=State["setup"]!.DeepClone() };
        if(reopen) {
            var saved=JsonNode.Parse(await File.ReadAllTextAsync(contextPath))!;
            Check(identity.ToJsonString()==saved["identity"]!.ToJsonString(),"ordinary reconnect recovers exactly the original U A S0 identities and keys");
            Check(State["current_location"]!.ToString()==saved["location"]!.ToString(),"separate process reopens the same committed created space");
            Check((await Instructions()).SequenceEqual(saved["instructions"]!.AsArray().Select(n=>n!.ToString())) && State["pending"]!.GetValue<int>()==0,"ordinary original-result recovery issues no new personal instruction or replay");
            Check(app.ActiveAccounts.Outcomes.Any(o=>Json.Committed(o)&&o["bindings"]?.AsArray().Any(b=>b?["Results"]!=null)==true),"reopen exposes the original certified creation and entry results");
            await WorkbenchStep(true);
        } else {
            var before=await Instructions();var originalLocation=State["current_location"]!.ToString();
            await Action("create-operations");var panel=(OperationsPanel)app.FindChild("operations",true,false);
            var storage=(OptionButton)panel.FindChild("operation-storage",true,false);
            int own=Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==human.Namespace+" @ "+human.Anchor);
            await Reveal(storage);await ChooseOperation(storage,own);await Until(()=>!panel.IsWorking);
            var classes=(OptionButton)panel.FindChild("operation-class",true,false);
            await Reveal(classes);await ChooseOperation(classes,Enumerable.Range(1,classes.ItemCount-1).Single(i=>classes.GetItemText(i)=="space"));
            await Until(()=>panel.Available);
            var offers=(OptionButton)panel.FindChild("offered-operation",true,false);
            int create=Enumerable.Range(1,offers.ItemCount-1).Single(i=>offers.GetItemText(i)=="Create space");
            if(offers.Selected!=create){await Reveal(offers);await ChooseOperation(offers,create);}
            else Check(panel.Current?.Name=="create","the current offered Create is already selected; unchanged native choice emits no new selection");
            Check(panel.Current!.Subject.ToString()==Term.Call("class_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom("space")).ToString(),"offered create keeps the explicitly chosen existing storage and anchored class");
            await Submit(panel);
            Check(panel.LastOutcome!=null && Json.Committed(panel.LastOutcome),"one software Control Submit commits the governed creation through U to A");
            var created=Result(SpaceResults(panel.LastOutcome!),"space");
            await Until(()=>State["world_accepted"]?.GetValue<bool>()==true && State["current_location"]!=null);
            Check(State["current_location"]!.ToString()==originalLocation,"creation retains A in the original space until explicit Enter");
            var results=panel.FindChild("operation-results",true,false);
            var open=results.GetChildren().OfType<Button>().Single(b=>b.TooltipText==created.ToString());
            await Reveal(open);await Activate(open);await Until(()=>panel.Available && panel.Current?.Name=="enter");
            Check(panel.Current!.Subject.ToString()==created.ToString(),"returned-subject native action opens the exact created-space Enter offer");
            await Submit(panel);
            Check(panel.LastOutcome!=null && Json.Committed(panel.LastOutcome),"explicit native Enter commits using the same signed form owner");
            await Until(()=>State["current_location"]?.ToString()==Term.Call("placed",created,Term.Parse("transform(0,0,0,0,0,0)")).ToString() && State["world_accepted"]!.GetValue<bool>());
            var instructions=await Instructions();Check(instructions.Length==before.Length+2 && State["pending"]!.GetValue<int>()==0,"creation and Enter each add one original instruction with no pending work");
            await WorkbenchStep(false);
            await File.WriteAllTextAsync(contextPath,new JsonObject { ["identity"]=identity,["location"]=State["current_location"]!.DeepClone(),["instructions"]=JsonSerializer.SerializeToNode(instructions) }.ToJsonString());
        }
        await Action("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"normal disconnect retires all signed view consumers");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,reopen,checks}));
        Console.WriteLine("M5_PACKAGE_JOURNEY_PASS "+(reopen?"reopen":"initial"));Console.Out.Flush();await app.CloseApplication();
    }
}
