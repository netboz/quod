using Godot;
using Quod.Client;
using File=System.IO.File;
using Json=Quod.Client.Json;

public partial class ExportChecks
{
    async Task SignedGui()
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);gui.Size=new(1200,900);
        async Task Raster(string name) {
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            using var image=gui.Surface.GetTexture().GetImage();Check(image.SavePng("/work/"+name+".png")==Error.Ok,"actual signed "+name+" raster retained");
        }
        Rect2 Clip(Control c) {
            var area=new Rect2(Vector2.Zero,gui.Surface.Size);
            for(Node? p=c.GetParent();p!=null;p=p.GetParent())if(p is Control v&&v.ClipContents)area=area.Intersection(v.GetGlobalRect());
            return area;
        }
        async Task Click(Control c) {
            await Frame();await Frame();
            await File.AppendAllTextAsync("/work/targets.jsonl",System.Text.Json.JsonSerializer.Serialize(new {name=c.Name.ToString(),visible=c.IsVisibleInTree(),rect=c.GetGlobalRect().ToString(),clip=Clip(c).ToString()})+"\n");
            Check(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect()),"actual product reveals the native target without diagnostic scrolling: "+c.Name);
            int hits=0;void Hit()=>hits++;if(c is BaseButton button)button.Pressed+=Hit;
            try {gui.Move(c.GetGlobalRect().GetCenter());await Frame();gui.Press();await Frame();gui.Release();await Frame();}
            finally {if(c is BaseButton b)b.Pressed-=Hit;}
            if(c is BaseButton)Check(hits==1,"one native pointer gesture reaches exactly one existing button");
            Check(gui.Captures==0,"native pointer releases its existing capture");
        }
        async Task Choose(OptionButton choice,int index) {
            await Click(choice);var popup=choice.GetPopup();await Frame();
            Check(popup.Visible,"the actual offered-choice popup opens");
            var area=new Rect2(Vector2.Zero,gui.Surface.Size);var popupRect=new Rect2(popup.Position,popup.Size);
            await File.AppendAllTextAsync("/work/targets.jsonl",System.Text.Json.JsonSerializer.Serialize(new {popup=choice.Name.ToString(),rect=popupRect.ToString(),surface=area.ToString(),maximum=popup.MaxSize.ToString(),embedded=popup.IsEmbedded()})+"\n");
            await Raster("popup-"+choice.Name);
            if(popup.IsEmbedded())Check(area.Encloses(popupRect),"the embedded offered-choice popup stays within its actual surface");
            else Check(popup.GetWindowId()!=DisplayServer.InvalidWindowId&&popup.GetVisibleRect().Size==(Vector2)popup.Size,"the desktop popup owns a real native window and its own content viewport");
            int changed=0;void Selected(long _)=>changed++;choice.ItemSelected+=Selected;
            try{popup.SetFocusedItem(index);foreach(bool down in new[]{true,false}) {
                var key=new InputEventKey {Keycode=Key.Enter,Pressed=down,WindowId=popup.GetWindowId()};
                if(popup.IsEmbedded())gui.Surface.PushInput(key,true);else Input.ParseInputEvent(key);
            }await Frame();}
            finally{choice.ItemSelected-=Selected;}
            Check(choice.Selected==index&&changed==1&&!popup.Visible,"one native popup selection reaches the original choice owner");
        }
        // Existing setup owners establish a disposable signed fixture. Only the
        // explicitly measured interactions below claim native pointer coverage.
        await Press("create-key");await Press("connect");await Press("register");await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&State["operation_available"]?.GetValue<bool>()==true);
        Check(!((Control)app.FindChild("create-key",true,false)).IsVisibleInTree()&&((Control)app.FindChild("workspace-connection",true,false)).IsVisibleInTree(),"completed setup is disclosed separately while the working task remains primary");
        await Click((Button)app.FindChild("client-tools",true,false));await Until(()=>!Busy);
        Check(((Button)app.FindChild("start-xr",true,false)).IsVisibleInTree(),"inspection settings retain the existing Start control when connection details are collapsed; it is not invoked");
        await Click((Button)app.FindChild("client-tools",true,false));await Until(()=>!Busy);
        await Raster("initial");
        var human=app.ActiveAccounts.Human!;var session=app.ActiveSession;
        async Task<int> Instructions()=>Json.Binding(await session.Read(human,"personal_instructions(Instructions).",CancellationToken.None),"Instructions").Items.Length;
        int original=await Instructions();
        await Click((Button)app.FindChild("create-operations",true,false));await Until(()=>!Busy);
        var panel=(OperationsPanel)app.FindChild("operations",true,false);
        await Raster("choose-storage");
        var storage=(OptionButton)panel.FindChild("operation-storage",true,false);
        int own=Enumerable.Range(1,storage.ItemCount-1).Single(i=>storage.GetItemTooltip(i)==human.Namespace+" @ "+human.Anchor);
        await Choose(storage,own);await Until(()=>!panel.IsWorking);
        var classes=(OptionButton)panel.FindChild("operation-class",true,false);
        await Choose(classes,Enumerable.Range(1,classes.ItemCount-1).Single(i=>classes.GetItemText(i)=="space"));
        await Until(()=>panel.Available&&panel.Current?.Name=="create");await Frame();await Frame();await Raster("create-form");
        var offer=panel.Current!;var primary=(Button)panel.FormPanel.Input(offer.Form.Submit.ToString())!;
        Check(primary.Text==offer.Form.Tree.Leaves.Single(c=>c.Role==offer.Form.Submit.ToString()).Label&&primary.ThemeTypeVariation=="PrimaryAction","signed authored label and actual submission role select the primary action");
        Check(panel.FormPanel.FindChildren("*","Label",true,false).OfType<Label>().Count(l=>l.Text==offer.Form.Tree.Label)==1,"the selected authored task has one visible title rather than a hidden dropdown caption");
        var actions=(OptionButton)panel.FindChild("offered-operation",true,false);
        Check(actions.Visible==(actions.ItemCount>2),"multiple actual offered actions remain selectable; only a single action omits its redundant chooser");
        Check(panel.StatusText.Contains(primary.Text)&&panel.StatusText.Contains("Local draft"),"current status names the actual action and local-draft boundary");
        var draft=panel.FormPanel.Draft;var control=primary.GetInstanceId();
        int sorts=0;var sorted=Callable.From(()=>sorts++);panel.Connect("sort_children",sorted);
        for(int i=0;i<3;i++)panel.Choose(offer.Name);await Frame();await Frame();
        panel.Disconnect("sort_children",sorted);
        Check(sorts==0&&ReferenceEquals(draft,panel.FormPanel.Draft)&&primary.GetInstanceId()==control,"unchanged accepted choices rebuild no controls and request no native panel layout work");
        gui.Move(primary.GetGlobalRect().GetCenter());gui.Press();gui.Cancel();await Frame();
        Check(await Instructions()==original&&!app.ActiveStore.Snapshot!.Pending.Any(),"cancelling a held native submit creates no signed instruction or pending write");
        Check(ReferenceEquals(draft,panel.FormPanel.Draft)&&primary.GetInstanceId()==control,"held cancellation preserves the actual offered controls and draft");
        await Click(primary);await Until(()=>!panel.IsWorking);
        Check(panel.LastOutcome!=null&&Json.Committed(panel.LastOutcome)&&await Instructions()==original+1,"one explicit native Create commits exactly one original personal instruction");
        await Until(()=>panel.Available && panel.IsVisibleInTree() && State["world_accepted"]?.GetValue<bool>()==true);
        await Frame();await Frame();await Raster("committed-result");
        var result=panel.FindChild("operation-results",true,false).GetChildren().OfType<Button>().First();
        var outcome=panel.FindChild("operation-results",true,false).GetChildren().OfType<Label>().First();
        Check(result.IsVisibleInTree()&&Clip(result).Encloses(result.GetGlobalRect())&&outcome.IsVisibleInTree()&&Clip(outcome).Encloses(outcome.GetGlobalRect())&&outcome.Text.StartsWith("Received outcome · Operation committed"),"committed status and returned action are visible through the existing result owner");
        Check(panel.LastOutcome!=null&&Json.Committed(panel.LastOutcome)&&((Button)panel.FormPanel.Input(panel.Current!.Form.Submit.ToString())!).Disabled,"accepted offer renewal retains the truthful original outcome and does not rearm the submitted draft");
        Check(!((Control)panel.FindChild("operation-exact-details",true,false)).Visible,"exact outcome data stays available behind disclosure");
        await Click(result);await Until(()=>panel.Available&&panel.Current?.Name=="enter");
        Check(panel.Current!.Form.Tree.Label.Length>0&&await Instructions()==original+1,"opening the returned exact subject selects its authored form without a domain write");
        await Click((Button)panel.FindChild("cancel-operation",true,false));
        Check(!panel.IsVisibleInTree()&&await Instructions()==original+1,"ordinary Cancel closes the form without submitting Enter");
        await Click((Button)app.FindChild("workspace-connection",true,false));await Until(()=>!Busy);
        await Click((Button)app.FindChild("disconnect",true,false));await app.ViewsDisposed;
        Check(SignedView.LiveSockets==0&&gui.Captures==0,"ordinary disconnect retires signed views and native captures");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {passed=true,checks,scope="fresh signed production owners; software native Control gestures; no host input, hardware or human acceptance"}));
        Console.WriteLine("GUI_SIGNED_PASS");Console.Out.Flush();await app.CloseApplication();
    }

    async Task GuiOutcomes()
    {
        // Supplied display samples exercise only the real presentation owner.
        // They are not transport responses or signed/domain acceptance evidence.
        var gui=new SpatialGui();app.AddChild(gui);gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);
        var scroll=new ScrollContainer {HorizontalScrollMode=ScrollContainer.ScrollMode.Disabled};scroll.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);gui.SetContent(scroll);
        var show=typeof(OperationsPanel).GetMethod("ShowOutcome",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!;
        foreach(var dimensions in new[]{(new Vector2(1200,800),26),(new Vector2(600,900),48)}) {
            gui.Size=dimensions.Item1;gui.TextSize(dimensions.Item2-gui.Appearance.DefaultFontSize);
            foreach(var sample in new[]{("committed","{\"result\":\"ok\",\"bindings\":[]}","Operation committed"),("refused","{\"result\":\"fail\"}","Operation finished without a commit"),("unknown","{\"result\":\"pending\"}","Outcome unknown")}) {
                var panel=new OperationsPanel {SizeFlagsHorizontal=Control.SizeFlags.ExpandFill};scroll.AddChild(panel);
                ((Control)panel.FindChild("operation-targeting",true,false)).Hide();((Control)panel.FindChild("offered-operation",true,false)).Hide();
                var reply=System.Text.Json.Nodes.JsonNode.Parse(sample.Item2)!;show.Invoke(panel,[reply]);await Frame();await Frame();
                var label=panel.FindChild("operation-results",true,false).GetChildren().OfType<Label>().Single();
                Check(label.Text=="Received outcome · "+panel.StatusText&&panel.StatusText.StartsWith(sample.Item3),"received "+sample.Item1+" outcome is explicitly distinct from a current draft at "+dimensions.Item2);
                Check(panel.LastOutcome!.ToJsonString()==reply.ToJsonString(),"presentation retains the exact supplied outcome without altering its state");
                Check(label.IsVisibleInTree()&&new Rect2(Vector2.Zero,gui.Surface.Size).Intersection(scroll.GetGlobalRect()).Encloses(label.GetGlobalRect()),"native received-outcome label is readable within its actual clipping viewport");
                await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();
                Check(image.SavePng(System.IO.Path.Combine(Env("GUI_IMAGES"),"outcome-"+sample.Item1+"-"+dimensions.Item2+".png"))==Error.Ok,"actual outcome presentation raster retained");
                scroll.RemoveChild(panel);panel.Free();
            }
        }
        gui.Free();await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {passed=true,checks,scope="supplied outcome display samples only; no network or domain action"}));
        Console.WriteLine("GUI_OUTCOMES_PASS");Console.Out.Flush();await app.CloseApplication();
    }

}
