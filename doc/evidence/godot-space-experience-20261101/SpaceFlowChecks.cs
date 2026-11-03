using Godot;
using Quod.Client;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task SpacePresentation()
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        GetTree().Root.Size=new(1200,800);await Frame();await Frame();
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&!Busy);
        string location=State["current_location"]!.ToString();var exact=Term.Parse(location).Args[0];
        Rect2 Clip(Control c){var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        bool Enclosed(Control c)=>c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect());
        async Task Click(Control c){
            var pendingRect=c.GetGlobalRect();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            Check(Enclosed(c),"actual native target enclosed: "+c.Name);int hits=0;void Hit()=>hits++;if(c is Button button)button.Pressed+=Hit;
            var rect=c.GetGlobalRect();
            try{gui.Move(rect.GetCenter());await Frame();var hover=gui.Surface.GuiGetHoveredControl()?.Name.ToString();gui.Press();await Frame();gui.Release();await Frame();await Frame();
                await File.AppendAllTextAsync("/work/presentation-actions.jsonl",JsonSerializer.Serialize(new{name=c.Name.ToString(),pending=pendingRect.ToString(),installed=rect.ToString(),after=c.GetGlobalRect().ToString(),hover,hits,gui.Cancellations})+"\n");}
            finally{if(c is Button b)b.Pressed-=Hit;}
            Check(gui.Captures==0,"complete native gesture releases capture");if(c is Button)Check(hits==1,"one native presentation callback: "+c.Name);
        }
        async Task Scroll(Control c){
            var owners=new List<ScrollContainer>();for(Node? p=c.GetParent();p!=null;p=p.GetParent())if(p is ScrollContainer s)owners.Add(s);
            foreach(var s in owners.AsEnumerable().Reverse())for(int i=0;i<24&&!s.GetGlobalRect().Encloses(c.GetGlobalRect());i++){
                var clip=s.GetGlobalRect();var rect=c.GetGlobalRect();var direction=rect.Position.Y<clip.Position.Y?MouseButton.WheelUp:MouseButton.WheelDown;var bar=s.GetVScrollBar();if(!bar.IsVisibleInTree())break;
                float distance=direction==MouseButton.WheelUp?clip.Position.Y-rect.Position.Y:rect.End.Y-clip.End.Y;
                var wheel=new InputEventMouseButton{Position=bar.GetGlobalRect().GetCenter(),ButtonIndex=direction,Factor=Math.Min(1,distance/(float)(bar.Page/8)),Pressed=true};gui.Surface.PushInput(wheel,true);wheel.Pressed=false;gui.Surface.PushInput(wheel,true);await Frame();
            }
            Check(Enclosed(c),"explicit native scrollbar reaches "+c.Name);
        }
        async Task Installed(Control target,Func<Task> action,Func<bool> predicate){
            var done=new TaskCompletionSource();void Changed(){if(predicate())done.TrySetResult();}void Scrolled(double _)=>Changed();
            var scroll=(ScrollContainer)app.FindChild("workspace-scroll",true,false);app.Changed+=Changed;target.ItemRectChanged+=Changed;scroll.GetVScrollBar().ValueChanged+=Scrolled;
            try{await action();Changed();await done.Task.WaitAsync(TimeSpan.FromSeconds(60));}finally{app.Changed-=Changed;target.ItemRectChanged-=Changed;scroll.GetVScrollBar().ValueChanged-=Scrolled;}
        }
        async Task Raster(string name){await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/"+name+".png")==Error.Ok,"native current composition raster retained: "+name);}
        await Click((Button)app.FindChild("location-operations",true,false));var pane=(EidolonPanel)app.FindChild("representations",true,false);await Until(()=>pane.Available);
        var preview=(ScenePanel)pane.FindChild("representation-scene",true,false);var world=(ScenePanel)app.FindChild("space-scene",true,false);
        Button Choice(Eidolon e)=>pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==e.Exact.ToString());
        var view=pane.Offered.Single(e=>e.Purpose.Name=="playing"&&e.Style=="wireframe");
        try{await Installed(preview,()=>Click(Choice(view)),()=>preview.Count>0&&Enclosed(preview));}
        finally{await File.WriteAllTextAsync("/work/exterior-state.json",JsonSerializer.Serialize(new{pane.Available,pane.StatusText,selected=pane.Selected?.Style,preview.Count,visible=preview.IsVisibleInTree(),enclosed=Enclosed(preview),rect=preview.GetGlobalRect().ToString(),clip=Clip(preview).ToString(),scroll=((ScrollContainer)app.FindChild("workspace-scroll",true,false)).ScrollVertical}));}
        Check(preview.NavigationBlocked&&world.Count==0&&State["current_location"]!.ToString()==location,"explicit exterior view is fully revealed without destination scrolling or entering; actual current interior remains separate");
        await Raster("explicit-exterior");
        await Click((Button)app.FindChild("space-home",true,false));await Click((Button)app.FindChild("resume-inspector",true,false));
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);var sourceChoice=pane.Offered.Single(e=>e.Purpose.Name=="prolog"&&e.Style=="source");
        var more=(Button)app.FindChild("representation-more",true,false);await Scroll(more);await Click(more);await Scroll(Choice(sourceChoice));await Click(Choice(sourceChoice));await Until(()=>source.CanEdit&&source.Content.Length>0);
        var form=(FormPanel)source.FindChild("source-form",true,false);var editor=(TextEdit)form.Input("source")!;var keyboard=(Control)gui.Surface.FindChild("spatial-keyboard",true,false);
        foreach(int font in new[]{26,48}){
            xr.PresentWorkspace(true);gui.TextSize(font-gui.Appearance.DefaultFontSize);await Frame();await Frame();await Scroll(editor);await Click(editor);await Frame();
            Check(editor.HasFocus()&&keyboard.IsVisibleInTree()&&Enclosed(editor)&&Enclosed(keyboard),"adjacent native keyboard and actual focused editor remain enclosed at "+font);
            string before=editor.Text;var space=(Button)keyboard.FindChild("keyboard-space",true,false);await Click(space);
            Check(editor.Text.Length==before.Length+1&&source.Content==editor.Text&&pane.Current!.Exact.ToString()==exact.ToString(),"one keyboard gesture edits only the current exact-subject local source draft at "+font);
            editor.Select(0,0,0,3);string draft=editor.Text;await Raster("source-keyboard-"+font);
            await Click((Button)app.FindChild("space-home",true,false));
            Check(!keyboard.IsVisibleInTree()&&!editor.IsVisibleInTree()&&gui.Captures==0,"Home hides retained editor and revokes its keyboard/capture at "+font);
            await Click((Button)app.FindChild("resume-inspector",true,false));
            Check(ReferenceEquals(editor,form.Input("source"))&&source.Content==draft&&editor.HasSelection(),"native editor draft and selection survive spatial Home recall at "+font);
        }
        Check(State["current_location"]!.ToString()==location&&!app.ActiveStore.Snapshot!.Pending.Any()&&!xr.Running,"view and keyboard actions create no domain instruction, uncertain work or XR runtime");
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0&&gui.Captures==0,"presentation disconnect retires signed consumers and capture");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("SPACE_EXPERIENCE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task SpaceFlow()
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        GetTree().Root.Size=new(1200,800);await Frame();await Frame();
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&!Busy);
        await Frame();await Frame();
        Rect2 Clip(Control c){var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        bool Enclosed(Control c)=>c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect());
        async Task Raster(string name){await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/"+name+".png")==Error.Ok,"current native raster retained: "+name);}
        async Task Pixel(Vector2 p){gui.Move(p);await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();Check(gui.Captures==0,"native gesture releases capture");}
        async Task Click(Button b){
            Check(Enclosed(b)&&!b.Disabled,"visible enabled native action: "+b.Name);int n=0,down=0,up=0;void Hit()=>n++;void Down()=>down++;void Up()=>up++;
            b.Pressed+=Hit;b.ButtonDown+=Down;b.ButtonUp+=Up;
            try{
                var rect=b.GetGlobalRect();gui.Move(rect.GetCenter());await Frame();var hover=gui.Surface.GuiGetHoveredControl()?.Name.ToString();
                gui.Press();await Frame();var held=new{disabled=b.Disabled,captures=gui.Captures,pressed=b.ButtonPressed,rect=b.GetGlobalRect().ToString(),mouse=gui.Surface.GetMousePosition().ToString()};
                gui.Release();await Frame();await Frame();
                await File.AppendAllTextAsync("/work/native-actions.jsonl",JsonSerializer.Serialize(new{name=b.Name.ToString(),rect=rect.ToString(),hover,held,down,up,callbacks=n,after=b.GetGlobalRect().ToString(),gui.Cancellations})+"\n");
                Check(gui.Captures==0,"native gesture releases capture");
            }finally{b.Pressed-=Hit;b.ButtonDown-=Down;b.ButtonUp-=Up;}
            Check(n==1,"one native gesture delivers one callback: "+b.Name);await Until(()=>!Busy);
        }
        Button Button(string name)=>(Button)app.FindChild(name,true,false);
        // Explicit user scrolling is allowed for a chosen long inspector. This
        // helper is never used for landing, Home or an action's destination.
        async Task Scroll(Control target){
            var owners=new List<ScrollContainer>();for(Node? p=target.GetParent();p!=null;p=p.GetParent())if(p is ScrollContainer scroll)owners.Add(scroll);
            foreach(var owner in owners.AsEnumerable().Reverse())for(int i=0;i<24&&!owner.GetGlobalRect().Encloses(target.GetGlobalRect());i++){
                var clip=owner.GetGlobalRect();var rect=target.GetGlobalRect();var direction=rect.Position.Y<clip.Position.Y?MouseButton.WheelUp:MouseButton.WheelDown;
                var bar=owner.GetVScrollBar();if(!bar.IsVisibleInTree())break;
                float distance=direction==MouseButton.WheelUp ? clip.Position.Y-rect.Position.Y : rect.End.Y-clip.End.Y;
                // Native smooth-wheel factor: the pinned scrollbar consumes
                // page/8 per unit. Fractional movement avoids oscillating
                // around an editor exactly as tall as its clipping viewport.
                float factor=Math.Min(1,distance/(float)(bar.Page/8));
                var wheel=new InputEventMouseButton {Position=bar.GetGlobalRect().GetCenter(),ButtonIndex=direction,Factor=factor,Pressed=true};
                gui.Surface.PushInput(wheel,true);wheel.Pressed=false;gui.Surface.PushInput(wheel,true);await Frame();
            }
            if(!Enclosed(target)){await Raster("scroll-failure");await File.WriteAllTextAsync("/work/scroll-failure.json",JsonSerializer.Serialize(new{target=target.GetGlobalRect().ToString(),clip=Clip(target).ToString(),owners=owners.Select(o=>new{rect=o.GetGlobalRect().ToString(),bar=o.GetVScrollBar().GetGlobalRect().ToString(),value=o.ScrollVertical,max=o.GetVScrollBar().MaxValue,page=o.GetVScrollBar().Page})}));}
            Check(Enclosed(target),"explicit bounded native scrolling reaches "+target.Name);
        }
        async Task Mode(bool spatial,int width,int font){GetTree().Root.Size=new(width,800);xr.PresentWorkspace(spatial);gui.Surface.GuiEmbedSubwindows=true;gui.TextSize(font-gui.Appearance.DefaultFontSize);await Frame();await Frame();}
        var human=app.ActiveAccounts.Human!;var session=app.ActiveSession;string setup=app.ActiveAccounts.Setup!.ToString();
        var initial=Term.Parse(State["current_location"]!.ToString()).Require("placed",2)[0];string initialLocation=State["current_location"]!.ToString();
        Check(scene.Count==0&&Enclosed(scene)&&app.FindChild("representations",true,false)==null,"ordinary landing is the empty accepted interior before any subject choice or scroll");
        Check(((Label)app.FindChild("current-place-title",true,false)).Text=="Current space · Space","current place uses its authorized authored name");
        foreach(var mode in new[]{(false,1200,26),(false,1200,48),(false,560,26),(true,1200,26),(true,1200,48)}){
            await Mode(mode.Item1,mode.Item2,mode.Item3);await Raster("home-"+mode);
            Check(Enclosed(scene)&&scene.Size.Y>=300&&Enclosed(Button("location-operations"))&&Enclosed(Button("create-operations")),"current interior and ordinary tasks enclosed without scrolling at "+mode);
        }
        await Mode(false,1200,26);
        async Task<int> Instructions()=>Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length;
        int instructions=await Instructions();
        await Click(Button("create-operations"));var pane=(EidolonPanel)app.FindChild("representations",true,false);var operations=pane.Operations;
        async Task Select(OptionButton control,int index){
            Check(index>0&&index<control.ItemCount,"actual offered catalogue item exists");await Scroll(control);
            control.Select(index);control.EmitSignal(OptionButton.SignalName.ItemSelected,(long)index);await Frame();
        }
        var storage=(OptionButton)operations.FindChild("operation-storage",true,false);
        await Select(storage,Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==human.Namespace+" @ "+human.Anchor));await Until(()=>!operations.IsWorking);
        var classes=(OptionButton)operations.FindChild("operation-class",true,false);
        await Select(classes,Enumerable.Range(1,classes.ItemCount-1).Single(i=>classes.GetItemText(i)=="space"));await Until(()=>pane.Available&&operations.Available);
        Button Choice(Eidolon e)=>pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==e.Exact.ToString());
        async Task Choose(string purpose,string style){var choice=pane.Offered.Single(e=>e.Purpose.Name==purpose&&e.Style==style);if(!Choice(choice).IsVisibleInTree()){var more=Button("representation-more");await Scroll(more);await Click(more);}await Scroll(Choice(choice));await Click(Choice(choice));await Until(()=>pane.Selected?.Exact.ToString()==choice.Exact.ToString());await Frame();}
        await Choose("operation","create");var name=(LineEdit)operations.FormPanel.Input("space_name")!;await Scroll(name);await Pixel(name.GetGlobalRect().GetCenter());
        name.SelectAll();gui.Surface.PushInput(new InputEventKey{Keycode=Key.Backspace,Pressed=true},true);gui.Surface.PushInput(new InputEventKey{Keycode=Key.Backspace,Pressed=false},true);
        foreach(char c in "Library"){gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=true},true);gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=false},true);}await Frame();
        Check(operations.FormPanel.Draft["space_name"]=="Library","native text edits the single offered local name draft");
        var create=(Button)operations.FormPanel.Input(operations.Current!.Form.Submit.ToString())!;await Scroll(create);await Click(create);await Until(()=>!operations.IsWorking);
        Check(operations.LastOutcome!=null&&Json.Committed(operations.LastOutcome),"one explicit Create has a committed original outcome");
        var child=Result(SpaceResults(operations.LastOutcome!),"space");string outcome=operations.LastOutcome!.ToJsonString();
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&scene.SubjectIds(child).Length>0);
        await Click(Button("space-home"));await Frame();await Frame();
        Check(Enclosed(scene)&&!pane.IsVisibleInTree()&&State["current_location"]!.ToString()==initialLocation,"Home exposes current contents without entering the created child");
        Check(scene.SubjectLabel(child)=="Library"&&await Instructions()==instructions+1,"actual contents retain the authored child label and exactly one creation instruction");
        await Raster("contents");
        var occurrence=scene.SubjectIds(child).First();var point=scene.Project(occurrence,Vector3.Zero);
        Check(scene.Pick(point)?.ToString()==child.ToString(),"existing scene picker resolves the exact anchored child");
        await Pixel(scene.GlobalPosition+point*scene.Size/(Vector2)scene.Viewport.Size);
        await Until(()=>pane.Available&&operations.Available&&pane.Current?.Exact.ToString()==child.ToString());await Frame();
        Check(pane.IsVisibleInTree()&&Enclosed((Control)pane.GetChild(0))&&State["current_location"]!.ToString()==initialLocation,"native content pick opens selected context without changing current place or scrolling the destination");
        Check(((Label)pane.FindChild("representation-subject",true,false)).Text.Contains("Library"),"selected authored name is distinct from the current place");
        await Raster("selected-subject");
        foreach(var mode in new[]{(false,1200,48),(false,560,26),(true,1200,48)}){
            await Mode(mode.Item1,mode.Item2,mode.Item3);await Raster("selected-"+mode);
            var offeredEnter=pane.Offered.Single(e=>e.Operation&&e.Style=="enter");
            Check(Enclosed((Control)pane.GetChild(0))&&Enclosed(Choice(offeredEnter)),"selected subject and its available primary action are enclosed without destination scrolling at "+mode);
        }
        await Mode(false,1200,26);
        var preview=(ScenePanel)pane.FindChild("representation-scene",true,false);var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        Check(preview.NavigationBlocked,"inspector presentation does not advertise world travel through its read-only preview");
        await Choose("operation","enter");await Frame();var confirmation=(Button)operations.FormPanel.Input(operations.Current!.Form.Submit.ToString())!;
        Check(Enclosed(confirmation),"ordinary explicit Enter choice exposes its confirmation without destination scrolling");
        var draft=operations.FormPanel.Draft;var id=confirmation.GetInstanceId();await Click(Button("space-home"));await Click(Button("resume-inspector"));
        Check(ReferenceEquals(draft,operations.FormPanel.Draft)&&confirmation.GetInstanceId()==id&&operations.LastOutcome!.ToJsonString()==outcome,"Home and inspector recall retain the same native draft and received original outcome");
        await Choose("operation","enter");Check(await Instructions()==instructions+1,"inspection and action-form choice submit nothing");await Click(confirmation);await Until(()=>!operations.IsWorking);
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&Term.Parse(State["current_location"]!.ToString()).Args[0].ToString()==child.ToString());
        Check(pane.Current!.Exact.ToString()==child.ToString()&&pane.IsVisibleInTree()&&((Label)app.FindChild("current-place-title",true,false)).Text=="Current space · Library","navigation updates current context without replacing the deliberate inspector");
        await Click(Button("space-home"));Check(scene.Count==0&&State["scene_count"]!.GetValue<int>()==0,"entered child's ordinary interior stays empty instead of showing its exterior cube");
        await Click(Button("location-operations"));await Until(()=>pane.Available&&operations.Available);await Choose("prolog","source");await Until(()=>source.CanEdit&&source.Content.Length>0);
        var form=(FormPanel)source.FindChild("source-form",true,false);var editor=(TextEdit)form.Input("source")!;await Scroll(editor);await Pixel(editor.GetGlobalRect().GetCenter());
        Check(editor.HasFocus(),"ordinary complete scroll and pointer gestures focus the actual native source editor");
        editor.SetCaretLine(editor.GetLineCount()-1);editor.SetCaretColumn(editor.GetLine(editor.GetLineCount()-1).Length);editor.InsertTextAtCaret(" ");await Frame();string local=source.Content;editor.Select(0,0,0,3);
        int reads=source.SnapshotReads,rebuilt=scene.Rebuilt,writes=0;app.ActiveStore.DurabilityBoundary=_=>writes++;
        using(var socket=new System.Net.Sockets.TcpClient()){
            using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),limit.Token);Check(JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!["ready"]!.GetValue<bool>(),"named unchanged history/rebuild/write/sync watcher installed");
            for(int i=0;i<3;i++){await Click(Button("space-home"));await Click(Button("resume-inspector"));}
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),limit.Token);var work=JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!;await File.WriteAllTextAsync("/work/unchanged-work.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0&&writes==0&&reads==source.SnapshotReads&&rebuilt==scene.Rebuilt,"unchanged local home/inspector transitions perform no watched reads/rebuild/writes/sync or cursor reread");
        }
        app.ActiveStore.DurabilityBoundary=null;
        Check(ReferenceEquals(editor,form.Input("source"))&&source.Content==local&&editor.HasSelection(),"same native editor dirty text and selection survive local Home transitions");
        string location=State["current_location"]!.ToString();int count=await Instructions();await Press("disconnect");await app.ViewsDisposed;await Press("connect");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&pane.Available&&source.CanEdit&&source.Content==local);
        session=app.ActiveSession;
        Check(app.ActiveAccounts.Human==human&&app.ActiveAccounts.Setup!.ToString()==setup&&State["current_location"]!.ToString()==location&&pane.Current!.Exact.ToString()==child.ToString()&&pane.IsVisibleInTree()&&await Instructions()==count,"explicit same-profile reconnect retains original U/A/location/source draft and deliberate inspector with no replay");
        await Click(Button("space-home"));await Click(Button("location-operations"));await Until(()=>pane.Available&&operations.Available);await Choose("operation","leave");
        confirmation=(Button)operations.FormPanel.Input(operations.Current!.Form.Submit.ToString())!;Check(Enclosed(confirmation),"Leave confirmation is the actual ordinary destination");await Click(confirmation);await Until(()=>!operations.IsWorking&&State["current_location"]?.ToString()=="unplaced");
        await Click(Button("space-home"));Check(!scene.IsVisibleInTree()&&((Label)app.FindChild("current-place-title",true,false)).Text=="Not placed in a space"&&await Instructions()==instructions+3,"explicit Leave yields truthful unplaced context with no inferred parent and exactly three instructions");
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0&&gui.Captures==0&&!xr.Running,"ordinary disconnect retires all signed consumers and capture with XR off");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks}));Console.WriteLine("SPACE_EXPERIENCE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
