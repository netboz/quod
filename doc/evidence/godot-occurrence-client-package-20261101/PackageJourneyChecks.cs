using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

// Removable package companion; ordinary native Controls and signed owners only.
public partial class ExportChecks
{
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
        string[] clauses=[
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
        await Click(personal);Check(!pane.NearOccurrence&&xr.BoundOccurrence==null,"explicit personal placement releases only the occurrence binding");
        await Click(near);store.DurabilityBoundary=null;
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
        string outcome;
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
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0&&!xr.Running,"ordinary disconnect retires signed consumers and input resources with XR off");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,reopen,checks}));
        Console.WriteLine("M5_PACKAGE_JOURNEY_PASS "+(reopen?"reopen":"initial"));Console.Out.Flush();await app.CloseApplication();
    }
}
