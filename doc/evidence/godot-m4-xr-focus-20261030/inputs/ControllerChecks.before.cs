using Godot;
using Quod.Client;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
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
        adapter.Configure(scene,gui,resources,()=>null,()=>overlay,()=>new[]{("Test existing menu consumer",(Func<bool>)(()=>menuEnabled),(Action)(()=>menuActivated++))});
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
        void Advance()=>adapter.Advance(++frame,true);
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
        Held(left,"trigger_press",true);adapter.Focus(false);
        Check(gui.Captures==0 && clicked==1 && !button.ButtonPressed,"no-frame focus loss cancels native capture without click");
        adapter.Focus(true);Advance();Held(left,"trigger_press",false);Check(clicked==1,"held focus return requires release before rearming");
        Advance();Held(left,"trigger_press",true);left.InvalidatePose("aim");Advance();Held(left,"trigger_press",false);
        Check(clicked==1 && gui.Captures==0,"lost current ray cancels while an old engine transform remains");
        Pose(left,button.GetGlobalRect().GetCenter());Advance();Held(left,"trigger_press",true);left.InvalidatePose("grip");Advance();Held(left,"trigger_press",false);
        Check(clicked==1,"lost grip pose cannot select through a retained ray");
        left.SetPose("grip",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);Advance();
        Held(left,"trigger_press",true);adapter.Advance(frame,true);Held(left,"trigger_press",false);
        Check(clicked==1,"duplicate stale frame cancels pending selection");
        Advance();Held(left,"trigger_press",true);adapter.Visibility(false);adapter.Visibility(true);Held(left,"trigger_press",false);
        Check(clicked==1,"visibility notification cancels without waiting for an XR frame");
        Advance();Held(left,"trigger_press",true);adapter.Install(null);Held(left,"trigger_press",false);
        var retained=System.Text.Json.JsonSerializer.Serialize(resources.Metrics);adapter.Install(mapping);await adapter.Completion;Advance();
        Check(System.Text.Json.JsonSerializer.Serialize(resources.Metrics)==retained && clicked==1,"authorization reinstallation retains inert source resources without acquisition/decode/node/texture work");
        for(int i=0;i<20;i++){adapter.Install(mapping);Advance();}
        Check(System.Text.Json.JsonSerializer.Serialize(resources.Metrics)==retained,"unchanged mapping/frame repeats perform zero render-resource work");
        Held(left,"trigger_press",true);adapter.InvalidateWorld();Held(left,"trigger_press",false);
        Check(clicked==1 && gui.Captures==0,"control or world invalidation cancels the old gesture before another frame");Advance();
        Held(left,"trigger_press",true);left.Hand=XRPositionalTracker.TrackerHand.Unknown;Advance();Held(left,"trigger_press",false);
        Check(clicked==1 && gui.Captures==0,"changed handedness cancels a held source without committing");left.Hand=XRPositionalTracker.TrackerHand.Left;Advance();
        Held(left,"trigger_press",true);adapter.Install(mapping with { Digest="changed-contract" });Held(left,"trigger_press",false);
        Check(clicked==1 && gui.Captures==0,"mapping replacement cancels before release and retains the same appearance");adapter.Install(mapping);Advance();
        Advance();Held(left,"trigger_press",true);button.Hide();Check(gui.Captures==0 && clicked==1,"hiding a pressed existing control cancels before replacement");Held(left,"trigger_press",false);button.Show();
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
        for(int i=0;i<20;i++)Advance();Check(adapter.MenuRedraws==menuDraw && menuDraw>beforeRedraw,"unchanged radial selection does not redraw menu labels or textures");
        var menu=gui.Surface.FindChild("xr-menu",true,false) as PanelContainer??throw new Exception("Expected native menu");await Frame();
        var entry=menu.FindChildren("*","Button",true,false).OfType<Button>().Single();ulong entryId=entry.GetInstanceId();
        menuEnabled=false;adapter.RefreshMenu();Check(entry.Disabled && entry.GetInstanceId()==entryId && adapter.MenuRedraws==menuDraw,"changed menu availability updates the existing native entry without rebuilding the menu");
        menuEnabled=true;adapter.RefreshMenu();Check(!entry.Disabled && adapter.MenuRedraws==menuDraw,"returned menu availability preserves selection and native entry identity");Pose(right,entry.GetGlobalRect().GetCenter());
        Held(right,"trigger_press",true);Held(right,"trigger_press",false);Held(right,"pad_press",false);
        Check(menuActivated==1 && adapter.Router.MenuOwner==null,"trigger menu choice consumes its later pad release exactly once");
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
