using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task VisibilityChecks(ScenePanel scene,Term subject,string[] ids)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        async Task Settled(){await Frame();await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);}
        Rect2 Clip(Control c){var r=c.GetViewport().GetVisibleRect();for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        async Task Scroll(Control target){
            foreach(var owner in Ancestors(target).OfType<ScrollContainer>().Reverse())for(int i=0;i<24&&!owner.GetGlobalRect().Encloses(target.GetGlobalRect());i++){
                var clip=owner.GetGlobalRect();var rect=target.GetGlobalRect();var direction=rect.Position.Y<clip.Position.Y?MouseButton.WheelUp:MouseButton.WheelDown;
                var bar=owner.GetVScrollBar();if(!bar.IsVisibleInTree())break;
                float distance=direction==MouseButton.WheelUp?clip.Position.Y-rect.Position.Y:rect.End.Y-clip.End.Y;
                var wheel=new InputEventMouseButton{Position=bar.GetGlobalRect().GetCenter(),ButtonIndex=direction,Factor=Math.Min(1,distance/(float)(bar.Page/8)),Pressed=true};
                bar.GetViewport().PushInput(wheel,true);wheel.Pressed=false;bar.GetViewport().PushInput(wheel,true);await Frame();
            }
        }
        async Task Image(SubViewport viewport,string name){await Settled();using var image=viewport.GetTexture().GetImage();Check(image.SavePng("/work/"+name+".png")==Error.Ok,"actual rendered "+name+" retained");}
        scene.Select(scene.Pick(scene.Project(ids[0],Vector3.Zero))!);
        var pane=(EidolonPanel)app.FindChild("representations",true,false);var ops=pane.Operations;
        await Until(()=>pane.Available&&ops.Available&&pane.Selected?.Style=="configure");await Settled();
        var field=(LineEdit)ops.FormPanel.Input("run_name")!;var draft=ops.FormPanel.Draft;string revision=ops.Current!.Revision.ToString();
        var captured=pane.Occurrence!;
        Check(captured.Subject.ToString()==subject.ToString()&&captured.Id==ids[0],"same authored non-space instance form retains its exact selected occurrence");
        await Image(gui.Surface,"desktop-before-selection-layout");
        xr.PresentWorkspace(true);await Settled();
        Check(!xr.Running&&xr.BoundOccurrence==captured,"spatial composition uses production placement without starting native XR");
        var quad=(QuadMesh)xr.GuiSurface.Mesh;var pose=captured.Pose!.Value;
        var eye=pose.Origin+new Vector3(0,-.8f,1);
        var target=xr.GuiSurface.GlobalTransform*(quad.CenterOffset+new Vector3(0,-quad.Size.Y*.44f,0));
        var inverse=pose.AffineInverse();var bounds=new Aabb(new Vector3(-.25f,-.25f,-.25f),new Vector3(.5f,.5f,.5f));
        bool occluded=bounds.IntersectsSegment(inverse*eye,inverse*target);
        var camera=(Camera3D)scene.Viewport.FindChild("scene-camera",true,false);var priorCamera=camera.GlobalTransform;
        camera.GlobalPosition=eye;camera.LookAt(xr.GuiSurface.GlobalPosition);
        // Spatial composition hides the desktop container. This software-only
        // observer explicitly draws that existing mono viewport without UseXR.
        scene.Viewport.RenderTargetUpdateMode=SubViewport.UpdateMode.Always;
        await Image(scene.Viewport,"near-occlusion");
        Check(!scene.Viewport.UseXR&&scene.Viewport.GetRenderInfo(Viewport.RenderInfoType.Visible,Viewport.RenderInfo.DrawCallsInFrame)>0&&camera.GlobalPosition.IsEqualApprox(eye),"current software scene camera and actual draw observed without XR");
        await File.WriteAllTextAsync("/work/occlusion.json",JsonSerializer.Serialize(new{occluded,eye=eye.ToString(),target=target.ToString(),model=pose.ToString(),panel=xr.GuiSurface.GlobalTransform.ToString(),size=quad.Size.ToString(),offset=quad.CenterOffset.ToString(),corners=captured.Corners.Select(p=>p.ToString()).ToArray(),native_xr=xr.Running}));
        camera.GlobalTransform=priorCamera;
        if(Env("M1B_PHASE")=="visibility-occlusion"){
            Check(!occluded,"near form target is not hidden behind the selected solid along the retained software viewing ray");return;
        }
        var panelBasis=xr.GuiSurface.GlobalBasis;var planeOrigin=xr.GuiSurface.GlobalPosition;
        Check(captured.Corners.All(p=>(panelBasis.Inverse()*(p-planeOrigin)).Z<=-.149f),"actual near panel clears the selected model's full near extent in the retained selection basis");
        var layouts=new List<object>();bool hierarchy=true;
        IEnumerable<Node> Nodes(Node n){foreach(var c in n.GetChildren()){yield return c;foreach(var k in Nodes(c))yield return k;}}
        foreach(var mode in new[]{(false,1200,26),(false,1200,48),(false,560,26),(true,1200,26),(true,1200,48)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Settled();
            // Exercise the real native field focus and scroll owner, not a test-only Reveal.
            field.GrabFocus();await Settled();
            await Scroll(field);await Settled();
            var section=Nodes(pane).OfType<Label>().Single(l=>l.Text=="Measurement");
            await Scroll(section);await Settled();
            var titles=Nodes(pane).OfType<Label>().Where(l=>l.Text=="Analyzer settings"&&l.IsVisibleInTree()).ToArray();
            var title=titles.FirstOrDefault(l=>Clip(l).Encloses(l.GetGlobalRect()));
            bool enclosed=title!=null;bool persistent=title!=null&&!Ancestors(title).OfType<ScrollContainer>().Any();hierarchy&=enclosed&&persistent;
            layouts.Add(new{spatial=mode.Item1,width=mode.Item2,text=mode.Item3,field=field.GetGlobalRect().ToString(),field_clip=Clip(field).ToString(),section=section.GetGlobalRect().ToString(),titles=titles.Select(l=>new{rect=l.GetGlobalRect().ToString(),clip=Clip(l).ToString(),font=l.GetThemeFontSize("font_size"),text=l.Text}).ToArray(),enclosed,persistent});
            await Image(gui.FormSurface,"hierarchy-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3);
            Check(Clip(field).Encloses(field.GetGlobalRect()),"native scroll exposes the complete editor at "+mode);
            Check(Clip(section).Encloses(section.GetGlobalRect()),"native scroll exposes the complete authored section with its editor at "+mode);
            Check(title!=null&&title.GetThemeFontSize("font_size")>section.GetThemeFontSize("font_size")&&section.GetThemeFontSize("font_size")>field.GetThemeFontSize("font_size"),"authored title section and native field have distinct accessible scale at "+mode);
            gui.EndTextInput();
        }
        await File.WriteAllTextAsync("/work/hierarchy.json",JsonSerializer.Serialize(layouts));
        Check(hierarchy,"authored task title stays visible outside the field/task scroll at 26 48 narrow and spatial sizes");
        Check(!occluded,"near form target is not hidden behind the selected solid along the retained software viewing ray");
        Check(ReferenceEquals(field,ops.FormPanel.Input("run_name"))&&ReferenceEquals(draft,ops.FormPanel.Draft)&&revision==ops.Current!.Revision.ToString(),"layout retains the same native field draft and semantic revision");
    }
    async Task QuestionVisibilityChecks()
    {
        var human=app.ActiveAccounts.Human!;var setup=app.ActiveAccounts.Setup!.Require("account",6);
        string reference=Term.Call("form_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom("visibility_request")).ToString();
        string[] rules=["instance_of(quod:gui:form,visibility_request)","instance_of(quod:gui:text_box,answer)","instance_of(quod:gui:button,send_answer)",
            "gui_children(visibility_request,[answer,send_answer])","attribute(visibility_request,label,<<\"Measurement request\">>)",
            "attribute(visibility_request,help,<<\"Name this measurement.\">>)","attribute(answer,label,<<\"Run name\">>)","attribute(send_answer,label,<<\"Send answer\">>)",
            "gui_initial(visibility_request,answer,<<\"Original\">>)","gui_form(visibility_request,[field(answer,Answer)],submit(send_answer,assertz(visibility_answer(Answer))))",
            $"gui_question_policy(visibility_request,{setup[0]},{setup[1]})",$"gui_responder_policy(personal,{reference},{setup[0]})",
            "gui_pending_allowance(personal,4)","gui_completion_allowance(personal,300000)"];
        using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(180));
        async Task Commit(string goal)=>Check(Json.Committed(await ExecuteComplete(app.ActiveSession,app.ActiveStore,human,goal,limit.Token)),"explicit signed question layout fixture commits");
        await Commit("transaction(("+string.Join(",",rules.Select(c=>"assertz(("+c+" :- true))"))+" )).");
        await Commit("gui_open(visibility_request,Reference).");
        IEnumerable<Node> Nodes(Node n){foreach(var c in n.GetChildren()){yield return c;foreach(var k in Nodes(c))yield return k;}}
        QuestionPanel? question=null;await Until(()=>{question=Nodes(app).OfType<QuestionPanel>().SingleOrDefault();return question?.Available==true;});
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        ((Button)app.FindChild("attention",true,false)).EmitSignal(BaseButton.SignalName.Pressed);question!.Choice.EmitSignal(BaseButton.SignalName.Pressed);await Frame();await Frame();
        var field=(LineEdit)question.FormPanel.Input("answer")!;var draft=question.FormPanel.Draft;
        field.Text="Retained local answer";field.EmitSignal(LineEdit.SignalName.TextChanged,field.Text);field.Select(2,7);field.CaretColumn=7;
        Rect2 Clip(Control c){var r=c.GetViewport().GetVisibleRect();for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        foreach(var mode in new[]{(false,1200,26),(false,1200,48),(false,560,26),(true,1200,26),(true,1200,48)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Frame();
            var title=Nodes(question.FormPanel).OfType<Label>().Single(l=>l.Text=="Measurement request");
            foreach(var control in new Control[]{title,field,question.FormPanel.Input("send_answer")!,
                    (Button)question.FindChild("hide-question",true,false),(Button)question.FindChild("cancel-question",true,false)}) {
                await File.AppendAllTextAsync("/work/question-geometry.jsonl",JsonSerializer.Serialize(new {mode=mode.ToString(),control=control.Name.ToString(),rect=control.GetGlobalRect().ToString(),clip=Clip(control).ToString()})+"\n");
                Check(control.IsVisibleInTree()&&Clip(control).Encloses(control.GetGlobalRect()),"shared title styling retains question title field and actions at "+mode+" "+control.Name);
            }
            Check(!Ancestors(title).OfType<ScrollContainer>().Any(),"question root title remains outside its bounded field scroll");
            gui.Move(field.GetGlobalRect().GetCenter());gui.Press();gui.Release();await Frame();await Frame();
            Check(field.HasFocus()&&(!mode.Item1||gui.TextEntryActive),"question native editor and adjacent keyboard remain available at "+mode);
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();
            Check(image.SavePng("/work/question-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3+".png")==Error.Ok,"actual affected question raster retained");gui.EndTextInput();
        }
        Check(ReferenceEquals(field,question.FormPanel.Input("answer"))&&ReferenceEquals(draft,question.FormPanel.Draft)&&field.Text=="Retained local answer"&&question.Discovered,
            "question title layout preserves its native draft and pending identity");
        var answers=await app.ActiveSession.Read(human,"findall(X,visibility_answer(X),Answers).",limit.Token);
        Check(Json.Binding(answers,"Answers").Items.Length==0&&!app.ActiveStore.Snapshot!.Pending.Any()&&!xr.Running,"layout never submits or cancels the question and never starts native XR");
        xr.PresentWorkspace(false);
    }
    static IEnumerable<Node> Ancestors(Node node){for(Node? n=node.GetParent();n!=null;n=n.GetParent())yield return n;}
}
