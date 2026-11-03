using Godot;
using Quod.Client;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task OccurrenceSpace(ScenePanel scene)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        var start=Actor.FromTerm(app.ActiveAccounts.Setup!.Require("account",6)[2]);
        var analyzer=(human with {InstanceText="analyzer."}).Entity;
        Check(Json.Committed(await ExecuteComplete(session,app.ActiveStore,human,"retract((space_contains("+Term.Parse(start.InstanceText.TrimEnd('.'))+","+analyzer+") :- true)).",CancellationToken.None)),"remove only the separate diagnostic instrument membership before the space task");
        await Until(()=>State["world_accepted"]!.GetValue<bool>()&&scene.SubjectIds(analyzer).Length==0);
        string initial=State["current_location"]!.ToString();
        async Task<int> Instructions()=>Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length;
        int instructions=await Instructions();
        Rect2 Clip(Control c){var r=c.GetViewport().GetVisibleRect();for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        async Task Scroll(Control target){
            var owners=new List<ScrollContainer>();for(Node? p=target.GetParent();p!=null;p=p.GetParent())if(p is ScrollContainer s)owners.Add(s);
            foreach(var owner in owners.AsEnumerable().Reverse())for(int i=0;i<32&&!owner.GetGlobalRect().Encloses(target.GetGlobalRect());i++){
                var clip=owner.GetGlobalRect();var rect=target.GetGlobalRect();var direction=rect.Position.Y<clip.Position.Y?MouseButton.WheelUp:MouseButton.WheelDown;var bar=owner.GetVScrollBar();if(!bar.IsVisibleInTree())break;
                float distance=direction==MouseButton.WheelUp?clip.Position.Y-rect.Position.Y:rect.End.Y-clip.End.Y;
                var wheel=new InputEventMouseButton{Position=bar.GetGlobalRect().GetCenter(),ButtonIndex=direction,Factor=Math.Min(1,distance/(float)(bar.Page/8)),Pressed=true};bar.GetViewport().PushInput(wheel,true);wheel.Pressed=false;bar.GetViewport().PushInput(wheel,true);await Frame();
            }
            Check(target.IsVisibleInTree()&&Clip(target).Encloses(target.GetGlobalRect()),"actual bounded space-form control is reachable: "+target.Name);
        }
        async Task Click(Control c){await Frame();await Frame();await Scroll(c);OccurrencePoint(gui,c);await Frame();gui.Press();await Frame();gui.Release();await Frame();}
        async Task Raster(string name){await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=(gui.Spatial ? gui.PresentationSurface : gui.Surface).GetTexture().GetImage();Check(image.SavePng("/work/"+name+".png")==Error.Ok,"retained actual "+name+" raster");}
        await Press("create-operations");var pane=(EidolonPanel)app.FindChild("representations",true,false);var ops=pane.Operations;
        var storage=(OptionButton)ops.FindChild("operation-storage",true,false);
        int i=Enumerable.Range(1,storage.ItemCount-1).Single(j=>storage.GetItemTooltip(j)==human.Namespace+" @ "+human.Anchor);storage.Select(i);storage.EmitSignal(OptionButton.SignalName.ItemSelected,(long)i);await Until(()=>!ops.IsWorking);
        var classes=(OptionButton)ops.FindChild("operation-class",true,false);i=Enumerable.Range(1,classes.ItemCount-1).Single(j=>classes.GetItemText(j)=="space");classes.Select(i);classes.EmitSignal(OptionButton.SignalName.ItemSelected,(long)i);await Until(()=>pane.Available&&ops.Available);
        async Task Choose(string action){
            var offered=pane.Offered.Single(e=>e.Operation&&e.Style==action);var browse=(Button)pane.FindChild("representation-browse",true,false);var choice=pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==offered.Exact.ToString());
            if(!choice.IsVisibleInTree())await Click(browse);await Click(choice);await Until(()=>ops.Current?.Name==action&&pane.Selected?.Exact.ToString()==offered.Exact.ToString());
        }
        await Choose("create");var name=(LineEdit)ops.FormPanel.Input("space_name")!;await Click(name);name.SelectAll();
        foreach(char c in "Workshop"){name.GetViewport().PushInput(new InputEventKey{Unicode=c,Pressed=true},true);name.GetViewport().PushInput(new InputEventKey{Unicode=c,Pressed=false},true);}
        await Click(ops.FormPanel.Input(ops.Current!.Form.Submit.ToString())!);await Until(()=>!ops.IsWorking&&ops.LastOutcome!=null);
        Check(Json.Committed(ops.LastOutcome!),"ordinary offered Create commits the named space exactly once");
        var child=Result(SpaceResults(ops.LastOutcome!),"space");string creation=ops.LastOutcome!.ToJsonString();
        await Until(()=>State["world_accepted"]!.GetValue<bool>()&&scene.SubjectIds(child).Length>0);
        await Click((Button)pane.FindChild("hide-subject-form",true,false));await Frame();await Frame();
        var id=scene.SubjectIds(child).Single();var point=scene.GlobalPosition+scene.Project(id,Vector3.Zero)*scene.Size/(Vector2)scene.Viewport.Size;
        Check(scene.IsVisibleInTree()&&Clip(scene).HasPoint(point),"named space exterior is an actual visible native selection target");
        Check(scene.Pick(scene.Project(id,Vector3.Zero))?.Subject.ToString()==child.ToString(),"the visible centre resolves the chosen space rather than an occluding subject");
        gui.Move(point);await Frame();gui.Press();await Frame();gui.Release();await Frame();await Until(()=>pane.Available&&pane.Current?.Exact.ToString()==child.ToString());
        Check(pane.Occurrence?.Id==id&&pane.NearOccurrence&&State["current_location"]!.ToString()==initial,"space pick retains its exact exterior occurrence without entering");
        await Choose("enter");await Raster("space-enter-associated");
        var form=ops.FormPanel;var submit=form.Input("space_travel_submit")!;var draft=form.Draft;string revision=ops.Current!.Revision.ToString();var binding=pane.Occurrence;
        Check(ops.Current.Subject.ToString()==child.ToString()&&form.Descriptor.Tree.Label=="Enter space"&&binding?.Subject.ToString()==child.ToString(),"the same class-selected authored Enter form targets the exact depicted space");
        await Click((Button)pane.FindChild("form-personal-workspace",true,false));await Click((Button)pane.FindChild("form-near-object",true,false));
        Check(ReferenceEquals(submit,form.Input("space_travel_submit"))&&ReferenceEquals(draft,form.Draft)&&ops.Current.Revision.ToString()==revision&&ops.LastOutcome!.ToJsonString()==creation&&pane.Occurrence==binding,"space-form relocation preserves its controller draft revision and original creation outcome");
        xr.PresentWorkspace(true);await Raster("space-enter-spatial");Check(xr.BoundOccurrence==binding&&xr.GuiSurface.Visible&&!xr.Running,"space action uses the same associated spatial surface without native XR");xr.PresentWorkspace(false);
        Check(await Instructions()==instructions+1&&State["current_location"]!.ToString()==initial,"viewing choosing and relocating the space form cause no travel or duplicate instruction");
        await Click(submit);await Until(()=>!ops.IsWorking&&ops.LastOutcome!=null&&ops.LastOutcome.ToJsonString()!=creation&&State["current_location"]!=null&&State["current_location"]!.ToString()!=initial);
        Check(Json.Committed(ops.LastOutcome!)&&Term.Parse(State["current_location"]!.ToString()).Require("placed",2)[0].ToString()==child.ToString()&&await Instructions()==instructions+2,"one explicit original Move enters the exact space with the same personal agent");
        await Until(()=>State["world_accepted"]!.GetValue<bool>()&&scene.Count==0);
        Check(binding!.Pose==null&&pane.Occurrence==binding,"changed current interior cannot keep the previous exterior occurrence interactive");
        await Click((Button)pane.FindChild("form-personal-workspace",true,false));await Until(()=>pane.Available&&ops.Available);await Choose("leave");
        string entered=ops.LastOutcome!.ToJsonString();await Click(ops.FormPanel.Input("space_travel_submit")!);await Until(()=>!ops.IsWorking&&ops.LastOutcome!=null&&ops.LastOutcome.ToJsonString()!=entered&&State["current_location"]?.ToString()=="unplaced");
        Check(Json.Committed(ops.LastOutcome!)&&await Instructions()==instructions+3&&!app.ActiveStore.Snapshot!.Pending.Any(),"explicit offered Leave commits once and remains separate from form placement");
    }
}
