using Godot;
using Quod.Client;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task WorkspaceAdapter()
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        scene.Hide(); // Exercise the same layout visibility, without native XR.
        gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);
        var reports=new List<object>();
        foreach(var dimensions in new[]{new Vector2(1850,496),new Vector2(600,900)}) {
            gui.Size=dimensions;await Frame();await Frame();
            var target=(Button)app.FindChild("create-key",true,false);
            var rectangle=target.GetGlobalRect();
            var clip=target.GetViewport().GetVisibleRect();
            for(Node? parent=target.GetParent();parent!=null;parent=parent.GetParent())
                if(parent is Control control&&control.ClipContents)clip=clip.Intersection(control.GetGlobalRect());
            bool accessible=clip.Encloses(rectangle);
            reports.Add(new { pixels=new[]{gui.Surface.Size.X,gui.Surface.Size.Y},target=rectangle.ToString(),clip=clip.ToString(),accessible });
            await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { reports,checks }));
            Check(accessible,"the actual primary login action remains fully inside the shared workspace at "+dimensions);
        }
        gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);await Frame();await Frame();
        var desktopPixels=gui.Surface.Size;
        var body=(VBoxContainer)app.FindChild("body",true,false);
        var form=new FormPanel();body.AddChild(form);
        form.Present(Form.Decode(Term.Parse("component(f,form,[property(label,<<\"Retained draft\">>)],[component(note,text_box,[property(label,<<\"Note\">>)],[]),component(save,button,[property(label,<<\"Submit\">>)],[])])"),Term.Parse("[field(note,<<\"draft\">>)]"),Term.Atom("save")));
        var editor=(LineEdit)form.Input("note")!;editor.Text="unsent exact draft";
        editor.EmitSignal(LineEdit.SignalName.TextChanged,editor.Text);
        Check(form.Draft["note"]=="unsent exact draft","fixture delivers the native editor change into the existing form owner before measuring retention");
        var draft=form.Draft;ulong editorId=editor.GetInstanceId();int submits=0;form.Invoked+=_=>submits++;
        var actual=(OpenXRInput)app.FindChild("openxr-input",true,false);
        Check(actual.Router.Description.StartsWith("Saved mapping revision 0"),
            "the opening application installs local GUI-only Vive controls before sign-in");
        actual.PresentWorkspace(true);await Frame();await Frame();
        Check(gui.Surface.Size==new Vector2I(1200,800) && form.GetThemeDefaultFontSize()==26,"XR uses the actual shared controls with a readable-density layout profile");
        Check(!((Control)app.FindChild("location",true,false)).IsVisibleInTree() && !((Control)app.FindChild("controllers",true,false)).IsVisibleInTree() && ((Button)app.FindChild("create-key",true,false)).IsVisibleInTree() && ((Button)app.FindChild("create-key",true,false)).ThemeTypeVariation=="PrimaryAction","offline spatial presentation retains its required key action while collapsing raw identity/controller detail");
        var options=(Button)app.FindChild("connection-details",true,false);
        var busy=typeof(Main).GetField("busy",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!;
        var update=typeof(Main).GetMethod("UpdateButtons",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!;
        busy.SetValue(app,true);update.Invoke(app,null);
        Console.WriteLine($"M4_OPTIONS_TARGET text={options.Text} disabled={options.Disabled} flat={options.Flat} min={options.CustomMinimumSize} rect={options.GetGlobalRect()} visible={gui.Surface.GetVisibleRect()}");Console.Out.Flush();
        Check(options.Text=="Options" && !options.Disabled && !options.Flat && options.CustomMinimumSize.Y>=48 && gui.Surface.GetVisibleRect().Encloses(options.GetGlobalRect()),
            "the visible VR Options target remains available during a connection attempt");
        await NativePress(options);await Frame();
        var trust=(Button)app.FindChild("forget-node-key",true,false);
        Check(trust.Text=="Trust this server" && trust.IsVisibleInTree() && gui.Surface.GetVisibleRect().Encloses(trust.GetGlobalRect()),
            "Options reveals the explicit server-trust action within the VR workspace");
        await NativePress(options);busy.SetValue(app,false);update.Invoke(app,null);
        await Device("text_larger");await Frame();
        Check(form.Input("note")!.GetInstanceId()==editorId && ReferenceEquals(form.Draft,draft) && draft["note"]=="unsent exact draft" && form.GetThemeDefaultFontSize()==30,$"larger text preserves the actual control/draft: identity={form.Input("note")!.GetInstanceId()==editorId}, sameDraft={ReferenceEquals(form.Draft,draft)}, value={draft["note"]}, font={form.GetThemeDefaultFontSize()}");
        var desktopUpdate=scene.Viewport.RenderTargetUpdateMode;
        scene.Viewport.RenderTargetUpdateMode=SubViewport.UpdateMode.Always;
        await Device("workspace_hide");
        Check(!form.IsVisibleInTree() && !actual.WorkspaceVisible && submits==0,"Hide removes presentation without submitting or discarding the form");
        Check(scene.Viewport.RenderTargetUpdateMode==SubViewport.UpdateMode.Always,"hiding workspace controls preserves the independently active scene render target");
        scene.Viewport.RenderTargetUpdateMode=desktopUpdate;
        actual.ShowWorkspace();actual.PresentWorkspace(false);await Frame();await Frame();
        Check(gui.Surface.Size==desktopPixels && form.Input("note")!.GetInstanceId()==editorId && ReferenceEquals(form.Draft,draft) && form.IsVisibleInTree(),"leaving spatial presentation restores desktop size and the same working controls");

        actual.PresentWorkspace(true);await Press("import-backup");
        var backup=(Control)app.FindChild("backup-dialog",true,false);
        var backupPath=(LineEdit)backup.FindChild("backup-path",true,false);
        Check(backup.GetViewport()==gui.Surface && backup.IsVisibleInTree() && !((Control)app.FindChild("login-steps",true,false)).IsVisibleInTree(),
            "backup import replaces the login controls inside the same visible VR surface");
        var keyboard=(Control)gui.FindChild("spatial-keyboard",true,false);
        var shown=ToSignal(keyboard,CanvasItem.SignalName.VisibilityChanged);backupPath.GrabFocus();
        if(!keyboard.Visible)await shown;
        Check(gui.TextEntryActive,"the existing spatial keyboard can edit a backup path");
        await NativePress((Button)backup.FindChild("backup-close",true,false));await Frame();
        Check(!gui.TextEntryActive && ((Control)app.FindChild("login-steps",true,false)).IsVisibleInTree(),
            "closing backup releases text input and restores the retained sign-in controls");
        actual.PresentWorkspace(false);

        Check(XRServer.GetTracker("head")==null,"qualification owns an unused local head tracker identity");
        var head=new XRPositionalTracker { Name="head",Type=XRServer.TrackerType.Head };
        XRServer.AddTracker(head);
        var bytes=await File.ReadAllBytesAsync(Env("M4_MODEL"));
        var mapping=ControllerMapping.Decode(Term.Parse(await File.ReadAllTextAsync(Env("M4_MAPPING"))))!;
        using var models=new RenderModels((asset,cancellation)=>Task.FromResult(bytes));
        var adapter=new OpenXRInput();scene.Viewport.AddChild(adapter);
        bool fullMenu=false,formOpen=false;int dismissed=0;var pie=new PieMenu();gui.Surface.AddChild(pie);
        var full=QualificationPie(Enumerable.Range(1,8).Select(i=>(i,"Long authored wedge label "+i,i%3!=0)).ToArray());
        pie.Selected+=_=>{if(!fullMenu)adapter.ShowWorkspace();};
        adapter.Configure(scene,gui,models,()=>null,()=>form.IsVisibleInTree(),pie,_=>{
            pie.Open(gui.Surface.Size/2,300,"Reading…");pie.Present(fullMenu ? full : QualificationPie((1,"Show retained workspace",true)),"");return true;},
            ()=>{if(formOpen)dismissed++;return formOpen;});
        void PresentForm()=>form.Visible=adapter.WorkspaceVisible;
        adapter.Changed+=PresentForm;form.TreeExiting+=()=>adapter.Changed-=PresentForm;
        adapter.AttachSources();adapter.Install(mapping);adapter.PresentWorkspace(true);
        ulong frame=0;void Advance(bool focused=true,bool running=true,bool tracked=true)=>adapter.Advance(++frame,focused,running,tracked);
        Advance(tracked:false);
        Check(!adapter.GuiSurface.Visible,"a missing tracked head cannot invent an initial panel placement");
        void Head(Vector3 position,float yaw)=>head.SetPose("default",new(new Basis(Vector3.Up,yaw),position),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
        head.SetPose("default",new(Basis.FromEuler(new(.8f,.4f,.9f)),new(1.2f,1.4f,-.7f)),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);Advance(focused:false);
        Check(adapter.GuiSurface.Visible && adapter.DriveRequests==0,"a tracked visible XR session presents the workspace before input focus without dispatching travel");
        var workspace=(Control)app.FindChild("workspace-content",true,false).GetChild(0);
        workspace.Hide();Advance();
        Check(!adapter.GuiSurface.Visible,"an XR workspace with no visible application content shows no blank panel");
        workspace.Show();Advance();
        Check(adapter.GuiSurface.Visible,"visible application content restores the same XR workspace");
        var loginLogo=(TextureRect)app.FindChild("login-logo",true,false);
        Check(loginLogo.IsVisibleInTree() && loginLogo.Texture?.ResourcePath=="res://assets/quod-icon.png",
            "the first visible XR workspace contains the bundled Quod icon before sign-in or input focus");
        Advance();
        var openingHead=((Node3D)adapter.FindChild("xr-origin",true,false)).GlobalTransform*head.GetPose("default").GetAdjustedTransform();
        var openingPanel=adapter.GuiSurface.GlobalTransform;var flatForward=-openingHead.Basis.Z;flatForward.Y=0;flatForward=flatForward.Normalized();
        Check(openingPanel.Basis.Y.Dot(Vector3.Up)>.9999f && Mathf.Abs(openingPanel.Origin.Y-openingHead.Origin.Y)<.0001f &&
            (openingPanel.Origin-openingHead.Origin).DistanceTo(flatForward*2)<.0001f,
            "the actual first tilted tracked head opens an upright workspace at eye height in its horizontal forward view");
        adapter.PresentWorkspace(false);adapter.PresentWorkspace(true);
        head.SetPose("default",new(Basis.FromEuler(new(Mathf.Pi/2,0,0)),new(1.2f,1.4f,-.7f)),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);Advance();
        Check(!adapter.GuiSurface.Visible,"a vertical-only head direction waits for a measurable horizontal heading rather than inventing one");
        adapter.ShowWorkspace();Head(new(1.2f,1.4f,-.7f),.4f);Advance();
        var origin=(Node3D)adapter.FindChild("xr-origin",true,false);
        Transform3D Expected(float distance)=>origin.GlobalTransform*head.GetPose("default").GetAdjustedTransform()*new Transform3D(Basis.Identity,new(0,0,-distance));
        bool Same(Transform3D a,Transform3D b)=>a.Origin.DistanceTo(b.Origin)<.0001f && a.Basis.IsEqualApprox(b.Basis);
        Check(adapter.GuiSurface.Visible && Same(adapter.GuiSurface.GlobalTransform,Expected(2)),"the real frame owner opens the panel from the current adjusted tracked head");
        var fixedPose=adapter.GuiSurface.GlobalTransform;
        Head(new(1.7f,1.2f,-.4f),-.7f);Advance();
        Check(Same(adapter.GuiSurface.GlobalTransform,fixedPose),"ordinary head movement leaves the working panel world-stable");
        adapter.ShowWorkspace();Advance();Check(Same(adapter.GuiSurface.GlobalTransform,Expected(2)),"explicit Recenter uses the current view without changing tracking calibration");
        adapter.MoveWorkspace();Head(new(.5f,1.1f,.2f),.1f);Advance();
        Check(adapter.MovingWorkspace && Same(adapter.GuiSurface.GlobalTransform,Expected(2)),"explicit Move updates placement through the existing frame owner");
        adapter.MoveWorkspace();fixedPose=adapter.GuiSurface.GlobalTransform;Head(new(.9f,1.3f,.4f),.5f);Advance();
        Check(!adapter.MovingWorkspace && Same(adapter.GuiSurface.GlobalTransform,fixedPose),"Place ends movement and retains a stationary panel");
        adapter.MoveWorkspace();Advance(focused:false);fixedPose=adapter.GuiSurface.GlobalTransform;Head(new(.2f,1.5f,1),-.2f);Advance();
        Check(!adapter.MovingWorkspace && Same(adapter.GuiSurface.GlobalTransform,fixedPose),"lost native eligibility stops Move without an automatic resume");

        XRControllerTracker Tracker(string name,XRPositionalTracker.TrackerHand hand) {
            var t=new XRControllerTracker { Name=name,Type=XRServer.TrackerType.Controller,Profile="/interaction_profiles/htc/vive_controller",Hand=hand };
            t.SetInput("trigger_press",false);t.SetInput("trigger_value",0.0);t.SetInput("squeeze_press",false);t.SetInput("pad_press",false);t.SetInput("pad_touch",false);t.SetInput("pad_axes",Vector2.Zero);
            t.SetPose("aim",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
            t.SetPose("grip",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);XRServer.AddTracker(t);return t;
        }
        var left=Tracker("workspace_left",XRPositionalTracker.TrackerHand.Left);var right=Tracker("workspace_right",XRPositionalTracker.TrackerHand.Right);
        await Frame();await adapter.Completion;Advance();
        int clicks=0;var button=new Button { Position=new(430,390),Size=new(300,80),Text="Existing native target" };gui.Surface.AddChild(button);button.Pressed+=()=>clicks++;
        await Frame();
        Vector3 Aim() {
            var pixels=gui.Surface.Size;var size=((QuadMesh)adapter.GuiSurface.Mesh).Size;var pixel=button.GetGlobalRect().GetCenter();
            var hit=adapter.GuiSurface.GlobalTransform*new Vector3((pixel.X/pixels.X-.5f)*size.X,(.5f-pixel.Y/pixels.Y)*size.Y,0);
            var pose=new Transform3D(adapter.GuiSurface.GlobalBasis,hit+adapter.GuiSurface.GlobalBasis.Z);
            left.SetPose("aim",origin.GlobalTransform.AffineInverse()*pose,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);return hit;
        }
        void Trigger(bool down){left.SetInput("trigger_press",down);Advance();}
        adapter.WorkspaceDistance(1);Advance();var hit=Aim();Advance();
        var pointer=adapter.Sources.Single(s=>s.Hand=="left").Pointer;
        Check((pointer.GlobalTransform*new Vector3(0,0,-2)).DistanceTo(hit)<.001f,"visible ray endpoint and native GUI hit use the same repositioned surface geometry");
        Trigger(true);Check(gui.Captures==1,"the repositioned panel acquires the existing native control capture");
        adapter.ShowWorkspace();Advance();Trigger(false);
        Check(clicks==0 && gui.Captures==0,"Recenter cancels a held capture without click and release cannot replay it");
        Advance();Aim();Trigger(true);Trigger(false);
        Check(clicks==1 && gui.Captures==0,"neutral then one fresh mapped gesture reaches the same native control after repositioning");
        Aim();Trigger(true);gui.TextSize(4);Trigger(false);
        Check(clicks==1 && gui.Captures==0,"text reflow cancels through the attached input owner and cannot release a stale click");
        Advance();Aim();Trigger(true);Trigger(false);
        Check(clicks==2 && gui.Captures==0,"neutral rearms the real GUI after text reflow");
        // A press that misses the panel is offered to the open form's owner; one on the panel never is.
        formOpen=true;var onPanel=left.GetPose("aim").Transform;
        left.SetPose("aim",onPanel.Translated(onPanel.Basis.X*10),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);Advance();
        Trigger(true);Trigger(false);
        Check(dismissed==1 && clicks==2 && gui.Captures==0,"a trigger press outside the panel reaches the open form's owner once and nothing else");
        Advance();Aim();Advance();Trigger(true);Trigger(false);
        Check(dismissed==1 && clicks==3 && gui.Captures==0,"a trigger press on the panel stays the panel's own");
        formOpen=false;
        adapter.HideWorkspace();right.SetInput("pad_axes",new Vector2(0,1));right.SetInput("pad_press",true);Advance();
        Check(adapter.Router.MenuOwner==null,"Hide disarms an already-held menu until a released frame");
        right.SetInput("pad_press",false);right.SetInput("pad_axes",Vector2.Zero);Advance();
        Check(adapter.Sources.Single(s=>s.Hand=="right").Read("xr-standard-touchpad")!.Neutral,"fixture supplies an actually released neutral touchpad before the next menu gesture");
        right.SetInput("pad_axes",new Vector2(0,1));right.SetInput("pad_press",true);Advance();Advance();
        Check(adapter.Router.MenuOwner!=null && adapter.PieQuad.Visible && !adapter.GuiSurface.Visible && !form.IsVisibleInTree(),"the pie opens on its own surface while the working panel stays hidden");
        right.SetInput("pad_press",false);Advance();Advance();
        Check(adapter.WorkspaceVisible && form.IsVisibleInTree() && adapter.Router.MenuOwner==null && ReferenceEquals(form.Draft,draft) && submits==0,"mapped menu recall restores the same unsent working form without submitting it");
        // The HUD strip is body-locked below the view and tags along.
        var strip=new Button {Text="Strip command",Size=new(200,60)};adapter.HudSurface.AddChild(strip);
        Head(new(0,1.6f,0),0);Advance();
        var hudPose=adapter.HudQuad.GlobalTransform;var eye=(origin.GlobalTransform*head.GetPose("default").GetAdjustedTransform()).Origin;
        var offset=hudPose.Origin-eye;float below=Mathf.RadToDeg(Mathf.Atan2(-offset.Y,new Vector2(offset.X,offset.Z).Length()));
        Check(adapter.HudQuad.Visible && Math.Abs(below-25)<.5f && Math.Abs(offset.Length()-1.5f)<.01f,"the HUD strip sits 25° below eye level at reading distance");
        Head(new(0,1.6f,0),Mathf.DegToRad(30));Advance();
        Check(Same(adapter.HudQuad.GlobalTransform,hudPose),"a head turn within 35° leaves the strip where it is");
        Head(new(0,1.6f,0),Mathf.DegToRad(40));Advance();
        Check(!Same(adapter.HudQuad.GlobalTransform,hudPose),"a head turn past 35° brings the strip along");
        strip.Free();Advance();Check(!adapter.HudQuad.Visible,"an empty strip surface shows nothing");
        string retained=System.Text.Json.JsonSerializer.Serialize(models.Metrics);fixedPose=adapter.GuiSurface.GlobalTransform;
        for(int i=0;i<20;i++)Advance();
        Check(retained==System.Text.Json.JsonSerializer.Serialize(models.Metrics) && Same(adapter.GuiSurface.GlobalTransform,fixedPose),"unchanged frames retain placement and perform no model acquisition decode instance or texture work");

        var probeFailures=new List<string>();
        void Probe(bool yes,string name) { reports.Add(new { name,passed=yes });Console.WriteLine((yes ? "PASS " : "FAIL ")+name);Console.Out.Flush();if(!yes)probeFailures.Add(name); }
        gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);gui.Size=new(1850,496);await Frame();await Frame();
        var shield=new Control { MouseFilter=Control.MouseFilterEnum.Stop };gui.Surface.AddChild(shield);shield.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);gui.Surface.MoveChild(button,gui.Surface.GetChildCount()-1);
        var pixel=button.GetGlobalRect().GetCenter();var mirrored=gui.GlobalPosition+pixel*gui.Size/(Vector2)gui.Surface.Size;int beforeMirror=clicks;
        void Mouse(bool down)=>app.GetViewport().PushInput(new InputEventMouseButton { ButtonIndex=MouseButton.Left,Pressed=down,Position=mirrored,GlobalPosition=mirrored },true);
        app.GetViewport().PushInput(new InputEventMouseMotion { Position=mirrored,GlobalPosition=mirrored },true);Mouse(true);Mouse(false);await Frame();
        Probe(clicks==beforeMirror+1 && gui.Surface.GetMousePosition().DistanceTo(pixel)<.1f,"desktop mirror coordinates reach the same native Control at unequal physical and surface sizes");
        reports.Add(new { mirrorExpected=pixel.ToString(),mirrorObserved=gui.Surface.GetMousePosition().ToString(),nativeClickDelta=clicks-beforeMirror });
        Vector2 relative=Vector2.Zero;void Motion(InputEvent input){if(input is InputEventMouseMotion m)relative=m.Relative;}
        button.GuiInput+=Motion;var moved=mirrored+new Vector2(5,3)*gui.Size/(Vector2)gui.Surface.Size;
        app.GetViewport().PushInput(new InputEventMouseMotion { Position=moved,GlobalPosition=moved },true);await Frame();button.GuiInput-=Motion;
        Probe(relative.DistanceTo(new(5,3))<.1f,"mirrored relative mouse motion uses the same logical surface units");
        Mouse(true);int beforeMirrorResize=clicks;gui.Size=new(1000,700);await Frame();mirrored=gui.GlobalPosition+pixel*gui.Size/(Vector2)gui.Surface.Size;Mouse(false);
        Probe(gui.Captures==0 && !gui.NativePressed && clicks==beforeMirrorResize,"resizing the mirror cancels its held native capture without click");shield.Free();
        Advance();Aim();int beforeRay=clicks;Trigger(true);Trigger(false);
        Probe(clicks==beforeRay+1,"XR GUI hits remain in surface coordinates when the desktop mirror has a different size");
        while(gui.Appearance.DefaultFontSize<48)gui.TextSize(4);
        fullMenu=true;adapter.HideWorkspace();right.SetInput("pad_axes",Vector2.Zero);Advance();right.SetInput("pad_axes",new Vector2(0,1));right.SetInput("pad_press",true);Advance();Advance();await Frame();await Frame();
        var reach=new Rect2(gui.Surface.Size/2-new Vector2(300,300)*1.04f,new Vector2(600,600)*1.04f);
        Probe(pie.IsOpen && pie.Navigator!.Level.Children.Length==8 && new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(reach),
            "the full eight-wedge pie fits the surface at largest supported text");
        right.SetInput("pad_axes",new Vector2(1,0));Advance();await Frame();await Frame();
        Probe(pie.Navigator!.Hovered==3 && pie.Title==full.At(3)!.Label && pie.Note=="Not here.",
            "actual right-pad selection points wedge 3 and the centre names it with its reason");
        right.SetInput("pad_axes",new Vector2(-.71f,.7f));Advance();
        Probe(pie.Navigator!.Hovered==8 && pie.Title==full.At(8)!.Label,"the last wedge is reachable by direction without scrolling");
        Probe(ReferenceEquals(form.Draft,draft) && form.Input("note")!.GetInstanceId()==editorId && submits==0,
            "the pie over the panel preserves the same unsent native form and draft beneath it");
        reports.Add(new { maximumFont=gui.Appearance.DefaultFontSize,reach=reach.ToString(),title=pie.Title });
        if(DisplayServer.GetName()!="headless") {
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();
            string directory=Env("M4_PRESENTATION_IMAGES");System.IO.Directory.CreateDirectory(directory);
            Probe(image.SavePng(System.IO.Path.Combine(directory,"pie-selection.png"))==Error.Ok,"actual pie selection raster retained");
        }
        adapter.Router.CancelMenu();right.SetInput("pad_press",false);Advance();adapter.ShowWorkspace();Advance();
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { reports,checks,probeFailures }));
        Check(probeFailures.Count==0,"new shared mirror/menu seams: "+string.Join("; ",probeFailures));

        button.Free();
        if(DisplayServer.GetName()!="headless") {
            actual.PresentWorkspace(true);
            gui.TextSize(26-gui.Appearance.DefaultFontSize);
            async Task<Color> Background(string name) {
                await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
                using var image=gui.Surface.GetTexture().GetImage();
                string directory=Env("M4_PRESENTATION_IMAGES");System.IO.Directory.CreateDirectory(directory);
                Check(image.SavePng(System.IO.Path.Combine(directory,name+".png"))==Error.Ok,"actual "+name+" workspace raster retained");
                int opaqueText=0;for(int y=0;y<image.GetHeight();y++)for(int x=0;x<image.GetWidth();x++) { var c=image.GetPixel(x,y);if(c.A>.99f && c.R>.7f && c.G>.7f && c.B>.7f)opaqueText++; }
                reports.Add(new { raster=name,opaqueText });Check(opaqueText>100,"workspace text remains opaque in "+name+" mode");return image.GetPixel(3,3);
            }
            gui.Opaque(true);await Device("opaque");
            var tinted=await Background("tinted");
            await Device("opaque");
            var opaque=await Background("opaque");
            Check(tinted.A>.7f && tinted.A<.9f && opaque.A>.99f,"real renderer applies translucency to the background and keeps an opaque option");
        }
        scene.Apply(Term.Parse("[mark(<<\"new\">>,<<\"box\">>,[f(<<\"width\">>,500),f(<<\"height\">>,500),f(<<\"depth\">>,500)],transform(0,0,-2250,0,0,0),surface(<<\"#6A90D9\">>,0,700,0,1000,[]),unlabelled,depicts_nothing)]"));
        await Frame();await Frame();Advance();
        var framed=origin.GlobalTransform.Origin;
        scene.Stand(ScenePose.Decode(Term.Parse("transform(0,0,0,0,0,0)")));Advance();
        Check(framed.DistanceTo(new(0,0,-2.25f))<1 && origin.GlobalTransform.IsEqualApprox(Transform3D.Identity),
            $"a headset stands where the agent is placed, two metres from a new half-metre space, not at the desktop camera that frames it from {framed.DistanceTo(new(0,0,-2.25f)):0.00} m");
        scene.Stand(null);scene.Withdraw();
        adapter.StopSession();await adapter.Completion;
        Check(adapter.Subscriptions==0 && models.LiveLeases==0 && models.LiveTemplates==0 && gui.Captures==0,"workspace retirement releases real input/render consumers and captures");
        XRServer.RemoveTracker(left);XRServer.RemoveTracker(right);XRServer.RemoveTracker(head);adapter.GetParent().RemoveChild(adapter);adapter.Free();form.Free();
        await NativePress((Button)app.FindChild("create-key",true,false));await Until(()=>!Busy);
        var identity=State["public_key"]!.ToString();
        var endpoint=(LineEdit)app.FindChild("endpoint",true,false);endpoint.Text="https://server.invalid";
        app.ActiveStore.Update(saved=>saved.NodeKeys[endpoint.Text]=new string('0',64));
        await NativePress(options);await NativePress(trust);await Until(()=>!Busy);
        Check(app.ActiveStore.Snapshot!.NodeKey(endpoint.Text)=="" && State["public_key"]!.ToString()==identity &&
            !((Button)app.FindChild("connect",true,false)).Disabled,
            "native Options choice removes only disposable server trust and keeps the saved key and Sign in ready");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { passed=true,reports,checks,coverage="real Main/native GUI layout and injected XRServer consumers; no native runtime or physical readability claim" }));
        Console.WriteLine("M4_WORKSPACE_OBSERVED");Console.Out.Flush();Console.WriteLine("M4_WORKSPACE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
