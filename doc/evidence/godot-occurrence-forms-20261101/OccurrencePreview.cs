using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json=Quod.Client.Json;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task OccurrencePreview(ScenePanel world,Term subject,string[] ids)
    {
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        string recipe=$"class_eidolon(occurrence_instrument,playing,solid,recipe({Term.Text(human.Namespace)},{Term.Binary(Identity.Decode(human.Anchor))},instrument_solid))";
        Check(Json.Committed(await ExecuteComplete(session,app.ActiveStore,human,"assertz(("+recipe+" :- true)).",CancellationToken.None)),"ordinary authorized same-ontology visual recipe is offered for the independent instance");
        await Until(()=>State["world_accepted"]!.GetValue<bool>()&&world.Pick(world.Project(ids[0],Vector3.Zero))!=null);
        world.Select(world.Pick(world.Project(ids[0],Vector3.Zero))!);
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        await Until(()=>pane.Available&&pane.Offered.Any(e=>e.Purpose.Name=="playing"));
        pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="playing"));
        var preview=pane.Preview;
        await Until(()=>preview.SubjectIds(subject).Length==2&&preview.IsVisibleInTree());await Frame();await Frame();
        var picked=preview.Pick(preview.Project(preview.SubjectIds(subject).Order().First(),Vector3.Zero))!;
        Check(picked.Subject.ToString()==subject.ToString()&&picked.Pose!=null,"the existing embedded visual picker returns its exact installed occurrence");
        preview.Select(picked);await Frame();
        pane.Choose(pane.Offered.Single(e=>e.Operation&&e.Style=="configure"));await Until(()=>pane.Operations.Available);await Frame();await Frame();
        var input=pane.Operations.FormPanel.Input("run_name");
        await File.WriteAllTextAsync("/work/preview-binding.json",JsonSerializer.Serialize(new{selected=picked.Id,pose=picked.Pose?.ToString(),preview.Count,preview.Visible,near=pane.NearOccurrence,sameBinding=pane.Occurrence==picked,fieldPresent=input!=null,fieldVisible=input?.IsVisibleInTree()}));
        Check(picked.Pose!=null&&pane.Occurrence==picked&&input?.IsVisibleInTree()==true,"choosing the authored form retains its previously selected embedded visual occurrence and visible native field");
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var ops=pane.Operations;var form=ops.FormPanel;var field=(LineEdit)input!;var draft=form.Draft;string revision=ops.Current!.Revision.ToString();
        var personal=(Button)pane.FindChild("form-personal-workspace",true,false);var near=(Button)pane.FindChild("form-near-object",true,false);
        Check(field.GetViewport()==gui.FormSurface&&preview.GetViewport()==gui.Surface&&!gui.FormSurface.IsAncestorOf(preview),"one form-only native tree and an external visual owner form an acyclic texture dependency");
        async Task Settle(){await Frame();await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);}
        async Task Raster(string label){await Settle();using var image=(gui.Spatial ? gui.PresentationSurface : gui.Surface).GetTexture().GetImage();Check(image.SavePng("/work/"+label+".png")==Error.Ok,"retained current "+label+" raster");}
        Rect2 Clip(Control c){var clip=c.GetViewport().GetVisibleRect();for(Node? p=c.GetParent();p!=null;p=p.GetParent())if(p is Control control&&control.ClipContents)clip=clip.Intersection(control.GetGlobalRect());return clip;}
        async Task Scroll(Control target){
            var owners=new List<ScrollContainer>();for(Node? p=target.GetParent();p!=null;p=p.GetParent())if(p is ScrollContainer scroll)owners.Add(scroll);
            foreach(var owner in owners.AsEnumerable().Reverse())for(int i=0;i<24&&!Clip(target).Encloses(target.GetGlobalRect());i++){
                var bounds=owner.GetGlobalRect();var rect=target.GetGlobalRect();var bar=owner.GetVScrollBar();if(!bar.IsVisibleInTree())break;
                var direction=rect.Position.Y<bounds.Position.Y?MouseButton.WheelUp:MouseButton.WheelDown;float distance=direction==MouseButton.WheelUp?bounds.Position.Y-rect.Position.Y:rect.End.Y-bounds.End.Y;
                var wheel=new InputEventMouseButton{Position=bar.GetGlobalRect().GetCenter(),ButtonIndex=direction,Factor=Math.Min(1,distance/(float)(bar.Page/8)),Pressed=true};bar.GetViewport().PushInput(wheel,true);wheel.Pressed=false;bar.GetViewport().PushInput(wheel,true);await Frame();
            }
        }
        async Task Point(Control control){
            await Settle();await Scroll(control);
            var parents=new List<object>();for(Node? p=control.GetParent();p!=null;p=p.GetParent())if(p is Control c)parents.Add(new{name=c.Name.ToString(),rect=c.GetGlobalRect().ToString(),minimum=c.GetCombinedMinimumSize().ToString(),c.ClipContents,scroll=c is ScrollContainer sc ? sc.ScrollVertical : -1,page=c is ScrollContainer sv ? sv.GetVScrollBar().Page : -1});
            await File.AppendAllTextAsync("/work/preview-geometry.jsonl",JsonSerializer.Serialize(new{target=control.Name.ToString(),font=control.GetThemeDefaultFontSize(),rect=control.GetGlobalRect().ToString(),clip=Clip(control).ToString(),parents})+"\n");
            if(!Clip(control).Encloses(control.GetGlobalRect()))await Raster("unreachable-"+control.Name);
            Check(control.IsVisibleInTree()&&Clip(control).Encloses(control.GetGlobalRect()),"native associated target is enclosed without diagnostic reveal: "+control.Name);
            if(gui.Spatial&&pane.NearOccurrence){
                var plane=preview.FormSurface!;var quad=(QuadMesh)plane.Mesh;var pixel=control.GetGlobalRect().GetCenter();
                var local=new Vector3((pixel.X/gui.FormSurface.Size.X-.5f)*quad.Size.X,(.5f-pixel.Y/gui.FormSurface.Size.Y)*quad.Size.Y,0)+quad.CenterOffset;
                var projected=preview.Viewport.GetCamera3D().UnprojectPosition(plane.GlobalTransform*local);
                var rootPoint=preview.GlobalPosition+projected/(Vector2)preview.Viewport.Size*preview.Size;
                Check(Clip(preview).HasPoint(rootPoint),"associated texture point is inside the visible preview and its clipping ancestors");gui.Move(rootPoint);
            }else OccurrencePoint(gui,control);
            await Frame();var hovered=gui.FormSurface.GuiGetHoveredControl();
            await File.AppendAllTextAsync("/work/preview-input.jsonl",JsonSerializer.Serialize(new{target=control.Name.ToString(),rootHover=gui.Surface.GuiGetHoveredControl()?.Name.ToString(),hover=hovered?.Name.ToString(),point=gui.FormSurface.GetMousePosition().ToString(),rect=control.GetGlobalRect().ToString(),formPixels=gui.FormSurface.Size.ToString(),planeSize=(preview.FormSurface?.Mesh as QuadMesh)?.Size.ToString(),near=pane.NearOccurrence,gui.Spatial})+"\n");
            Check(hovered==control||hovered!=null&&control.IsAncestorOf(hovered),"existing capture owner resolves the rendered native form control");
        }
        async Task Click(Control control){await Point(control);gui.Press();await Frame();gui.Release();await Frame();}
        await Click(field);Check(field.HasFocus(),"desktop mirror gives actual focus to the retained native field");field.SelectAll();
        foreach(char c in "Preview sweep"){field.GetViewport().PushInput(new InputEventKey {Unicode=c,Pressed=true},true);field.GetViewport().PushInput(new InputEventKey {Unicode=c,Pressed=false},true);}
        field.Select(2,7);field.CaretColumn=7;
        foreach(var mode in new[]{(false,1200,26),(false,1200,48),(false,560,26),(true,1200,26),(true,1200,48)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Raster("preview-form-"+mode);
            Check(personal.IsVisibleInTree()&&Clip(personal).Encloses(personal.GetGlobalRect()),"explicit personal alternative is reachable at "+mode);
            if(mode.Item1){Check(preview.FormSurface?.Visible==true&&((StandardMaterial3D)preview.FormSurface.MaterialOverride).AlbedoTexture==gui.FormSurface.GetTexture()&&!xr.Running,"preview draws the same form texture near its exact visual occurrence without native XR");await Click(field);Check(gui.TextEntryActive,"associated native field opens the single adjacent keyboard");await Settle();
                field.Select(2,7);field.CaretColumn=7;string expectedText=field.Text[..2]+"a"+field.Text[7..];
                var key=(Button)gui.FormSurface.FindChild("keyboard-char-97",true,false);await Click(key);await Until(()=>field.Text==expectedText);
                Check(field.HasFocus(),"keyboard native command retains the same active editor");gui.EndTextInput();
                var undo=new InputEventKey {Keycode=Key.Z,CtrlPressed=true,Pressed=true};field.GetViewport().PushInput(undo,true);undo.Pressed=false;field.GetViewport().PushInput(undo,true);await Frame();
                Check(field.Text=="Preview sweep"&&form.Draft["run_name"]==field.Text,"native undo restores the editor and its original local draft together");field.Select(2,7);field.CaretColumn=7;
            }
            await Click(personal);Check(!pane.NearOccurrence&&xr.BoundOccurrence==null,"explicit personal placement releases only the preview binding");await Click(near);
            Check(pane.Occurrence==picked&&pane.NearOccurrence&&ReferenceEquals(field,form.Input("run_name"))&&ReferenceEquals(draft,form.Draft)&&ops.Current!.Revision.ToString()==revision&&field.Text=="Preview sweep"&&field.HasSelection()&&field.CaretColumn==7,"return retains exact occurrence native editor caret selection draft and semantic revision");
        }
        xr.PresentWorkspace(false);GetTree().Root.Size=new(1200,800);gui.TextSize(26-gui.Appearance.DefaultFontSize);await Settle();
        int rebuilt=preview.Rebuilt,sockets=SignedView.LiveSockets,writes=0;app.ActiveStore.DurabilityBoundary=_=>writes++;
        using(var socket=new System.Net.Sockets.TcpClient()){
            await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")));using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"));Check(JsonNode.Parse((await reader.ReadLineAsync())!)!["ready"]!.GetValue<bool>(),"existing work owner starts scoped observation");
            for(int i=0;i<3;i++){await Click(personal);await Click(near);await Renew(pane,"representation");await Renew(ops);}
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"));var work=JsonNode.Parse((await reader.ReadLineAsync())!)!;await File.WriteAllTextAsync("/work/preview-work.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0&&writes==0&&SignedView.LiveSockets==sockets&&preview.Rebuilt==rebuilt&&ReferenceEquals(field,form.Input("run_name")),"unchanged preview/form renewals and relocation retain native and signed resources with zero named history rebuild write sync work");
        }
        app.ActiveStore.DurabilityBoundary=null;
        var submit=form.Input("apply_configuration")!;await Click(submit);await Until(()=>!ops.IsWorking&&ops.LastOutcome!=null);
        Check(Json.Committed(ops.LastOutcome!),"the retained preview-associated form executes its original explicit action once");
        string outcome=ops.LastOutcome!.ToJsonString();var configurations=await session.Read(human,"findall(X,instrument_configuration(X),Configurations).",CancellationToken.None);
        Check(Json.Binding(configurations,"Configurations").ToString()=="[<<\"Preview sweep\">>]","the original exact subject action commits the retained local draft once");
        await Click(personal);await Click(near);Check(ops.LastOutcome.ToJsonString()==outcome,"original received outcome survives near/personal relocation");
        var other=preview.Pick(preview.Project(preview.SubjectIds(subject).Single(id=>id!=picked.Id),Vector3.Zero))!;
        preview.Select(other);await Settle();Check(pane.Occurrence==other&&picked.Pose!=null&&other.Pose!=picked.Pose&&ReferenceEquals(field,form.Input("run_name")),"second preview occurrence of the same exact subject reuses the native controller with a distinct current placement");
        int callbacks=0;personal.Pressed+=()=>callbacks++;await Point(personal);gui.Press();await Frame();int held=callbacks;
        async Task Commit(string goal)=>Check(Json.Committed(await ExecuteComplete(session,app.ActiveStore,human,goal,CancellationToken.None)),"ordinary authorized preview recipe update commits");
        await Commit("transaction((retract((eidolon(instrument_solid,analyzer,Parts) :- true)),Parts=[Left,part(Id,Geometry,_,Surface,Label,Depicts)],assertz((eidolon(instrument_solid,analyzer,[Left,part(Id,Geometry,transform(900,0,0,15,25,0),Surface,Label,Depicts)]) :- true)))).");
        await Until(()=>other.Pose is Transform3D pose&&Mathf.IsEqualApprox(pose.Origin.X,.9f)&&ops.Available);gui.Release();
        Check(callbacks==held&&gui.Captures==0&&pane.NearOccurrence&&ReferenceEquals(field,form.Input("run_name"))&&ops.LastOutcome?.ToJsonString()==outcome,"accepted preview movement cancels the held placement gesture and retains draft controller and original result");
        await Commit("transaction((retract((eidolon(instrument_solid,analyzer,Parts) :- true)),Parts=[Left,_],assertz((eidolon(instrument_solid,analyzer,[Left]) :- true)))).");
        await Until(()=>preview.SubjectIds(subject).Length==1&&other.Pose==null);
        Check(picked.Pose!=null&&!((Control)pane.FindChild("representation-content",true,false)).Visible,"selected preview removal withdraws only that occurrence and its form interaction");
        await Click(personal);await Until(()=>pane.Available&&ops.Available);
        Check(!pane.NearOccurrence&&ops.Available&&ReferenceEquals(field,form.Input("run_name")),"explicit personal placement retains the independently authorized form after visual removal");
        await Commit("retract(("+recipe+" :- true)).");await Until(()=>pane.Available&&!pane.Offered.Any(e=>e.Purpose.Name=="playing"));
        // Revoking this selected visual recipe is observed by its actual reader,
        // independently from a live world and the already committed operation.
        await Until(()=>preview.Count==0&&!preview.Visible);
        Check(picked.Pose==null&&preview.FormSurface?.Visible!=true&&ops.LastOutcome?.ToJsonString()==outcome,"actual visual offer revocation clears its preview and bound surface without changing the original action result");
        pane.Open(session,app.ActiveAccounts,app.ActiveStore,human.Ontology);await Until(()=>pane.Current?.Exact.ToString()==human.Ontology.ToString()&&pane.Available);
        Check(preview.Count==0&&other.Pose==null&&pane.Occurrence==null,"changing the semantic subject retires the previous preview consumer and placement");
        await Renew(app,"worldView");Check(State["world_accepted"]!.GetValue<bool>()&&!app.ActiveStore.Snapshot!.Pending.Any(),"fresh independent world remains accepted with no pending or replayed domain work");
    }
}
