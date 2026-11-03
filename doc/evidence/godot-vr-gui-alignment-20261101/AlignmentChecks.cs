using Godot;
using Quod.Client;
using System.Text.Json;
using Json=Quod.Client.Json;
using System.Reflection;
using System.Text.Json.Nodes;
using File=System.IO.File;

// Removable tests of the installed shared renderer and signed question owners.
public partial class ExportChecks
{
    IEnumerable<Node> AlignmentNodes(Node n)
    { foreach(var c in n.GetChildren()){yield return c;foreach(var d in AlignmentNodes(c))yield return d;} }
    async Task AlignmentRaster(string path,SubViewport viewport)
    { await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=viewport.GetTexture().GetImage();Check(image.SavePng("/work/"+path+".png")==Error.Ok,"retained actual "+path+" raster"); }
    async Task Alignment()
    {
        if(Env("M1B_PHASE").StartsWith("alignment-material"))await AlignmentMaterial();else await AlignmentAttention();
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks}));
        Console.WriteLine("ALIGNMENT_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task AlignmentMaterial()
    {
        var scene=new ScenePanel {Position=new(0,0),Size=new(1200,740)};app.AddChild(scene);
        var descriptor=Term.Parse("[mark(<<\"solid\">>,<<\"box\">>,[f(<<\"width\">>,1000),f(<<\"height\">>,1000),f(<<\"depth\">>,1000)],transform(0,0,0,20,35,0),surface(<<\"#6A90D9\">>,0,700,0,[]),label(<<\"Solid shape\">>,<<\"above\">>),depicts_nothing)]");
        scene.Apply(descriptor);await Frame();await Frame();await AlignmentRaster("solid-oblique",scene.Viewport);
        using var image=scene.Viewport.GetTexture().GetImage();
        var points=new[]{new Vector3(-.5f,0,0),new Vector3(0,.5f,0),new Vector3(0,0,.5f)};
        var samples=points.Select(p=>{var at=(Vector2I)scene.Project("solid",p);return image.GetPixel(at.X,at.Y);}).ToArray();
        float L(Color c)=>(c.R+c.G+c.B)/3;
        await File.WriteAllTextAsync("/work/material.json",JsonSerializer.Serialize(new {samples=samples.Select(c=>c.ToHtml()).ToArray(),faceDifference=samples.Max(L)-samples.Min(L)}));
        Check(samples.Max(L)-samples.Min(L)>10f/255,"oblique solid faces have measurable directional shading rather than identical unshaded colour");
        if(Env("M1B_PHASE")=="alignment-material-full") {
            MeshInstance3D Mesh()=>AlignmentNodes(scene.SceneRoot).OfType<MeshInstance3D>().Single();
            var mesh=Mesh();var material=(StandardMaterial3D)mesh.MaterialOverride;int rebuilt=scene.Rebuilt;
            for(int i=0;i<3;i++)scene.Apply(descriptor);
            Check(scene.Rebuilt==rebuilt&&ReferenceEquals(mesh,Mesh())&&ReferenceEquals(material,Mesh().MaterialOverride),"three unchanged scene renewals retain mesh and material resources");
            var green=Term.Parse(descriptor.ToString().Replace("#6A90D9","#60C880"));scene.Apply(green);await Frame();await Frame();await AlignmentRaster("green-oblique",scene.Viewport);
            Check(scene.Rebuilt==rebuilt+1&&((StandardMaterial3D)Mesh().MaterialOverride).AlbedoColor.IsEqualApprox(new Color("#60C880")),"a real authored colour update changes only its existing occurrence");
            string materialTerm=green.ToString().Replace(",0,700,0,[])",",650,250,800,[])");var authored=Term.Parse(materialTerm);scene.Apply(authored);await Frame();await Frame();
            var decoded=SceneMark.Decode(authored).Single();material=(StandardMaterial3D)Mesh().MaterialOverride;
            Check(decoded.Metallic==650&&decoded.Roughness==250&&decoded.Emission==800&&Mathf.IsEqualApprox(material.Metallic,.65f)&&Mathf.IsEqualApprox(material.Roughness,.25f)&&material.EmissionEnabled&&Mathf.IsEqualApprox(material.EmissionEnergyMultiplier,.8f)&&material.AlbedoColor.A==1,"existing metallic roughness emission permille reach native material and never become alpha");
            await AlignmentRaster("emissive-solid",scene.Viewport);
            var wire=Term.Parse(descriptor.ToString().Replace("box","wire_box"));scene.Apply(wire);await Frame();await Frame();await AlignmentRaster("wire-label",scene.Viewport);
            var surface=RenderingServer.MeshGetSurface(Mesh().Mesh.GetRid(),0);material=(StandardMaterial3D)Mesh().MaterialOverride;
            Check(surface["primitive"].AsInt32()==(int)RenderingServer.PrimitiveType.Lines&&surface["vertex_count"].AsInt32()==24&&material.ShadingMode==BaseMaterial3D.ShadingModeEnum.Unshaded,"wire box remains twelve unshaded edges with no solid faces");
            Check(AlignmentNodes(scene.SceneRoot).OfType<Label3D>().Single() is {Shaded:false,Modulate.A:1},"authored billboard label stays opaque and unshaded");
            var sphere=Term.Parse("[mark(<<\"sphere\">>,<<\"sphere\">>,[f(<<\"diameter\">>,1000)],transform(0,0,0,0,0,0),surface(<<\"#D89060\">>,0,700,0,[]),unlabelled,depicts_nothing)]");
            scene.Apply(sphere);await Frame();await Frame();await AlignmentRaster("solid-sphere",scene.Viewport);
            Check(((StandardMaterial3D)Mesh().MaterialOverride).ShadingMode==BaseMaterial3D.ShadingModeEnum.PerPixel,"ordinary sphere shares the same lit solid adapter");
            foreach(string bad in new[]{descriptor.ToString().Replace(",0,700,0,[])",",1001,700,0,[])"),descriptor.ToString().Replace(",0,700,0,[])",",0,700,-1,[])")}) {
                bool refused=false;try{scene.Apply(Term.Parse(bad));}catch(FormatException){refused=true;}
                Check(refused&&scene.Ids.SequenceEqual(new[]{"sphere"}),"invalid material is refused before replacing accepted geometry");
            }
            scene.Withdraw();Check(scene.Count==0&&scene.PickRay(new(0,0,5),Vector3.Forward)==null,"retirement withdraws geometry and picking together");
        }
        scene.QueueFree();
    }
    async Task AlignmentAttention()
    {
        GetTree().Root.Size=new(1200,800);await Frame();await Frame();
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["question_receiver_ready"]?.GetValue<bool>()==true&&!Busy);
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;var setup=app.ActiveAccounts.Setup!.Require("account",6);
        using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(180));
        string form=Term.Call("form_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom("alignment_request")).ToString();
        string[] rules=["instance_of(quod:gui:form,alignment_request)","instance_of(quod:gui:text_box,answer)","instance_of(quod:gui:button,send_answer)",
            "gui_children(alignment_request,[answer,send_answer])","attribute(alignment_request,label,<<\"Measurement request\">>)",
            "attribute(alignment_request,help,<<\"Name this measurement.\">>)","attribute(answer,label,<<\"Run name\">>)","attribute(send_answer,label,<<\"Send answer\">>)",
            "gui_initial(alignment_request,answer,<<\"Original\">>)","gui_form(alignment_request,[field(answer,Answer)],submit(send_answer,assertz(alignment_answer(Answer))))",
            $"gui_question_policy(alignment_request,{setup[0]},{setup[1]})",$"gui_responder_policy(personal,{form},{setup[0]})",
            "gui_pending_allowance(personal,4)","gui_completion_allowance(personal,300000)"];
        async Task Commit(string goal)=>Check(Json.Committed(await ExecuteComplete(session,app.ActiveStore,human,goal,limit.Token)),"explicit signed question fixture transaction commits");
        await Commit("transaction(("+string.Join(",",rules.Select(c=>"assertz(("+c+" :- true))"))+" )).");
        await Commit("gui_open(alignment_request,Reference).");await Commit("gui_open(alignment_request,Reference).");
        QuestionPanel[] panels=[];
        await Until(()=>{panels=AlignmentNodes(app).OfType<QuestionPanel>().ToArray();return panels.Length==2&&panels.All(p=>p.Available);});
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);await Frame();await Frame();
        await AlignmentRaster("attention-arrival",gui.Surface);
        int visible=panels.Count(p=>p.FormPanel.IsVisibleInTree());
        await File.WriteAllTextAsync("/work/attention-arrival.json",JsonSerializer.Serialize(new {questions=panels.Length,visibleForms=visible,focus=gui.Surface.GuiGetFocusOwner()?.Name.ToString(),state=State}));
        Check(visible==0,"new signed questions update attention without opening any working form before human selection");
        if(Env("M1B_PHASE")=="alignment-attention-full")await AlignmentWorking(panels,Commit,limit.Token);
    }
    async Task AlignmentWorking(QuestionPanel[] initial,Func<string,Task> commit,CancellationToken cancellation)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        QuestionPanel[] Panels()=>AlignmentNodes(app).OfType<QuestionPanel>().Where(p=>!p.IsQueuedForDeletion()).ToArray();
        Rect2 Clip(Control c){var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        async Task Click(Control c) {
            await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            Check(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect()),"native target is visibly enclosed without diagnostic reveal: "+c.Name);
            gui.Move(c.GetGlobalRect().GetCenter());await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();
        }
        var attention=(Button)app.FindChild("attention",true,false);await Click(attention);
        Check(Panels().All(p=>!p.FormPanel.IsVisibleInTree())&&attention.Text.Contains("2"),"compact attention exposes the two exact independent occurrences without opening either");
        var first=initial[0];var other=initial[1];await Click(first.Choice);
        var form=first.FormPanel;var field=(LineEdit)form.Input("answer")!;var submit=(Button)form.Input("send_answer")!;var draft=form.Draft;
        var current=typeof(QuestionPanel).GetField("current",BindingFlags.Instance|BindingFlags.NonPublic)!;var original=(QuestionDescriptor)current.GetValue(first)!;
        Check(first.IsVisibleInTree()&&!other.IsVisibleInTree()&&original.Source.Require("form_ref",3)[2].ToString()=="alignment_request","one selected exact question is the primary working form");
        await Click(field);Check(field.HasFocus(),"native field receives actual surface focus");field.SelectAll();
        foreach(char c in "Retained local answer"){gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=true},true);gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=false},true);}
        field.Select(2,7);field.CaretColumn=7;await commit("gui_open(alignment_request,Reference).");
        await Until(()=>Panels().Length==3&&Panels().All(p=>p.Available));var third=Panels().Single(p=>!initial.Contains(p));
        Check(first.IsVisibleInTree()&&!other.IsVisibleInTree()&&!third.IsVisibleInTree()&&(gui.Surface.GuiGetFocusOwner()==null||gui.Surface.GuiGetFocusOwner()==field),"arrival leaves the chosen task in place and never transfers focus to another request");
        Check(field.Text=="Retained local answer"&&field.HasSelection()&&field.CaretColumn==7&&ReferenceEquals(draft,form.Draft)&&other.FormPanel.Draft["answer"]=="Original","same-form occurrences retain independent native drafts selection and caret");
        int writes=0;app.ActiveStore.DurabilityBoundary=_=>writes++;int sockets=SignedView.LiveSockets;
        using(var socket=new System.Net.Sockets.TcpClient()) {
            await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),cancellation);using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),cancellation);Check(JsonNode.Parse((await reader.ReadLineAsync(cancellation))!)!["ready"]!.GetValue<bool>(),"real named work watcher installed");
            for(int i=0;i<3;i++){await Click((Button)first.FindChild("hide-question",true,false));await Click(first.Choice);await Renew(first);await Until(()=>first.Available);}
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),cancellation);var work=JsonNode.Parse((await reader.ReadLineAsync(cancellation))!)!;await File.WriteAllTextAsync("/work/unchanged-work.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0&&writes==0&&SignedView.LiveSockets==sockets&&ReferenceEquals(field,form.Input("answer"))&&ReferenceEquals(draft,form.Draft),"three hide recalls and accepted renewals retain controls subscriptions and zero named history rebuild write sync work");
        }
        app.ActiveStore.DurabilityBoundary=null;
        foreach(var mode in new[]{(false,1200,26),(false,1200,48),(false,560,26),(true,1200,26),(true,1200,48)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Frame();
            await AlignmentRaster("working-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3,gui.Surface);
            foreach(var control in new Control[]{field,submit,(Button)first.FindChild("hide-question",true,false),(Button)first.FindChild("cancel-question",true,false)})Check(control.IsVisibleInTree()&&Clip(control).Encloses(control.GetGlobalRect()),"primary question field action dismissal and cancellation enclosed at "+mode);
            await Click(field);Check(field.HasFocus()&&(!mode.Item1||gui.TextEntryActive),"selected native field supports existing adjacent keyboard at "+mode);
            Check(ReferenceEquals(field,form.Input("answer"))&&field.Text=="Retained local answer"&&!xr.Running,"layout and spatial composition retain local text without native XR");
        }
        xr.PresentWorkspace(false);GetTree().Root.Size=new(1200,800);gui.TextSize(26-gui.Appearance.DefaultFontSize);await Frame();await Frame();
        var before=await app.ActiveSession.Read(app.ActiveAccounts.Human!,"findall(X,alignment_answer(X),Answers).",cancellation);
        Check(Json.Binding(before,"Answers").Items.Length==0&&!app.ActiveStore.Snapshot!.Pending.Any(),"attention selection hide resize and refresh never answer a question or submit domain work");
        await Click(submit);await Until(()=>!Panels().Contains(first));await app.ActiveAccounts.Resolve(cancellation);
        var after=await app.ActiveSession.Read(app.ActiveAccounts.Human!,"findall(X,alignment_answer(X),Answers).",cancellation);
        Check(Json.Binding(after,"Answers").ToString()=="[<<\"Retained local answer\">>]","explicit native Submit executes the original continuation exactly once with retained text");
        await Click(other.Choice);await Click((Button)other.FindChild("cancel-question",true,false));await Until(()=>!Panels().Contains(other));await app.ActiveAccounts.Resolve(cancellation);
        Check(Panels().Single()==third,"explicit Cancel retires only its exact question; Later did not cancel");
        await Click((Button)app.FindChild("hide-attention",true,false));await Click((Button)app.FindChild("location-operations",true,false));
        var pane=(EidolonPanel)app.FindChild("representations",true,false);await Until(()=>pane.Available);
        string subject=pane.Current!.Exact.ToString();await Click(attention);await Click(third.Choice);await Click((Button)third.FindChild("hide-question",true,false));await Click((Button)app.FindChild("hide-attention",true,false));
        Check(pane.Current!.Exact.ToString()==subject&&pane.IsVisibleInTree()&&!app.ActiveStore.Snapshot!.Pending.Any(),"attention returns to the same signed subject inspector without travel or replay");
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0&&gui.Captures==0,"all question views and native capture retire through the existing disconnect owner");
    }
}
