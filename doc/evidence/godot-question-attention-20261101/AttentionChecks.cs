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
    async Task AttentionChecks()
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
        if(Env("M1B_PHASE")=="attention-refused")rules=rules.Select(r=>r.Replace("submit(send_answer,assertz(alignment_answer(Answer)))","submit(send_answer,fail)")).ToArray();
        await Commit("transaction(("+string.Join(",",rules.Select(c=>"assertz(("+c+" :- true))"))+" )).");
        if(Env("M1B_PHASE")=="attention-stale")await Commit("assertz((attribute(answer,required,true) :- true)).");
        await Commit("gui_open(alignment_request,Reference).");await Commit("gui_open(alignment_request,Reference).");
        QuestionPanel[] panels=[];
        await Until(()=>{panels=AlignmentNodes(app).OfType<QuestionPanel>().ToArray();return panels.Length==2&&panels.All(p=>p.Available);});
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);await Frame();await Frame();
        await AlignmentRaster("attention-arrival",gui.Surface);
        int visible=panels.Count(p=>p.FormPanel.IsVisibleInTree());
        await File.WriteAllTextAsync("/work/attention-arrival.json",JsonSerializer.Serialize(new {questions=panels.Length,visibleForms=visible,focus=gui.Surface.GuiGetFocusOwner()?.Name.ToString(),rectangles=panels.Select(p=>new {rect=p.GetGlobalRect().ToString(),visible=p.IsVisibleInTree()}).ToArray(),state=State}));
        Check(visible==0,"new signed questions update attention without opening any working form before human selection");
        if(Env("M1B_PHASE")=="attention-composition")await AttentionComposition(panels,limit.Token);
        if(Env("M1B_PHASE")=="attention-refused")await AttentionRefused(panels,limit.Token);
        if(Env("M1B_PHASE")=="attention-stale")await AttentionStale(panels,Commit,limit.Token);
        if(Env("M1B_PHASE")=="attention-unknown")await AttentionUnknown(panels,limit.Token);
        if(Env("M1B_PHASE")=="attention-state")await AttentionState(panels,Commit,limit.Token);
        if(Env("M1B_PHASE")=="attention-full")await AttentionWorking(panels,Commit,limit.Token);
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks}));
        Console.WriteLine("ATTENTION_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task AttentionWorking(QuestionPanel[] initial,Func<string,Task> commit,CancellationToken cancellation)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        QuestionPanel[] Panels()=>AlignmentNodes(app).OfType<QuestionPanel>().Where(p=>!p.IsQueuedForDeletion()).ToArray();
        Rect2 Clip(Control c){var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        async Task Click(Control c) {
            await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            Check(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect()),"native target is visibly enclosed without diagnostic reveal: "+c.Name);
            string targetName=c.Name.ToString();int calls=0;void Pressed()=>calls++;var button=c as BaseButton;if(button!=null){Check(!button.Disabled,"native action enabled: "+c.Name);button.Pressed+=Pressed;}
            try {
                var before=c.GetGlobalRect();int cancelled=gui.Cancellations;gui.Move(before.GetCenter());await Frame();
                var hovered=gui.Surface.GuiGetHoveredControl();var atPress=c.GetGlobalRect();var beforeFocus=gui.Surface.GuiGetFocusOwner();
                gui.Press();var pressedFocus=gui.Surface.GuiGetFocusOwner();await Frame();gui.Release();await Frame();await Frame();
                await File.AppendAllTextAsync("/work/input-observations.jsonl",JsonSerializer.Serialize(new {control=targetName,before=before.ToString(),atPress=atPress.ToString(),after=IsInstanceValid(c)?c.GetGlobalRect().ToString():"retired",hoveredSame=hovered==c,focusBefore=IsInstanceValid(beforeFocus)?beforeFocus.Name.ToString():null,focusOnPress=IsInstanceValid(pressedFocus)?pressedFocus.Name.ToString():null,afterFocus=gui.Surface.GuiGetFocusOwner()?.Name.ToString(),cancelled=gui.Cancellations-cancelled,editable=IsInstanceValid(c)?(c as LineEdit)?.Editable:null})+"\n");
            }
            finally {if(button!=null&&IsInstanceValid(button))button.Pressed-=Pressed;}
            if(button!=null){await File.AppendAllTextAsync("/work/actions.jsonl",JsonSerializer.Serialize(new {control=targetName,calls,retired=!IsInstanceValid(button),disabled=IsInstanceValid(button)?button.Disabled:(bool?)null,visible=IsInstanceValid(c)&&c.IsVisibleInTree()})+"\n");Check(calls==1,"one complete native gesture delivers one action: "+targetName);}
        }
        var attention=(Button)app.FindChild("attention",true,false);Check(app.WorkspaceMenuEntries().Any(e=>e.Item1.StartsWith("Your attention")&&e.Item2()),"existing spatial menu offers the same authorized attention owner");await Click(attention);
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
            foreach(var control in new Control[]{field,submit,(Button)first.FindChild("hide-question",true,false),(Button)first.FindChild("cancel-question",true,false)}) { await File.AppendAllTextAsync("/work/geometry.jsonl",JsonSerializer.Serialize(new {mode=mode.ToString(),control=control.Name.ToString(),rect=control.GetGlobalRect().ToString(),clip=Clip(control).ToString()})+"\n");Check(control.IsVisibleInTree()&&Clip(control).Encloses(control.GetGlobalRect()),"primary question field action dismissal and cancellation enclosed at "+mode+" "+control.Name); }
            await Click(field);Check(field.HasFocus()&&(!mode.Item1||gui.TextEntryActive),"selected native field supports existing adjacent keyboard at "+mode);
            Check(ReferenceEquals(field,form.Input("answer"))&&field.Text=="Retained local answer"&&!xr.Running,"layout and spatial composition retain local text without native XR");
        }
        xr.PresentWorkspace(false);GetTree().Root.Size=new(1200,800);gui.TextSize(26-gui.Appearance.DefaultFontSize);await Frame();await Frame();
        var before=await app.ActiveSession.Read(app.ActiveAccounts.Human!,"findall(X,alignment_answer(X),Answers).",cancellation);
        Check(Json.Binding(before,"Answers").Items.Length==0&&!app.ActiveStore.Snapshot!.Pending.Any(),"attention selection hide resize and refresh never answer a question or submit domain work");
        await Click(submit);await Until(()=>!first.Discovered&&!app.ActiveAccounts.Uncertain);await app.ActiveAccounts.Resolve(cancellation);
        var after=await app.ActiveSession.Read(app.ActiveAccounts.Human!,"findall(X,alignment_answer(X),Answers).",cancellation);
        Check(Json.Binding(after,"Answers").ToString()=="[<<\"Retained local answer\">>]","explicit native Submit executes the original continuation exactly once with retained text");
        await Click(attention);await Click(other.Choice);Check(other.IsVisibleInTree()&&!first.IsVisibleInTree(),"explicit selection installs only the second question's retained form");
        var cancellationButton=(Button)other.FindChild("cancel-question",true,false);
        await File.WriteAllTextAsync("/work/pre-cancel.json",JsonSerializer.Serialize(new {other.Available,other.Status,other.Discovered,cancellationButton.Disabled}));
        await Until(()=>other.Available);await Click(cancellationButton);await Until(()=>!other.Discovered&&!app.ActiveAccounts.Uncertain);await app.ActiveAccounts.Resolve(cancellation);
        Check(Panels().Count(p=>p.Discovered)==1&&third.Discovered,"explicit Cancel retires only its exact question; Later did not cancel");
        Check(first.LastOutcome!=null&&Json.Committed(first.LastOutcome)&&first.Status.Contains("Submitted")&&!first.Status.StartsWith("Applied"),"received input commit is retained without inventing application success from HUD removal");
        await Click((Button)other.FindChild("hide-question",true,false));Check(!IsInstanceValid(other)||other.IsQueuedForDeletion(),"Later acknowledges only the selected received cancellation result");
        await Click(third.Choice);await Click((Button)third.FindChild("hide-question",true,false));
        Check(third.Discovered&&third.FormPanel.Draft["answer"]=="Original","Later retains exact pending question and draft without cancellation");
        await Click((Button)app.FindChild("hide-attention",true,false));
        var reference=typeof(QuestionPanel).GetField("question",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(third)!.ToString();
        var identity=app.ActiveAccounts.Human;var location=State["current_location"]!.ToString();
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0&&gui.Captures==0,"all question views and native capture retire through existing disconnect");
        await Press("connect");await Until(()=>State["question_receiver_ready"]?.GetValue<bool>()==true&&Panels().Count()==1&&Panels().Single().Available&&State["world_accepted"]?.GetValue<bool>()==true);
        var reopened=Panels().Single();Check(app.ActiveAccounts.Human==identity&&State["current_location"]!.ToString()==location&&typeof(QuestionPanel).GetField("question",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(reopened)!.ToString()==reference,"same-profile Connect recovers the original still-pending question identity and location");
        var final=await app.ActiveSession.Read(app.ActiveAccounts.Human!,"findall(X,alignment_answer(X),Answers).",cancellation);
        Check(Json.Binding(final,"Answers").ToString()=="[<<\"Retained local answer\">>]"&&!app.ActiveStore.Snapshot!.Pending.Any(),"reconnect never resubmits the original answer or invents a new domain result");
        await Press("disconnect");await app.ViewsDisposed;
    }
}
