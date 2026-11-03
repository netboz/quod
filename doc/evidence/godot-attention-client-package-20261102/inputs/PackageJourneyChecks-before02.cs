using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Reflection;
using File=System.IO.File;
using Json=Quod.Client.Json;

// Removable package companion; ordinary native Controls and signed owners only.
public partial class ExportChecks
{
    IEnumerable<Node> PackageNodes(Node n) { foreach(var c in n.GetChildren()){yield return c;foreach(var d in PackageNodes(c))yield return d;} }
    async Task PackageJourney(bool reopen)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        GetTree().Root.Size=new(1200,800);await Frame();await Frame();
        Rect2 Clip(Control c){var r=c.GetViewport().GetVisibleRect();for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        int settlement=0;
        async Task Settled(){int n=++settlement;Console.WriteLine($"PACKAGE_WAIT {n} frame-one");await Frame();Console.WriteLine($"PACKAGE_WAIT {n} frame-two");await Frame();Console.WriteLine($"PACKAGE_WAIT {n} post-draw");await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);Console.WriteLine($"PACKAGE_WAIT {n} settled");}
        async Task Raster(string name){await Settled();using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/"+name+".png")==Error.Ok,"current ordinary composition raster retained: "+name);}
        void Point(Control c){var point=c.GetGlobalRect().GetCenter();if(c.GetViewport()==gui.FormSurface){if(gui.Spatial){gui.Move(point,gui.FormSurface);return;}point=gui.FormMirror.GlobalPosition+point/(Vector2)gui.FormSize*gui.FormMirror.Size;}gui.Move(point);}
        async Task Click(Control c){await Settled();Check(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect()),"current native target visible and enclosed: "+c.Name);int hits=0;void Hit()=>hits++;if(c is Button b){Check(!b.Disabled,"native action enabled: "+b.Name);b.Pressed+=Hit;}try{Point(c);await Frame();gui.Press();await Frame();gui.Release();await Frame();}finally{if(c is Button b2)b2.Pressed-=Hit;}Check(gui.Captures==0&&(c is not Button||hits==1),"one complete native gesture with no duplicate callback");}
        async Task Scroll(Control c){var owners=new List<ScrollContainer>();for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is ScrollContainer s)owners.Add(s);foreach(var owner in owners.AsEnumerable().Reverse())for(int i=0;i<24&&!owner.GetGlobalRect().Encloses(c.GetGlobalRect());i++){var clip=owner.GetGlobalRect();var rect=c.GetGlobalRect();var direction=rect.Position.Y<clip.Position.Y?MouseButton.WheelUp:MouseButton.WheelDown;var bar=owner.GetVScrollBar();if(!bar.IsVisibleInTree())break;float distance=direction==MouseButton.WheelUp?clip.Position.Y-rect.Position.Y:rect.End.Y-clip.End.Y;var wheel=new InputEventMouseButton{Position=bar.GetGlobalRect().GetCenter(),ButtonIndex=direction,Factor=Math.Min(1,distance/(float)(bar.Page/8)),Pressed=true};bar.GetViewport().PushInput(wheel,true);wheel.Pressed=false;bar.GetViewport().PushInput(wheel,true);await Frame();}Check(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect()),"bounded native scrolling reaches the chosen form control");}
        if(!reopen)await Press("create-key");else Check(State["public_key"]!=null,"new process loads the original active key");
        await Press("connect");Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"ordinary signed Connect uses the fresh fixture trust");
        if(!reopen){await Press("register");await Press("prepare");await Press("setup");}
        Console.WriteLine("PACKAGE_WAIT account-world");await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&!Busy);Console.WriteLine("PACKAGE_WAIT world-accepted");await Settled();
        Check(scene.IsVisibleInTree()&&Clip(scene).Encloses(scene.GetGlobalRect())&&scene.Size.Y>=300,"ordinary current interior is reachable before any helper selection or scroll");
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;var store=app.ActiveStore;
        var subject=(human with {InstanceText="analyzer."}).Entity;
        var identity=new JsonObject{["key"]=State["public_key"]!.DeepClone(),["human"]=State["human"]!.DeepClone(),["setup"]=State["setup"]!.DeepClone()};
        string location=State["current_location"]!.ToString();string contextPath="/work/occurrence-context.json";
        var saved=reopen?JsonNode.Parse(await File.ReadAllTextAsync(contextPath)):null;
        async Task<string[]> Instructions()=>Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Select(t=>t.Args[0].ToString()).Order().ToArray();
        if(!reopen){
            Check(scene.Count==0,"fresh ordinary space has no manufactured contents");
            var s0=Actor.FromTerm(app.ActiveAccounts.Setup!.Require("account",6)[2]);
        string ns=Term.Text(human.Namespace).ToString(),anchor=Term.Binary(Identity.Decode(human.Anchor)).ToString();
        string parts="[part(<<\"left\">>,box(500,500,500),transform(-700,0,0,15,25,0),surface(<<\"#6A90D9\">>,0,700,0,[]),label(<<\"Analyzer left\">>,<<\"above\">>),depicts_nothing),part(<<\"right\">>,box(500,500,500),transform(700,0,0,15,25,0),surface(<<\"#60C880\">>,0,700,0,[]),label(<<\"Analyzer right\">>,<<\"above\">>),depicts_nothing)]";
        var account=app.ActiveAccounts.Setup!.Require("account",6);
        string request=Term.Call("form_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom("package_request")).ToString();
        string[] clauses=[
            "instance_of(quod:gui:form,package_request)","instance_of(quod:gui:text_box,answer)","instance_of(quod:gui:button,send_answer)",
            "gui_children(package_request,[answer,send_answer])","attribute(package_request,label,<<\"Measurement request\">>)",
            "attribute(package_request,help,<<\"Name this measurement.\">>)","attribute(answer,label,<<\"Run name\">>)","attribute(send_answer,label,<<\"Send answer\">>)",
            "gui_initial(package_request,answer,<<\"Original\">>)","gui_form(package_request,[field(answer,Answer)],submit(send_answer,assertz(package_answer(Answer))))",
            $"gui_question_policy(package_request,{account[0]},{account[1]})",$"gui_responder_policy(personal,{request},{account[0]})",
            "gui_pending_allowance(personal,4)","gui_completion_allowance(personal,300000)",
            "isa(occurrence_instrument,thing)","instance_of(occurrence_instrument,analyzer)",
            "class_permission(occurrence_instrument,configure,allow)",
            $"class_eidolon(occurrence_instrument,operation(instance),configure,recipe({ns},{anchor},instrument_form))",
            $"eidolon(instrument_form,subject(ontology_ref({ns},{anchor}),instance(analyzer)),operation(instrument_settings))",
            $"entity_scene(analyzer,playing,appearance(analyzer,solid,analyzer,transform(0,0,0,0,0,0),[eidolon(playing,solid,recipe({ns},{anchor},instrument_solid))]))",
            $"eidolon(instrument_solid,analyzer,{parts})",
            $"space_contains({Term.Parse(s0.InstanceText.TrimEnd('.'))},{subject})",
            "instance_of(quod:gui:form,instrument_settings)","instance_of(quod:gui:text_box,run_name)","instance_of(quod:gui:button,apply_configuration)",
            "gui_children(instrument_settings,[run_name,apply_configuration])",
            "attribute(instrument_settings,label,<<\"Analyzer settings\">>)","attribute(instrument_settings,help,<<\"Edit the run name locally. Apply configuration saves it.\">>)",
            "attribute(run_name,label,<<\"Run name\">>)","attribute(apply_configuration,label,<<\"Apply configuration\">>)",
            "gui_form(instrument_settings,[field(run_name,Name)],submit(apply_configuration,assertz(instrument_configuration(Name)),operation(configure,[])))",
            "gui_initial(instrument_settings,run_name,<<\"Sweep A\">>)"
        ];
        var result=await ExecuteComplete(session,app.ActiveStore,human,"transaction(("+string.Join(",",clauses.Select(c=>"assertz(("+c+" :- true))"))+" )).",CancellationToken.None);
        Check(Json.Committed(result),"authorized same-ontology fixture offers a non-space instance form and two visual occurrences");
        await Until(()=>State["question_receiver_ready"]?.GetValue<bool>()==true);
        for(int i=0;i<2;i++)Check(Json.Committed(await ExecuteComplete(session,store,human,"gui_open(package_request,Reference).",CancellationToken.None)),"existing signed owner creates one independent pending request");

        }else{
            Check(identity.ToJsonString()==saved!["identity"]!.ToJsonString()&&location==saved["location"]!.ToString(),"new-process same-profile reopen preserves original U A S0 key and location");
            Check((await Instructions()).SequenceEqual(saved["instructions"]!.AsArray().Select(n=>n!.ToString())),"reconnect performs no new personal instruction or uncertain replay");
            var original=JsonNode.Parse(saved["outcome"]!.ToString())!;
            var recovered=app.ActiveAccounts.Outcomes.Where(o=>Json.S(o,"operation_id")==Json.S(original,"operation_id")&&Json.S(o,"request_digest")==Json.S(original,"request_digest")).ToArray();
            Check(recovered.Length==1&&Json.Committed(recovered[0])&&JsonNode.DeepEquals(recovered[0]["bindings"],original["bindings"]),"reopened account certifies the exact original operation and request with the same committed bindings");
            await File.WriteAllTextAsync("/work/recovered-outcome.json",JsonSerializer.Serialize(new{exact_operation=true,exact_request=true,committed=true,same_bindings=true,matching_outcomes=recovered.Length,initial_result=original["result"]!.ToString(),recovered_result=recovered[0]["result"]!.ToString(),recovered_status=recovered[0]["status"]?.ToString()}));
        }
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&scene.SubjectIds(subject).Length==2);await Settled();
        string[] ids=scene.SubjectIds(subject).Order().ToArray();var before=await Instructions();
        async Task Pick(string id){await Settled();var p=scene.GlobalPosition+scene.Project(id,Vector3.Zero)*scene.Size/(Vector2)scene.Viewport.Size;Check(scene.IsVisibleInTree()&&Clip(scene).HasPoint(p)&&scene.Pick(scene.Project(id,Vector3.Zero))?.Id==id,"exact visible occurrence is reachable before native picking");int n=0;ScenePanel.Selection? selected=null;void Select(ScenePanel.Selection s){n++;selected=s;}scene.Selected+=Select;try{gui.Move(p);await Frame();gui.Press();await Frame();gui.Release();await Frame();}finally{scene.Selected-=Select;}Check(n==1&&selected?.Id==id&&selected.Subject.ToString()==subject.ToString(),"one native pick selects the exact occurrence and semantic subject without travel");}
        await Pick(ids[0]);var pane=(EidolonPanel)app.FindChild("representations",true,false);var ops=pane.Operations;
        await Until(()=>pane.Available&&ops.Available&&pane.Selected?.Style=="configure");
        Check(pane.NearOccurrence&&pane.Occurrence?.Id==ids[0]&&xr.BoundOccurrence==pane.Occurrence&&ops.Current!.Subject.ToString()==subject.ToString(),"offered ontology action form binds to the selected visual and exact subject");
        var form=ops.FormPanel;var field=(LineEdit)form.Input("run_name")!;var submit=(Button)form.Input("apply_configuration")!;
        var personal=(Button)pane.FindChild("form-personal-workspace",true,false);var near=(Button)pane.FindChild("form-near-object",true,false);
        var draft=form.Draft;string revision=ops.Current!.Revision.ToString();var binding=pane.Occurrence;
        await Click(field);Check(field.HasFocus(),"actual native pointer focuses the existing editor");field.SelectAll();
        string text=reopen?"Unsubmitted reopen draft":"Package sweep";
        foreach(char c in text){field.GetViewport().PushInput(new InputEventKey{Unicode=c,Pressed=true},true);field.GetViewport().PushInput(new InputEventKey{Unicode=c,Pressed=false},true);}await Frame();
        field.Select(2,7);field.CaretColumn=7;int writes=0,rebuilt=scene.Rebuilt,sockets=SignedView.LiveSockets;store.DurabilityBoundary=_=>writes++;
        using var watcher=new System.Net.Sockets.TcpClient();await watcher.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")));
        using var watchStream=watcher.GetStream();using var watchReader=new System.IO.StreamReader(watchStream);
        await watchStream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"));Check(JsonNode.Parse((await watchReader.ReadLineAsync())!)!["ready"]!.GetValue<bool>(),"named work watcher installed for local placement");
        await Click(personal);Check(!pane.NearOccurrence&&xr.BoundOccurrence==null,"explicit personal placement releases only the occurrence binding");
        await Click(near);store.DurabilityBoundary=null;
        await watchStream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"));var work=JsonNode.Parse((await watchReader.ReadLineAsync())!)!;
        await File.WriteAllTextAsync("/work/"+(reopen?"reopen":"initial")+"-unchanged-work.json",work.ToJsonString());Check(work["work"]!["calls"]!.AsArray().Count==0,"local near personal transitions perform zero named history rebuild write or sync work");
        Check(pane.NearOccurrence&&pane.Occurrence==binding&&xr.BoundOccurrence==binding&&ReferenceEquals(field,form.Input("run_name"))&&ReferenceEquals(draft,form.Draft)&&field.Text==text&&field.HasSelection()&&field.CaretColumn==7&&ops.Current.Revision.ToString()==revision,"near and personal preserve the same native editor draft caret selection and semantic revision");
        Check(writes==0&&rebuilt==scene.Rebuilt&&sockets==SignedView.LiveSockets,"local relocation writes no profile and recreates no scene or signed consumer");
        await Pick(ids[1]);await Until(()=>pane.Available&&ops.Available&&pane.Occurrence?.Id==ids[1]);
        Check(ReferenceEquals(field,form.Input("run_name"))&&field.Text==text&&State["current_location"]!.ToString()==location,"second same-subject visual keeps the same form and does not move the agent");
        await Raster(reopen?"reopened-associated-form":"associated-form");
        xr.PresentWorkspace(true);await Settled();
        Check(!xr.Running&&xr.GuiSurface.Visible&&xr.BoundOccurrence==pane.Occurrence&&xr.GuiSurface.GlobalPosition.Y>pane.Occurrence!.Corners.Max(p=>p.Y),"same form surface sits above the chosen occurrence with native XR disabled");
        using(var image=scene.Viewport.GetTexture().GetImage())Check(image.SavePng("/work/"+(reopen?"reopened-spatial":"spatial")+".png")==Error.Ok,"actual software spatial occurrence raster retained");
        xr.PresentWorkspace(false);await Settled();
        Check((await Instructions()).SequenceEqual(before)&&!store.Snapshot!.Pending.Any(),"selection text editing and placement issue no domain action or replay");
        string outcome="";
        if(!reopen){
            await Scroll(submit);await Click(submit);await Until(()=>!ops.IsWorking&&ops.LastOutcome!=null);
            Check(Json.Committed(ops.LastOutcome!),"one explicit offered native submission returns its original committed result");outcome=ops.LastOutcome!.ToJsonString();
            await Click(personal);
            await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&pane.Available&&ops.Available&&pane.Occurrence?.Pose!=null);
            await Click(near);
            Check(ops.LastOutcome!.ToJsonString()==outcome&&ReferenceEquals(field,form.Input("run_name")),"postcommit relocation retains the original outcome and editor");
            Check((await Instructions()).Length==before.Length+1,"explicit Apply adds exactly one personal instruction");
            await File.WriteAllTextAsync(contextPath,new JsonObject{["identity"]=identity,["location"]=location,["instructions"]=JsonSerializer.SerializeToNode(await Instructions()),["outcome"]=outcome,["subject"]=subject.ToString()}.ToJsonString());
        }else Check(subject.ToString()==saved!["subject"]!.ToString(),"new process reopens the same anchored instance without reauthoring its fixture");
        var configurations=Json.Binding(await session.Read(human,"findall(X,instrument_configuration(X),Configurations).",CancellationToken.None),"Configurations");
        Check(configurations.ToString()=="[<<\"Package sweep\">>]","committed original configuration reads back exactly once; reopen draft remains unsubmitted");
        QuestionPanel[] Panels()=>PackageNodes(app).OfType<QuestionPanel>().Where(p=>!p.IsQueuedForDeletion()).ToArray();
        await Until(()=>Panels().Count(p=>p.Discovered)==(reopen?1:2)&&Panels().Where(p=>p.Discovered).All(p=>p.Available));
        var pending=Panels().Where(p=>p.Discovered).ToArray();var first=pending[0];
        string Ref(QuestionPanel q)=>typeof(QuestionPanel).GetField("question",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(q)!.ToString()!;
        Check(pending.All(p=>!p.FormPanel.IsVisibleInTree()),"independent question arrival stays compact without replacing the occurrence form");
        var attention=(Button)app.FindChild("attention",true,false);await Click(attention);await Click(first.Choice);
        Check(first.IsVisibleInTree()&&Panels().Count(p=>p.FormPanel.IsVisibleInTree())==1&&attention.Text.EndsWith(reopen?"1":"2"),"attention count and one user-selected exact request share the existing native owner");
        if(reopen)Check(Ref(first)==saved!["question"]!.ToString(),"same-profile reopen retains the original pending question identity without recreation");
        var questionField=(LineEdit)first.FormPanel.Input("answer")!;var questionDraft=first.FormPanel.Draft;
        await Click(questionField);Check(questionField.HasFocus(),"attention native editor receives ordinary software pointer focus");questionField.SelectAll();
        string questionText="Local question draft";foreach(char c in questionText){questionField.GetViewport().PushInput(new InputEventKey{Unicode=c,Pressed=true},true);questionField.GetViewport().PushInput(new InputEventKey{Unicode=c,Pressed=false},true);}
        questionField.Select(2,7);questionField.CaretColumn=7;
        await Raster(reopen?"reopened-attention":"attention");
        await Click((Button)first.FindChild("hide-question",true,false));
        Check(first.Discovered&&!first.FormPanel.IsVisibleInTree(),"Later hides the local task and leaves its exact domain question pending");
        await Click(first.Choice);
        Check(ReferenceEquals(questionField,first.FormPanel.Input("answer"))&&ReferenceEquals(questionDraft,first.FormPanel.Draft)&&questionField.Text==questionText&&questionField.HasSelection()&&questionField.CaretColumn==7,"Later and recall retain the same native draft caret and selection");
        await Click((Button)first.FindChild("hide-question",true,false));
        if(!reopen){
            var other=pending[1];await Click(other.Choice);await Until(()=>other.Available);await Click((Button)other.FindChild("cancel-question",true,false));
            await Until(()=>!other.Discovered&&!app.ActiveAccounts.Uncertain);
            Check(first.Discovered&&Panels().Count(p=>p.Discovered)==1&&other.LastOutcome!=null&&Json.Committed(other.LastOutcome),"explicit Cancel commits only the second exact request; Later did not cancel the first");
            await Click((Button)other.FindChild("hide-question",true,false));
        }
        await Click((Button)app.FindChild("hide-attention",true,false));
        await Until(()=>pane.Available&&ops.Available&&pane.Occurrence?.Pose!=null);await Settled();
        Check(ReferenceEquals(field,form.Input("run_name"))&&field.Text==text&&ReferenceEquals(draft,form.Draft)&&pane.NearOccurrence,"return from attention recalls the same occurrence form and local draft");
        if(!reopen){
            Check(ops.LastOutcome!.ToJsonString()==outcome,"attention selection Later and independent Cancel retain the received original occurrence outcome");
            var context=JsonNode.Parse(await File.ReadAllTextAsync(contextPath))!;context["question"]=Ref(first);context["instructions"]=JsonSerializer.SerializeToNode(await Instructions());await File.WriteAllTextAsync(contextPath,context.ToJsonString());
        }else Check((await Instructions()).SequenceEqual(saved!["instructions"]!.AsArray().Select(n=>n!.ToString())),"reopened local question editing and Later issue no instruction or replay");
        Check(Json.Binding(await session.Read(human,"findall(X,package_answer(X),Answers).",CancellationToken.None),"Answers").Items.Length==0&&!store.Snapshot!.Pending.Any(),"unsubmitted local question draft is not a domain answer and no uncertain work was replayed");
        await Raster(reopen?"reopened-returned-form":"returned-form");
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0&&!xr.Running,"ordinary disconnect retires signed consumers and input resources with XR off");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,reopen,checks}));
        Console.WriteLine("M5_PACKAGE_JOURNEY_PASS "+(reopen?"reopen":"initial"));Console.Out.Flush();await app.CloseApplication();
    }
}
