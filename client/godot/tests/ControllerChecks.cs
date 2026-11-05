using Godot;
using Quod.Client;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    // A fixed authored-shaped pie for injected-input qualification.
    internal static MenuNode QualificationPie(params (int Slot,string Label,bool Enabled)[] items)=>
        new(Term.Atom("menu"),"Qualification","",true,0,8,0,null,false,items.Select(i=>new MenuNode(
            Term.Call("wedge",Term.List(Term.Number(i.Slot.ToString()))),i.Label,i.Enabled ? "" : "Not here.",i.Enabled,i.Slot,8,0,
            new MenuTarget(Term.Atom("qualification"),Term.Atom("choice_"+i.Slot)),false,[])).ToArray());
    async Task ControllerAdapter()
    {
        // Frames are injected through real XRServer trackers. GUI events,
        // scene nodes and GLB decode are the production engine consumers.
        await Frame();
        byte[] model=await File.ReadAllBytesAsync(Env("M4_MODEL"));
        var mapping=ControllerMapping.Decode(Term.Parse(await File.ReadAllTextAsync(Env("M4_MAPPING"))))!;
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        var adapter=new OpenXRInput();scene.Viewport.AddChild(adapter);
        int fetched=0,clicked=0,menuActivated=0;bool overlay=false,menuEnabled=true;
        using var resources=new RenderModels((asset,cancellation)=> { fetched++;return Task.FromResult(model); });
        var pie=new PieMenu();gui.Surface.AddChild(pie);pie.Selected+=_=>menuActivated++;
        adapter.Configure(scene,gui,resources,()=>null,()=>overlay,pie,_=>{
            pie.Open(gui.Surface.Size/2,300,"Reading…");pie.Present(QualificationPie((1,"Test existing menu consumer",menuEnabled)),"");return true;});
        adapter.GuiSurface.Visible=true;adapter.GuiSurface.Transform=Transform3D.Identity;
        var button=new Button { Text="Controller capture qualification",Position=new(430,310),Size=new(300,80),MouseFilter=Control.MouseFilterEnum.Stop };
        gui.Surface.AddChild(button);button.Pressed+=()=>clicked++;
        XRControllerTracker Tracker(string name,XRPositionalTracker.TrackerHand hand) {
            var t=new XRControllerTracker { Name=name,Type=XRServer.TrackerType.Controller,Profile="/interaction_profiles/htc/vive_controller",Hand=hand };
            t.SetInput("trigger_press",false);t.SetInput("trigger_value",0.0);t.SetInput("squeeze_press",false);t.SetInput("pad_press",false);t.SetInput("pad_touch",false);t.SetInput("pad_axes",Vector2.Zero);
            t.SetPose("aim",new(Basis.Identity,new(0,0,1)),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
            t.SetPose("grip",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);XRServer.AddTracker(t);return t;
        }
        adapter.Install(mapping);adapter.AttachSources();
        var left=Tracker("m4_left",XRPositionalTracker.TrackerHand.Left);var right=Tracker("m4_right",XRPositionalTracker.TrackerHand.Right);
        ulong frame=0;
        void Advance(bool focused=true,bool running=true,bool tracked=true)=>adapter.Advance(++frame,focused,running,tracked);
        void Pose(XRControllerTracker t,Vector2 pixel) {
            var size=((QuadMesh)adapter.GuiSurface.Mesh).Size;
            var p=new Vector3((pixel.X/gui.Surface.Size.X-.5f)*size.X,(.5f-pixel.Y/gui.Surface.Size.Y)*size.Y,1);
            t.SetPose("aim",new(Basis.Identity,p),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
        }
        void Held(XRControllerTracker t,string name,bool down) { t.SetInput(name,down);Advance(); }
        await Frame();Pose(left,button.GetGlobalRect().GetCenter());Pose(right,button.GetGlobalRect().GetCenter());
        left.SetInput("trigger_press",true);await adapter.Completion;Advance();Held(left,"trigger_press",false);
        Check(clicked==0 && gui.Captures==0,"already-held source connection requires neutral before selection can arm");Advance();
        Check(fetched==1 && resources.Decodes==1 && resources.LiveLeases==2 && resources.InstancesCreated==2,"two tracked sources share verified bytes/template with independent engine appearances");
        Held(left,"trigger_press",true);
        Console.WriteLine($"M4_CAPTURE captures={gui.Captures} clicks={clicked} mouse={gui.Surface.GetMousePosition()} hover={gui.Surface.GuiGetHoveredControl()?.Name} button={button.GetGlobalRect()} pressed={button.ButtonPressed} source={adapter.Sources[0].Aim.GlobalTransform} raw={left.GetPose("aim").Transform} panel={adapter.GuiSurface.GlobalTransform} size={gui.Surface.Size} disabled={gui.Surface.GuiDisableInput} local={gui.Surface.HandleInputLocally} visible={gui.Visible}");
        Check(gui.Captures==1 && clicked==0,"mapped press acquires the real native GUI capture without activation");
        string beforeNotice=System.Text.Json.JsonSerializer.Serialize(resources.Metrics);string sourceId=adapter.Router.SourceChoices.Single(s=>s.Hand=="left").Id;
        XRServer.AddTracker(left);XRServer.Singleton.EmitSignal(XRServer.SignalName.TrackerRemoved,left.Name,(long)XRServer.TrackerType.Controller);await Frame();
        Check(gui.Captures==1 && adapter.Router.SourceChoices.Single(s=>s.Hand=="left").Id==sourceId && System.Text.Json.JsonSerializer.Serialize(resources.Metrics)==beforeNotice,"duplicate update and stale removal notices retain the actual registered source capture and render resources");
        Held(right,"trigger_press",true);Check(gui.Captures==1,"second controller cannot steal an active GUI press");
        Held(left,"trigger_press",false);Check(clicked==1 && gui.Captures==0,"mapped release activates the existing native button exactly once");
        Held(right,"trigger_press",false);Check(clicked==1,"competing pointer release cannot activate a second click");
        Held(left,"trigger_press",true);adapter.DesktopFocusLost();
        Check(gui.Captures==0 && clicked==1 && !button.ButtonPressed,"no-frame focus loss cancels native capture without click");
        string focusResources=System.Text.Json.JsonSerializer.Serialize(resources.Metrics);
        bool ModelsVisible()=>adapter.Sources.Length==2 && adapter.Sources.All(s=>s.Grip.GetChildren().OfType<Node3D>().Any(n=>n.Visible));
        bool ModelsHidden()=>adapter.Sources.Length==2 && adapter.Sources.All(s=>s.Grip.GetChildren().OfType<Node3D>().All(n=>!n.Visible));
        Advance();
        Check(ModelsVisible() && gui.Captures==0,"runtime-interactive models remain visible after desktop focus loss without replaying a held press");
        Held(left,"trigger_press",false);Check(clicked==1,"release after desktop focus loss cannot commit the cancelled press");
        Advance();Held(left,"trigger_press",true);Held(left,"trigger_press",false);
        Check(clicked==2,"neutral then a new native GUI gesture works while desktop focus remains absent");
        int expectedClicks=clicked;
        for(int i=0;i<20;i++){adapter.DesktopFocusLost();Advance();}
        Check(ModelsVisible() && System.Text.Json.JsonSerializer.Serialize(resources.Metrics)==focusResources,"repeated desktop focus loss and unchanged XR frames retain model leases templates instances and textures");
        foreach(var gate in new[]{(Focused:false,Running:true,Tracked:true),(Focused:true,Running:false,Tracked:true),(Focused:true,Running:true,Tracked:false)}) {
            Advance();Held(left,"trigger_press",true);Advance(gate.Focused,gate.Running,gate.Tracked);
            Check(ModelsHidden() && gui.Captures==0 && clicked==expectedClicks,"native focus/running/head gate cancels input and withholds controller models: "+gate);
            left.SetInput("trigger_press",false);Advance(gate.Focused,gate.Running,gate.Tracked);Advance();
            Check(ModelsVisible() && clicked==expectedClicks,"restored native gate rearms only from neutral without a cancelled release: "+gate);
        }
        int menuBeforeFocus=adapter.MenuRedraws;
        right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);
        Check(adapter.Router.MenuOwner!=null,"native menu opens with desktop focus absent");
        adapter.DesktopFocusLost();int cancelledMenuRedraws=adapter.MenuRedraws;Advance();
        Check(adapter.Router.MenuOwner==null && menuActivated==0 && adapter.MenuRedraws==cancelledMenuRedraws,"desktop focus-out closes a held menu once without reopening redraw or activation");
        Held(right,"pad_press",false);right.SetInput("pad_axes",Vector2.Zero);Advance();
        Check(menuActivated==0,"release of a focus-cancelled menu cannot commit");
        right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);
        Check(adapter.Router.MenuOwner!=null && adapter.MenuRedraws>menuBeforeFocus,"neutral permits a fresh menu while desktop focus stays absent");
        adapter.DesktopFocusLost();Held(right,"pad_press",false);right.SetInput("pad_axes",Vector2.Zero);Advance();
        overlay=true;Advance();int guardedDrives=adapter.DriveRequests;
        left.SetInput("squeeze_press",true);left.SetInput("pad_axes",new Vector2(0,1));Advance();
        Check(adapter.DriveRequests==guardedDrives,"an open working form still blocks travel");
        left.SetInput("squeeze_press",false);left.SetInput("pad_axes",Vector2.Zero);Advance();
        right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);
        Check(adapter.Router.MenuOwner!=null,"the presentation menu stays accessible while a working form blocks scene interaction");
        string menuResources=System.Text.Json.JsonSerializer.Serialize(resources.Metrics);int stableMenu=adapter.MenuRedraws;
        for(int i=0;i<20;i++)Advance();
        Check(adapter.MenuRedraws==stableMenu && System.Text.Json.JsonSerializer.Serialize(resources.Metrics)==menuResources,"unchanged visible-form menu frames do no redraw or render-resource work");
        gui.Surface.GuiEmbedSubwindows=true;
        var popup=new PopupPanel { Size=new(300,180),Exclusive=true };gui.Surface.AddChild(popup);popup.Popup();await Frame();Advance();
        Check(adapter.Router.MenuOwner==null && menuActivated==0,"a native popup withdraws the held presentation menu without activation");
        Held(right,"pad_press",false);right.SetInput("pad_axes",Vector2.Zero);Advance();
        right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);
        Check(adapter.Router.MenuOwner==null,"a visible native popup blocks a fresh presentation-menu gesture");
        Held(right,"pad_press",false);right.SetInput("pad_axes",Vector2.Zero);Advance();popup.Hide();popup.Free();
        Pose(left,button.GetGlobalRect().GetCenter());Held(left,"trigger_press",true);right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);
        Check(gui.Captures==1 && adapter.Router.MenuOwner==null,"an active pointer capture still blocks the other-source menu");
        adapter.Router.Cancel();Held(left,"trigger_press",false);Held(right,"pad_press",false);right.SetInput("pad_axes",Vector2.Zero);Advance();
        Check(clicked==expectedClicks && menuActivated==0,"cancelled pointer and menu releases commit neither action");
        right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);
        Check(adapter.Router.MenuOwner!=null,"neutral after popup/capture withdrawal rearms presentation access with the form still open");
        adapter.Router.CancelMenu();Held(right,"pad_press",false);right.SetInput("pad_axes",Vector2.Zero);overlay=false;Advance();
        int focusDrives=adapter.DriveRequests;
        left.SetInput("squeeze_press",true);left.SetInput("pad_axes",new Vector2(0,1));Advance();
        Check(adapter.DriveRequests>focusDrives,"neutral permits new travel through the existing consumer with desktop focus absent");
        int focusStops=adapter.StopRequests;adapter.DesktopFocusLost();int cancelledDrives=adapter.DriveRequests;
        for(int i=0;i<20;i++){adapter.DesktopFocusLost();Advance();}
        Check(adapter.StopRequests==focusStops+1 && adapter.DriveRequests==cancelledDrives,"desktop focus-out stops held travel once and repeated frames never replay it");
        left.SetInput("squeeze_press",false);left.SetInput("pad_axes",Vector2.Zero);Advance();
        Check(adapter.DriveRequests==cancelledDrives,"neutral release does not resume cancelled travel");
        Advance();Held(left,"trigger_press",true);left.InvalidatePose("aim");Advance();Held(left,"trigger_press",false);
        Check(clicked==expectedClicks && gui.Captures==0,"lost current ray cancels while an old engine transform remains");
        Pose(left,button.GetGlobalRect().GetCenter());Advance();Held(left,"trigger_press",true);left.InvalidatePose("grip");Advance();Held(left,"trigger_press",false);
        Check(clicked==expectedClicks,"lost grip pose cannot select through a retained ray");
        left.SetPose("grip",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);Advance();
        Held(left,"trigger_press",true);adapter.Advance(frame,true,true,true);Held(left,"trigger_press",false);
        Check(clicked==expectedClicks,"duplicate stale frame cancels pending selection");
        Advance();Held(left,"trigger_press",true);adapter.Visibility(false);Advance();
        Check(ModelsHidden() && gui.Captures==0,"desktop visibility remains a persistent input and model gate");
        Held(left,"trigger_press",false);adapter.Visibility(true);Advance();
        Check(clicked==expectedClicks,"visibility notification cancels without waiting for an XR frame");
        Advance();Held(left,"trigger_press",true);adapter.Install(null);Held(left,"trigger_press",false);
        Check(ModelsHidden() && gui.Captures==0 && clicked==expectedClicks,"signed mapping withdrawal blocks models and input after desktop focus loss");
        var retained=System.Text.Json.JsonSerializer.Serialize(resources.Metrics);adapter.Install(mapping);await adapter.Completion;Advance();
        Check(System.Text.Json.JsonSerializer.Serialize(resources.Metrics)==retained && clicked==expectedClicks,"authorization reinstallation retains inert source resources without acquisition/decode/node/texture work");
        for(int i=0;i<20;i++){adapter.Install(mapping);Advance();}
        Check(System.Text.Json.JsonSerializer.Serialize(resources.Metrics)==retained,"unchanged mapping/frame repeats perform zero render-resource work");
        Held(left,"trigger_press",true);adapter.InvalidateWorld();Held(left,"trigger_press",false);
        Check(clicked==expectedClicks && gui.Captures==0,"control or world invalidation cancels the old gesture before another frame");Advance();
        Held(left,"trigger_press",true);left.Hand=XRPositionalTracker.TrackerHand.Unknown;Advance();Held(left,"trigger_press",false);
        Check(clicked==expectedClicks && gui.Captures==0,"changed handedness cancels a held source without committing");left.Hand=XRPositionalTracker.TrackerHand.Left;Advance();
        Held(left,"trigger_press",true);adapter.Install(mapping with { Digest="changed-contract" });Held(left,"trigger_press",false);
        Check(clicked==expectedClicks && gui.Captures==0,"mapping replacement cancels before release and retains the same appearance");adapter.Install(mapping);Advance();
        Advance();Held(left,"trigger_press",true);button.Hide();Check(gui.Captures==0 && clicked==expectedClicks,"hiding a pressed existing control cancels before replacement");Held(left,"trigger_press",false);button.Show();
        right.Hand=XRPositionalTracker.TrackerHand.Left;Advance();int drives=adapter.DriveRequests;
        left.SetInput("squeeze_press",true);left.SetInput("pad_axes",new Vector2(0,1));Advance();
        Check(adapter.DriveRequests==drives,"ambiguous handedness does not select the first travel source");
        var leftId=adapter.Router.SourceChoices.Single(s=>s.Id==adapter.Router.SourceChoices[0].Id).Id;
        Check(adapter.Router.Choose("navigation",leftId),"explicit local role choice resolves an ambiguous session source");
        left.SetInput("squeeze_press",false);left.SetInput("pad_axes",Vector2.Zero);Advance();
        left.SetInput("squeeze_press",true);left.SetInput("pad_axes",new Vector2(0,1));Advance();
        Check(adapter.DriveRequests>drives,"resolved source reaches the existing semantic travel consumer");
        int stops=adapter.StopRequests;Advance();Check(adapter.StopRequests==stops,"an idle second source cannot cancel valid travel");
        right.SetInput("trigger_press",true);Advance();Check(adapter.StopRequests==stops+1 && gui.Captures==1,"pointer capture suppresses other-source travel in that same frame");
        right.SetInput("trigger_press",false);Advance();int after=adapter.DriveRequests;Advance();Check(adapter.DriveRequests==after,"travel stays disarmed until neutral after capture");
        left.SetInput("squeeze_press",false);left.SetInput("pad_axes",Vector2.Zero);Advance();
        right.Hand=XRPositionalTracker.TrackerHand.Right;Advance();
        // Entry/status updates do not replace a mapping or cancel other input.
        int beforeRedraw=adapter.MenuRedraws;
        right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);int menuDraw=adapter.MenuRedraws;
        for(int i=0;i<20;i++)Advance();Check(adapter.MenuRedraws==menuDraw && menuDraw>beforeRedraw,"unchanged radial selection does not redraw the pie");
        Check(pie.Navigator!.Hovered==1 && pie.Caption=="Test existing menu consumer","pad direction and the pie centre name the same wedge");
        menuEnabled=false;pie.Present(QualificationPie((1,"Test existing menu consumer",false)),"");
        Check(pie.Navigator!.Hovered==1 && !pie.Navigator.HoveredItem!.Enabled && adapter.MenuRedraws==menuDraw+1 && pie.Caption=="Test existing menu consumer · Not here.",
            "changed availability keeps the pointed wedge and shows its reason with one redraw");
        int disabledDraw=adapter.MenuRedraws;string disabledResources=System.Text.Json.JsonSerializer.Serialize(resources.Metrics);
        for(int i=0;i<20;i++)Advance();
        Check(adapter.MenuRedraws==disabledDraw && System.Text.Json.JsonSerializer.Serialize(resources.Metrics)==disabledResources,"unchanged disabled selection performs no menu redraw acquisition decode or lease work");
        Held(right,"pad_press",false);Check(menuActivated==0 && adapter.Router.MenuOwner==null && pie.IsOpen,"releasing on an unavailable wedge keeps the pie and its reason without activation");
        adapter.CancelMenu();right.SetInput("pad_axes",Vector2.Zero);Advance();menuEnabled=true;
        right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);
        right.SetInput("pad_axes",Vector2.Zero);Advance();
        Check(pie.Navigator!.Hovered==0 && pie.Caption=="Qualification","the centre clears the pad choice and names the menu");
        Held(right,"pad_press",false);Check(menuActivated==0 && adapter.Router.MenuOwner==null && !pie.IsOpen,"centre release cancels without a menu callback");
        Advance();right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);adapter.Router.CancelMenu();Advance();
        Check(adapter.Router.MenuOwner==null && menuActivated==0 && !pie.IsOpen,"cancelled held pad cannot reopen without a neutral release");
        Held(right,"pad_press",false);right.SetInput("pad_axes",Vector2.Zero);Advance();
        right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);Held(right,"pad_press",false);Advance();
        Check(menuActivated==1 && adapter.Router.MenuOwner==null && !pie.IsOpen,"neutral then a new angular selection commits its wedge exactly once on release (turbo)");
        right.SetInput("pad_axes",Vector2.Zero);Advance();right.SetInput("pad_axes",new Vector2(0,1));Held(right,"pad_press",true);await Frame();
        menuDraw=adapter.MenuRedraws;pie.Present(QualificationPie((1,"Test existing menu consumer",true)),"");
        Check(adapter.MenuRedraws==menuDraw,"an unchanged menu projection retains the pie and selection without redraw");
        right.SetInput("pad_axes",Vector2.Zero);Advance();Check(pie.Navigator!.Hovered==0,"returning the thumb to the pad centre points no wedge");
        Pose(right,gui.Surface.Size/2-new Vector2(0,300*.66f));Advance();
        Check(pie.Navigator!.Hovered==1,"the controller ray on the pie surface points the same wedge as the pad");
        Held(right,"trigger_press",true);Held(right,"trigger_press",false);Held(right,"pad_press",false);
        Check(menuActivated==2 && adapter.Router.MenuOwner==null,"trigger wedge choice consumes its later pad release exactly once");
        right.SetInput("pad_axes",Vector2.Zero);Advance();right.Hand=XRPositionalTracker.TrackerHand.Unknown;Advance();beforeRedraw=adapter.MenuRedraws;Held(right,"pad_press",true);
        Check(adapter.MenuRedraws==beforeRedraw,"unknown handedness does not receive the default menu role");Held(right,"pad_press",false);
        left.Profile="unsupported-profile";Advance();Pose(left,button.GetGlobalRect().GetCenter());Held(left,"trigger_press",true);Held(left,"trigger_press",false);
        Check(gui.Captures==0,"unknown profile refuses selection without guessed components");
        left.Profile="/interaction_profiles/htc/vive_controller";left.SetInput("pad_axes",default(Variant));Advance();drives=adapter.DriveRequests;
        left.SetInput("squeeze_press",true);Advance();Check(adapter.DriveRequests==drives,"missing named axes refuse dependent mapping");
        left.SetInput("pad_axes",Vector2.Zero);left.SetInput("squeeze_press",false);Advance();
        Check(adapter.Router.SourceChoices.Length==2,"late component initialization keeps the existing source identity");
        drives=adapter.DriveRequests;left.SetInput("squeeze_press",true);left.SetInput("pad_axes",new Vector2(0,1));Advance();
        Check(adapter.DriveRequests>drives,"late named-component initialization rearms actual travel after neutral");left.SetInput("squeeze_press",false);left.SetInput("pad_axes",Vector2.Zero);Advance();
        left.Hand=XRPositionalTracker.TrackerHand.Unknown;adapter.Install(mapping with { Digest="disabled-roles",Roles=new(){["navigation"]="none",["menu"]="none"} });Advance();
        beforeRedraw=adapter.MenuRedraws;Held(left,"pad_press",true);Held(left,"pad_press",false);
        Check(adapter.MenuRedraws==beforeRedraw,"disabled role never assigns an unknown-handed source");adapter.Install(mapping);left.Hand=XRPositionalTracker.TrackerHand.Left;Advance();
        Pose(left,button.GetGlobalRect().GetCenter());Advance();Held(left,"trigger_press",true);int beforeUnrelated=clicked;
        right.Profile="unsupported-unrelated-profile";adapter.Install(mapping with { Revision=mapping.Revision+1 });button.Text="Live presentation status changed";Advance();
        Check(gui.Captures==1,"unrelated source/status and same-digest revision updates retain the existing capture");Held(left,"trigger_press",false);
        Check(clicked==beforeUnrelated+1,"retained capture releases exactly once after an unrelated update");
        int beforeDisposal=clicked;
        var removable=new Button { Text="Dispose during capture",Position=button.Position,Size=button.Size };
        button.Hide();gui.Surface.AddChild(removable);await Frame();Pose(left,removable.GetGlobalRect().GetCenter());Advance();Held(left,"trigger_press",true);
        Check(gui.Captures==1,"replacement native control receives one capture");removable.Free();Held(left,"trigger_press",false);
        Check(gui.Captures==0 && clicked==beforeDisposal,"disposing a captured native control releases without click-through");button.Show();
        var originalGuiSize=gui.Size;gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);gui.Size=originalGuiSize;await Frame();
        Pose(left,button.GetGlobalRect().GetCenter());Advance();Held(left,"trigger_press",true);int beforeResize=clicked,meshChanges=0;
        var quad=(QuadMesh)adapter.GuiSurface.Mesh;void GeometryChanged()=>meshChanges++;quad.Changed+=GeometryChanged;
        gui.Size=new(800,800);await Frame();
        Check(gui.Captures==0 && clicked==beforeResize && !button.ButtonPressed && meshChanges==1,"actual shared GUI resize cancels capture without click and updates one panel geometry");
        Held(left,"trigger_press",false);Advance();Pose(left,button.GetGlobalRect().GetCenter());Held(left,"trigger_press",true);
        meshChanges=0;gui.Size=new(1000,1000);await Frame();
        Check(gui.Captures==0 && clicked==beforeResize && meshChanges==0,"equal-aspect pixel resize cancels capture without rebuilding unchanged geometry");
        Held(left,"trigger_press",false);Advance();Pose(left,button.GetGlobalRect().GetCenter());Held(left,"trigger_press",true);
        string resizeResources=System.Text.Json.JsonSerializer.Serialize(resources.Metrics);meshChanges=0;
        for(int i=0;i<20;i++)gui.Surface.EmitSignal(Viewport.SignalName.SizeChanged);
        Check(gui.Captures==1 && meshChanges==0 && System.Text.Json.JsonSerializer.Serialize(resources.Metrics)==resizeResources,"unchanged size notices retain capture and perform zero mesh or model work");
        Held(left,"trigger_press",false);Check(clicked==beforeResize+1,"resized panel ray activates the same native control exactly once after neutral");
        gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);await Frame();
        int edgeClicks=0;var edgeButton=new Button { Text="Actual panel edge",Position=new(gui.Surface.Size.X-250,100),Size=new(220,60) };
        gui.Surface.AddChild(edgeButton);edgeButton.Pressed+=()=>edgeClicks++;await Frame();
        Pose(left,edgeButton.GetGlobalRect().GetCenter());Advance();Held(left,"trigger_press",true);Held(left,"trigger_press",false);
        Check(edgeClicks==1 && gui.Captures==0,"ray uses rendered panel bounds beyond the former fixed half-width");
        left.SetPose("aim",new(Basis.Identity,new(quad.Size.X*.51f,0,1)),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);Advance();Held(left,"trigger_press",true);Held(left,"trigger_press",false);
        Check(edgeClicks==1 && gui.Captures==0,"ray outside actual resized quad cannot activate a native GUI control");
        quad.Changed-=GeometryChanged;edgeButton.Free();
        int released=resources.Releases;var removed=new TaskCompletionSource();void Retired(){if(resources.Releases==released+1)removed.TrySetResult();}adapter.Changed+=Retired;
        try { XRServer.RemoveTracker(left);await removed.Task.WaitAsync(TimeSpan.FromSeconds(5)); }finally { adapter.Changed-=Retired; }
        Check(resources.Releases==released+1,"source removal releases its actual appearance lease");
        left.Profile="late-callback";Check(adapter.Router.Count==1,"late removed-source notifications cannot recreate input");
        adapter.StopSession();await adapter.Completion;Check(adapter.Subscriptions==0 && adapter.Router.Count==0 && gui.Captures==0 && resources.LiveLeases==0 && resources.LiveTemplates==0,"stop releases every source observer capture and render lease");
        XRServer.RemoveTracker(right);adapter.AttachSources();Check(adapter.Router.Count==0,"reentry has no inherited source or held gesture");adapter.StopSession();
        var metrics=adapter.Metrics;adapter.GetParent().RemoveChild(adapter);adapter.Free();
        if(DisplayServer.GetName()!="headless")await NativePress(button);
        button.QueueFree();
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { passed=true,coverage="injected real XRServer/native GUI/render consumers; no physical headset claim",checks,metrics }));
        Console.WriteLine("M4_CONTROLLER_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
