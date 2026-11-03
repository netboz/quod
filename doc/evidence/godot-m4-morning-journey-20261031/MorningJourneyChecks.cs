using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;

// Exported, bounded software rehearsal. Only this explicit qualification
// phase injects trackers or input; VivePhysical never calls this method.
public partial class ExportChecks
{
    async Task MorningJourney()
    {
        await Press("create-key");await Press("connect");
        Check(State["network"]?.ToString()==Env("M1B_NETWORK"),"fresh private journey authenticates the expected network");
        await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true && State["operation_available"]?.GetValue<bool>()==true && State["controller_status"]?["available"]?.GetValue<bool>()==true);
        var original=app.ActiveAccounts.Setup!.ToString();var human=app.ActiveAccounts.Human!;
        var panel=(OperationsPanel)app.FindChild("operations",true,false);
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        var adapter=(OpenXRInput)app.FindChild("openxr-input",true,false);
        var instruction=MorningInstruction(gui);
        async Task Raster(string name)
        {
            if(DisplayServer.GetName()=="headless")return;
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            string directory=Env("M4_MORNING_IMAGES");System.IO.Directory.CreateDirectory(directory);
            using var image=gui.Surface.GetTexture().GetImage();
            Check(image.SavePng(System.IO.Path.Combine(directory,name+".png"))==Error.Ok,"actual current shared GUI renderer retained: "+name);
        }
        var guide=new MorningJourneyGuide();
        string Guide(){var state=State;var text=guide.Observe(state,panel.Current,panel.Available,panel.LastOutcome,state["human"]!=null && app.ActiveAccounts.Uncertain,panel.IsWorking);instruction.Text=ViveLookCue.Compose(true,true,text);return text;}
        Check(Guide().StartsWith("1 ·"),"guidance starts from actual installed S0, not a recorded success");
        var pending=State.DeepClone();pending["pending"]=1;
        Check(guide.Observe(pending,panel.Current,panel.Available,panel.LastOutcome).StartsWith("STOP") && guide.Step==0,"pending original work stops guidance without advancing or replay");
        Check(guide.Observe(State,panel.Current,panel.Available,panel.LastOutcome,true).StartsWith("STOP") && guide.Step==0,"authoritative uncertainty without a device journal also stops guidance");
        Check(guide.Observe(State,panel.Current,panel.Available,panel.LastOutcome,false,true).StartsWith("WAITING") && guide.Step==0,"in-flight operation cannot be mistaken for a committed step");

