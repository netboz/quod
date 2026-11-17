using Godot;
using Quod.Client;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task OnboardingSource()
    {
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["operation_available"]?.GetValue<bool>()==true);
        Check(new[]{"create-key","register","prepare","setup"}.All(n=>!((Button)app.FindChild(n,true,false)).IsVisibleInTree())&&((Button)app.FindChild("workspace-connection",true,false)).IsVisibleInTree()&&((Button)app.FindChild("create-operations",true,false)).IsVisibleInTree(),"completed signed account collapses provisioning while keeping actual space actions and explicit identity access");
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        async Task<int> Instructions()=>Json.Binding(await app.ActiveSession.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length;
        int instructions=await Instructions();await Press("inspect");
        var pane=(EidolonPanel)app.FindChild("representations",true,false);await Until(()=>pane.Available);
        pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="prolog"&&e.Style=="source"),true);
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);await Until(()=>source.CanEdit&&source.Content.Length>0);
        var editor=(TextEdit)((FormPanel)source.FindChild("source-form",true,false)).Input("source")!;
        string baseline=source.Content;ulong sourceId=source.GetInstanceId(),editorId=editor.GetInstanceId();
        xr.PresentWorkspace(true);await Frame();await Frame();
        var revealed=new TaskCompletionSource();SpatialGui.Reveal(editor,()=>GodotObject.IsInstanceValid(editor),()=>revealed.TrySetResult());await revealed.Task.WaitAsync(TimeSpan.FromSeconds(60));await Frame();
        gui.Move(editor.GetGlobalRect().GetCenter());gui.Press();await Frame();gui.Release();await Frame();await Frame();
        editor.SetCaretLine(editor.GetLineCount()-1);editor.SetCaretColumn(editor.GetLine(editor.GetLineCount()-1).Length);
        var changed=new TaskCompletionSource();void Edited()=>changed.TrySetResult();editor.TextChanged+=Edited;
        var enter=(Button)gui.FindChild("keyboard-enter",true,false);gui.Move(enter.GetGlobalRect().GetCenter());gui.Press();await Frame();gui.Release();
        await changed.Task.WaitAsync(TimeSpan.FromSeconds(60));editor.TextChanged-=Edited;
        string local=source.Content;
        Check(local==baseline+"\n"&&app.ActiveStore.Snapshot!.SourceDrafts.Values.Any(d=>d.Text==local&&d.Baseline==baseline),"existing native keyboard edits only the exact durable source draft before recovery");
        int reads=source.SnapshotReads,writes=0;app.ActiveStore.DurabilityBoundary=_=>writes++;
        byte[] before=await File.ReadAllBytesAsync(System.IO.Path.Combine(profile,"active.json"));
        using(var probe=new System.Net.Sockets.TcpClient()) {
            using var stop=new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),stop.Token);
            using var stream=probe.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),stop.Token);
            Check(JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!["ready"]!.GetValue<bool>(),"named unchanged-work observation installed before ordinary same-source reopening");
            var view=(SignedView)typeof(EidolonPanel).GetField("representation",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(pane)!;
            await Press("inspect");await Press("inspect");
            Check(ReferenceEquals(view,typeof(EidolonPanel).GetField("representation",BindingFlags.NonPublic|BindingFlags.Instance)!.GetValue(pane))&&source.CanEdit,"ordinary same-source actions retain the installed exact signed consumer");
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),stop.Token);
            var work=JsonNode.Parse((await reader.ReadLineAsync(stop.Token))!)!;await File.WriteAllTextAsync("/work/unchanged-work.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0,"unchanged ordinary source actions have zero watched history rebuild write or sync calls");
        }
        app.ActiveStore.DurabilityBoundary=null;
        byte[] after=await File.ReadAllBytesAsync(System.IO.Path.Combine(profile,"active.json"));
        Check(writes==0&&before.SequenceEqual(after)&&source.SnapshotReads==reads&&editor.GetInstanceId()==editorId,"unchanged source actions preserve native source and local profile without persistence");
        int expired=0;session.Expired+=()=>expired++;
        var key=(Button)gui.FindChild("keyboard-char-97",true,false);gui.Move(key.GetGlobalRect().GetCenter());gui.Press();gui.Release();
        app.Disconnect();await app.ViewsDisposed;await session.Expiration;await Frame();await Frame();
        Check(expired==0&&SignedSession.Now<session.Expires&&SignedView.LiveSockets==0&&gui.Captures==0,"explicit disconnect cancels the original expiry observation and all signed input resources");
        Check(!((Control)gui.FindChild("spatial-keyboard",true,false)).Visible&&app.ActiveStore.Snapshot!.SourceDrafts.Values.Any(d=>d.Text==local),"disconnect vetoes queued keyboard input without changing the retained draft");
        xr.PresentWorkspace(false);await Press("connect");await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&source.CanEdit&&source.Content==local);
        Check(source.GetInstanceId()==sourceId&&app.ActiveAccounts.Human==human,"explicit same-key recovery reauthorizes the existing exact source consumer");
        Check(await Instructions()==instructions&&!app.ActiveStore.Snapshot!.Pending.Any(),"source draft recovery submits no domain instruction or source Save");
        await Press("disconnect");await app.ViewsDisposed;
        var endpoint=(LineEdit)app.FindChild("endpoint",true,false);endpoint.Text="http://invalid.invalid";
        await Press("connect");
        Check(State["status"]!.ToString().Contains("HTTPS node origin")&&!((Button)app.FindChild("connect",true,false)).Disabled&&!((Button)app.FindChild("register",true,false)).Visible,"ordinary refused connection keeps truthful error and explicit retry without registration fallback");
        Check(SignedView.LiveSockets==0&&gui.Captures==0&&!xr.Running,"failed connection leaves no signed sockets captures or native XR");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks,phase="onboarding-source",scope="native Control software keys and ordinary same-source actions; no source Save or host input"}));
        Console.WriteLine("ONBOARDING_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
