using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json=Quod.Client.Json;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task OccurrenceInteraction(ScenePanel scene,Term subject,string[] ids,string parts)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;var store=app.ActiveStore;
        using var lifetime=new CancellationTokenSource(TimeSpan.FromSeconds(180));
        Rect2 Clip(Control c){var r=c.GetViewport().GetVisibleRect();for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        async Task Settled(){await Frame();await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);}
        async Task Raster(string label){await Settled();using var image=(gui.Spatial ? gui.PresentationSurface : gui.Surface).GetTexture().GetImage();Check(image.SavePng("/work/"+label+".png")==Error.Ok,"retained actual native "+label+" raster");}
        async Task Scroll(Control target){
            var owners=new List<ScrollContainer>();for(Node? p=target.GetParent();p!=null;p=p.GetParent())if(p is ScrollContainer s)owners.Add(s);
            foreach(var owner in owners.AsEnumerable().Reverse())for(int i=0;i<24&&!owner.GetGlobalRect().Encloses(target.GetGlobalRect());i++){
                var clip=owner.GetGlobalRect();var rect=target.GetGlobalRect();var direction=rect.Position.Y<clip.Position.Y?MouseButton.WheelUp:MouseButton.WheelDown;
                var bar=owner.GetVScrollBar();if(!bar.IsVisibleInTree())break;
                float distance=direction==MouseButton.WheelUp?clip.Position.Y-rect.Position.Y:rect.End.Y-clip.End.Y;
                var wheel=new InputEventMouseButton {Position=bar.GetGlobalRect().GetCenter(),ButtonIndex=direction,Factor=Math.Min(1,distance/(float)(bar.Page/8)),Pressed=true};
                bar.GetViewport().PushInput(wheel,true);wheel.Pressed=false;bar.GetViewport().PushInput(wheel,true);await Frame();
            }
            Check(target.IsVisibleInTree()&&Clip(target).Encloses(target.GetGlobalRect()),"bounded actual native scroll reaches "+target.Name);
        }
        async Task Click(Control c){await Settled();Check(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect()),"actual native target enclosed without reveal: "+c.Name);OccurrencePoint(gui,c);await Frame();gui.Press();await Frame();gui.Release();await Frame();}
        async Task Pick(string id){await Settled();var at=scene.GlobalPosition+scene.Project(id,Vector3.Zero)*scene.Size/(Vector2)scene.Viewport.Size;Check(scene.IsVisibleInTree()&&Clip(scene).HasPoint(at),"chosen real occurrence is visibly reachable before native pick");int delivered=0;ScenePanel.Selection? selected=null;void Selected(ScenePanel.Selection s){delivered++;selected=s;}scene.Selected+=Selected;
            try{gui.Move(at);await Frame();gui.Press();await Frame();gui.Release();await Frame();Check(delivered==1&&selected?.Id==id&&selected.Subject.ToString()==subject.ToString(),"one native scene gesture selects exactly its occurrence and subject");}finally{scene.Selected-=Selected;}}
        async Task Commit(string goal)=>Check(Json.Committed(await ExecuteComplete(session,store,human,goal,lifetime.Token)),"ordinary authorized fixture source update commits");
        await Pick(ids[0]);var pane=(EidolonPanel)app.FindChild("representations",true,false);var ops=pane.Operations;
        await Until(()=>pane.Available&&ops.Available&&pane.Selected?.Style=="configure");await Raster("first-associated-form");
        Check(pane.Occurrence?.Id==ids[0]&&pane.NearOccurrence&&xr.BoundOccurrence==pane.Occurrence&&pane.Current?.Exact.ToString()==subject.ToString(),"chosen authored operation is bound to the exact selected visible occurrence");
        var form=ops.FormPanel;var field=(LineEdit)form.Input("run_name")!;var submit=(Button)form.Input("apply_configuration")!;
        var draft=form.Draft;string revision=ops.Current!.Revision.ToString();var surface=gui.Surface;var firstBinding=pane.Occurrence!;
        var personal=(Button)pane.FindChild("form-personal-workspace",true,false);var near=(Button)pane.FindChild("form-near-object",true,false);
        await Click(field);Check(field.HasFocus(),"native editor receives actual focus");field.SelectAll();
        foreach(char c in "Retained sweep"){field.GetViewport().PushInput(new InputEventKey{Unicode=c,Pressed=true},true);field.GetViewport().PushInput(new InputEventKey{Unicode=c,Pressed=false},true);}
        field.Select(2,7);field.CaretColumn=7;
        await Click(personal);Check(!pane.NearOccurrence&&xr.BoundOccurrence==null,"explicit personal placement releases only the visual binding");
        await Click(near);Check(pane.NearOccurrence&&xr.BoundOccurrence==firstBinding,"explicit return restores the same current occurrence binding");
        Check(ReferenceEquals(field,form.Input("run_name"))&&field.Text=="Retained sweep"&&field.HasSelection()&&field.CaretColumn==7&&ReferenceEquals(draft,form.Draft)&&ops.Current.Revision.ToString()==revision&&ReferenceEquals(gui.Surface,surface),"relocation preserves the same native editor caret selection draft semantic revision and surface");
        await Pick(ids[1]);await Until(()=>pane.Occurrence?.Id==ids[1]&&ops.Available);await Raster("second-associated-form");
        Check(pane.Occurrence!.Id!=firstBinding.Id&&pane.Occurrence.Subject.ToString()==subject.ToString()&&ReferenceEquals(field,form.Input("run_name"))&&ReferenceEquals(draft,form.Draft),"two same-subject occurrences select distinct placement without reacquiring the form or draft");
        int rebuilt=scene.Rebuilt,writes=0,sockets=SignedView.LiveSockets;store.DurabilityBoundary=_=>writes++;
        using(var socket=new System.Net.Sockets.TcpClient()){
            await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),lifetime.Token);using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),lifetime.Token);Check(JsonNode.Parse((await reader.ReadLineAsync(lifetime.Token))!)!["ready"]!.GetValue<bool>(),"real owner work watcher installed");
            for(int i=0;i<3;i++){await Click(personal);await Click(near);await Renew(ops);await Renew(app,"worldView");}
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),lifetime.Token);var work=JsonNode.Parse((await reader.ReadLineAsync(lifetime.Token))!)!;await File.WriteAllTextAsync("/work/unchanged-work.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0&&writes==0&&scene.Rebuilt==rebuilt&&SignedView.LiveSockets==sockets&&ReferenceEquals(field,form.Input("run_name")),"three relocations and accepted unchanged form/world renewals retain resources and perform no named history rebuild write sync work");
        }
        store.DurabilityBoundary=null;
        foreach(var mode in new[]{(false,1200,26),(false,1200,48),(false,560,26),(true,1200,26),(true,1200,48)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Raster("form-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3);
            var placement=pane.NearOccurrence?personal:near;
            Check(placement.IsVisibleInTree()&&Clip(placement).Encloses(placement.GetGlobalRect()),"placement remains visible outside the bounded task scroll at "+mode);
            await Scroll(field);await Raster("field-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3);
            if(mode.Item1) {
                Check(!xr.Running&&xr.GuiSurface.Visible&&xr.BoundOccurrence==pane.Occurrence&&xr.GuiSurface.GlobalPosition.Y>pane.Occurrence!.Corners.Max(p=>p.Y),"existing spatial surface is above the chosen occurrence with XR disabled");
                await Click(field);Check(gui.TextEntryActive&&field.HasFocus(),"same native editor opens its existing adjacent keyboard");
                gui.EndTextInput();
            }
            await Scroll(submit);await Raster("action-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3);
            Check(ReferenceEquals(field,form.Input("run_name"))&&field.Text=="Retained sweep"&&ops.Current!.Revision.ToString()==revision,"responsive composition retains exact native form draft and operation revision");
        }
        xr.PresentWorkspace(false);GetTree().Root.Size=new(1200,800);gui.TextSize(26-gui.Appearance.DefaultFontSize);await Settled();
        var before=await session.Read(human,"findall(X,instrument_configuration(X),Configurations).",lifetime.Token);
        Check(Json.Binding(before,"Configurations").Items.Length==0&&!store.Snapshot!.Pending.Any(),"selection relocation resizing and renewal issue no domain configuration or replay");
        await Scroll(submit);await Click(submit);await Until(()=>!ops.IsWorking&&ops.LastOutcome!=null);
        Check(Json.Committed(ops.LastOutcome!),"one explicit native submission produces the original committed outcome");
        var after=await session.Read(human,"findall(X,instrument_configuration(X),Configurations).",lifetime.Token);
        Check(Json.Binding(after,"Configurations").ToString()=="[<<\"Retained sweep\">>]","original authored action committed once with the retained local draft");
        string outcome=ops.LastOutcome!.ToJsonString();await Click(personal);await Click(near);
        await File.WriteAllTextAsync("/work/postcommit-placement.json",System.Text.Json.JsonSerializer.Serialize(new{pane.NearOccurrence,near.Visible,personalVisible=personal.Visible,contentVisible=((Control)pane.FindChild("representation-content",true,false)).Visible,formSame=ReferenceEquals(field,form.Input("run_name")),gui.Captures,gui.Cancellations}));
        Check(ops.LastOutcome.ToJsonString()==outcome&&ReferenceEquals(field,form.Input("run_name")),"received original outcome and installed editor survive postcommit relocation");
        await Commit("transaction((retract((eidolon(instrument_solid,analyzer,_) :- true)),assertz((eidolon(instrument_solid,analyzer,"+parts.Replace("transform(700,0,0","transform(900,0,0")+") :- true)))).");
        await Until(()=>State["world_accepted"]!.GetValue<bool>()&&pane.Occurrence?.Pose is Transform3D p&&Mathf.IsEqualApprox(p.Origin.X,.9f));
        Check(ReferenceEquals(field,form.Input("run_name"))&&ops.LastOutcome!.ToJsonString()==outcome,"real scene movement updates placement while retaining the same editor and original outcome");
        var retired=pane.Occurrence!;
        await Commit("retract((space_contains("+Term.Parse(Actor.FromTerm(app.ActiveAccounts.Setup!.Require("account",6)[2]).InstanceText.TrimEnd('.'))+","+subject+") :- true)).");
        await Until(()=>State["world_accepted"]!.GetValue<bool>()&&scene.SubjectIds(subject).Length==0);
        await File.WriteAllTextAsync("/work/removal-observation.json",System.Text.Json.JsonSerializer.Serialize(new{pane.NearOccurrence,retired=retired.Pose==null,contentVisible=((Control)pane.FindChild("representation-content",true,false)).Visible,formSame=ReferenceEquals(field,form.Input("run_name")),ops.Available,scene.Count,worldAccepted=State["world_accepted"]!.GetValue<bool>()}));
        Check(retired.Pose==null&&!((Control)pane.FindChild("representation-content",true,false)).Visible&&ReferenceEquals(field,form.Input("run_name")),"occurrence removal withdraws placement without destroying the retained independent form");
        await Click(personal);await Until(()=>pane.Available&&ops.Available);
        Check(!pane.NearOccurrence&&ops.Available&&ops.LastOutcome!.ToJsonString()==outcome,"unplaced subject is inspectable only through deliberate personal placement and its current signed form");
        var wrong=(human with {Anchor=Identity.Encode(new byte[32]),InstanceText="analyzer."}).Entity;
        pane.Open(session,app.ActiveAccounts,store,wrong);await Until(()=>ops.StatusText.StartsWith("Unavailable:"));
        Check(!pane.Available&&ops.Current==null&&pane.Occurrence==null,"wrong-anchor selection withdraws the form and never inherits occurrence authority");
        await Renew(app,"worldView");Check(State["world_accepted"]!.GetValue<bool>(),"a freshly accepted independent world survives selected-subject refusal");
    }
}
