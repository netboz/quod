using Godot;
using Quod.Client;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task KeyboardSigned()
    {
        // Existing disposable fixture setup; typing below is native GUI input.
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["operation_available"]?.GetValue<bool>()==true);
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        async Task<int> Instructions()=>Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length;
        int original=await Instructions();await Press("inspect");
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        await Until(()=>pane.Available);
        pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="prolog"&&e.Style=="source"),true);
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        await Until(()=>source.CanEdit&&source.Content.Length>0);
        var form=(FormPanel)source.FindChild("source-form",true,false);var editor=(TextEdit)form.Input("source")!;
        string committed=source.Content;int reads=source.SnapshotReads;ulong editorId=editor.GetInstanceId(),sourceId=source.GetInstanceId();
        xr.PresentWorkspace(true);gui.Surface.GuiEmbedSubwindows=true;await Frame();await Frame();
        async Task Reveal(Control c) {var installed=new TaskCompletionSource();SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>installed.TrySetResult());await installed.Task.WaitAsync(TimeSpan.FromSeconds(60));await Frame();}
        async Task Click(Control c) {gui.Move(c.GetGlobalRect().GetCenter());await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();}
        Rect2 Clip(Control c) {var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        var status=(Label)source.FindChild("source-status",true,false);var geometry=new List<object>();
        foreach(int font in new[]{26,48}) {
            gui.TextSize(font-gui.Appearance.DefaultFontSize);await Frame();await Frame();await Reveal(editor);await Click(editor);
            var keyboard=(Control)gui.FindChild("spatial-keyboard",true,false);
            geometry.Add(new {font,editor=editor.GetGlobalRect().ToString(),editorClip=Clip(editor).ToString(),status=status.GetGlobalRect().ToString(),statusClip=Clip(status).ToString(),keyboard=keyboard.GetGlobalRect().ToString()});
            await File.WriteAllTextAsync("/work/keyboard-geometry.json",System.Text.Json.JsonSerializer.Serialize(geometry));
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();
            Check(image.SavePng("/work/source-keyboard-"+font+".png")==Error.Ok,"actual signed source keyboard raster retained at "+font);
            Check(keyboard.IsVisibleInTree()&&editor.HasFocus()&&Clip(editor).Encloses(editor.GetGlobalRect()),"actual signed source editor is focused and enclosed with adjacent keyboard at "+font);
            Check(status.IsVisibleInTree()&&Clip(status).Encloses(status.GetGlobalRect()),"actual signed source status remains visible while editing at "+font);
        }
        gui.TextSize(26-gui.Appearance.DefaultFontSize);await Frame();await Frame();await Reveal(editor);await Click(editor);
        editor.SetCaretLine(editor.GetLineCount()-1);editor.SetCaretColumn(editor.GetLine(editor.GetLineCount()-1).Length);
        var changed=new TaskCompletionSource();void Edited()=>changed.TrySetResult();editor.TextChanged+=Edited;
        await Click((Button)gui.FindChild("keyboard-enter",true,false));await changed.Task.WaitAsync(TimeSpan.FromSeconds(60));editor.TextChanged-=Edited;
        Check(source.Content==committed+"\n"&&app.ActiveStore.Snapshot!.SourceDrafts.Values.Any(d=>d.Text==source.Content&&d.Baseline==committed),"native keyboard editing reaches the existing exact-source durable local draft owner");
        Check(source.SnapshotReads==reads&&editor.GetInstanceId()==editorId&&await Instructions()==original&&!app.ActiveStore.Snapshot!.Pending.Any(),"typing adds no source reread personal instruction pending write or replacement editor");
        string local=source.Content;var key=(Button)gui.FindChild("keyboard-char-97",true,false);
        gui.Move(key.GetGlobalRect().GetCenter());gui.Press();gui.Release();source.Withdraw();await Frame();await Frame();
        Check(!((Control)gui.FindChild("spatial-keyboard",true,false)).Visible&&!editor.Editable&&app.ActiveStore.Snapshot!.SourceDrafts.Values.Any(d=>d.Text==local),"real source withdrawal revokes queued typing while retaining the original stored draft");
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0,"ordinary disconnect retires exact signed consumer and text capture");
        await Press("connect");await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);await Press("inspect");
        var replacement=(EidolonPanel)app.FindChild("representations",true,false);await Until(()=>replacement.Available);
        replacement.Choose(replacement.Offered.Single(e=>e.Purpose.Name=="prolog"&&e.Style=="source"),true);
        var nextSource=(SourcePanel)replacement.FindChild("source-tools",true,false);await Until(()=>nextSource.CanEdit&&nextSource.Content.Length>0);
        Check(nextSource.Content==local&&nextSource.GetInstanceId()!=sourceId,"ordinary reconnect restores the exact local draft through the new Main-owned source consumer");
        await Press("disconnect");await app.ViewsDisposed;
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {passed=true,checks,geometry,scope="signed owners and native Control software keys; no domain Save or host input"}));
        Console.WriteLine("KEYBOARD_SIGNED_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
