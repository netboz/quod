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
        // First observe real native input on this root window. Giving a
        // control focus before the host activates its window is not an
        // installed-input fence; reuse the existing harmless F24 seam.
        var ready=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void NativeReady(InputEvent input) {if(input is InputEventKey {Keycode:Key.F24,Pressed:true} key && key.WindowId==GetTree().Root.GetWindowId())ready.TrySetResult();}
        GetTree().Root.WindowInput+=NativeReady;
        try {Console.WriteLine("M2_NATIVE_KEY F24");Console.Out.Flush();await ready.Task.WaitAsync(TimeSpan.FromSeconds(5));}
        finally {GetTree().Root.WindowInput-=NativeReady;}
        Check(ready.Task.IsCompletedSuccessfully,"real native input is processed by this exact ordinary root before control focus");
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
            button.GrabFocus();await Frame();Check(button.HasFocus(),"native keyboard focus belongs to the intended existing button");
            var pressed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);int clicks=0;
            void Clicked(){clicks++;pressed.TrySetResult();}button.Pressed+=Clicked;
            try {Console.WriteLine("M2_NATIVE_KEY space");Console.Out.Flush();await pressed.Task.WaitAsync(TimeSpan.FromSeconds(5));}
            finally {button.Pressed-=Clicked;}
            Check(clicks==1,"one real native keyboard activation emits exactly one button press");
        }
        async Task Submit(OperationsPanel panel) {
            var button=(Button)panel.FormPanel.Input(panel.Current!.Form.Submit.ToString())!;
            Check(!button.Disabled,"current signed offered Submit is enabled");await Reveal(button);await Activate(button);
            await Until(()=>!panel.IsWorking);Check(gui.Captures==0,"native keyboard Submit leaves no GUI pointer capture");
        }
        if(!reopen)await Action("create-key");
        else Check(State["public_key"]!=null,"separate installed process unlocks its original private active profile");
        await Action("connect");Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"real signed authentication uses the fresh fixture network");
        if(!reopen){await Action("register");await Action("prepare");await Action("setup");}
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true && State["operation_available"]?.GetValue<bool>()==true);
        var human=app.ActiveAccounts.Human!;var session=app.ActiveSession;
        async Task<string[]> Instructions()=>Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Select(t=>t.Args[0].ToString()).Order().ToArray();
        var contextPath=System.IO.Path.Combine("/work","journey-context.json");
        var identity=new JsonObject { ["public_key"]=State["public_key"]!.DeepClone(),["human"]=State["human"]!.DeepClone(),["setup"]=State["setup"]!.DeepClone() };
        if(reopen) {
            var saved=JsonNode.Parse(await File.ReadAllTextAsync(contextPath))!;
            Check(identity.ToJsonString()==saved["identity"]!.ToJsonString(),"ordinary reconnect recovers exactly the original U A S0 identities and keys");
            Check(State["current_location"]!.ToString()==saved["location"]!.ToString(),"separate process reopens the same committed created space");
            Check((await Instructions()).SequenceEqual(saved["instructions"]!.AsArray().Select(n=>n!.ToString())) && State["pending"]!.GetValue<int>()==0,"ordinary original-result recovery issues no new personal instruction or replay");
            Check(app.ActiveAccounts.Outcomes.Any(o=>Json.Committed(o)&&o["bindings"]?.AsArray().Any(b=>b?["Results"]!=null)==true),"reopen exposes the original certified creation and entry results");
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
            Check(panel.LastOutcome!=null && Json.Committed(panel.LastOutcome),"one actual native Submit commits the governed creation through U to A");
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
            await File.WriteAllTextAsync(contextPath,new JsonObject { ["identity"]=identity,["location"]=State["current_location"]!.DeepClone(),["instructions"]=JsonSerializer.SerializeToNode(instructions) }.ToJsonString());
        }
        await Action("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"normal disconnect retires all signed view consumers");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,reopen,checks}));
        Console.WriteLine("M5_PACKAGE_JOURNEY_PASS "+(reopen?"reopen":"initial"));Console.Out.Flush();await app.CloseApplication();
    }
}
