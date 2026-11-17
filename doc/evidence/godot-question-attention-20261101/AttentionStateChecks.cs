using Godot;
using Quod.Client;
using System.Net.Http;
using HttpClient=System.Net.Http.HttpClient;
using System.Reflection;
using System.Text.Json;
using Json=Quod.Client.Json;
using File=System.IO.File;

public partial class ExportChecks
{
    // Forward the actual signed request through its original TLS client, then
    // lose only its reply. This cannot fabricate a committed server outcome.
    sealed class LostAnswer(HttpClient original) : HttpMessageHandler
    {
        public bool Armed,Before;
        public int Writes, Losses;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        {
            using var copy=new HttpRequestMessage(request.Method,request.RequestUri);
            foreach(var header in request.Headers)copy.Headers.TryAddWithoutValidation(header.Key,header.Value);
            if(request.Content!=null){copy.Content=new ByteArrayContent(await request.Content.ReadAsByteArrayAsync(token));foreach(var h in request.Content.Headers)copy.Content.Headers.TryAddWithoutValidation(h.Key,h.Value);}
            bool write=request.RequestUri!.AbsolutePath=="/api/goals/execute";if(write)Writes++;
            if(write&&Armed&&Before){Armed=false;Losses++;throw new HttpRequestException("Diagnostic transport loss without an admission reply");}
            var response=await original.SendAsync(copy,token);
            if(write&&Armed){Armed=false;Losses++;response.Dispose();throw new HttpRequestException("Diagnostic reply loss after actual signed transport");}
            return response;
        }
    }
    async Task AttentionState(QuestionPanel[] initial,Func<string,Task> commit,CancellationToken token)
    {
        var first=initial[0];var other=initial[1];var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var attention=(Button)app.FindChild("attention",true,false);attention.EmitSignal(BaseButton.SignalName.Pressed);first.Choice.EmitSignal(BaseButton.SignalName.Pressed);
        await Frame();await Frame();
        var transport=app.ActiveSession.Transport;var member=typeof(Transport).GetField("client",BindingFlags.Instance|BindingFlags.NonPublic)!;
        var original=(HttpClient)member.GetValue(transport)!;using var fault=new LostAnswer(original);using var client=new HttpClient(fault){BaseAddress=original.BaseAddress,Timeout=System.Threading.Timeout.InfiniteTimeSpan};
        member.SetValue(transport,client);
        try {
            var field=(LineEdit)first.FormPanel.Input("answer")!;field.Text="One original answer";field.EmitSignal(LineEdit.SignalName.TextChanged,field.Text);Check(first.FormPanel.Draft["answer"]==field.Text,"native edit event updates the exact retained draft before the reply-loss test");
            fault.Armed=true;((Button)first.FormPanel.Input("send_answer")!).EmitSignal(BaseButton.SignalName.Pressed);
            await ((Task)typeof(QuestionPanel).GetField("working",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(first)!).WaitAsync(TimeSpan.FromSeconds(60));
            Check(fault.Writes==1&&fault.Losses==1&&app.ActiveStore.Snapshot!.Pending.Count==1&&!first.Available,"lost real reply retains one original signed operation and locks the exact question");
            await Until(()=>!first.Discovered);
            var work=app.ActiveStore.Snapshot!.Pending.Single();
            ((Button)first.FormPanel.Input("send_answer")!).EmitSignal(BaseButton.SignalName.Pressed);((Button)first.FindChild("cancel-question",true,false)).EmitSignal(BaseButton.SignalName.Pressed);
            await Frame();Check(fault.Writes==1&&app.ActiveStore.Snapshot!.Pending.Single().Id==work.Id,"retired question never resubmits or cancels its unknown original operation");
            var resolve=(Button)first.FindChild("resolve-question",true,false);
            await File.WriteAllTextAsync("/work/unknown-outcome.json",JsonSerializer.Serialize(new {first.Discovered,first.Status,resolve.Disabled,resolve.Visible,fault.Writes,fault.Losses,pending=app.ActiveStore.Snapshot.Pending.Count}));
            Check(!resolve.Disabled&&resolve.IsVisibleInTree(),"original outcome remains recoverable after authoritative question removal");
            resolve.EmitSignal(BaseButton.SignalName.Pressed);await ((Task)typeof(QuestionPanel).GetField("working",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(first)!).WaitAsync(TimeSpan.FromSeconds(60));
            Check(first.LastOutcome!=null&&Json.Committed(first.LastOutcome)&&!app.ActiveStore.Snapshot.Pending.Any()&&fault.Writes==1,"existing outcome resolver verifies the original request without a second write");
            var read=await app.ActiveSession.Read(app.ActiveAccounts.Human!,"findall(X,alignment_answer(X),Answers).",token);
            await File.WriteAllTextAsync("/work/recovered-readback.json",JsonSerializer.Serialize(new {answers=Json.Binding(read,"Answers").ToString(),other.Discovered}));
            Check(Json.Binding(read,"Answers").ToString()=="[<<\"One original answer\">>]"&&other.Discovered,"real continuation applies once and the independent question stays pending");
        } finally {member.SetValue(transport,original);}
        await app.ActiveAccounts.Resolve(token);
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0,"fault observation retires every owned view and capture normally");
    }
    async Task AttentionUnknown(QuestionPanel[] initial,CancellationToken token)
    {
        var first=initial[0];var transport=app.ActiveSession.Transport;
        ((Button)app.FindChild("attention",true,false)).EmitSignal(BaseButton.SignalName.Pressed);first.Choice.EmitSignal(BaseButton.SignalName.Pressed);await Frame();await Frame();
        var member=typeof(Transport).GetField("client",BindingFlags.Instance|BindingFlags.NonPublic)!;var original=(HttpClient)member.GetValue(transport)!;
        using var fault=new LostAnswer(original){Before=true,Armed=true};using var client=new HttpClient(fault){BaseAddress=original.BaseAddress,Timeout=System.Threading.Timeout.InfiniteTimeSpan};member.SetValue(transport,client);
        try {
            ((Button)first.FormPanel.Input("send_answer")!).EmitSignal(BaseButton.SignalName.Pressed);
            await ((Task)typeof(QuestionPanel).GetField("working",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(first)!).WaitAsync(TimeSpan.FromSeconds(60));
            Check(app.ActiveStore.Snapshot!.Pending.Count==1&&!first.Available,"unacknowledged request retains its original signed journal barrier");
            await Renew(first);
            Check(first.Discovered&&!first.Available&&first.Status.StartsWith("Outcome unknown")&&!first.Status.StartsWith("Submitted"),"accepted awaiting refresh cannot turn an unknown submission into a claimed input commit");
            var work=app.ActiveStore.Snapshot.Pending.Single();
            ((Button)first.FormPanel.Input("send_answer")!).EmitSignal(BaseButton.SignalName.Pressed);((Button)first.FindChild("cancel-question",true,false)).EmitSignal(BaseButton.SignalName.Pressed);
            Check(fault.Writes==1&&app.ActiveStore.Snapshot.Pending.Single().Id==work.Id,"repeated native commands cannot replay or replace unknown original work");
            var read=await app.ActiveSession.Read(app.ActiveAccounts.Human!,"findall(X,alignment_answer(X),Answers).",token);
            Check(Json.Binding(read,"Answers").Items.Length==0&&initial.All(p=>p.Discovered),"real owner has no answer and both questions remain pending; no refusal inferred");
            var resolve=(Button)first.FindChild("resolve-question",true,false);Check(!resolve.Disabled,"explicit original lookup remains offered");resolve.EmitSignal(BaseButton.SignalName.Pressed);
            await ((Task)typeof(QuestionPanel).GetField("working",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(first)!).WaitAsync(TimeSpan.FromSeconds(60));
            Check(fault.Writes==1&&app.ActiveStore.Snapshot.Pending.Single().Id==work.Id&&first.Status.StartsWith("Outcome unknown"),"original absence before its deadline stays uncertain and never authorizes another submission");
        } finally {member.SetValue(transport,original);}
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"unknown original profile is preserved while all views close normally");
    }
    async Task AttentionStale(QuestionPanel[] initial,Func<string,Task> commit,CancellationToken token)
    {
        var first=initial[0];var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        ((Button)app.FindChild("attention",true,false)).EmitSignal(BaseButton.SignalName.Pressed);first.Choice.EmitSignal(BaseButton.SignalName.Pressed);await Frame();await Frame();
        var field=(LineEdit)first.FormPanel.Input("answer")!;var draft=first.FormPanel.Draft;
        field.Text="";field.EmitSignal(LineEdit.SignalName.TextChanged,field.Text);
        int writes=0;app.ActiveStore.DurabilityBoundary=_=>writes++;
        ((Button)first.FormPanel.Input("send_answer")!).EmitSignal(BaseButton.SignalName.Pressed);await Frame();
        Check(first.Status.StartsWith("Invalid input")&&writes==0&&!app.ActiveAccounts.Uncertain&&first.FormPanel.Draft["answer"]=="","real required-field validation retains invalid draft without a signed write");
        var error=AlignmentNodes(first.FormPanel).OfType<Label>().Single(l=>l.Text.Contains("Text is required"));
        Check(error.IsVisibleInTree()&&error.GetParent()==field.GetParent(),"existing validation error remains adjacent to the affected native field");
        await File.WriteAllTextAsync("/work/validation-scope.json",JsonSerializer.Serialize(new {inline=true,focusableSummary=AlignmentNodes(first.FormPanel).OfType<Control>().Any(c=>c.Name.ToString()=="validation-summary"),error=error.Text}));
        field.Text="Retained stale draft";field.EmitSignal(LineEdit.SignalName.TextChanged,field.Text);field.Select(2,8);field.CaretColumn=8;app.ActiveStore.DurabilityBoundary=null;
        await commit("transaction((retract((attribute(alignment_request,help,_) :- true)),assertz((attribute(alignment_request,help,<<\"A changed authored instruction.\">>) :- true)))).");
        await Until(()=>first.Status.StartsWith("Stale form"));
        Check(ReferenceEquals(field,first.FormPanel.Input("answer"))&&ReferenceEquals(draft,first.FormPanel.Draft)&&field.Text=="Retained stale draft"&&!field.Editable,"accepted schema change keeps the original native draft and disables stale submission");
        await File.WriteAllTextAsync("/work/stale-before-renew.json",JsonSerializer.Serialize(new {first.Status,first.Available,field.Editable,text=field.Text}));
        try {await Renew(first);}
        finally {await File.WriteAllTextAsync("/work/stale-after-renew.json",JsonSerializer.Serialize(new {first.Status,first.Available,field.Editable,text=field.Text,sameEditor=ReferenceEquals(field,first.FormPanel.Input("answer"))}));}
        Check(first.Status.StartsWith("Stale form")&&field.Text=="Retained stale draft"&&field.HasSelection()&&field.CaretColumn==8,"unchanged stale renewal retains the old form rather than applying a different semantic appearance tree");
        var cancel=(Button)first.FindChild("cancel-question",true,false);Check(!cancel.Disabled,"current authorized stale question still offers its explicit Cancel");cancel.EmitSignal(BaseButton.SignalName.Pressed);await Until(()=>!first.Discovered&&!app.ActiveAccounts.Uncertain);
        Check(initial[1].Discovered,"cancelling one stale question leaves the independent question pending");
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0&&gui.Captures==0,"stale question consumers and capture close through existing owner");
    }

    async Task AttentionRefused(QuestionPanel[] initial,CancellationToken token)
    {
        var first=initial[0];((Button)app.FindChild("attention",true,false)).EmitSignal(BaseButton.SignalName.Pressed);first.Choice.EmitSignal(BaseButton.SignalName.Pressed);await Frame();await Frame();
        ((Button)first.FormPanel.Input("send_answer")!).EmitSignal(BaseButton.SignalName.Pressed);
        await ((Task)typeof(QuestionPanel).GetField("working",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(first)!).WaitAsync(TimeSpan.FromSeconds(60));
        Check(first.LastOutcome!=null&&Json.Committed(first.LastOutcome),"real answer input commits independently of a failing authored application continuation");
        var current=typeof(QuestionPanel).GetField("current",BindingFlags.Instance|BindingFlags.NonPublic)!;
        await Until(()=>first.Discovered&&((QuestionDescriptor?)current.GetValue(first))?.Interaction=="submitted");
        var q=(Term)typeof(QuestionPanel).GetField("question",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(first)!;
        var original=await app.ActiveSession.Read(app.ActiveAccounts.Human!,"gui_question("+q+",_,_,_,_,submitted(_,_,_,Original)).",token);
        using(var socket=new System.Net.Sockets.TcpClient()) {
            await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),token);using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
            var request=new System.Text.Json.Nodes.JsonObject {["request"]=Identity.Encode(Json.Binding(original,"Original").Bytes)};
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes(request.ToJsonString()+"\n"),token);
            var completed=System.Text.Json.Nodes.JsonNode.Parse((await reader.ReadLineAsync(token))!)!;
            Check(completed["terminal"]!.GetValue<bool>(),"existing original application owner has published terminal completion before explicit outcome read");
        }
        var resolve=(Button)first.FindChild("resolve-question",true,false);Check(!resolve.Disabled,"submitted input offers explicit original application outcome read");resolve.EmitSignal(BaseButton.SignalName.Pressed);
        await ((Task)typeof(QuestionPanel).GetField("working",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(first)!).WaitAsync(TimeSpan.FromSeconds(60));
        await File.WriteAllTextAsync("/work/refused-outcome.json",JsonSerializer.Serialize(new {first.Status,first.Discovered,inputCommitted=Json.Committed(first.LastOutcome!)}));
        Check(first.Status.StartsWith("Needs attention")&&!first.Status.StartsWith("Applied"),"only a certified negative application outcome offers recovery rather than claiming Applied");
        var cancel=(Button)first.FindChild("cancel-question",true,false);Check(!cancel.Disabled,"certified negative submitted question enables its existing authorized cancellation");cancel.EmitSignal(BaseButton.SignalName.Pressed);await Until(()=>!first.Discovered&&!app.ActiveAccounts.Uncertain);
        var read=await app.ActiveSession.Read(app.ActiveAccounts.Human!,"findall(X,alignment_answer(X),Answers).",token);
        Check(Json.Binding(read,"Answers").Items.Length==0&&initial[1].Discovered,"failed continuation creates no answer and does not cancel the independent question");
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"refused application question consumers retire normally");
    }

