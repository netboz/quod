using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Reflection;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task AuthoredAppearance()
    {
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
        if(Env("M1B_PHASE")=="appearance-lens-dependency") {
            await AppearanceLensDependency();await Press("disconnect");await app.ViewsDisposed;
            Check(SignedView.LiveSockets==0,"all computed inspection consumers retire");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("APPEARANCE_PASS");Console.Out.Flush();await app.CloseApplication();return;
        }
        if(Env("M1B_PHASE")=="appearance-inspection") {
            await AppearanceInspection();await Press("disconnect");await app.ViewsDisposed;
            Check(SignedView.LiveSockets==0,"all authored inspection appearance consumers retire");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("APPEARANCE_PASS");Console.Out.Flush();await app.CloseApplication();return;
        }
        if(Env("M1B_PHASE")=="appearance-question") {
            await AppearanceQuestion();await Press("disconnect");await app.ViewsDisposed;
            Check(SignedView.LiveSockets==0,"all authored question appearance consumers retire");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("APPEARANCE_PASS");Console.Out.Flush();await app.CloseApplication();return;
        }
        if(Env("M1B_PHASE")=="appearance-workspaces") {
            await AppearanceWorkspaces();await Press("disconnect");await app.ViewsDisposed;
            Check(SignedView.LiveSockets==0,"all workspace appearance consumers retire");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("APPEARANCE_PASS");Console.Out.Flush();await app.CloseApplication();return;
        }
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        string ns=Term.Text(human.Namespace).ToString(),anchor=Term.Binary(Identity.Decode(human.Anchor)).ToString();
        string[] clauses=[
            "isa(appearance_instrument,thing)","instance_of(appearance_instrument,analyzer)",
            "class_permission(appearance_instrument,configure,allow)",
            $"class_eidolon(appearance_instrument,operation(instance),configure,recipe({ns},{anchor},instrument_form))",
            $"eidolon(instrument_form,subject(ontology_ref({ns},{anchor}),instance(analyzer)),operation(instrument_settings))",
            "instance_of(quod:gui:form,instrument_settings)","instance_of(quod:gui:text_box,run_name)","instance_of(quod:gui:button,apply_configuration)",
            "gui_children(instrument_settings,[run_name,apply_configuration])",
            "attribute(instrument_settings,label,<<\"Instrument configuration\">>)",
            "attribute(instrument_settings,help,<<\"Edit a local run name; Apply configuration is explicit.\">>)",
            "attribute(run_name,label,<<\"Run name\">>)","attribute(apply_configuration,label,<<\"Apply configuration\">>)",
            "attribute(instrument_settings,appearance,appearance(1,[token(accent,rgb(80,200,240)),token(panel,rgb(40,24,60)),token(panel_opacity,650),token(spacing,18)]))",
            "gui_form(instrument_settings,[field(run_name,Name)],submit(apply_configuration,assert(instrument_configuration(Name)),operation(configure,[])))",
            "gui_initial(instrument_settings,run_name,<<\"Sweep A\">>)"
        ];
        var created=await session.Execute(human,"transaction(("+string.Join(",",clauses.Select(c=>"assertz(("+c+" :- true))"))+" )).","appearance-fixture",CancellationToken.None);
        await File.WriteAllTextAsync("/work/fixture.json",created.ToJsonString());
        Check(Json.Committed(created),"ordinary authorized source transaction authors an independent non-space instrument form and appearance");
        var subject=human with {InstanceText="analyzer."};
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        pane.Open(session,app.ActiveAccounts,app.ActiveStore,subject.Entity);
        await Until(()=>pane.Available&&pane.Operations.Available&&pane.Operations.Current?.Name=="configure");
        Check(pane.Current!.Exact.ToString()==subject.Entity.ToString()&&pane.Selected!.Style=="configure","exact anchored subject reaches its authored operation through existing signed discovery and form owners");
        var form=pane.Operations.FormPanel;var button=(Button)form.Input("apply_configuration")!;
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        xr.PresentWorkspace(true);gui.Surface.GuiEmbedSubwindows=true;
        var revealed=new TaskCompletionSource();SpatialGui.Reveal(button,()=>GodotObject.IsInstanceValid(button),()=>revealed.TrySetResult());await revealed.Task.WaitAsync(TimeSpan.FromSeconds(60));await Frame();
        await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
        using(var image=gui.Surface.GetTexture().GetImage())Check(image.SavePng("/work/authored-appearance.png")==Error.Ok,"actual native signed instrument raster retained");
        var fill=((StyleBoxFlat)button.GetThemeStylebox("normal")).BgColor;
        await File.WriteAllTextAsync("/work/appearance-state.json",JsonSerializer.Serialize(new {form=form.Descriptor.Tree.Label,properties=form.Descriptor.Tree.Properties.ToDictionary(p=>p.Key,p=>p.Value.ToString()),fill=fill.ToHtml(),subject=pane.Current.Exact.ToString(),revision=pane.Operations.Current!.Revision.ToString()}));
        Check(fill.IsEqualApprox(new Color(80/255f,200/255f,240/255f)),"authored appearance reaches the native primary action instead of the adapter default");
        if(Env("M1B_PHASE") is "appearance-full" or "appearance-independent")await AppearanceRenewal(pane,gui,xr,clauses);
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0&&!xr.Running,"appearance consumers retire through ordinary disconnect");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("APPEARANCE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task AppearanceRenewal(EidolonPanel pane,SpatialGui gui,OpenXRInput xr,string[] clauses)
    {
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;var tools=app.ActiveAccounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        var ops=pane.Operations;var form=ops.FormPanel;var field=(LineEdit)form.Input("run_name")!;var button=(Button)form.Input("apply_configuration")!;
        var original=ops.Current!;var draft=form.Draft;var style=button.GetThemeStylebox("normal");
        Rect2 Clip(Control c){var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        async Task Reveal(Control c){var ready=new TaskCompletionSource();SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>ready.TrySetResult());await ready.Task.WaitAsync(TimeSpan.FromSeconds(60));await Frame();}
        async Task Pixel(Vector2 p){gui.Move(p);await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();}
        async Task Click(Control c){await Reveal(c);Check(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect()),"native target enclosed in every clipping ancestor: "+c.Name);await Pixel(c.GetGlobalRect().GetCenter());}
        async Task Raster(string name){await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/"+name+".png")==Error.Ok,"actual appearance raster retained: "+name);}
        async Task Commit(string goal){Check(Json.Committed(await session.Execute(human,goal,"appearance-fixture",CancellationToken.None)),"explicit fixture source change commits once");}
        var secondary=clauses.Select(c=>c.Replace("appearance_instrument","appearance_meter").Replace("analyzer","meter").Replace("instrument_form","meter_form").Replace("instrument_settings","meter_settings").Replace("run_name","meter_name").Replace("apply_configuration","apply_meter").Replace("Instrument configuration","Meter configuration"));
        await Commit("transaction(("+string.Join(",",secondary.Select(c=>"assertz(("+c+" :- true))"))+" )).");
        var independent=new OperationsPanel();gui.Surface.AddChild(independent);var other=human with{InstanceText="meter."};independent.OpenSubject(session,app.ActiveAccounts,other,other.Entity);
        async Task OtherReady(){var ready=new TaskCompletionSource();void Changed(){if(independent.Available&&independent.Current!=null)ready.TrySetResult();}independent.Changed+=Changed;try{Changed();await ready.Task.WaitAsync(TimeSpan.FromSeconds(60));}finally{independent.Changed-=Changed;}}
        await OtherReady();independent.Hide();var otherButton=independent.FormPanel.Input("apply_meter");var otherStyle=otherButton!.GetThemeStylebox("normal");
        async Task RefusalAndIndependent()
        {
            var selectedView=(SignedView)typeof(OperationsPanel).GetField("view",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(ops)!;
            var refused=new TaskCompletionSource<JsonNode>();void Refused(JsonNode value){if(Json.S(value,"value")=="[]")refused.TrySetResult(value);}selectedView.Projection+=Refused;
            try {
                await Commit("assertz((attribute(instrument_settings,appearance,appearance(1,[token(accent,rgb(1,2,3))])) :- true)).");
                var rejected=await refused.Task.WaitAsync(TimeSpan.FromSeconds(60));
                Check(ops.Available&&ops.Current==null&&!selectedView.Updating,"ambiguous authored appearance removes the action from a current accepted empty offered-operation projection");
                var otherView=(SignedView)typeof(OperationsPanel).GetField("view",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(independent)!;
                var accepted=new TaskCompletionSource<JsonNode>();void Projected(JsonNode value)=>accepted.TrySetResult(value);otherView.Projection+=Projected;
                JsonNode current;
                try{await otherView.Renew();current=await accepted.Task.WaitAsync(TimeSpan.FromSeconds(60));}finally{otherView.Projection-=Projected;}
                Check(independent.Available&&!otherView.Updating&&ReferenceEquals(otherButton,independent.FormPanel.Input("apply_meter")),"one explicitly renewed accepted independent occurrence retains its exact native controls after the selected refusal");
                await File.WriteAllTextAsync("/work/independent-current.json",JsonSerializer.Serialize(new{refusalValue=Json.S(rejected,"value"),acceptedHeight=current["height"]?.ToString(),dependencies=current["dependencies"]?.ToString(),sameControl=ReferenceEquals(otherButton,independent.FormPanel.Input("apply_meter")),available=independent.Available}));
            } finally {selectedView.Projection-=Refused;}
            independent.DisposeView();await independent.Completion;gui.Surface.RemoveChild(independent);independent.QueueFree();
        }
        if(Env("M1B_PHASE")=="appearance-independent"){await RefusalAndIndependent();return;}
        await Click(field);field.SelectAll();foreach(char c in "Local sweep"){gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=true},true);gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=false},true);}await Frame();field.Select(1,5);field.CaretColumn=5;
        Check(field.Text=="Local sweep"&&draft["run_name"]==field.Text,"real native editing reaches the same dirty local draft");
        int caret=field.CaretColumn,from=field.GetSelectionFromColumn(),to=field.GetSelectionToColumn();
        var keyboard=(PanelContainer)gui.FindChild("spatial-keyboard",true,false);
        Check(keyboard.Visible&&((StyleBoxFlat)keyboard.GetThemeStylebox("panel")).BgColor.A==1,"adjacent native keyboard remains opaque and holds no appearance text copy");
        string changed="appearance(1,[token(accent,rgb(220,160,240)),token(panel,rgb(24,46,60)),token(panel_opacity,600),token(spacing,18)])";
        await Commit("transaction((retract((attribute(instrument_settings,appearance,_) :- true)),assertz((attribute(instrument_settings,appearance,"+changed+") :- true)))).");
        await Until(()=>ops.Available&&ops.Current?.Form.Tree.Properties.GetValueOrDefault("appearance")?.ToString()==Term.Parse(changed).ToString());
        Check(ReferenceEquals(field,form.Input("run_name"))&&ReferenceEquals(button,form.Input("apply_configuration"))&&ReferenceEquals(draft,form.Draft)&&ReferenceEquals(style,button.GetThemeStylebox("normal")),"appearance-only commit retains native controls draft and style resource identity");
        Check(field.Text=="Local sweep"&&field.CaretColumn==caret&&field.HasSelection()&&field.GetSelectionFromColumn()==from&&field.GetSelectionToColumn()==to,"appearance-only colour renewal retains dirty text caret and selection");
        Check(!field.HasFocus()&&!keyboard.Visible,"existing authorization withdrawal revokes input and keyboard; appearance never restores focus");
        Check(ops.Current!.Revision.ToString()==original.Revision.ToString()&&ops.Current.Subject.ToString()==original.Subject.ToString()&&ops.Current.Form.Submit.ToString()==original.Form.Submit.ToString()&&!button.Disabled&&ops.LastOutcome==null&&!app.ActiveStore.Snapshot!.Pending.Any(),"appearance-only renewal preserves semantic revision submit target permission and original outcome");
        Check(((StyleBoxFlat)style).BgColor.IsEqualApprox(new Color(220/255f,160/255f,240/255f))&&ReferenceEquals(otherButton,independent.FormPanel.Input("apply_meter"))&&ReferenceEquals(otherStyle,otherButton.GetThemeStylebox("normal"))&&((StyleBoxFlat)otherStyle).BgColor.IsEqualApprox(new Color(80/255f,200/255f,240/255f)),"actual changed colour applies only to its authored independent occurrence");
        // Measure unchanged work after the prior changed theme has actually
        // reached native draw, not while its deferred notifications are pending.
        await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
        var view=(SignedView)typeof(OperationsPanel).GetField("view",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(ops)!;int writes=0,themeChanges=0;void Themed()=>themeChanges++;field.ThemeChanged+=Themed;app.ActiveStore.DurabilityBoundary=_=>writes++;
        using(var socket=new System.Net.Sockets.TcpClient()) {
            using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),limit.Token);Check(JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!["ready"]!.GetValue<bool>(),"named history rebuild write sync measurement starts");
            for(int i=0;i<3;i++){var ready=new TaskCompletionSource();void Project(JsonNode _)=>ready.TrySetResult();view.Projection+=Project;try{await view.Renew();await ready.Task.WaitAsync(limit.Token);}finally{view.Projection-=Project;}}
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),limit.Token);var cost=JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!;await File.WriteAllTextAsync("/work/unchanged-work.json",cost.ToJsonString());
            await File.WriteAllTextAsync("/work/unchanged-native.json",JsonSerializer.Serialize(new{writes,themeChanges,sameStyle=ReferenceEquals(style,button.GetThemeStylebox("normal"))}));
            Check(cost["work"]!["calls"]!.AsArray().Count==0&&writes==0&&themeChanges==0&&ReferenceEquals(style,button.GetThemeStylebox("normal")),"unchanged signed renewals reuse themes controls and projections with zero named history rebuild write sync work");
        }
        app.ActiveStore.DurabilityBoundary=null;field.ThemeChanged-=Themed;
        var surface=form.GetChildren().OfType<PanelContainer>().Single();var panelStyle=(StyleBoxFlat)surface.GetThemeStylebox("panel");
        Check(Mathf.IsEqualApprox(panelStyle.BgColor.A,.6f)&&field.GetThemeColor("font_color").A==1&&((StyleBoxFlat)field.GetThemeStylebox("normal")).BgColor.A==1,"authored permille affects only the panel background");
        gui.Opaque(true);Check(panelStyle.BgColor.A==1&&ReferenceEquals(field,form.Input("run_name")),"local Opaque preference overrides authored transparency without rebuilding");gui.Opaque(false);
        int presses=0;void Applied()=>presses++;button.Pressed+=Applied;await Reveal(button);gui.Move(button.GetGlobalRect().GetCenter());gui.Press();int cancellations=gui.Cancellations;
        string resized=changed.Replace("token(spacing,18)","token(spacing,24)");await Commit("transaction((retract((attribute(instrument_settings,appearance,_) :- true)),assertz((attribute(instrument_settings,appearance,"+resized+") :- true)))).");
        await Until(()=>ops.Available&&ops.Current?.Form.Tree.Properties.GetValueOrDefault("appearance")?.ToString()==Term.Parse(resized).ToString());gui.Release();button.Pressed-=Applied;
        Check(gui.Cancellations==cancellations+1&&gui.Captures==0&&presses==0&&ops.LastOutcome==null,"appearance geometry change cancels an existing native capture without submitting");
        var geometry=new List<object>();
        foreach(var mode in new[]{(true,1200,26),(true,1200,48),(false,560,26)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.Surface.GuiEmbedSubwindows=true;gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Frame();
            foreach(var control in new Control[]{field,button}){await Reveal(control);geometry.Add(new{mode,role=control.GetMeta("role").AsString(),rect=control.GetGlobalRect().ToString(),clip=Clip(control).ToString()});Check(Clip(control).Encloses(control.GetGlobalRect()),"authored appearance target remains reachable at "+mode);}
            Check(field.GetThemeFontSize("font_size")==mode.Item3,"local text size has precedence over authored appearance at "+mode);
            await Click(field);Check(field.HasFocus()&&field.Text=="Local sweep","native field focus retains exact local draft at "+mode);
            if(mode.Item1)Check(keyboard.Visible&&Clip(field).Encloses(field.GetGlobalRect()),"active field stays visible with the existing adjacent keyboard at "+mode);
            Check(mode.Item1||((StyleBoxFlat)surface.GetThemeStylebox("panel")).BgColor.A==1,"ordinary desktop panels remain opaque");await Raster("instrument-"+mode.Item2+"-"+mode.Item3);
        }
        await File.WriteAllTextAsync("/work/geometry.json",JsonSerializer.Serialize(geometry));
        await AppearanceValidation(session,human,tools);
        await RefusalAndIndependent();
    }
    async Task AppearanceLensDependency()
    {
        var pane=(EidolonPanel)app.FindChild("representations",true,false);var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        pane.Open(session,app.ActiveAccounts,app.ActiveStore,human.Ontology);await Until(()=>pane.Available);
        var choice=pane.Offered.Single(e=>e.Purpose.Name=="inspection"&&e.Style=="policy");
        pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==choice.Exact.ToString()).EmitSignal(BaseButton.SignalName.Pressed);
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);var form=(FormPanel)source.FindChild("source-form",true,false);
        await Until(()=>source.Content.Length>0&&!source.IsWorking);var editor=(TextEdit)form.Input("source")!;string before=source.Content;
        var version=typeof(SourcePanel).GetField("sourceVersion",BindingFlags.Instance|BindingFlags.NonPublic)!;string initialVersion=(string)version.GetValue(source)!;
        var view=(SignedView)typeof(EidolonPanel).GetField("representation",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(pane)!;
        var accepted=new TaskCompletionSource();void Changed(JsonNode _)=>accepted.TrySetResult();view.Projection+=Changed;
        try {
            using var client=new System.Net.Sockets.TcpClient();using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await client.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);
            using var stream=client.GetStream();using var reader=new System.IO.StreamReader(stream);await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"appearance_lens_rows\":true}\n"),limit.Token);
            Check(JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!["lens_rows_changed"]!.GetValue<bool>(),"ordinary authorized recipe computation change commits without changing the inspected target");
            await accepted.Task.WaitAsync(TimeSpan.FromSeconds(60));await Until(()=>!source.IsWorking&&source.Content.Length>0);
        }finally{view.Projection-=Changed;}
        bool sameTarget=(string)version.GetValue(source)! == initialVersion;
        await File.WriteAllTextAsync("/work/lens-dependency.json",JsonSerializer.Serialize(new{sameTargetVersion=sameTarget,sameEditor=ReferenceEquals(editor,form.Input("source")),sameText=source.Content==before,expected=source.Content=="% revised inspection lens\n",reads=source.SnapshotReads}));
        Check(sameTarget&&source.Content=="% revised inspection lens\n","accepted authored recipe computation change updates readonly inspection despite unchanged target source version");
        Check(ReferenceEquals(editor,form.Input("source"))&&!source.CanEdit&&!editor.Editable&&!app.ActiveStore.Snapshot!.SourceDrafts.Any()&&!app.ActiveStore.Snapshot.Pending.Any(),"computed inspection refresh retains its native readonly editor without drafts or domain instructions");
    }
    async Task AppearanceInspection()
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var pane=(EidolonPanel)app.FindChild("representations",true,false);var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        xr.PresentWorkspace(true);gui.Surface.GuiEmbedSubwindows=true;
        async Task Click(Control c){var ready=new TaskCompletionSource();SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>ready.TrySetResult());await ready.Task.WaitAsync(TimeSpan.FromSeconds(60));await Frame();gui.Move(c.GetGlobalRect().GetCenter());await Frame();gui.Press();await Frame();gui.Release();await Frame();}
        async Task<JsonNode> Command(string command){using var client=new System.Net.Sockets.TcpClient();using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await client.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);using var stream=client.GetStream();using var reader=new System.IO.StreamReader(stream);await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes(command+"\n"),limit.Token);return JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!;}
        pane.Open(session,app.ActiveAccounts,app.ActiveStore,human.Ontology);await Until(()=>pane.Available);
        var choice=pane.Offered.Single(e=>e.Purpose.Name=="inspection"&&e.Style=="policy");await Click(pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==choice.Exact.ToString()));
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);var form=(FormPanel)source.FindChild("source-form",true,false);
        await Until(()=>source.Visible&&source.Content.Length>0);var editor=(TextEdit)form.Input("source")!;await Click(editor);editor.Select(0,0,0,3);
        string text=editor.Text;int reads=source.SnapshotReads;
        using(var client=new System.Net.Sockets.TcpClient()) {
            using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await client.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);using var stream=client.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"appearance_workspace\":true}\n"),limit.Token);Check(JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!["appearance_changed"]!.GetValue<bool>(),"ordinary authored workspace token update reaches the inspection owner");
        }
        await Until(()=>!source.IsWorking&&source.Content.Length>0&&form.Descriptor.Tree.Properties.GetValueOrDefault("appearance")?.Name=="appearance");
        await File.WriteAllTextAsync("/work/inspection-appearance.json",JsonSerializer.Serialize(new{sameEditor=ReferenceEquals(editor,form.Input("source")),sameText=source.Content==text,readsBefore=reads,readsAfter=source.SnapshotReads,editorAlive=GodotObject.IsInstanceValid(editor),selection=GodotObject.IsInstanceValid(editor)&&editor.HasSelection(),editable=source.CanEdit}));
        Check(ReferenceEquals(editor,form.Input("source"))&&source.Content==text&&editor.HasSelection(),"appearance-only inspection refresh retains its exact native editor text and selection");
        Check(source.SnapshotReads==reads+1&&!source.CanEdit&&!editor.Editable,"computed inspection re-evaluates once under current authority and remains readonly");
        Check(!app.ActiveStore.Snapshot!.SourceDrafts.Any()&&!app.ActiveStore.Snapshot.Pending.Any(),"readonly appearance creates no local source draft or domain instruction");
        foreach(var mode in new[]{(true,1200,26),(true,1200,48),(false,560,26)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Click(editor);
            var clip=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=editor.GetParent();n!=null;n=n.GetParent())if(n is Control c&&c.ClipContents)clip=clip.Intersection(c.GetGlobalRect());
            Check(clip.Encloses(editor.GetGlobalRect())&&editor.HasFocus()&&editor.Text==text&&!editor.Editable,"readonly appearance editor remains natively reachable with exact text at "+mode);
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/inspection-"+mode.Item2+"-"+mode.Item3+".png")==Error.Ok,"actual native inspection appearance raster retained");
        }
        await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
        int repeatedReads=source.SnapshotReads,writes=0,textChanges=0;var style=editor.GetThemeStylebox("normal");void Edited()=>textChanges++;editor.TextChanged+=Edited;
        app.ActiveStore.DurabilityBoundary=_=>writes++;
        try {
            using var client=new System.Net.Sockets.TcpClient();using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await client.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);
            using var stream=client.GetStream();using var reader=new System.IO.StreamReader(stream);await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),limit.Token);
            Check(JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!["ready"]!.GetValue<bool>(),"computed inspection named history rebuild write sync observer is installed");
            var view=(SignedView)typeof(EidolonPanel).GetField("representation",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(pane)!;
            var accepted=new TaskCompletionSource();void Projected(JsonNode _)=>accepted.TrySetResult();view.Projection+=Projected;
            try{await view.Renew();await accepted.Task.WaitAsync(limit.Token);await Until(()=>!source.IsWorking&&source.Content.Length>0);}finally{view.Projection-=Projected;}
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),limit.Token);var work=JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!;
            await File.WriteAllTextAsync("/work/inspection-unchanged-work.json",JsonSerializer.Serialize(new{work,readsBefore=repeatedReads,readsAfter=source.SnapshotReads,writes,textChanges,sameStyle=ReferenceEquals(style,editor.GetThemeStylebox("normal"))}));
            Check(work["work"]!["calls"]!.AsArray().Count==0&&writes==0&&textChanges==0&&ReferenceEquals(style,editor.GetThemeStylebox("normal")),"accepted computed inspection renewal performs no history rebuild disk write sync native text replacement or style acquisition");
            Check(source.SnapshotReads==repeatedReads+1&&editor.Text==text&&!editor.Editable,"one necessary authored computation refresh preserves the exact readonly native text");
        }finally{app.ActiveStore.DurabilityBoundary=null;editor.TextChanged-=Edited;}
        int targetReads=source.SnapshotReads;
        Check(Json.Committed(await session.Execute(human,"assertz((attribute(me,inspection_observed_change,true) :- true)).","appearance-fixture",CancellationToken.None)),"an actual inspection target source change commits normally");
        await Until(()=>source.SnapshotReads>targetReads&&!source.IsWorking&&source.Content.Length>0);
        Check(ReferenceEquals(editor,form.Input("source"))&&source.Content==text&&!source.CanEdit,"changed source dependency rereads the readonly lens without replacing its native editor");
        await Command("{\"source_access\":\"deny\"}");await Until(()=>source.Content.Length==0&&!form.IsVisibleInTree());
        Check(!source.CanEdit&&editor.Text.Length==0&&State["world_accepted"]!.GetValue<bool>(),"inspection denial clears retained source while the independent world remains accepted");
    }
    async Task AppearanceQuestion()
    {
        await Until(()=>State["question_receiver_ready"]?.GetValue<bool>()==true);
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;var setup=app.ActiveAccounts.Setup!.Require("account",6);
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        xr.PresentWorkspace(true);gui.Surface.GuiEmbedSubwindows=true;
        string reference=Term.Call("form_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom("appearance_question")).ToString();
        string blue="appearance(1,[token(accent,rgb(80,200,240)),token(panel,rgb(40,24,60)),token(padding,16)])";
        string green="appearance(1,[token(accent,rgb(100,220,160)),token(panel,rgb(26,50,40)),token(padding,16)])";
        string[] declarations=[
            "instance_of(quod:gui:form,appearance_question)","instance_of(quod:gui:text_box,answer)","instance_of(quod:gui:selection,mode)","instance_of(quod:gui:button,apply_answer)",
            "gui_children(appearance_question,[answer,mode,apply_answer])","attribute(appearance_question,label,<<\"Measurement request\">>)",
            "attribute(appearance_question,help,<<\"Choose a mode and answer this request once.\">>)","attribute(answer,label,<<\"Run name\">>)",
            "attribute(mode,label,<<\"Measurement mode\">>)","attribute(mode,options,[option(a,<<\"Survey\">>),option(b,<<\"Detailed measurement\">>)])",
            "attribute(apply_answer,label,<<\"Send answer\">>)","attribute(appearance_question,appearance,"+blue+")",
            "gui_initial(appearance_question,answer,<<\"Original\">>)",
            "gui_form(appearance_question,[field(answer,Answer),field(mode,Mode)],submit(apply_answer,assertz(appearance_answer(Answer,Mode))))",
            $"gui_question_policy(appearance_question,{setup[0]},{setup[1]})",$"gui_responder_policy(personal,{reference},{setup[0]})",
            "gui_pending_allowance(personal,4)","gui_completion_allowance(personal,300000)"
        ];
        using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(180));
        async Task Commit(string goal){Check(Json.Committed(await ExecuteComplete(session,app.ActiveStore,human,goal,limit.Token)),"explicit authored question fixture transaction commits");}
        async Task Reveal(Control c){var ready=new TaskCompletionSource();SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>ready.TrySetResult());await ready.Task.WaitAsync(limit.Token);await Frame();}
        async Task Pixel(Vector2 p){gui.Move(p);await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();}
        async Task Click(Control c){await Reveal(c);await Pixel(c.GetGlobalRect().GetCenter());}
        IEnumerable<Node> Descendants(Node node){foreach(var child in node.GetChildren(true)){yield return child;foreach(var item in Descendants(child))yield return item;}}
        await Commit("transaction(("+string.Join(",",declarations.Select(c=>"assertz(("+c+" :- true))"))+" )).");
        await Commit("gui_open(appearance_question,Reference).");
        QuestionPanel? question=null;await Until(()=>{question=FindQuestion(app);return question?.Available==true;});
        var form=question!.FormPanel;var field=(LineEdit)form.Input("answer")!;var button=(Button)form.Input("apply_answer")!;var choice=(OptionButton)form.Input("mode")!;
        var current=typeof(QuestionPanel).GetField("current",BindingFlags.Instance|BindingFlags.NonPublic)!;
        var original=(QuestionDescriptor)current.GetValue(question)!;var draft=form.Draft;var style=button.GetThemeStylebox("normal");
        await Click(field);field.SelectAll();foreach(char c in "Retained answer"){gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=true},true);gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=false},true);}await Frame();field.Select(1,4);field.CaretColumn=4;
        await Commit("transaction((retract((attribute(appearance_question,appearance,_) :- true)),assertz((attribute(appearance_question,appearance,"+green+") :- true)))).");
        await Until(()=>question.Available&&form.Descriptor.Tree.Properties.GetValueOrDefault("appearance")?.ToString()==Term.Parse(green).ToString());
        var renewed=(QuestionDescriptor)current.GetValue(question)!;
        Check(ReferenceEquals(field,form.Input("answer"))&&ReferenceEquals(choice,form.Input("mode"))&&ReferenceEquals(draft,form.Draft)&&ReferenceEquals(style,button.GetThemeStylebox("normal")),"question appearance refresh preserves native controls draft and style resource");
        Check(field.Text=="Retained answer"&&field.CaretColumn==4&&field.HasSelection()&&field.GetSelectionFromColumn()==1&&field.GetSelectionToColumn()==4,"question refresh retains dirty native text selection and caret");
        Check(renewed.Opened.ToString()==original.Opened.ToString()&&renewed.Revision.ToString()==original.Revision.ToString()&&renewed.Interaction=="editable"&&renewed.Form.Submit.ToString()==original.Form.Submit.ToString(),"appearance does not stale or replace the original deferred question contract");
        Check(((StyleBoxFlat)style).BgColor.IsEqualApprox(new Color(100/255f,220/255f,160/255f))&&!field.HasFocus(),"question colour applies while existing withdrawal revokes focus");
        var geometry=new List<object>();
        foreach(var mode in new[]{(true,1200,26),(true,1200,48),(false,560,26)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.Surface.GuiEmbedSubwindows=true;gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();
            foreach(var control in new Control[]{field,choice,button}) {
                await Reveal(control);var clip=new Rect2(Vector2.Zero,gui.Surface.Size);var ancestors=new List<object>();
                for(Node? n=control.GetParent();n!=null;n=n.GetParent())if(n is Control c){ancestors.Add(new{kind=c.GetClass(),rect=c.GetGlobalRect().ToString(),minimum=c.GetCombinedMinimumSize().ToString(),c.ClipContents});if(c.ClipContents)clip=clip.Intersection(c.GetGlobalRect());}
                geometry.Add(new{mode,role=control.GetMeta("role").AsString(),rect=control.GetGlobalRect().ToString(),clip=clip.ToString(),ancestors});await File.WriteAllTextAsync("/work/question-geometry.json",JsonSerializer.Serialize(geometry));
                Check(clip.Encloses(control.GetGlobalRect()),"authored question target enclosed in every actual clipping ancestor at "+mode);
            }
            int index=choice.Selected==0 ? 1 : 0,hits=0;void Chosen(long i){if(i==index)hits++;}choice.ItemSelected+=Chosen;
            try {
                await Click(choice);var popup=choice.GetPopup();
                Check(popup.Visible&&new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(new Rect2(popup.Position,popup.Size)),"authored native popup is enclosed in the current surface at "+mode);
                Check(((StyleBoxFlat)popup.GetThemeStylebox("panel")).BgColor.A==1&&popup.GetThemeColor("font_color").A==1,"popup foreground and background remain opaque");
                popup.ScrollToItem(index);await Frame();var scroll=Descendants(popup).OfType<ScrollContainer>().Single(v=>v.IsVisibleInTree());var items=scroll.GetChildren(true).OfType<Control>().Single(v=>v.GetClass()=="PopupMenuItems");
                int font=popup.GetThemeFontSize("font_size","PopupMenu"),gap=popup.GetThemeConstant("v_separation","PopupMenu");float h=Math.Max(popup.GetThemeFont("font","PopupMenu").GetHeight(font),popup.GetThemeIcon("radio_checked","PopupMenu").GetHeight());
                await Pixel((Vector2)popup.Position+items.GlobalPosition+new Vector2(60,index*(h+gap)+gap+h/2));
                Check(hits==1&&choice.Selected==index&&!popup.Visible&&field.Text=="Retained answer","native popup selects the exact changed item once without disturbing the text draft");
            } finally {choice.ItemSelected-=Chosen;}
            await Reveal(button);await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/question-"+mode.Item2+"-"+mode.Item3+".png")==Error.Ok,"current native authored question raster retained");
        }
        string selected=choice.Selected==0 ? "a" : "b";
        var before=await session.Read(human,"findall(answer(Text,Mode),appearance_answer(Text,Mode),Answers).",limit.Token);
        Check(Json.Binding(before,"Answers").Items.Length==0,"appearance and local choices send no question answer or continuation");
        int presses=0;void Pressed()=>presses++;button.Pressed+=Pressed;await Click(button);button.Pressed-=Pressed;
        Check(presses==1,"one native explicit answer action reaches the original question owner");
        await Until(()=>FindQuestion(app)==null);await app.ActiveAccounts.Resolve(limit.Token);
        var after=await session.Read(human,"findall(answer(Text,Mode),appearance_answer(Text,Mode),Answers).",limit.Token);
        Check(Json.Binding(after,"Answers").ToString()=="[answer(<<\"Retained answer\">>,"+selected+")]"&&!app.ActiveAccounts.Uncertain,"the original question continuation commits exactly once with the preserved dirty values");
    }
    async Task AppearanceValidation(SignedSession session,Actor human,Actor tools)
    {
        string Raw(string appearance)=>"component(probe,[form],[attribute(label,<<\"Palette probe\">>),attribute(appearance,"+appearance+")],[])";
        string Native(string appearance)=>"component(probe,form,[property(label,<<\"Palette probe\">>),property(appearance,"+appearance+")],[])";
        var valid=Term.Parse("appearance(1,[token(accent,rgb(80,200,240)),token(panel_opacity,650),token(padding,16)])");
        var old=Component.Decode(Term.Parse("component(probe,form,[property(label,<<\"Palette probe\">>)],[])"));
        Check(old.Semantic.ToString()==Component.Decode(Term.Parse(Native(valid.ToString()))).Semantic.ToString(),"semantic component identity excludes only authored appearance");
        foreach(string appearance in new[]{"appearance(2,[])","appearance(1,[token(accent,rgb(1,2,300))])","appearance(1,[token(panel_opacity,1001)])","appearance(1,[token(css,<<\"color:red\">>)])","appearance(1,[token(spacing,1),token(spacing,2)])","appearance(1,[token(padding,-1)])"}) {
            bool refused=false;try{Component.Decode(Term.Parse(Native(appearance)));}catch(FormatException){refused=true;}Check(refused,"native parser refuses malformed unsupported or ambiguous appearance");
            var reply=await session.Read(human,SignedSession.ViewGoal(tools,Term.Parse("gui_tree_schema("+Raw(appearance)+",Tree,Inputs)")),CancellationToken.None);
            Check(reply["result"]?.ToString()=="fail","the signed anchored vocabulary refuses the same invalid appearance");
        }
        var wrong=tools with{Anchor=Identity.Encode(new byte[32])};
        var denied=await session.Read(human,SignedSession.ViewGoal(wrong,Term.Parse("gui_tree_schema("+Raw(valid.ToString())+",Tree,Inputs)")),CancellationToken.None);
        Check(denied["result"]?.ToString()!="ok","wrong anchored appearance vocabulary cannot supply a native descriptor");
    }
    async Task AppearanceWorkspaces()
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var pane=(EidolonPanel)app.FindChild("representations",true,false);var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        xr.PresentWorkspace(true);gui.Surface.GuiEmbedSubwindows=true;
        async Task Reveal(Control c){var ready=new TaskCompletionSource();SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>ready.TrySetResult());await ready.Task.WaitAsync(TimeSpan.FromSeconds(60));await Frame();}
        async Task Click(Control c){await Reveal(c);gui.Move(c.GetGlobalRect().GetCenter());await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();}
        async Task<JsonNode> Command(string command){using var client=new System.Net.Sockets.TcpClient();using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await client.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);using var stream=client.GetStream();using var reader=new System.IO.StreamReader(stream);await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes(command+"\n"),limit.Token);return JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!;}
        pane.Open(session,app.ActiveAccounts,app.ActiveStore,human.Ontology);await Until(()=>pane.Available);
        var choice=pane.Offered.Single(e=>e.Style=="workbench");await Click(pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==choice.Exact.ToString()));
        var graph=(WorkbenchPanel)pane.FindChild("ontology-workbench",true,false);var source=(SourcePanel)pane.FindChild("source-tools",true,false);var scene=(ScenePanel)pane.FindChild("representation-scene",true,false);
        await Until(()=>graph.Visible&&source.CanEdit&&source.Content.Length>0);
        var graphForm=(FormPanel)graph.FindChild("workbench-form",true,false);var sourceForm=(FormPanel)source.FindChild("source-form",true,false);
        await Click(graphForm.Input("show_source")!);var editor=(TextEdit)sourceForm.Input("source")!;await Click(editor);
        editor.SetCaretLine(editor.GetLineCount()-1);editor.SetCaretColumn(editor.GetLine(editor.GetLineCount()-1).Length);
        foreach(char c in "\n% local appearance draft\n"){gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=true},true);gui.Surface.PushInput(new InputEventKey{Unicode=c,Pressed=false},true);}await Frame();
        Check(source.Content.Contains("local appearance draft")&&app.ActiveStore.Snapshot!.SourceDrafts.Count>0,"ordinary native source editing creates its existing durable local draft");
        editor.Select(0,0,0,3);int line=editor.GetCaretLine(),column=editor.GetCaretColumn();var sourceText=editor.Text;var drafts=app.ActiveStore.Snapshot!.SourceDrafts.ToDictionary(p=>p.Key,p=>p.Value);
        var nodes=graphForm.Input("node");int reads=source.SnapshotReads,updates=graph.Updates,rebuilt=scene.Rebuilt;
        var representation=(SignedView)typeof(EidolonPanel).GetField("representation",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(pane)!;
        var records=new List<object>();void Projection(JsonNode value)=>records.Add(new{height=value["height"]?.ToString(),dependencies=value["dependencies"]?.ToString()});representation.Projection+=Projection;
        int suspended=0;bool suspensionSafe=true;void Withdrawn(string reason){if(!representation.Updating)return;suspended++;suspensionSafe&=!graph.Visible&&!scene.Visible&&!source.CanEdit&&source.Content.Length==0&&scene.Pick(new Vector2(100,100))==null;}representation.Withdrawn+=Withdrawn;
        var reply=await Command("{\"appearance_workspace\":true}");Check(reply["appearance_changed"]!.GetValue<bool>(),"ordinary signed administrator source edit changes the fresh fixture workspace appearance");
        await Until(()=>source.CanEdit&&sourceForm.Descriptor.Tree.Properties.GetValueOrDefault("appearance")?.Name=="appearance"&&graphForm.Descriptor.Tree.Properties.GetValueOrDefault("appearance")?.Name=="appearance");
        representation.Projection-=Projection;representation.Withdrawn-=Withdrawn;
        await File.WriteAllTextAsync("/work/workspace-appearance.json",JsonSerializer.Serialize(new{readsBefore=reads,readsAfter=source.SnapshotReads,updatesBefore=updates,updatesAfter=graph.Updates,rebuiltBefore=rebuilt,rebuiltAfter=scene.Rebuilt,editorSame=ReferenceEquals(editor,sourceForm.Input("source")),nodesSame=ReferenceEquals(nodes,graphForm.Input("node")),textSame=source.Content==sourceText,caretLine=editor.GetCaretLine(),caretColumn=editor.GetCaretColumn(),selection=editor.HasSelection(),records}));
        Check(source.SnapshotReads==reads&&graph.Updates==updates&&scene.Rebuilt==rebuilt,"appearance-only workspace update reacquires no unchanged source snapshot graph or scene");
        Check(suspended>0&&suspensionSafe,"every observed updating interval withdraws interaction visibility source access and scene picking");
        Check(ReferenceEquals(editor,sourceForm.Input("source"))&&ReferenceEquals(nodes,graphForm.Input("node"))&&source.Content==sourceText&&editor.GetCaretLine()==line&&editor.GetCaretColumn()==column&&editor.HasSelection(),"signed workbench appearance retains same dirty native editor selection caret and catalogues");
        Check(drafts.Count==app.ActiveStore.Snapshot!.SourceDrafts.Count&&drafts.All(p=>app.ActiveStore.Snapshot.SourceDrafts[p.Key]==p.Value)&&!app.ActiveStore.Snapshot.Pending.Any(),"appearance update preserves exact durable source drafts without a signed edit");
        Check(Json.Committed(await session.Execute(human,"assertz((attribute(me,appearance_observed_change,<<\"actual committed change\">>) :- true)).","appearance-fixture",CancellationToken.None)),"an actual target source change commits through the original signed owner");
        await Until(()=>source.CanEdit&&source.SnapshotReads>reads&&source.Status.Contains("Saved source changed"));
        Check(source.Content==sourceText&&app.ActiveStore.Snapshot!.SourceDrafts.Values.Any(d=>d.Text==sourceText),"changed committed dependency refreshes the baseline comparison without discarding the original dirty draft");
        await Reveal(editor);await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using(var image=gui.Surface.GetTexture().GetImage())Check(image.SavePng("/work/workspace-appearance.png")==Error.Ok,"actual authored workbench source appearance raster retained");
        await Command("{\"source_access\":\"deny\"}");await Until(()=>!graph.Visible&&!source.CanEdit&&source.Content.Length==0);
        Check(!sourceForm.IsVisibleInTree()||!editor.IsVisibleInTree()||editor.Text.Length==0,"denied appearance owner withdraws source data from the visible native surface");
        Check(State["world_accepted"]!.GetValue<bool>(),"selected source denial preserves the independent current world");
    }
}