        Check(XRServer.GetTracker("head")==null,"rehearsal owns unused software tracker identities");
        var head=new XRPositionalTracker { Name="head",Type=XRServer.TrackerType.Head };
        head.SetPose("default",new(Basis.FromEuler(new(.8f,.4f,.9f)),new(.2f,1.3f,-.1f)),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);XRServer.AddTracker(head);
        XRControllerTracker Hand(string name,XRPositionalTracker.TrackerHand hand) {
            var t=new XRControllerTracker { Name=name,Type=XRServer.TrackerType.Controller,Profile="/interaction_profiles/htc/vive_controller",Hand=hand };
            foreach(string key in new[]{"trigger_press","squeeze_press","pad_press","pad_touch"})t.SetInput(key,false);
            t.SetInput("trigger_value",0.0);t.SetInput("pad_axes",Vector2.Zero);
            foreach(string pose in new[]{"aim","grip"})t.SetPose(pose,Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
            XRServer.AddTracker(t);return t;
        }
        var left=Hand("morning_left",XRPositionalTracker.TrackerHand.Left);var right=Hand("morning_right",XRPositionalTracker.TrackerHand.Right);
        adapter.AttachSources();adapter.PresentWorkspace(true);gui.Surface.GuiEmbedSubwindows=true;
        await Frame();await adapter.Completion;
        ulong frame=0;void Advance()=>adapter.Advance(++frame,true,true,true);
        Advance();Advance();
        Check(adapter.GuiSurface.GlobalBasis.Y.Dot(Vector3.Up)>.9999f,"the corrected shared owner places the first tilted head upright during a real signed session");
        object[] Scrolls(Control target){var rows=new List<object>();for(Node? n=target.GetParent();n!=null;n=n.GetParent())if(n is ScrollContainer v)rows.Add(new { rect=v.GetGlobalRect().ToString(),v.ScrollHorizontal,v.ScrollVertical });return rows.ToArray();}
        async Task Click(Control target)
        {
            await Frame();await Frame();
            for(Node? n=target.GetParent();n!=null;n=n.GetParent())if(n is ScrollContainer scroll)scroll.EnsureControlVisible(target);
            await Frame();
            var rect=target.GetGlobalRect();
            Console.WriteLine("MORNING_LAYOUT "+JsonSerializer.Serialize(new { target=target.Name.ToString(),rect=rect.ToString(),surface=gui.Surface.Size.ToString(),instruction=instruction.GetGlobalRect().ToString(),scrolls=Scrolls(target),overwide=gui.Surface.FindChildren("*","Control",true,false).OfType<Control>().Where(c=>c.IsVisibleInTree() && c.GetCombinedMinimumSize().X>1100).Take(20).Select(c=>new { name=c.Name.ToString(),kind=c.GetClass(),min=c.GetCombinedMinimumSize().ToString(),size=c.Size.ToString() }) }));
            Check(target.IsVisibleInTree() && new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(rect),"current real control is inside the reflowed surface: "+target.Name);
            Check(new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(instruction.GetGlobalRect()),"the SAME headset instruction stays accessible while the real form scrolls");
            await Pixel(rect.GetCenter(),target.Name.ToString());
        }
        async Task ReadyGesture()
        {
            await Until(()=>State["controller_status"]?["available"]?.GetValue<bool>()==true);
            await adapter.Completion;Advance();
            Check(adapter.Sources.All(s=>new[]{"xr-standard-trigger","xr-standard-squeeze","xr-standard-touchpad"}.All(c=>s.Read(c)?.Neutral==true)),"all actual software control samples are released before a new gesture");
            Check(adapter.Sources.Length==2 && adapter.Sources.All(s=>s.Current(frame) && s.Grip.GetChildren().OfType<Node3D>().Any(n=>n.Visible)),"the actual signed mapping and current software poses/models are installed before a fresh gesture");
        }
        void AimPixel(Vector2 pixel,string name)
        {
            var origin=(Node3D)adapter.FindChild("xr-origin",true,false);var size=((QuadMesh)adapter.GuiSurface.Mesh).Size;
            var point=adapter.GuiSurface.GlobalTransform*new Vector3((pixel.X/gui.Surface.Size.X-.5f)*size.X,(.5f-pixel.Y/gui.Surface.Size.Y)*size.Y,0);
            var aim=new Transform3D(adapter.GuiSurface.GlobalBasis,point+adapter.GuiSurface.GlobalBasis.Z);
            left.SetPose("aim",origin.GlobalTransform.AffineInverse()*aim,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
            Advance();
            Console.WriteLine("MORNING_INPUT "+JsonSerializer.Serialize(new { target=name,mouse=gui.Surface.GetMousePosition().ToString(),hover=gui.Surface.GuiGetHoveredControl()?.Name.ToString(),panel=adapter.GuiSurface.Visible,tracked=adapter.Sources.Select(s=>new { s.Hand,current=s.Current(frame) }).ToArray() }));
        }
        async Task Pixel(Vector2 pixel,string name)
        {
            await ReadyGesture();AimPixel(pixel,name);
            left.SetInput("trigger_press",true);Advance();
            Console.WriteLine("MORNING_CAPTURE "+JsonSerializer.Serialize(new { target=name,captures=gui.Captures,hover=gui.Surface.GuiGetHoveredControl()?.Name.ToString() }));
            left.SetInput("trigger_press",false);Advance();await Frame();
            Check(gui.Captures==0,"one injected LEFT press/release leaves no native capture");
        }
        async Task Action(string name){var b=(Button)app.FindChild(name,true,false);int count=0;void Pressed()=>count++;b.Pressed+=Pressed;try{await Click(b);}finally{b.Pressed-=Pressed;}Check(count==1,"one actual native action Pressed: "+name);await Until(()=>!Busy);}
        IEnumerable<Node> Descendants(Node n){foreach(Node c in n.GetChildren(true)){yield return c;foreach(var d in Descendants(c))yield return d;}}
        async Task SelectOption(OptionButton select,int index)
        {
            int prior=select.Selected;bool reselect=select.AllowReselect;
            await Click(select);await Frame();var popup=select.GetPopup();
            Console.WriteLine("MORNING_POPUP "+JsonSerializer.Serialize(new { target=select.Name.ToString(),visible=popup.Visible,position=popup.Position.ToString(),size=popup.Size.ToString(),embedded=popup.IsEmbedded(),surface=gui.Surface.Size.ToString() }));
            Check(popup.Visible && new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(new Rect2(popup.Position,popup.Size)),"actual opened selector popup is reachable inside the same surface: "+select.Name);
            popup.ScrollToItem(index);await Frame();
            var scroll=Descendants(popup).OfType<ScrollContainer>().Single(v=>v.IsVisibleInTree());
            var items=scroll.GetChildren(true).OfType<Control>().Single(c=>c.GetClass()=="PopupMenuItems");
            int font=popup.GetThemeFontSize("font_size","PopupMenu"),gap=popup.GetThemeConstant("v_separation","PopupMenu");
            float height=Math.Max(popup.GetThemeFont("font","PopupMenu").GetHeight(font),popup.GetThemeIcon("radio_checked","PopupMenu").GetHeight());
            var pixel=(Vector2)popup.Position+items.GlobalPosition+new Vector2(60,index*(height+gap)+gap+height/2);
            Check(new Rect2(Vector2.Zero,gui.Surface.Size).HasPoint(pixel),"the selected actual popup item is inside the ray surface");
            int selected=0;void Selected(long value){if(value==index)selected++;}select.ItemSelected+=Selected;
            try {await Pixel(pixel,select.Name+" item "+index);}finally{select.ItemSelected-=Selected;}
            Check(selected==(prior!=index || reselect ? 1 : 0) && select.Selected==index && !popup.Visible,"native popup commits one changed selection and no redundant unchanged-selection update");
        }
        async Task FreshDraft()
        {
            Check(panel.Available && panel.Current!=null && !app.ActiveAccounts.Uncertain && State["pending"]!.GetValue<int>()==0,"starting another intended draft requires a current offer and no unresolved original work");
            var defaults=(Button)panel.FindChild("current-defaults",true,false);
            if(defaults.Text=="Adopt current fields, keeping draft") {
                await Click(defaults);
                Check(defaults.Text=="Use current fields and defaults","explicit adoption installs current fields before starting a new draft");
            }
            await Click(defaults);
            Check(!((Button)panel.FormPanel.Input(panel.Current!.Form.Submit.ToString())!).Disabled,"explicit current defaults start this intended new operation after adoption");
        }
        async Task SelectCreate()
        {
            await Action("create-operations");
            var storage=(OptionButton)panel.FindChild("operation-storage",true,false);
            int chosen=Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==human.Namespace+" @ "+human.Anchor);
            await SelectOption(storage,chosen);await Until(()=>!panel.IsWorking);
            var classes=(OptionButton)panel.FindChild("operation-class",true,false);
            await SelectOption(classes,Enumerable.Range(1,classes.ItemCount-1).Single(i=>classes.GetItemText(i)=="space"));
            await Until(()=>panel.Available);
            var offers=(OptionButton)panel.FindChild("offered-operation",true,false);
            await SelectOption(offers,Enumerable.Range(1,offers.ItemCount-1).Single(i=>offers.GetItemText(i)=="Create space"));
            await FreshDraft();
            Check(panel.Current?.Name=="create" && panel.FormPanel.Validate(),"the current signed Create space offer supplies actual valid defaults");
            var exterior=(OptionButton)panel.FormPanel.Input("space_exterior(finite)")!;string before=panel.FormPanel.Draft["space_exterior(finite)"];
            await SelectOption(exterior,exterior.Selected);
            Check(panel.FormPanel.Draft["space_exterior(finite)"]==before,"the same native offered-field popup preserves its exact typed selected default");
        }
        bool Located(Term expected){var value=State["current_location"];if(value==null)return false;var at=Term.Parse(value.ToString());return at.Name=="placed" && at.Args[0].ToString()==expected.ToString();}
        async Task<int> Instructions()=>Json.Binding(await app.ActiveSession.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length;
        async Task Submit()
        {
            int before=await Instructions(),clicked=0;var submit=(Button)panel.FormPanel.Input(panel.Current!.Form.Submit.ToString())!;
            void Pressed()=>clicked++;submit.Pressed+=Pressed;
            try {await Click(submit);await Until(()=>!panel.IsWorking);}
            finally {submit.Pressed-=Pressed;}
            Console.WriteLine("MORNING_SUBMIT "+JsonSerializer.Serialize(new { clicked,disabled=submit.Disabled,available=panel.Available,working=panel.IsWorking,current=panel.Current?.Name,terminal=panel.LastOutcome!=null && Json.Terminal(panel.LastOutcome),committed=panel.LastOutcome!=null && Json.Committed(panel.LastOutcome),captures=gui.Captures,router=adapter.Router.Status }));
            Check(clicked==1 && panel.LastOutcome!=null && Json.Committed(panel.LastOutcome),"one mapped software gesture reaches the current offered binder and commits once");
            Check(await Instructions()==before+1 && State["pending"]!.GetValue<int>()==0,"exactly one personal instruction, terminal result and no pending replay");
        }
        async Task OpenResult(Term expected)
        {
            var result=panel.FindChildren("*","Button",true,false).OfType<Button>().Last(b=>b.Text=="Open result: space" && b.TooltipText==expected.ToString());
            await Click(result);await Until(()=>panel.Available && panel.Current?.Subject.ToString()==expected.ToString());
            Check(panel.Current?.Name=="enter","the returned exact subject exposes its ordinary Enter form");
            await FreshDraft();
        }
        await Action("location-operations");await Until(()=>panel.Available);
        Check(Guide().StartsWith("2 ·"),"current-space inspection advances guidance only from its installed offer");
        var initialDraft=panel.FormPanel.Draft;
        head.SetPose("default",new(new Basis(Vector3.Up,.9f),new(.3f,1.4f,.2f)),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
        right.SetInput("pad_axes",Vector2.Zero);Advance();right.SetInput("pad_axes",new Vector2(0,1));right.SetInput("pad_press",true);Advance();Advance();
        Check(adapter.Router.MenuOwner!=null,"mapped Recenter is reachable from a changed heading while the real working form remains open");
        right.SetInput("pad_press",false);Advance();right.SetInput("pad_axes",Vector2.Zero);Advance();
        Check(ReferenceEquals(initialDraft,panel.FormPanel.Draft),"visible-form Recenter preserves the exact draft");

        await SelectCreate();
        var draft=panel.FormPanel.Draft;var control=panel.FormPanel.Input("space_name")!;
        var formScroll=gui.Surface.FindChildren("*","ScrollContainer",true,false).OfType<ScrollContainer>().First();
        formScroll.ScrollVertical=0;await Frame();await Frame();var bar=formScroll.GetVScrollBar();
        double beforeScroll=bar.Value;var barRect=bar.GetGlobalRect();
        var track=bar.GetThemeStylebox("scroll","VScrollBar");float minimum=bar.GetThemeStylebox("grabber","VScrollBar").GetMinimumSize().Y;
        float decrement=bar.GetThemeIcon("decrement","VScrollBar").GetHeight(),increment=bar.GetThemeIcon("increment","VScrollBar").GetHeight();
        float area=bar.Size.Y-track.GetMinimumSize().Y-decrement-increment-minimum;
        float grabber=(float)(bar.Page/(bar.MaxValue-bar.MinValue))*area+minimum;
        var start=barRect.Position+new Vector2(bar.Size.X/2,decrement+track.GetContentMargin(Side.Top)+grabber/2);
        await ReadyGesture();AimPixel(start,"existing scrollbar thumb");left.SetInput("trigger_press",true);Advance();
        AimPixel(start+new Vector2(0,area/2),"existing scrollbar drag");left.SetInput("trigger_press",false);Advance();await Frame();
        Check(bar.Value>beforeScroll && gui.Captures==0,"one actual mapped native scrollbar drag scrolls the offered form and retires capture");

        // The existing mapped menu recalls the SAME draft from a changed view,
        // including when the world-stable workspace is currently hidden.
        await Action("workspace-hide");
        head.SetPose("default",new(new Basis(Vector3.Up,-.7f),new(.3f,1.4f,.2f)),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
        right.SetInput("pad_axes",Vector2.Zero);Advance();right.SetInput("pad_axes",new Vector2(0,1));right.SetInput("pad_press",true);Advance();Advance();
        Check(adapter.Router.MenuOwner!=null && adapter.GuiSurface.Visible,"mapped menu is summonable from changed heading while workspace is hidden");
        right.SetInput("pad_press",false);Advance();right.SetInput("pad_axes",Vector2.Zero);Advance();
        Check(adapter.WorkspaceVisible && ReferenceEquals(draft,panel.FormPanel.Draft) && panel.FormPanel.Input("space_name")==control,"mapped Recenter restores the same real unsent form and control");
        await Raster("create-form");
        await Submit();var first=Result(SpaceResults(panel.LastOutcome!),"space");
        await Until(()=>scene.SubjectIds(first).Length==1);Guide();await Raster("first-result");
        await Frame();await Frame();
        var firstAction=panel.FindChildren("*","Button",true,false).OfType<Button>().Last(b=>b.Text=="Open result: space" && b.TooltipText==first.ToString());
        Console.WriteLine("MORNING_RESULT_LAYOUT "+JsonSerializer.Serialize(new { rect=firstAction.GetGlobalRect().ToString(),surface=gui.Surface.Size.ToString() }));
        Check(new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(firstAction.GetGlobalRect()),"the committed returned-subject action is visible without hunting through exact identity/outcome text");
        var exactDetails=(ScrollContainer)panel.FindChild("operation-exact-details",true,false);
        var exactScope=(Label)panel.FindChild("operation-scope",true,false);
        Check(!exactDetails.Visible && !panel.StatusText.StartsWith("{") && !exactScope.IsVisibleInTree(),"exact protocol data is collapsed rather than dominating ordinary status/actions");
        var preservedDraft=panel.FormPanel.Draft;var preservedOffer=panel.Current;string exactOutcome=panel.LastOutcome!.ToJsonString();int beforeDetails=await Instructions();
        await Action("operation-details-toggle");await Frame();await Frame();
        Check(exactScope.IsVisibleInTree() && exactScope.Text.Contains(human.Namespace) && exactDetails.FindChildren("*","Label",true,false).OfType<Label>().Any(l=>l.Text==exactOutcome),"native detail disclosure retains the full exact identity and original reply");
        Console.WriteLine("MORNING_DETAILS_LAYOUT "+JsonSerializer.Serialize(new { rect=exactDetails.GetGlobalRect().ToString(),size=exactDetails.Size.ToString(),surface=gui.Surface.Size.ToString(),scrolls=Scrolls(exactDetails) }));
        Check(new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(exactDetails.GetGlobalRect()) && exactDetails.Size.Y==220,"explicit details stay reachable in a bounded native scroll region");
        await Action("operation-details-toggle");await Frame();
        Check(!exactDetails.Visible && ReferenceEquals(preservedDraft,panel.FormPanel.Draft) && ReferenceEquals(preservedOffer,panel.Current) && panel.LastOutcome!.ToJsonString()==exactOutcome && await Instructions()==beforeDetails,"opening/closing details preserves the exact offer/draft/outcome with zero domain instructions");
        Check(guide.First?.ToString()==first.ToString() && Located(Term.Parse(original).Args[2]),"actual first creation appears as one exterior and leaves the same agent in S0");
        var id=scene.SubjectIds(first).Single();var centre=scene.WorldPose(id).Origin;
        var picked=scene.PickRay(centre+new Vector3(0,0,2),Vector3.Forward);
        Check(picked?.ToString()==first.ToString(),"ordinary scene ray picking resolves the exact new object");
        await OpenResult(first);Guide();
        await Submit();await Until(()=>State["world_accepted"]!.GetValue<bool>() && Located(first));Guide();
        Check(guide.Step==4,"committed Enter, not dispatch, advances to nested creation");
        await SelectCreate();await Submit();var nested=Result(SpaceResults(panel.LastOutcome!),"space");
        Check(Result(SpaceResults(panel.LastOutcome!),"location").Args[0].ToString()==first.ToString(),"nested creation is committed inside the current first room");
        await Until(()=>scene.SubjectIds(nested).Length==1);Guide();await Raster("nested-result");await Frame();await Frame();
        var nestedAction=panel.FindChildren("*","Button",true,false).OfType<Button>().Last(b=>b.Text=="Open result: space" && b.TooltipText==nested.ToString());
        Check(new Rect2(Vector2.Zero,gui.Surface.Size).Encloses(nestedAction.GetGlobalRect()),"the newest nested returned-subject action remains immediately reachable");
        await OpenResult(nested);Guide();await Submit();
        await Until(()=>State["world_accepted"]!.GetValue<bool>() && Located(nested));Guide();
        await Action("location-operations");await Until(()=>panel.Available && panel.Current?.Name=="leave");await FreshDraft();await Submit();
        await Until(()=>State["current_location"]!.ToString()=="unplaced");Guide();
        Check(scene.Count==0 && !State["world_accepted"]!.GetValue<bool>() && guide.Step==8,"Leave is explicit unplaced navigation with no stale scene or guessed parent");
        await OpenResult(nested);await Submit();await Until(()=>State["world_accepted"]!.GetValue<bool>() && Located(nested));Guide();
        string location=State["current_location"]!.ToString();int instructions=await Instructions();
        await Press("disconnect");await app.ViewsDisposed;Guide();
        Check(SignedView.LiveSockets==0,"rehearsal disconnect retires every signed consumer");
        await Press("connect");await Until(()=>State["world_accepted"]!.GetValue<bool>());panel=(OperationsPanel)app.FindChild("operations",true,false);Guide();
        Check(State["current_location"]!.ToString()==location && app.ActiveAccounts.Setup!.ToString()==original && await Instructions()==instructions && guide.Step==10,"explicit reconnect restores the same U/A/S0 and committed nested location with zero new instructions");
        adapter.StopSession();await adapter.Completion;
        XRServer.RemoveTracker(left);XRServer.RemoveTracker(right);XRServer.RemoveTracker(head);
        await Press("disconnect");await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0 && adapter.Subscriptions==0 && gui.Captures==0,"all software rehearsal input and view consumers retire");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks,guide_step=guide.Step,first=first.ToString(),nested=nested.ToString(),current_location=location,metrics=adapter.Metrics,physical=false,physics="ordinary unsimulated spaces; no body travel or collision granted"}));
        Console.WriteLine("M4_MORNING_JOURNEY_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
