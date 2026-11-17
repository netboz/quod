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
    async Task ShutdownOwner(bool reopen)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        // This close-owner diagnostic uses existing native-Control signals.
        // It sends no host keyboard, pointer or compositor focus action.
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
            try {button.EmitSignal(BaseButton.SignalName.Pressed);await Until(()=>!Busy);}
            finally {button.Pressed-=Clicked;}
            Check(clicks==1,"one diagnostic native-Control signal reaches the ordinary action owner");
        }
        if(!reopen)await Action("create-key");
        else Check(State["public_key"]!=null,"separate installed process unlocks its original private active profile");
        await Action("connect");Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"real signed authentication uses the fresh fixture network");
        if(!reopen){await Action("register");await Action("prepare");await Action("setup");}
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true && State["operation_available"]?.GetValue<bool>()==true);
        await Action("inspect");
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        await Until(()=>pane.Available);
        var offered=pane.Offered.Single(e=>e.Style=="workbench");
        var choices=(OptionButton)pane.FindChild("representation-choices",true,false);
        await Reveal(choices);
        int choice=Array.IndexOf(pane.Offered,offered)+1;
        choices.Select(choice);choices.EmitSignal(OptionButton.SignalName.ItemSelected,(long)choice);
        var graph=(WorkbenchPanel)pane.FindChild("ontology-workbench",true,false);
        var scene=(ScenePanel)pane.FindChild("representation-scene",true,false);
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        await Until(()=>pane.Available && graph.Visible && source.CanEdit && source.Content.Length>0 && scene.Count>0);
        Check(pane.Current!.Exact.ToString()==app.ActiveAccounts.Human!.Ontology.ToString(),"installed workbench and editor use the exact signed account ontology");
        Check(app.ActiveStore.Snapshot!.Pending.Count==0,"no outstanding signed action before the ordinary close owner");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks,scene=scene.Count,sockets=SignedView.LiveSockets}));
        Console.WriteLine("SHUTDOWN_OWNER_PASS");Console.Out.Flush();
        // Deliberately close while the real scene/source/view consumers exist.
        // Main owns their cancellation and await order; no pre-retirement here.
        await app.CloseApplication();
    }
}

// Removable observations only. No timeout, second close owner, task completion
// source, authority change, native input or additional awaited work.
public partial class Main
{
    static void CloseStage(string stage,Task? work=null)
    {
        Console.Error.WriteLine("CLOSE_OWNER "+System.Text.Json.JsonSerializer.Serialize(new {
            stage,monotonic=System.Diagnostics.Stopwatch.GetTimestamp(),
            frequency=System.Diagnostics.Stopwatch.Frequency,status=work?.Status.ToString()}));
        Console.Error.Flush();
    }
    static void ObserveClose(string stage,Task work)
    {
        CloseStage(stage+".begin",work);
        _=work.ContinueWith(done=>CloseStage(stage+".settled",done),
            CancellationToken.None,TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
    }
}
