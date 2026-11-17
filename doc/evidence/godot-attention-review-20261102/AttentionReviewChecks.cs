using Godot;
using Quod.Client;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json=Quod.Client.Json;
using File=System.IO.File;

public partial class ExportChecks
{
    sealed class RefuseReceiver(System.Net.Http.HttpClient original):System.Net.Http.HttpMessageHandler
    {
        public bool Armed=true;public int Refusals;
        protected override async Task<System.Net.Http.HttpResponseMessage> SendAsync(System.Net.Http.HttpRequestMessage request,CancellationToken token)
        {
            if(Armed&&request.RequestUri!.AbsolutePath=="/api/goals/execute") {Armed=false;Refusals++;return new(System.Net.HttpStatusCode.ServiceUnavailable){Content=new System.Net.Http.StringContent("{\"error\":\"review_receiver_unavailable\",\"submitted\":false}")};}
            using var copy=new System.Net.Http.HttpRequestMessage(request.Method,request.RequestUri);
            foreach(var h in request.Headers)copy.Headers.TryAddWithoutValidation(h.Key,h.Value);
            if(request.Content!=null){copy.Content=new System.Net.Http.ByteArrayContent(await request.Content.ReadAsByteArrayAsync(token));foreach(var h in request.Content.Headers)copy.Content.Headers.TryAddWithoutValidation(h.Key,h.Value);}
            return await original.SendAsync(copy,token);
        }
    }
    static T ReviewField<T>(object owner,string name)=>(T)owner.GetType().GetField(name,BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(owner)!;
    static async Task ReviewCall(object owner,string name,params object[] args)
    { if(owner.GetType().GetMethod(name,BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(owner,args) is Task task)await task; }
    async Task ReviewProjection(SignedView view,Func<Task> change)
    { var accepted=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);void Seen(JsonNode n)=>accepted.TrySetResult();view.Projection+=Seen;try{await change();await accepted.Task.WaitAsync(TimeSpan.FromSeconds(30));await Frame();}finally{view.Projection-=Seen;} }
    async Task AttentionReview(QuestionPanel[] initial,Func<string,Task> commit,CancellationToken token)
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var hub=ReviewField<QuestionHub>(app,"questions");var hud=ReviewField<SignedView>(hub,"hud");
        var first=initial[0];var other=initial[1];var view=ReviewField<SignedView>(first,"view");
        string phase=Env("M1B_PHASE");
        if(phase=="attention-review-home") {
            ((Button)app.FindChild("workspace-connection",true,false)).EmitSignal(BaseButton.SignalName.Pressed);
            ((Button)app.FindChild("client-tools",true,false)).EmitSignal(BaseButton.SignalName.Pressed);
            // Use the existing read-only original-outcome action to populate
            // native status chrome; do not invent diagnostic product copy.
            await ReviewCall(app,"Run",(Func<Task>)(()=>ReviewCall(app,"Resolve")));
            Check(State["status"]!.ToString()=="Original outcomes resolved without submission.","existing outcome action exposes its real native status chrome");
            var scene=ReviewField<ScenePanel>(app,"scene");var scroll=ReviewField<ScrollContainer>(app,"workspaceScroll");
            var rows=new List<object>();bool readable=true;
            foreach(var mode in new[]{(1200,26),(1200,48),(560,26)}) {
                GetTree().Root.Size=new(mode.Item1,800);gui.TextSize(mode.Item2-gui.Appearance.DefaultFontSize);await Frame();await Frame();
                var rect=scene.GetGlobalRect();var clip=scroll.GetGlobalRect().Intersection(new Rect2(Vector2.Zero,gui.Surface.Size));
                rows.Add(new{mode=mode.ToString(),scene=rect.ToString(),clip=clip.ToString(),height=rect.Size.Y,minimum=scene.CustomMinimumSize.Y});
                await AlignmentRaster("expanded-home-"+mode.Item1+"-"+mode.Item2,gui.Surface);readable&=rect.Size.Y>=180;
                if(rect.Size.Y>=180) {
                    var point=scroll.GetVScrollBar().GetGlobalRect().GetCenter();gui.Move(point);
                    for(int i=0;i<64&&!clip.Encloses(scene.GetGlobalRect());i++) {
                        foreach(bool down in new[]{true,false})gui.Surface.PushInput(new InputEventMouseButton{Position=point,GlobalPosition=point,ButtonIndex=MouseButton.WheelDown,Pressed=down,Factor=1},true);
                        await Frame();
                    }
                    Check(clip.Encloses(scene.GetGlobalRect()),"complete bounded native wheel gestures reach the full interior at "+mode);
                    await AlignmentRaster("scrolled-home-"+mode.Item1+"-"+mode.Item2,gui.Surface);scroll.ScrollVertical=0;
                }
            }
            await File.WriteAllTextAsync("/work/expanded-home.json",JsonSerializer.Serialize(rows));
            Check(readable,"expanded Account and Tools retain a readable interior scene rather than collapsing its native viewport");
        } else if(phase=="attention-review-auth") {
            hub.Show();first.Choice.EmitSignal(BaseButton.SignalName.Pressed);await Frame();await Frame();
            var editor=(LineEdit)first.FormPanel.Input("answer")!;editor.Text="Independent authorization draft";editor.EmitSignal(LineEdit.SignalName.TextChanged,editor.Text);editor.Select(2,9);editor.CaretColumn=9;
            var draft=first.FormPanel.Draft;string status=first.Status;int projections=0;void Seen(JsonNode n)=>projections++;view.Projection+=Seen;
            await hud.Suspend(true);await Frame();
            var suspended=new{first.Available,first.Status,editor.Editable,shown=first.FormPanel.IsVisibleInTree(),projections};
            await ReviewProjection(hud,()=>hud.Reopen(true));
            await File.WriteAllTextAsync("/work/hud-independent.json",JsonSerializer.Serialize(new{suspended,after=new{first.Available,first.Status,editor.Editable,projections},sameEditor=ReferenceEquals(editor,first.FormPanel.Input("answer")),sameDraft=ReferenceEquals(draft,first.FormPanel.Draft)}));
            view.Projection-=Seen;
            Check(first.Available&&first.Status==status&&projections==0&&editor.Editable,"HUD-only withdrawal and accepted reprojection preserve independently authorized question state");
            await view.Suspend(true);await Frame();
            Check(!first.Available&&!editor.Editable&&!first.FormPanel.IsVisibleInTree(),"question authorization withdrawal hides and locks its own native form");
            await ReviewProjection(hud,()=>hud.Renew());
            Check(!first.Available&&!first.FormPanel.IsVisibleInTree()&&first.Status==status,"HUD acceptance cannot restore a withdrawn question or overwrite its last-known status");
            await ReviewProjection(view,()=>view.Reopen(true));
            Check(first.Available&&ReferenceEquals(editor,first.FormPanel.Input("answer"))&&ReferenceEquals(draft,first.FormPanel.Draft)&&editor.Text=="Independent authorization draft"&&editor.HasSelection()&&editor.CaretColumn==9,"only accepted question renewal restores the same native draft and selection");
            int writes=0,sockets=SignedView.LiveSockets;app.ActiveStore.DurabilityBoundary=_=>writes++;
            using(var socket=new System.Net.Sockets.TcpClient()) {
                await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),token);using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
                await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),token);Check(JsonNode.Parse((await reader.ReadLineAsync(token))!)!["ready"]!.GetValue<bool>(),"named unchanged-owner work watcher installed");
                for(int i=0;i<3;i++){await ReviewProjection(hud,()=>hud.Renew());await ReviewProjection(view,()=>view.Renew());}
                await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),token);var work=JsonNode.Parse((await reader.ReadLineAsync(token))!)!;await File.WriteAllTextAsync("/work/unchanged-work.json",work.ToJsonString());
                Check(work["work"]!["calls"]!.AsArray().Count==0&&writes==0&&SignedView.LiveSockets==sockets&&ReferenceEquals(editor,first.FormPanel.Input("answer")),"independent accepted renewals retain native resources and perform no history rebuild write sync work");
            }
            app.ActiveStore.DurabilityBoundary=null;
            xr.PresentWorkspace(true);await Frame();await Frame();gui.Move(editor.GetGlobalRect().GetCenter());gui.Press();await Frame();gui.Release();await Frame();await Frame();
            Check(gui.TextEntryActive,"complete native field gesture opens the adjacent keyboard after release");
            gui.Move(editor.GetGlobalRect().GetCenter());gui.Press();await Frame();
            Check(gui.Captures==1&&gui.TextEntryActive,"native question field holds existing capture and adjacent keyboard");
            await view.Suspend(true);await Frame();await Frame();
            Check(gui.Captures==0&&!gui.TextEntryActive&&!first.Available,"question withdrawal cancels native capture and keyboard without changing outcome");
            await ReviewProjection(view,()=>view.Reopen(true));xr.PresentWorkspace(false);
            var transport=app.ActiveSession.Transport;var member=typeof(Transport).GetField("client",BindingFlags.Instance|BindingFlags.NonPublic)!;var original=(System.Net.Http.HttpClient)member.GetValue(transport)!;
            using var fault=new LostAnswer(original){Before=true,Armed=true};using var client=new System.Net.Http.HttpClient(fault){BaseAddress=original.BaseAddress,Timeout=System.Threading.Timeout.InfiniteTimeSpan};member.SetValue(transport,client);
            try {
                ((Button)first.FormPanel.Input("send_answer")!).EmitSignal(BaseButton.SignalName.Pressed);await ReviewField<Task>(first,"working");string unknown=first.Status;var pending=app.ActiveStore.Snapshot!.Pending.Single();
                Check(unknown.StartsWith("Outcome unknown")&&!other.Available,"one unknown original operation applies the existing global uncertain barrier");
                await hud.Suspend(true);await ReviewProjection(hud,()=>hud.Reopen(true));await view.Suspend(true);await ReviewProjection(hud,()=>hud.Renew());
                Check(first.Status==unknown&&!first.Available,"HUD and question withdrawals retain exact unknown-outcome text without claiming refusal");
                ((Button)other.FindChild("cancel-question",true,false)).EmitSignal(BaseButton.SignalName.Pressed);
                Check(fault.Writes==1&&app.ActiveStore.Snapshot.Pending.Single().Id==pending.Id,"unrelated Cancel preserves the existing global uncertain barrier without a second write");
                await ReviewProjection(view,()=>view.Reopen(true));Check(!first.Available&&first.Status.StartsWith("Outcome unknown"),"accepted question refresh cannot clear unknown original work");
            } finally {member.SetValue(transport,original);}
        } else if(phase=="attention-review-receiver") {
            var transport=app.ActiveSession.Transport;var member=typeof(Transport).GetField("client",BindingFlags.Instance|BindingFlags.NonPublic)!;
            var original=(System.Net.Http.HttpClient)member.GetValue(transport)!;using var fault=new RefuseReceiver(original);
            using var client=new System.Net.Http.HttpClient(fault){BaseAddress=original.BaseAddress,Timeout=System.Threading.Timeout.InfiniteTimeSpan};member.SetValue(transport,client);
            var host=new VBoxContainer();gui.Surface.AddChild(host);
            var unavailable=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);var recovered=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            QuestionHub? receiver=null;receiver=new QuestionHub(app.ActiveSession,app.ActiveAccounts,app.ActiveStore,host,()=>{if(receiver==null)return;if(ReviewField<Label>(receiver,"notice").Visible)unavailable.TrySetResult();if(receiver.Ready)recovered.TrySetResult();});
            try {
                receiver.Start();var notice=ReviewField<Label>(receiver,"notice");await unavailable.Task.WaitAsync(TimeSpan.FromSeconds(30));Check(fault.Refusals==1&&!receiver.Ready&&!app.ActiveAccounts.Uncertain,"definite pre-admission receiver refusal is visible without an uncertain journal");
                var receiverHud=ReviewField<SignedView>(receiver,"hud");await ReviewProjection(receiverHud,()=>receiverHud.Renew());await recovered.Task.WaitAsync(TimeSpan.FromSeconds(30));
                await File.WriteAllTextAsync("/work/receiver-recovery.json",JsonSerializer.Serialize(new{receiver.Ready,notice.Visible,notice.Text,fault.Refusals,pending=app.ActiveStore.Snapshot!.Pending.Count}));
                Check(!notice.Visible,"accepted signed receiver recovery clears its obsolete unavailable notice");
            } finally {member.SetValue(transport,original);receiver.Dispose();await receiver.Completion;host.QueueFree();}
        } else if(phase=="attention-review-references") {
            JsonNode? old=null;void Saved(JsonNode n)=>old=n.DeepClone();hud.Projection+=Saved;await ReviewProjection(hud,()=>hud.Renew());hud.Projection-=Saved;
            Check(old!=null,"retained the actual accepted HUD projection before exact question retirement");
            hub.Show();first.Choice.EmitSignal(BaseButton.SignalName.Pressed);await Frame();
            ((Button)first.FindChild("cancel-question",true,false)).EmitSignal(BaseButton.SignalName.Pressed);await Until(()=>!first.Discovered&&!app.ActiveAccounts.Uncertain);
            long ignored=SignedView.IgnoredProjections;
            await ReviewCall(hud,"Handle",old!.DeepClone());await ReviewCall(hud,"Handle",old.DeepClone());await ReviewProjection(hud,()=>hud.Renew());
            Check(SignedView.IgnoredProjections==ignored+2&&!first.Discovered&&other.Discovered&&hub.Caption.EndsWith("1"),"the real signed owner rejects stale duplicate HUD projections and accepted renewal does not resurrect a consumed question");
            var refusal=await app.ActiveSession.Execute(app.ActiveAccounts.Human!,"fail.","review-definite-refusal",token);
            await File.WriteAllTextAsync("/work/definite-refusal.json",refusal.ToJsonString());
            Check(Json.Terminal(refusal)&&!Json.Committed(refusal)&&!app.ActiveAccounts.Uncertain,"real definite proof refusal retires only its original journal operation");
            await File.WriteAllTextAsync("/work/refusal-fields.json",JsonSerializer.Serialize(new{fields=refusal.AsObject().Select(p=>p.Key).ToArray(),reason=refusal["reason"]?.ToString(),error=refusal["error"]?.ToString()}));
        } else if(phase=="attention-review-identity") {
            hub.Show();first.Choice.EmitSignal(BaseButton.SignalName.Pressed);await Frame();await Frame();
            var editor=(LineEdit)first.FormPanel.Input("answer")!;editor.Text="Retained reference draft";editor.EmitSignal(LineEdit.SignalName.TextChanged,editor.Text);editor.Select(2,8);editor.CaretColumn=8;
            var draft=first.FormPanel.Draft;var references=(Button)first.FindChild("question-references",true,false);var identity=(TextEdit)first.FindChild("question-identity",true,false);var source=(Label)first.FindChild("question-source",true,false);
            int writes=0,sockets=SignedView.LiveSockets;app.ActiveStore.DurabilityBoundary=_=>writes++;
            foreach(var mode in new[]{(false,1200,26),(false,1200,48),(false,560,26),(true,1200,26),(true,1200,48)}) {
                xr.PresentWorkspace(mode.Item1);GetTree().Root.Size=new(mode.Item2,800);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Frame();
                gui.Move(references.GetGlobalRect().GetCenter());gui.Press();await Frame();gui.Release();await Frame();await Frame();
                Check(references.ButtonPressed&&identity.IsVisibleInTree()&&!identity.Editable&&identity.Text==source.TooltipText&&identity.GetViewport()==gui.Surface,"native References reveals full exact identity in the same texture at "+mode);
                var ink=identity.GetThemeColor("font_readonly_color");await File.AppendAllTextAsync("/work/readonly-ink.jsonl",JsonSerializer.Serialize(new{mode=mode.ToString(),ink=ink.ToString(),ink.A})+"\n");
                Check(ink.A==1,"native readonly reference text stays opaque");
                var clip=gui.Surface.GetVisibleRect();for(Node? n=identity.GetParent();n!=null;n=n.GetParent())if(n is Control c&&c.ClipContents)clip=clip.Intersection(c.GetGlobalRect());
                Check(clip.Encloses(identity.GetGlobalRect())&&clip.Encloses(references.GetGlobalRect()),"exact-reference reader and return control are enclosed at "+mode);
                await AlignmentRaster("references-"+mode.Item1+"-"+mode.Item2+"-"+mode.Item3,gui.Surface);
                gui.Move(references.GetGlobalRect().GetCenter());gui.Press();await Frame();gui.Release();await Frame();await Frame();
                Check(!references.ButtonPressed&&first.FormPanel.IsVisibleInTree()&&ReferenceEquals(editor,first.FormPanel.Input("answer"))&&ReferenceEquals(draft,first.FormPanel.Draft)&&editor.Text=="Retained reference draft"&&editor.HasSelection()&&editor.CaretColumn==8,"return from References retains the same native form draft caret and selection");
            }
            Check(writes==0&&sockets==SignedView.LiveSockets&&!app.ActiveAccounts.Uncertain,"identity inspection never writes or reacquires signed resources");app.ActiveStore.DurabilityBoundary=null;xr.PresentWorkspace(false);
        } else if(phase=="attention-review-tooltip") {
            hub.Show();xr.PresentWorkspace(true);await Frame();await Frame();
            var source=first.Choice;var appeared=new TaskCompletionSource<PopupPanel>(TaskCreationOptions.RunContinuationsAsynchronously);
            void Added(Node n){if(n is PopupPanel popup)appeared.TrySetResult(popup);}
            GetTree().NodeAdded+=Added;
            try {
                gui.Move(source.GetGlobalRect().GetCenter());await Frame();
                await File.WriteAllTextAsync("/work/tooltip-target.json",JsonSerializer.Serialize(new{hovered=gui.Surface.GuiGetHoveredControl()?.Name.ToString(),sameTarget=gui.Surface.GuiGetHoveredControl()==source,source.MouseFilter,rect=source.GetGlobalRect().ToString(),surfaceEmbeds=gui.Surface.GuiEmbedSubwindows}));
                var popup=await appeared.Task.WaitAsync(TimeSpan.FromSeconds(5));await Frame();await Frame();
                var text=AlignmentNodes(popup).OfType<Label>().Single();bool sameSurface=popup.GetParent().GetViewport()==gui.Surface;
                await AlignmentRaster("spatial-exact-reference-tooltip",gui.Surface);
                await File.WriteAllTextAsync("/work/tooltip.json",JsonSerializer.Serialize(new{popup.Visible,embedded=popup.IsEmbedded(),sameSurface,textMatches=text.Text==source.TooltipText,rect=popup.Size.ToString(),surface=gui.Surface.Size.ToString(),surfaceEmbeds=gui.Surface.GuiEmbedSubwindows}));
                Check(popup.IsEmbedded()&&gui.Surface.GuiEmbedSubwindows,"full exact references are rendered within the native spatial texture");
            }finally{GetTree().NodeAdded-=Added;xr.PresentWorkspace(false);}
        }
        await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0&&!xr.Running&&gui.Captures==0,"review fixture retires signed owners and captures without native XR");
    }
}