    async Task AttentionComposition(QuestionPanel[] initial,CancellationToken token)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var scene=(ScenePanel)typeof(Main).GetField("scene",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(app)!;
        Rect2 Clip(Control c){var r=c.GetViewport().GetVisibleRect();for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        foreach(var mode in new[]{(1200,26),(1200,48),(560,26)}) {
            GetTree().Root.Size=new(mode.Item1,800);gui.TextSize(mode.Item2-gui.Appearance.DefaultFontSize);await Frame();await Frame();
            await AlignmentRaster("attention-home-"+mode.Item1+"-"+mode.Item2,gui.Surface);
            await File.AppendAllTextAsync("/work/home-geometry.jsonl",JsonSerializer.Serialize(new {mode=mode.ToString(),rect=scene.GetGlobalRect().ToString(),clip=Clip(scene).ToString()})+"\n");
            Check(scene.IsVisibleInTree()&&Clip(scene).Encloses(scene.GetGlobalRect()),"compact attention retains the current interior viewport at "+mode);
        }
        GetTree().Root.Size=new(1200,800);gui.TextSize(26-gui.Appearance.DefaultFontSize);await Frame();await Frame();
        await Press("create-operations");var pane=(EidolonPanel)app.FindChild("representations",true,false);var operation=pane.Operations;var human=app.ActiveAccounts.Human!;
        var storage=(OptionButton)operation.FindChild("operation-storage",true,false);int index=Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==human.Namespace+" @ "+human.Anchor);storage.Select(index);storage.EmitSignal(OptionButton.SignalName.ItemSelected,(long)index);await Until(()=>!operation.IsWorking);
        var classes=(OptionButton)operation.FindChild("operation-class",true,false);index=Enumerable.Range(1,classes.ItemCount-1).Single(i=>classes.GetItemText(i)=="space");classes.Select(index);classes.EmitSignal(OptionButton.SignalName.ItemSelected,(long)index);await Until(()=>pane.Available&&operation.Available);
        pane.Choose(pane.Offered.Single(e=>e.Purpose.Name=="operation"&&e.Style=="create"));await Frame();
        var field=(LineEdit)operation.FormPanel.Input("space_name")!;field.Text="Unsent independent form";field.EmitSignal(LineEdit.SignalName.TextChanged,field.Text);field.Select(2,8);field.CaretColumn=8;
        var draft=operation.FormPanel.Draft;var offered=operation.Current;var question=initial[0];var qfield=question.FormPanel.Input("answer");
        int writes=0;app.ActiveStore.DurabilityBoundary=_=>writes++;int sockets=SignedView.LiveSockets;
        var entry=app.WorkspaceMenuEntries().Single(e=>e.Item1.StartsWith("Your attention"));Check(entry.Item2(),"same existing spatial-menu entry admits local attention selection");entry.Item3();question.Choice.EmitSignal(BaseButton.SignalName.Pressed);xr.PresentWorkspace(true);await Frame();await Frame();
        Check(!pane.IsVisibleInTree()&&question.FormPanel.IsVisibleInTree()&&question.FormPanel.GetViewport()==gui.Surface&&operation.FormPanel.GetViewport()==gui.FormSurface&&!gui.FormOnly,"question attention and object operation keep separate existing native surfaces and owners");
        await AlignmentRaster("attention-separate-spatial",gui.Surface);
        var target=question.FormPanel.Input("answer")!;gui.Move(target.GetGlobalRect().GetCenter());gui.Press();Check(gui.Captures==1,"existing native capture is held before local attention dismissal");
        ((Button)app.FindChild("hide-attention",true,false)).EmitSignal(BaseButton.SignalName.Pressed);await Frame();await Frame();
        Check(gui.Captures==0&&!question.IsVisibleInTree()&&pane.IsVisibleInTree()&&gui.FormOnly,"Back cancels the attention capture and recalls the independent object form");
        Check(ReferenceEquals(field,operation.FormPanel.Input("space_name"))&&ReferenceEquals(draft,operation.FormPanel.Draft)&&ReferenceEquals(offered,operation.Current)&&field.Text=="Unsent independent form"&&field.HasSelection()&&field.CaretColumn==8&&ReferenceEquals(qfield,question.FormPanel.Input("answer")),"attention changes neither installed controller native draft selection revision nor the independent question field");
        Check(writes==0&&sockets==SignedView.LiveSockets&&!app.ActiveAccounts.Uncertain,"attention and object-form transitions do not reacquire views or write domain/local state");app.ActiveStore.DurabilityBoundary=null;
        xr.PresentWorkspace(false);await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0&&gui.Captures==0,"both independent presentation owners retire normally without native XR");
    }

}
