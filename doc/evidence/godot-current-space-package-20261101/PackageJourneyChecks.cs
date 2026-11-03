using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

// Removable current-space companion. No host input, human-mode dispatch or
// product override; only the existing qualification dispatcher calls this code.
public partial class ExportChecks
{
    async Task PackageJourney(bool reopen)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        GetTree().Root.Size=new(1200,800);await Frame();await Frame();
        Rect2 Clip(Control c){var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        bool Enclosed(Control c)=>c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect());
        Button Button(string name)=>(Button)app.FindChild(name,true,false);
        async Task Draw()=>await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
        async Task Raster(string name){await Draw();using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/"+name+".png")==Error.Ok,"current package companion raster retained: "+name);}
        async Task Pixel(Vector2 p){gui.Move(p);await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();Check(gui.Captures==0,"complete software native gesture releases capture");}
        async Task Click(Button b){
            await Draw();Check(Enclosed(b)&&!b.Disabled,"visible enabled native action: "+b.Name);
            int hits=0;void Hit()=>hits++;b.Pressed+=Hit;
            try{await Pixel(b.GetGlobalRect().GetCenter());}finally{b.Pressed-=Hit;}
            Check(hits==1,"one software native gesture delivers one callback: "+b.Name);await Until(()=>!Busy);
        }
        // Used only after explicitly choosing a long inspector/form, never to
        // manufacture initial landing or subject/action destination visibility.
        async Task Scroll(Control target){
            var owners=new List<ScrollContainer>();for(Node? n=target.GetParent();n!=null;n=n.GetParent())if(n is ScrollContainer s)owners.Add(s);
            foreach(var s in owners.AsEnumerable().Reverse())for(int i=0;i<24&&!s.GetGlobalRect().Encloses(target.GetGlobalRect());i++){
                var clip=s.GetGlobalRect();var r=target.GetGlobalRect();var direction=r.Position.Y<clip.Position.Y?MouseButton.WheelUp:MouseButton.WheelDown;var bar=s.GetVScrollBar();if(!bar.IsVisibleInTree())break;
                float distance=direction==MouseButton.WheelUp?clip.Position.Y-r.Position.Y:r.End.Y-clip.End.Y;
                var wheel=new InputEventMouseButton{Position=bar.GetGlobalRect().GetCenter(),ButtonIndex=direction,Factor=Math.Min(1,distance/(float)(bar.Page/8)),Pressed=true};
                gui.Surface.PushInput(wheel,true);wheel.Pressed=false;gui.Surface.PushInput(wheel,true);await Frame();
            }
            await Draw();Check(Enclosed(target),"explicit native scrolling reaches chosen inspector control: "+target.Name);
        }
        if(!reopen)await Press("create-key");
        else Check(State["public_key"]!=null,"fresh process opens the original private active key");
        await Press("connect");Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"signed Connect uses this fresh fixture and ordinary trust");
        if(!reopen){await Press("register");await Press("prepare");await Press("setup");}
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&!Busy);await Draw();
        var human=app.ActiveAccounts.Human!;var session=app.ActiveSession;
        var identity=new JsonObject{["public_key"]=State["public_key"]!.DeepClone(),["human"]=State["human"]!.DeepClone(),["setup"]=State["setup"]!.DeepClone()};
        Check(scene.Count==0&&Enclosed(scene)&&scene.Size.Y>=300&&app.FindChild("representations",true,false)==null,"ordinary initial current interior is visible before any helper subject choice or scrolling");
        Check(Enclosed(Button("create-operations"))&&Enclosed(Button("location-operations")),"current-space tasks are initially reachable");
        await Raster(reopen?"reopened-home":"first-home");
        async Task<string[]> Instructions()=>Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Select(t=>t.Args[0].ToString()).Order().ToArray();
        var contextPath="/work/journey-context.json";JsonNode? saved=reopen?JsonNode.Parse(await File.ReadAllTextAsync(contextPath)):null;
        string originalLocation=State["current_location"]!.ToString();string[] before=await Instructions();
        if(reopen){
            Check(identity.ToJsonString()==saved!["identity"]!.ToJsonString(),"new process reconnect preserves original U A S0 and key");
            Check(originalLocation==saved["location"]!.ToString()&&before.SequenceEqual(saved["instructions"]!.AsArray().Select(n=>n!.ToString())),"same-profile current location and original instructions reopen without replay");
            Check(((Label)app.FindChild("current-place-title",true,false)).Text=="Current space · Library","reopened interior uses the committed authored name");
            Check(app.ActiveAccounts.Outcomes.Any(o=>Json.Committed(o)),"reopen retains certified original outcomes");
            await Click(Button("location-operations"));
        } else await Click(Button("create-operations"));
        var pane=(EidolonPanel)app.FindChild("representations",true,false);var operations=pane.Operations;
        Button Choice(Eidolon e)=>pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==e.Exact.ToString());
        async Task Choose(string purpose,string style){
            var choice=pane.Offered.Single(e=>e.Purpose.Name==purpose&&e.Style==style);
            if(!Choice(choice).IsVisibleInTree()){await Scroll(Button("representation-more"));await Click(Button("representation-more"));}
            await Scroll(Choice(choice));await Click(Choice(choice));await Until(()=>pane.Selected?.Exact.ToString()==choice.Exact.ToString());
        }
        if(!reopen){
            async Task Select(OptionButton control,int index){Check(index>0&&index<control.ItemCount,"exact offered catalogue item exists");await Scroll(control);control.Select(index);control.EmitSignal(OptionButton.SignalName.ItemSelected,(long)index);await Frame();}
            var storage=(OptionButton)operations.FindChild("operation-storage",true,false);
            await Select(storage,Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==human.Namespace+" @ "+human.Anchor));await Until(()=>!operations.IsWorking);
            var classes=(OptionButton)operations.FindChild("operation-class",true,false);
            await Select(classes,Enumerable.Range(1,classes.ItemCount-1).Single(i=>classes.GetItemText(i)=="space"));await Until(()=>pane.Available&&operations.Available);
            await Choose("operation","create");var name=(LineEdit)operations.FormPanel.Input("space_name")!;
            await Scroll(name);name.Text="Library";name.EmitSignal(LineEdit.SignalName.TextChanged,"Library");await Frame();
            Check(operations.FormPanel.Draft["space_name"]=="Library","software text signal edits the offered local name draft");
            var create=(Button)operations.FormPanel.Input(operations.Current!.Form.Submit.ToString())!;await Scroll(create);await Click(create);await Until(()=>!operations.IsWorking);
            Check(operations.LastOutcome!=null&&Json.Committed(operations.LastOutcome),"one explicit Create has a committed original outcome");
            var child=Result(SpaceResults(operations.LastOutcome!),"space");
            await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&scene.SubjectIds(child).Length>0);
            await Click(Button("space-home"));await Draw();
            Check(Enclosed(scene)&&scene.SubjectLabel(child)=="Library"&&State["current_location"]!.ToString()==originalLocation,"created named contents are visible without entering");await Raster("named-contents");
            var occurrence=scene.SubjectIds(child).First();var point=scene.Project(occurrence,Vector3.Zero);
            Check(scene.Pick(point)?.ToString()==child.ToString(),"current interior picker resolves the exact anchored child");
            await Pixel(scene.GlobalPosition+point*scene.Size/(Vector2)scene.Viewport.Size);
            await Until(()=>pane.Available&&operations.Available&&pane.Current?.Exact.ToString()==child.ToString());await Draw();
            Check(Enclosed((Control)pane.GetChild(0))&&State["current_location"]!.ToString()==originalLocation,"native contents pick exposes selected subject without movement or destination scrolling");
            var enter=pane.Offered.Single(e=>e.Operation&&e.Style=="enter");Check(Enclosed(Choice(enter)),"selected subject offers a reachable Enter action");await Click(Choice(enter));await Draw();
            var confirm=(Button)operations.FormPanel.Input(operations.Current!.Form.Submit.ToString())!;
            Check(Enclosed(confirm)&&(await Instructions()).Length==before.Length+1,"action choice exposes confirmation without a second instruction");
            await Click(confirm);await Until(()=>!operations.IsWorking&&State["world_accepted"]?.GetValue<bool>()==true&&Term.Parse(State["current_location"]!.ToString()).Args[0].ToString()==child.ToString());
            Check(Json.Committed(operations.LastOutcome!)&&(await Instructions()).Length==before.Length+2,"explicit Enter adds exactly one original instruction");
            await Click(Button("space-home"));Check(scene.Count==0,"entered child's interior is distinct from its exterior cube");
            await Click(Button("location-operations"));
        }
        await Until(()=>pane.Available&&operations.Available);await Choose("prolog","source");
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);await Until(()=>source.CanEdit&&source.Content.Length>0);
        var form=(FormPanel)source.FindChild("source-form",true,false);var editor=(TextEdit)form.Input("source")!;
        await Scroll(editor);await Pixel(editor.GetGlobalRect().GetCenter());Check(editor.HasFocus(),"native pointer focuses the exact current subject source editor");
        if(!reopen){editor.SetCaretLine(editor.GetLineCount()-1);editor.SetCaretColumn(editor.GetLine(editor.GetLineCount()-1).Length);editor.InsertTextAtCaret("\n% Unsent package journey draft.\n");await Frame();}
        else Check(source.Content==saved!["draft"]!.ToString(),"separate process restores the original unsent source draft");
        string local=source.Content;editor.Select(0,0,0,3);string? outcome=operations.LastOutcome?.ToJsonString();int reads=source.SnapshotReads,rebuilt=scene.Rebuilt,writes=0;
        app.ActiveStore.DurabilityBoundary=_=>writes++;
        await Click(Button("space-home"));Check(!pane.IsVisibleInTree()&&Enclosed(scene),"Home returns to current interior while retaining inspector");await Click(Button("resume-inspector"));
        app.ActiveStore.DurabilityBoundary=null;
        Check(ReferenceEquals(editor,form.Input("source"))&&source.Content==local&&editor.HasSelection()&&operations.LastOutcome?.ToJsonString()==outcome,"Inspector recalls the same native unsent draft selection and received outcome");
        Check(reads==source.SnapshotReads&&rebuilt==scene.Rebuilt&&writes==0,"local Home recall rereads no source rebuilds no scene and writes no profile");
        string[] instructions=await Instructions();Check(instructions.Length==(reopen?before.Length:before.Length+2)&&!app.ActiveStore.Snapshot!.Pending.Any(),"local draft and navigation do not submit or replay work");
        await Raster(reopen?"reopened-draft":"retained-draft");
        if(!reopen)await File.WriteAllTextAsync(contextPath,new JsonObject{["identity"]=identity,["location"]=State["current_location"]!.DeepClone(),["instructions"]=JsonSerializer.SerializeToNode(instructions),["draft"]=local}.ToJsonString());
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0&&!((OpenXRInput)app.FindChild("openxr-input",true,false)).Running,"ordinary disconnect retires signed consumers and capture with XR off");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,reopen,checks}));
        Console.WriteLine("M5_PACKAGE_JOURNEY_PASS "+(reopen?"reopen":"initial"));Console.Out.Flush();await app.CloseApplication();
    }
}
