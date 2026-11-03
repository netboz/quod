using Godot;
using Quod.Client;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task Contextual()
    {
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["operation_available"]?.GetValue<bool>()==true);
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        Rect2 Clip(Control c){var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        async Task Reveal(Control c){var done=new TaskCompletionSource();SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>done.TrySetResult());await done.Task.WaitAsync(TimeSpan.FromSeconds(60));await Frame();}
        async Task Click(Button b){await Reveal(b);Check(!b.Disabled&&b.IsVisibleInTree()&&Clip(b).Encloses(b.GetGlobalRect()),"current native target is enabled and enclosed: "+b.Name);int count=0;void Hit()=>count++;b.Pressed+=Hit;try{gui.Move(b.GetGlobalRect().GetCenter());await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();}finally{b.Pressed-=Hit;}Check(count==1&&gui.Captures==0,"one native press release activates exactly one callback");}
        await Click((Button)app.FindChild("location-operations",true,false));await Until(()=>pane.Available&&pane.Operations.Available);
        if(Env("M1B_PHASE")=="contextual-entry") {
            var heading=(Label)pane.FindChild("representation-subject",true,false);await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            bool shown=Clip(heading).Encloses(heading.GetGlobalRect());var initial=new {clip=Clip(heading).ToString(),rect=heading.GetGlobalRect().ToString(),shown};
            using(var image=gui.Surface.GetTexture().GetImage())image.SavePng("/work/open-context.png");
            var offeredAction=pane.Offered.Single(e=>e.Operation&&e.Style=="leave");
            await Click(pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==offeredAction.Exact.ToString()));
            await Until(()=>pane.Selected?.Exact.ToString()==offeredAction.Exact.ToString());await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            var title=pane.Operations.FormPanel.FindChildren("*","Label",true,false).OfType<Label>().Single(l=>l.Text==pane.Operations.Current!.Form.Tree.Label);
            var confirmation=pane.Operations.FormPanel.Input(pane.Operations.Current!.Form.Submit.ToString())!;
            bool formShown=Clip(title).Encloses(title.GetGlobalRect())&&Clip(confirmation).Encloses(confirmation.GetGlobalRect());
            await File.WriteAllTextAsync("/work/entry.json",JsonSerializer.Serialize(new{initial,formShown,title=title.GetGlobalRect().ToString(),confirmation=confirmation.GetGlobalRect().ToString(),clip=Clip(title).ToString()}));
            using(var image=gui.Surface.GetTexture().GetImage())image.SavePng("/work/open-action.png");
            Check(shown&&formShown,"ordinary subject and action opening reveal their actual context and confirmation without a test reveal of the destination");
            foreach(var mode in new[]{(true,1200,26),(true,1200,48),(false,560,26)}) {
                GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.Surface.GuiEmbedSubwindows=true;gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Frame();
                await Click((Button)app.FindChild("location-operations",true,false));await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
                Check(Clip(heading).Encloses(heading.GetGlobalRect()),"ordinary current subject context is visible after opening at "+mode);
                await Click(pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==offeredAction.Exact.ToString()));await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
                Check(Clip(title).Encloses(title.GetGlobalRect())&&Clip(confirmation).Encloses(confirmation.GetGlobalRect()),"opening the same action exposes its retained title and confirmation at "+mode);
                using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/action-"+mode+".png")==Error.Ok,"actual action destination raster retained");
            }
            await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0&&gui.Captures==0,"entry consumers retire normally");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("CONTEXTUAL_PASS");Console.Out.Flush();await app.CloseApplication();return;
        }
        xr.PresentWorkspace(true);gui.Surface.GuiEmbedSubwindows=true;gui.TextSize(26-gui.Appearance.DefaultFontSize);await Frame();await Frame();
        await Reveal((Control)pane.GetChild(0));await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
        using(var image=gui.Surface.GetTexture().GetImage())Check(image.SavePng("/work/current-subject.png")==Error.Ok,"actual current-subject raster retained");
        var offered=pane.Offered;
        var visible=pane.FindChildren("*","Button",true,false).OfType<Button>().Where(b=>b.IsVisibleInTree()).ToArray();
        await File.WriteAllTextAsync("/work/context-baseline.json",JsonSerializer.Serialize(new{subject=pane.Current!.Exact.ToString(),choices=offered.Select(e=>e.Exact.ToString()),buttons=visible.Select(b=>new{text=b.Text,tooltip=b.TooltipText}),location=State["current_location"]?.ToString()}));
        Check(offered.Length>1&&offered.All(e=>visible.Any(b=>b.TooltipText==e.Exact.ToString())),"each authored view or action has a directly visible labelled native choice without opening a technical dropdown");
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;var setup=app.ActiveAccounts.Setup!.ToString();
        var original=State["current_location"]!.ToString();var assignment=State["assignment_revision"]!.ToString();
        var subject=pane.Current!.Exact;var operations=pane.Operations;
        var preview=(ScenePanel)pane.FindChild("representation-scene",true,false);
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        async Task<int> Instructions()=>Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length;
        int beforeInstructions=await Instructions();
        Button Choice(Eidolon e)=>pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==e.Exact.ToString());
        async Task SelectView(string purpose,string style){var e=pane.Offered.Single(e=>e.Purpose.Name==purpose&&e.Style==style);await Click(Choice(e));await Until(()=>pane.Selected?.Exact.ToString()==e.Exact.ToString());}
        Check(((Label)pane.FindChild("representation-subject",true,false)).Text=="Current space"&&pane.Current.Exact.ToString()==subject.ToString(),"subject context is derived from the accepted current navigation identity");
        Check(operations.FindChild("offered-operation",true,false)==null,"one native choice dispatcher replaces the duplicate operation dropdown");
        await SelectView("operation","leave");
        var draft=operations.FormPanel.Draft;var submit=operations.FormPanel.Input(operations.Current!.Form.Submit.ToString());
        await SelectView("playing","solid");await Until(()=>preview.Visible&&preview.SubjectIds(subject).Length>0);
        await SelectView("playing","contents");await Until(()=>preview.Visible&&preview.Count==0);
        await SelectView("operation","leave");
        Check(ReferenceEquals(draft,operations.FormPanel.Draft)&&ReferenceEquals(submit,operations.FormPanel.Input(operations.Current!.Form.Submit.ToString())),"view choices preserve the same unsent native action form draft and control identity");
        Check(State["current_location"]!.ToString()==original&&State["assignment_revision"]!.ToString()==assignment&&await Instructions()==beforeInstructions&&!app.ActiveStore.Snapshot!.Pending.Any(),"viewing or opening an action form performs no movement instruction or pending write");
        foreach(var mode in new[]{(true,1200,26),(true,1200,48),(false,560,26)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Frame();
            var targets=pane.Offered.Select(Choice).Cast<Control>().Append((Control)submit!).ToArray();
            foreach(var target in targets){await Reveal(target);Check(target.IsVisibleInTree()&&Clip(target).Encloses(target.GetGlobalRect()),"context choice or confirmation reachable through all clipping ancestors at "+mode);}
            await Reveal((Control)pane.GetChild(0));await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/context-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3+".png")==Error.Ok,"current contextual raster retained");
        }
        xr.PresentWorkspace(true);GetTree().Root.Size=new(1200,800);gui.TextSize(26-gui.Appearance.DefaultFontSize);await Frame();await Frame();
        await SelectView("playing","solid");await Until(()=>preview.Visible&&preview.SubjectIds(subject).Length>0);
        var view=typeof(EidolonPanel).GetField("representation",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(pane);
        var buttons=pane.Offered.Select(Choice).Select(b=>b.GetInstanceId()).ToArray();int rebuilt=preview.Rebuilt,writes=0;app.ActiveStore.DurabilityBoundary=_=>writes++;
        using(var socket=new System.Net.Sockets.TcpClient()) {
            using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);
            using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),limit.Token);Check(JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!["ready"]!.GetValue<bool>(),"named history rebuild write sync observation installed");
            await SelectView("playing","solid");await SelectView("playing","solid");
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),limit.Token);var cost=JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!;await File.WriteAllTextAsync("/work/unchanged-work.json",cost.ToJsonString());
            Check(cost["work"]!["calls"]!.AsArray().Count==0&&writes==0&&preview.Rebuilt==rebuilt&&ReferenceEquals(view,typeof(EidolonPanel).GetField("representation",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(pane))&&buttons.SequenceEqual(pane.Offered.Select(Choice).Select(b=>b.GetInstanceId())),"unchanged visible choices retain native controls signed consumer scene and zero watched work");
        }
        app.ActiveStore.DurabilityBoundary=null;
        async Task Pixel(Vector2 p){gui.Move(p);await Frame();gui.Press();await Frame();gui.Release();await Frame();Check(gui.Captures==0,"native catalogue gesture releases capture");}
        IEnumerable<Node> Descendants(Node n){foreach(var c in n.GetChildren(true)){yield return c;foreach(var d in Descendants(c))yield return d;}}
        async Task Select(OptionButton select,int index){
            await Reveal(select);await Pixel(select.GetGlobalRect().GetCenter());var popup=select.GetPopup();await Frame();
            Check(popup.Visible&&new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(new Rect2(popup.Position,popup.Size)),"ordinary storage or class picker opens within the native surface");
            popup.ScrollToItem(index);await Frame();var scroll=Descendants(popup).OfType<ScrollContainer>().Single(v=>v.IsVisibleInTree());var items=scroll.GetChildren(true).OfType<Control>().Single(c=>c.GetClass()=="PopupMenuItems");
            int font=popup.GetThemeFontSize("font_size","PopupMenu"),gap=popup.GetThemeConstant("v_separation","PopupMenu");float height=Math.Max(popup.GetThemeFont("font","PopupMenu").GetHeight(font),popup.GetThemeIcon("radio_checked","PopupMenu").GetHeight());
            int changed=0;void Selected(long i){if(i==index)changed++;}select.ItemSelected+=Selected;
            try{await Pixel((Vector2)popup.Position+items.GlobalPosition+new Vector2(60,index*(height+gap)+gap+height/2));}finally{select.ItemSelected-=Selected;}
            Check(changed==1&&select.Selected==index&&!popup.Visible,"one actual catalogue item selects its exact target once");
        }
        await Click((Button)app.FindChild("create-operations",true,false));
        var storage=(OptionButton)operations.FindChild("operation-storage",true,false);
        await Select(storage,Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==human.Namespace+" @ "+human.Anchor));await Until(()=>!operations.IsWorking);
        var classes=(OptionButton)operations.FindChild("operation-class",true,false);
        await Select(classes,Enumerable.Range(1,classes.ItemCount-1).Single(i=>classes.GetItemText(i)=="space"));await Until(()=>pane.Available&&operations.Available);
        await SelectView("operation","create");
        Check(operations.Current!.Subject.ToString()==Term.Call("class_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom("space")).ToString(),"authored Create remains bound to explicitly chosen storage and exact class");
        await Click((Button)operations.FormPanel.Input(operations.Current.Form.Submit.ToString())!);await Until(()=>!operations.IsWorking);
        Check(operations.LastOutcome!=null&&Json.Committed(operations.LastOutcome),"one native Create receives an actual committed outcome");
        var created=Result(SpaceResults(operations.LastOutcome!),"space");string outcome=operations.LastOutcome!.ToJsonString();
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
        await Click(operations.FindChild("operation-results",true,false).GetChildren().OfType<Button>().Single(b=>b.TooltipText==created.ToString()));await Until(()=>pane.Available&&operations.Available);
        Check(pane.Current!.Exact.ToString()==created.ToString()&&State["current_location"]!.ToString()==original&&operations.LastOutcome!.ToJsonString()==outcome,"viewing the exact returned subject retains original outcome without entering it");
        await SelectView("playing","wireframe");await Until(()=>preview.Visible&&preview.SubjectIds(created).Length>0);
        await SelectView("operation","enter");await Click((Button)operations.FormPanel.Input(operations.Current!.Form.Submit.ToString())!);await Until(()=>!operations.IsWorking);
        Check(operations.LastOutcome!=null&&Json.Committed(operations.LastOutcome),"explicit native Move submits the existing signed Enter exactly once");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["current_location"]?.ToString()==Term.Call("placed",created,Term.Parse("transform(0,0,0,0,0,0)")).ToString());
        Check(app.ActiveAccounts.Setup!.ToString()==setup&&await Instructions()==beforeInstructions+2,"Create and Enter preserve original U A S0 and add exactly two instructions");
        await Click((Button)app.FindChild("location-operations",true,false));await Until(()=>pane.Available&&operations.Available);
        await SelectView("playing","contents");await Until(()=>preview.Visible&&preview.Count==0);
        Check(((Label)pane.FindChild("representation-subject",true,false)).Text=="Current space","committed movement updates the current subject context through its real owner");
        await SelectView("prolog","source");await Until(()=>source.CanEdit&&source.Content.Length>0);
        var sourceForm=(FormPanel)source.FindChild("source-form",true,false);var editor=(TextEdit)sourceForm.Input("source")!;string originalSource=source.Content;
        await Reveal(editor);await Pixel(editor.GetGlobalRect().GetCenter());editor.SetCaretLine(editor.GetLineCount()-1);editor.SetCaretColumn(editor.GetLine(editor.GetLineCount()-1).Length);
        var edited=new TaskCompletionSource();void Edited()=>edited.TrySetResult();editor.TextChanged+=Edited;
        try{gui.Surface.PushInput(new InputEventKey {Unicode=32,Pressed=true},true);gui.Surface.PushInput(new InputEventKey {Unicode=32,Pressed=false},true);await edited.Task.WaitAsync(TimeSpan.FromSeconds(30));}finally{editor.TextChanged-=Edited;}
        string local=source.Content;await SelectView("playing","contents");await Until(()=>preview.Visible);await SelectView("prolog","source");await Until(()=>source.CanEdit&&source.Content==local);
        Check(local==originalSource+" "&&ReferenceEquals(editor,sourceForm.Input("source"))&&pane.Current!.Exact.ToString()==created.ToString()&&await Instructions()==beforeInstructions+2,"local source text and control survive representation choice without Save or subject conversion");
        // System source revocation uses the existing disposable fixture policy owner.
        var system=app.ActiveAccounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        pane.Open(session,app.ActiveAccounts,app.ActiveStore,system.Ontology);await Until(()=>pane.Available);await SelectView("prolog","source");await Until(()=>source.Content.Length>0);
        Check(!source.CanEdit,"authored system source remains read only");
        var world=(SignedView)typeof(Main).GetField("worldView",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(app)!;int withdrawals=0;void Withdrawn(string _)=>withdrawals++;world.Withdrawn+=Withdrawn;
        await SpaceControl(new JsonObject {["source_access"]="deny"});await Until(()=>source.Content.Length==0);
        var accepted=new TaskCompletionSource();void Projected(JsonNode _)=>accepted.TrySetResult();world.Projection+=Projected;
        try{await world.Renew();await accepted.Task.WaitAsync(TimeSpan.FromSeconds(30));}finally{world.Projection-=Projected;world.Withdrawn-=Withdrawn;}
        Check(!source.CanEdit&&withdrawals==0&&State["world_accepted"]!.GetValue<bool>(),"selected source denial withdraws content while the independent world has a fresh accepted projection");
        var wrong=system with {Anchor=Identity.Encode(new byte[32])};pane.Open(session,app.ActiveAccounts,app.ActiveStore,wrong.Ontology);await Until(()=>pane.StatusText.StartsWith("Unavailable"));
        Check(!pane.Available&&source.Content.Length==0&&pane.FindChild("representation-choices",true,false).FindChildren("*","Button",true,false).OfType<Button>().All(b=>b.Disabled),"wrong-anchor subject cannot retain readable content or active stale choices");
        await Click((Button)app.FindChild("location-operations",true,false));await Until(()=>pane.Available&&operations.Available);await SelectView("operation","leave");
        await Click((Button)operations.FormPanel.Input(operations.Current!.Form.Submit.ToString())!);await Until(()=>!operations.IsWorking);
        Check(operations.LastOutcome!=null&&Json.Committed(operations.LastOutcome),"explicit native Leave commits through the unchanged governed form");await Until(()=>State["current_location"]?.ToString()=="unplaced");
        Check(await Instructions()==beforeInstructions+3&&app.ActiveAccounts.Setup!.ToString()==setup&&!app.ActiveStore.Snapshot!.Pending.Any(),"Create Enter Leave each submit once with the same U A and no uncertain replay");
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0&&!xr.Running,"contextual consumer retires all signed sockets and captures without native XR");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));
        Console.WriteLine("CONTEXTUAL_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
