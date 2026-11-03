using Godot;
using Quod.Client;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task WorkbenchUsability()
    {
        // Setup is existing software fixture dispatch; the qualified workbench
        // gestures below go through the real native controls, never host input.
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true);
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var xr=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var pane=(EidolonPanel)app.FindChild("representations",true,false);
        var graph=(WorkbenchPanel)pane.FindChild("ontology-workbench",true,false);
        var source=(SourcePanel)pane.FindChild("source-tools",true,false);
        var scene=(ScenePanel)pane.FindChild("representation-scene",true,false);
        var session=app.ActiveSession;var human=app.ActiveAccounts.Human!;
        var tools=app.ActiveAccounts.Catalogue.Single(a=>a.Namespace=="quod:gui");
        xr.PresentWorkspace(true);gui.Surface.GuiEmbedSubwindows=true;gui.TextSize(26-gui.Appearance.DefaultFontSize);await Frame();await Frame();
        Rect2 Clip(Control c){var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        async Task Reveal(Control c){var ready=new TaskCompletionSource();SpatialGui.Reveal(c,()=>GodotObject.IsInstanceValid(c),()=>ready.TrySetResult());await ready.Task.WaitAsync(TimeSpan.FromSeconds(60));await Frame();}
        async Task Pixel(Vector2 p){gui.Move(p);await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();Check(gui.Captures==0,"native pointer releases the actual capture");}
        async Task Click(Control c){await Reveal(c);Check(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect())&&c is not BaseButton {Disabled:true},"current native target is enabled and enclosed: "+c.Name);int pressed=0;void Hit()=>pressed++;if(c is BaseButton b)b.Pressed+=Hit;try{await Pixel(c.GetGlobalRect().GetCenter());}finally{if(c is BaseButton b2)b2.Pressed-=Hit;}if(c is BaseButton)Check(pressed==1,"one native release activates its displayed button exactly once");}
        IEnumerable<Node> Descendants(Node n){foreach(var c in n.GetChildren(true)){yield return c;foreach(var d in Descendants(c))yield return d;}}
        async Task Select(OptionButton c,int index){int expected=c.Selected==index&&!c.AllowReselect ? 0 : 1;await Click(c);var popup=c.GetPopup();Check(popup.Visible&&new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(new Rect2(popup.Position,popup.Size)),"opened native catalogue fits the actual surface");popup.ScrollToItem(index);await Frame();var scroll=Descendants(popup).OfType<ScrollContainer>().Single(v=>v.IsVisibleInTree());var items=scroll.GetChildren(true).OfType<Control>().Single(v=>v.GetClass()=="PopupMenuItems");int font=popup.GetThemeFontSize("font_size","PopupMenu"),gap=popup.GetThemeConstant("v_separation","PopupMenu");float h=Math.Max(popup.GetThemeFont("font","PopupMenu").GetHeight(font),popup.GetThemeIcon("radio_checked","PopupMenu").GetHeight());int hits=0;void Chosen(long i){if(i==index)hits++;}c.ItemSelected+=Chosen;try{await Pixel((Vector2)popup.Position+items.GlobalPosition+new Vector2(60,index*(h+gap)+gap+h/2));}finally{c.ItemSelected-=Chosen;}Check(hits==expected&&c.Selected==index&&!popup.Visible,expected==1 ? "native catalogue selects a changed exact item once" : "native catalogue reselection retains the current item without a duplicate event");}
        async Task AuthoredLayout() {
            var surface=new SpatialGui();app.AddChild(surface);surface.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);surface.Size=new(1600,800);
            var margin=new MarginContainer();margin.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);surface.SetContent(margin);var authored=new FormPanel();margin.AddChild(authored);
            try {
                foreach(string layout in new[]{"row","grid","column"}) {
                    authored.Present(Form.Decode(Term.Parse("component(f,form,[property(label,<<\"Authored layout\">>),property(layout,"+layout+")],[component(first,text_box,[property(label,<<\"First\">>)],[]),component(apply,button,[property(label,<<\"Apply here\">>)],[]),component(last,text_box,[property(label,<<\"Last\">>)],[])])"),Term.Parse("[field(first,<<\"one\">>),field(last,<<\"two\">>)]"),Term.Atom("apply")));
                    await Frame();await Frame();var a=authored.Input("first")!.GetGlobalRect();var b=authored.Input("apply")!.GetGlobalRect();var c=authored.Input("last")!.GetGlobalRect();
                    Check(layout=="row" ? a.Position.X<b.Position.X&&b.Position.X<c.Position.X : a.Position.Y<b.Position.Y&&b.Position.Y<c.Position.Y,"shared action sizing retains explicit authored "+layout+" order");
                    Check(authored.Draft["first"]=="one"&&authored.Draft["last"]=="two","shared action sizing preserves authored field values at "+layout);
                }
            } finally {app.RemoveChild(surface);surface.QueueFree();await Frame();}
        }
        async Task Raster(string name){await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/"+name+".png")==Error.Ok,"actual native raster retained: "+name);}
        pane.Open(session,app.ActiveAccounts,app.ActiveStore,human.Ontology);await Until(()=>pane.Available);
        var choice=pane.Offered.Single(e=>e.Style=="workbench");
        await Click(pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==choice.Exact.ToString()));
        await Until(()=>graph.Visible&&source.CanEdit&&source.Content.Length>0);
        var form=(FormPanel)graph.FindChild("workbench-form",true,false);var sourceForm=(FormPanel)source.FindChild("source-form",true,false);
        var nodes=(OptionButton)form.Input("node")!;var facts=(OptionButton)form.Input("fact")!;
        var selected=Term.Call("class_ref",Term.Text(human.Namespace),Term.Binary(Identity.Decode(human.Anchor)),Term.Atom("space"));
        await Select(nodes,Enumerable.Range(1,nodes.ItemCount-1).Single(i=>nodes.GetItemTooltip(i)==selected.ToString()));
        await Select(facts,Enumerable.Range(1,facts.ItemCount-1).Single(i=>facts.GetItemTooltip(i)=="isa(space,thing)"));
        await Reveal(nodes);await Raster("inspection-baseline");
        var inspection=new {classField=form.Input("class_name")!.IsVisibleInTree(),attributeField=form.Input("attribute_name")!.IsVisibleInTree(),caption=facts.GetItemText(facts.Selected),exact=facts.GetItemTooltip(facts.Selected),details=form.Input("exact_details")?.IsVisibleInTree()==true};
        await File.WriteAllTextAsync("/work/inspection.json",JsonSerializer.Serialize(inspection));
        Check(!inspection.classField&&!inspection.attributeField&&inspection.caption!=inspection.exact&&inspection.details,"native inspection separates readable selected fact and exact details from unrequested class and attribute preparation fields");
        Check(graph.Selected!.ToString()==selected.ToString(),"inspection retains the exact anchored class identity");
        if(Env("M1B_PHASE")=="workbench-ux-access") {
            pane.Open(session,app.ActiveAccounts,app.ActiveStore,tools.Ontology);await Until(()=>pane.Available);
            var readOnlyChoice=pane.Offered.Single(e=>e.Style=="workbench");
            await Click(pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==readOnlyChoice.Exact.ToString()));
            await Until(()=>graph.Visible&&source.Content.Length>0&&!source.CanEdit);
            await Reveal(graph.FindChild("workbench-selection",true,false) as Control ?? graph);await Raster("read-only-inspection");
            var state=graph.FindChild("workbench-source-state",true,false) as Label;
            Check(state!=null&&state.IsVisibleInTree()&&state.Text==source.Status&&state.Text.Contains("read-only"),"read-only inspection explains the existing source owner's actual state alongside its disabled preparation actions");
            await Reveal(state!);Check(Clip(state!).Encloses(state!.GetGlobalRect()),"source state is reachable in its actual clipping viewport");
            await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"read-only consumers retire normally");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("WORKBENCH_UX_PASS");Console.Out.Flush();await app.CloseApplication();return;
        }
        if(Env("M1B_PHASE")=="workbench-ux-labels") {
            await Click(form.Input("new_attribute")!);
            foreach(var mode in new[]{(true,1200,26),(true,1200,48),(false,560,26)}) {
                GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Frame();
                var button=(Button)form.Input("add_attribute")!;await Reveal(button);await Raster("label-"+mode.Item2+"-"+mode.Item3);
                var font=button.GetThemeFont("font");int size=button.GetThemeFontSize("font_size");float border=button.GetThemeStylebox("normal").GetMinimumSize().X;
                float word=button.Text.Split(' ').Max(w=>font.GetStringSize(w,HorizontalAlignment.Left,-1,size).X);
                await File.AppendAllTextAsync("/work/word-bounds.jsonl",JsonSerializer.Serialize(new{mode,word,border,rect=button.GetGlobalRect().ToString(),clip=Clip(button).ToString(),width=button.Size.X})+"\n");
                Check(button.Size.X-border>=Math.Min(word,Clip(button).Size.X-border),"native action label preserves whole words when they fit its clipping viewport at "+mode);
                Check(Clip(button).Encloses(button.GetGlobalRect()),"readable action remains enclosed at "+mode);
            }
            await AuthoredLayout();
            await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"label consumers retire normally");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("WORKBENCH_UX_PASS");Console.Out.Flush();await app.CloseApplication();return;
        }
        if(Env("M1B_PHASE")=="workbench-ux-adapter") {
            var committedFacts=(Term[])typeof(WorkbenchPanel).GetField("facts",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(graph)!;
            var membership=committedFacts.First(f=>f.Name=="instance_of");
            int instanceIndex=Enumerable.Range(1,nodes.ItemCount-1).First(i=>{var s=Subject.Decode(Term.Parse(nodes.GetItemTooltip(i)));return s.Exact.Name=="entity_ref"&&s.Local.ToString()==membership.Args[1].ToString();});
            string instance=nodes.GetItemTooltip(instanceIndex);await Select(nodes,instanceIndex);await Select(facts,Enumerable.Range(1,facts.ItemCount-1).Single(i=>facts.GetItemTooltip(i)==membership.ToString()));
            Check(graph.Selected!.ToString()==instance&&facts.GetItemText(facts.Selected)==membership.Args[1]+" is a member of "+membership.Args[0],"native instance inspection preserves exact subject and membership fact while showing a readable caption");
            await Select(nodes,Enumerable.Range(1,nodes.ItemCount-1).Single(i=>nodes.GetItemTooltip(i)==selected.ToString()));
            await Select(facts,Enumerable.Range(1,facts.ItemCount-1).Single(i=>facts.GetItemTooltip(i)=="isa(space,thing)"));
            var representation=Json.Binding(await session.Read(human,SignedSession.ViewGoal(human,choice.Read(pane.Current!.Local)),CancellationToken.None),"View").Require("workbench",6);
            Term Readonly(Term value){var a=value.Require("component",4);var properties=a[2].Items.Select(p=>a[0].ToString()=="class_name"&&p.Args[0].Name=="readonly" ? Term.Call("property",Term.Atom("readonly"),Term.Atom("true")) : p);return Term.Call("component",a[0],a[1],Term.List(properties.ToArray()),Term.List(a[3].Items.Select(Readonly).ToArray()));}
            var originalEditor=sourceForm.Input("source");int adapterReads=source.SnapshotReads;var bytes=File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"));
            graph.Install(human,representation[3],Readonly(representation[4]));await Click(form.Input("new_class")!);
            var readonlyField=(LineEdit)form.Input("class_name")!;await Click(readonlyField);
            Check(!readonlyField.Editable&&!gui.TextEntryActive&&source.CanEdit,"authored readonly field stays readonly even when its signed source consumer permits editing");
            graph.Install(human,representation[3],representation[4]);await Frame();
            Check(((LineEdit)form.Input("class_name")!).Editable&&ReferenceEquals(originalEditor,sourceForm.Input("source"))&&adapterReads==source.SnapshotReads&&bytes.SequenceEqual(File.ReadAllBytes(System.IO.Path.Combine(profile,"active.json"))),"controls-only installation preserves the source editor and performs no source read or store write");
            await Until(()=>JsonSerializer.SerializeToNode(xr.Router.Status)!["available"]!.GetValue<bool>());
            Check(XRServer.GetTracker("head")==null&&!xr.Running,"software ray fixture starts without native XR or an existing head tracker");
            var head=new XRPositionalTracker {Name="head",Type=XRServer.TrackerType.Head};XRServer.AddTracker(head);head.SetPose("default",new(Basis.Identity,new(0,1.6f,0)),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
            XRControllerTracker Tracker(string name,XRPositionalTracker.TrackerHand hand){var t=new XRControllerTracker{Name=name,Type=XRServer.TrackerType.Controller,Profile="/interaction_profiles/htc/vive_controller",Hand=hand};t.SetInput("trigger_press",false);t.SetInput("trigger_value",0.0);t.SetInput("squeeze_press",false);t.SetInput("pad_press",false);t.SetInput("pad_touch",false);t.SetInput("pad_axes",Vector2.Zero);t.SetPose("aim",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);t.SetPose("grip",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);XRServer.AddTracker(t);return t;}
            var left=Tracker("workbench_left",XRPositionalTracker.TrackerHand.Left);var right=Tracker("workbench_right",XRPositionalTracker.TrackerHand.Right);ulong frame=0;
            void Advance()=>xr.Advance(++frame,true,true,true);
            try {
                xr.AttachSources();xr.PresentWorkspace(true);Advance();await Frame();await xr.Completion.WaitAsync(TimeSpan.FromSeconds(30));Advance();var origin=(Node3D)xr.FindChild("xr-origin",true,false);
                async Task Ray(Control control){await Reveal(control);Advance();var mesh=(QuadMesh)xr.GuiSurface.Mesh;var p=control.GetGlobalRect().GetCenter();var pixels=gui.Surface.Size;var hit=xr.GuiSurface.GlobalTransform*(mesh.CenterOffset+new Vector3((p.X/pixels.X-.5f)*mesh.Size.X,(.5f-p.Y/pixels.Y)*mesh.Size.Y,0));var pose=new Transform3D(xr.GuiSurface.GlobalBasis,hit+xr.GuiSurface.GlobalBasis.Z);left.SetPose("aim",origin.GlobalTransform.AffineInverse()*pose,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);Advance();left.SetInput("trigger_press",true);Advance();await Frame();left.SetInput("trigger_press",false);Advance();await Frame();await Frame();Advance();}
                foreach(int font in new[]{26,48}) {
                    gui.TextSize(font-gui.Appearance.DefaultFontSize);await Frame();await Frame();
                    if(!form.Input("class_name")!.IsVisibleInTree())await Click(form.Input("new_class")!);
                    var line=(LineEdit)form.Input("class_name")!;await Ray(line);Check(line.HasFocus()&&gui.TextEntryActive&&Clip(line).Encloses(line.GetGlobalRect()),"current signed mapping and injected ray focus the contextual class field at "+font);
                    line.CaretColumn=line.Text.Length;string old=line.Text;await Ray((Control)gui.FindChild("keyboard-char-98",true,false));
                    Check(line.Text==old+"b"&&form.Draft["class_name"]==line.Text&&gui.Captures==0,"same ray types once through current native field and draft at "+font);
                    await Ray(form.Input("cancel_edit")!);Check(!line.IsVisibleInTree()&&!gui.TextEntryActive&&gui.Captures==0,"mapped Back to inspection retires the local keyboard target at "+font);
                }
            } finally {xr.StopSession();await xr.Completion;XRServer.RemoveTracker(left);XRServer.RemoveTracker(right);XRServer.RemoveTracker(head);left.Dispose();right.Dispose();head.Dispose();}
            Check(xr.Subscriptions==0&&gui.Captures==0&&!xr.Running,"software ray source subscriptions and captures retire without a runtime session");
            await Press("disconnect");await app.ViewsDisposed;Check(SignedView.LiveSockets==0,"adapter signed consumers retire normally");
            await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("WORKBENCH_UX_PASS");Console.Out.Flush();await app.CloseApplication();return;
        }
        string before=await session.ReadSource(human,tools,human,CancellationToken.None);
        string location=State["current_location"]!.ToString();var draft=form.Draft;var field=form.Input("attribute_name")!;var editor=sourceForm.Input("source")!;
        async Task Type(string role,string text){var line=(LineEdit)form.Input(role)!;await Click(line);Check(line.HasFocus(),"native pointer focuses the actual preparation field");line.SelectAll();foreach(char character in text){gui.Surface.PushInput(new InputEventKey{Unicode=character,Pressed=true},true);gui.Surface.PushInput(new InputEventKey{Unicode=character,Pressed=false},true);}await Frame();Check(line.Text==text&&form.Draft[role]==text,"native text events reach the same local form draft");}
        await Click(form.Input("new_class")!);await Type("class_name","local_class");
        var parents=(OptionButton)form.Input("parent")!;await Select(parents,Enumerable.Range(1,parents.ItemCount-1).Single(i=>Subject.Decode(Term.Parse(parents.GetItemTooltip(i))).Local.Name=="thing"));
        Check(form.Input("class_name")!.IsVisibleInTree()&&!field.IsVisibleInTree()&&form.Input("add_class")!.IsVisibleInTree(),"new class presents its own fields and explicit local preparation");await Click(form.Input("cancel_edit")!);
        await Click(form.Input("exact_details")!);var exact=(Label)graph.FindChild("workbench-exact",true,false);await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);await File.WriteAllTextAsync("/work/details-destination.json",JsonSerializer.Serialize(new{visible=Clip(exact).Encloses(exact.GetGlobalRect()),rect=exact.GetGlobalRect().ToString(),clip=Clip(exact).ToString()}));await Reveal(exact);
        Check(exact.IsVisibleInTree()&&exact.Text.Contains(selected.ToString())&&exact.Text.Contains("isa(space,thing)")&&exact.Text.Contains("does not delete"),"explicit details retain exact anchored subject fact and no-cascade limit");await Click(form.Input("exact_details")!);
        await Click(form.Input("new_attribute")!);
        Check(field.IsVisibleInTree()&&!form.Input("class_name")!.IsVisibleInTree(),"attribute preparation exposes only its relevant existing fields");
        await Type("attribute_name","ux_note");await Type("attribute_value","hello");
        var keyboard=(Control)gui.FindChild("spatial-keyboard",true,false);Check(keyboard.IsVisibleInTree(),"native workbench field opens the existing spatial keyboard");
        await Click((Control)gui.FindChild("keyboard-char-97",true,false));
        Check(((LineEdit)form.Input("attribute_value")!).Text=="helloa"&&form.Draft["attribute_value"]=="helloa","existing keyboard edits the same workbench native draft");
        // A queued key cannot reach a field hidden by local task cancellation.
        var cancel=form.Input("cancel_edit")!;await Reveal(cancel);Check(Clip(cancel).Encloses(cancel.GetGlobalRect()),"native cancellation target is enclosed before queued-input check");
        var key=(Control)gui.FindChild("keyboard-char-122",true,false);gui.Move(key.GetGlobalRect().GetCenter());gui.Press();gui.Release();
        gui.Move(cancel.GetGlobalRect().GetCenter());gui.Press();gui.Release();await Frame();await Frame();
        string preserved=form.Draft["attribute_value"];
        Check(preserved=="helloa"&&!keyboard.IsVisibleInTree()&&!field.IsVisibleInTree()&&ReferenceEquals(draft,form.Draft),"native task cancellation revokes a queued key and retains the same draft");
        await Click(form.Input("new_attribute")!);Check(ReferenceEquals(field,form.Input("attribute_name"))&&form.Draft["attribute_value"]==preserved,"reopening preparation retains actual field and draft identity");
        await Type("attribute_value","hello");
        var geometries=new List<object>();
        foreach(var mode in new[]{(true,1200,26),(true,1200,48),(false,560,26)}) {
            GetTree().Root.Size=new(mode.Item2,800);xr.PresentWorkspace(mode.Item1);gui.Surface.GuiEmbedSubwindows=true;gui.TextSize(mode.Item3-gui.Appearance.DefaultFontSize);await Frame();await Frame();
            foreach(var role in new[]{"attribute_name","attribute_value","add_attribute","cancel_edit","show_source","exact_details"}){var c=form.Input(role)!;await Reveal(c);geometries.Add(new{mode,role,rect=c.GetGlobalRect().ToString(),clip=Clip(c).ToString()});Check(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect()),"current workbench target fits all clipping ancestors at "+mode+" "+role);}
            var preparedButton=(Button)form.Input("add_attribute")!;var nativeFont=preparedButton.GetThemeFont("font");int nativeSize=preparedButton.GetThemeFontSize("font_size");float edge=preparedButton.GetThemeStylebox("normal").GetMinimumSize().X;
            Check(preparedButton.Size.X-edge>=Math.Min(preparedButton.Text.Split(' ').Max(w=>nativeFont.GetStringSize(w,HorizontalAlignment.Left,-1,nativeSize).X),Clip(preparedButton).Size.X-edge),"contextual action label retains whole words at "+mode);
            await Click(field);Check(((LineEdit)field).HasFocus(),"native field remains focusable at "+mode);
            if(mode.Item1)Check(keyboard.IsVisibleInTree()&&Clip(field).Encloses(field.GetGlobalRect()),"keyboard leaves the active field visible at "+mode);
            await Click(form.Input("cancel_edit")!);await Select(nodes,nodes.Selected);await Select(facts,facts.Selected);
            await Reveal(nodes);await Raster("inspection-"+mode.Item2+"-"+mode.Item3);
            await Click(form.Input("new_attribute")!);await Reveal(form.Input("attribute_value")!);await Raster("preparation-"+mode.Item2+"-"+mode.Item3);
        }
        await File.WriteAllTextAsync("/work/geometry.json",JsonSerializer.Serialize(geometries));
        GetTree().Root.Size=new(1200,800);xr.PresentWorkspace(true);gui.TextSize(26-gui.Appearance.DefaultFontSize);await Frame();await Frame();
        int updates=graph.Updates,reads=source.SnapshotReads,rebuilt=scene.Rebuilt,writes=0;var view=typeof(EidolonPanel).GetField("representation",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(pane);app.ActiveStore.DurabilityBoundary=_=>writes++;
        using(var socket=new System.Net.Sockets.TcpClient()) {
            using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(30));await socket.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),limit.Token);using var stream=socket.GetStream();using var reader=new System.IO.StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),limit.Token);Check(JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!["ready"]!.GetValue<bool>(),"named unchanged history rebuild write sync observer installed");
            await Click(form.Input("cancel_edit")!);await Select(nodes,nodes.Selected);await Click(form.Input("new_attribute")!);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),limit.Token);var cost=JsonNode.Parse((await reader.ReadLineAsync(limit.Token))!)!;await File.WriteAllTextAsync("/work/unchanged-work.json",cost.ToJsonString());
            Check(cost["work"]!["calls"]!.AsArray().Count==0&&writes==0&&graph.Updates==updates&&source.SnapshotReads==reads&&scene.Rebuilt==rebuilt&&ReferenceEquals(view,typeof(EidolonPanel).GetField("representation",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(pane))&&ReferenceEquals(field,form.Input("attribute_name")),"local inspection and preparation reuse controls consumers source scene with zero named work");
        }
        app.ActiveStore.DurabilityBoundary=null;
        await Click(form.Input("add_attribute")!);await source.Completion;await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
        var run=sourceForm.Input("run")!;var status=(Label)source.FindChild("source-status",true,false);
        await Raster("prepared-destination");await File.WriteAllTextAsync("/work/prepared-destination.json",JsonSerializer.Serialize(new {source.Status,statusRect=status.GetGlobalRect().ToString(),run=run.GetGlobalRect().ToString(),statusClip=Clip(status).ToString(),runClip=Clip(run).ToString()}));
        Check(source.Visible&&source.Content.Contains("ux_note")&&Clip(run).Encloses(run.GetGlobalRect())&&Clip(status).Encloses(status.GetGlobalRect()),"ordinary preparation reveals the same draft status and Preview without a test reveal of its destination");
        var currentState=(Label)graph.FindChild("workbench-source-state",true,false);Check(currentState.Text==source.Status&&currentState.Text.Contains("local source draft"),"workbench preparation shows the same source owner's uncommitted state");
        Check(await session.ReadSource(human,tools,human,CancellationToken.None)==before&&!app.ActiveStore.Snapshot!.Pending.Any()&&State["current_location"]!.ToString()==location,"preparation remains local with no committed source movement or pending instruction");
        await Click(run);await source.Completion;Check(source.Status.Contains("Nothing committed")&&!((Button)sourceForm.Input("accept")!).Disabled,"Preview stages the existing proof and explicitly remains uncommitted");
        Check(currentState.Text==source.Status,"workbench preview state follows the original source consumer");
        await Click(sourceForm.Input("stop")!);await source.Completion;Check(source.CanEdit&&source.Content.Contains("ux_note")&&source.Status.Contains("cancelled"),"Cancel preview preserves the same local prepared draft");
        await Click(run);await source.Completion;await Click(sourceForm.Input("accept")!);await source.Completion;
        await Until(()=>pane.Available&&source.CanEdit&&graph.Visible);
        string saved=await session.ReadSource(human,tools,human,CancellationToken.None);
        Check(saved!=before&&saved.Contains("ux_note")&&saved.Contains("hello")&&!app.ActiveStore.Snapshot!.Pending.Any(),"explicit guarded Save commits and sibling source reads the exact change without replay");
        Check(currentState.Text==source.Status,"workbench commit message remains the original source owner's result");
        await Until(()=>((Term[])typeof(WorkbenchPanel).GetField("facts",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(graph)!).Any(f=>f.Name=="attribute"&&f.Args[1].Name=="ux_note"));
        await Click(form.Input("cancel_edit")!);await Select(nodes,Enumerable.Range(1,nodes.ItemCount-1).Single(i=>nodes.GetItemTooltip(i)==selected.ToString()));
        await Select(facts,Enumerable.Range(1,facts.ItemCount-1).Single(i=>facts.GetItemTooltip(i).Contains("ux_note")));
        Check(facts.GetItemText(facts.Selected)=="ux_note = hello"&&ReferenceEquals(editor,sourceForm.Input("source")),"committed graph caption and retained source editor describe the same exact fact");
        await Click(form.Input("edit_fact")!);Check(((LineEdit)field).Text=="ux_note"&&((LineEdit)form.Input("attribute_value")!).Text=="hello","selected fact opens its existing contextual replacement fields");await Click(form.Input("cancel_edit")!);
        var system=app.ActiveAccounts.Catalogue.Single(a=>a.Namespace=="quod:gui");pane.Open(session,app.ActiveAccounts,app.ActiveStore,system.Ontology);await Until(()=>pane.Available);var sysChoice=pane.Offered.Single(e=>e.Style=="workbench");
        await Click(pane.FindChildren("*","Button",true,false).OfType<Button>().Single(b=>b.TooltipText==sysChoice.Exact.ToString()));await Until(()=>graph.Visible&&source.Content.Length>0);
        Check(!source.CanEdit&&new[]{"new_class","new_attribute","edit_fact","remove_fact"}.All(r=>((Button)form.Input(r)!).Disabled),"system read-only workbench keeps inspection and disables preparation");
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0&&!xr.Running,"workbench consumers retire through ordinary disconnect without XR");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks}));Console.WriteLine("WORKBENCH_UX_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
