using Godot;
using Quod.Client;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task KeyboardChecks()
    {
        if(Env("M1B_PHASE")=="keyboard-ray"){await KeyboardRay();return;}
        var gui=new SpatialGui();app.AddChild(gui);
        var root=new MarginContainer();root.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);
        foreach(string side in new[]{"left","right","top","bottom"})root.AddThemeConstantOverride("margin_"+side,24);
        gui.SetContent(root);var form=new FormPanel();root.AddChild(form);
        form.Present(Form.Decode(Term.Parse("component(f,form,[property(label,<<\"Local text entry\">>),property(help,<<\"Typing changes this draft only. Save is explicit.\">>)],[component(note,text_box,[property(label,<<\"Name\">>)],[]),component(count,number_input,[property(label,<<\"Count\">>),property(range,range(-100,100,1))],[]),component(notes,text_area,[property(label,<<\"Notes\">>)],[]),component(save,button,[property(label,<<\"Save\">>)],[])])"),Term.Parse("[field(note,<<\"draft\">>),field(count,2),field(notes,<<\"Two lines\">>)]"),Term.Atom("save")));
        gui.PresentSpatial(true);await Frame();await Frame();
        var field=(LineEdit)form.Input("note")!;
        gui.Move(field.GetGlobalRect().GetCenter());gui.Press();gui.Release();await Frame();await Frame();
        Check(field.HasFocus(),"ordinary native pointer focuses the actual editable spatial field");
        var keyboard=gui.FindChild("spatial-keyboard",true,false) as Control;
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {passed=false,checks,field_focused=field.HasFocus(),keyboard_available=keyboard?.IsVisibleInTree()==true}));
        if(DisplayServer.GetName()!="headless"){
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();
            Check(image.SavePng(System.IO.Path.Combine(Env("GUI_IMAGES"),"spatial-text-entry.png"))==Error.Ok,"actual focused spatial field raster retained");
        }
        Check(keyboard?.IsVisibleInTree()==true,"focusing an editable spatial native field exposes the adjacent keyboard");
        int submits=0,changes=0;form.Invoked+=_=>submits++;form.Edited+=()=>changes++;
        var draft=form.Draft;ulong fieldId=field.GetInstanceId();
        async Task Pixel(Control c) {gui.Move(c.GetGlobalRect().GetCenter());await Frame();gui.Press();await Frame();gui.Release();await Frame();await Frame();}
        Button KeyButton(string name)=>(Button)gui.FindChild("keyboard-"+name,true,false);
        async Task Type(string name)=>await Pixel(KeyButton(name));
        field.Text="aé🦉b";field.EmitSignal(LineEdit.SignalName.TextChanged,field.Text);field.CaretColumn=1;
        for(int i=0;i<2;i++){gui.Surface.PushInput(new InputEventKey {Keycode=Key.Right,ShiftPressed=true,Pressed=true},true);gui.Surface.PushInput(new InputEventKey {Keycode=Key.Right,ShiftPressed=true,Pressed=false},true);}
        Check(field.GetSelectedText()=="é🦉","native shift-arrow selection owns the Unicode range and its caret");
        int keyDown=0,keyPressed=0;KeyButton("char-122").ButtonDown+=()=>keyDown++;KeyButton("char-122").Pressed+=()=>keyPressed++;
        await Type("char-122");
        Console.WriteLine("KEYBOARD_EDIT "+System.Text.Json.JsonSerializer.Serialize(new {field.Text,draft=form.Draft["note"],focus=field.HasFocus(),keyboard.Visible,keyDown,keyPressed,caret=field.CaretColumn,selection=field.GetSelectedText()}));
        Check(field.Text=="azb"&&form.Draft["note"]=="azb"&&field.HasFocus(),"virtual AZERTY key replaces native Unicode selection through the existing draft event");
        await Type("backspace");Check(field.Text=="ab","Backspace uses the native caret and delete owner");
        await Type("shift");await Type("undo");Check(field.Text=="azb","labelled Undo remains native Undo when Shift is enabled");await Type("shift");
        field.CaretColumn=1;await Type("delete");Check(field.Text=="ab","Delete edits forward from the native caret");
        await Type("shift");await Type("char-97");Check(field.Text=="aAb","Shift changes the actual key input without replacing the native editor");await Type("shift");
        await Type("left");await Type("char-122");Check(field.Text=="azAb","caret movement and insertion use ordinary native key events");
        int submitted=0;field.TextSubmitted+=_=>submitted++;
        await Type("enter");Check(submitted==1&&submits==0,"Enter follows LineEdit semantics and does not invoke the form Save");
        var number=(LineEdit)form.Input("count")!;await Pixel(number);number.SelectAll();await Type("char-51");
        Check(form.Draft["count"]=="3"&&number.Text=="3","the same keyboard edits an ordinary numeric field and its existing binder");
        var notes=(TextEdit)form.Input("notes")!;
        var revealed=new TaskCompletionSource();SpatialGui.Reveal(notes,()=>GodotObject.IsInstanceValid(notes),()=>revealed.TrySetResult());
        await revealed.Task.WaitAsync(TimeSpan.FromSeconds(60));await Pixel(notes);notes.SetCaretLine(0);notes.SetCaretColumn(notes.Text.Length);await Type("enter");await Type("char-97");
        Check(notes.Text=="Two lines\na"&&form.Draft["notes"]==notes.Text,"multiline Enter and typing retain the actual TextEdit local draft");
        app.GetViewport().PushInput(new InputEventKey {Unicode=0x00e9,Pressed=true,WindowId=app.GetWindow().GetWindowId()},true);
        app.GetViewport().PushInput(new InputEventKey {Unicode=0x00e9,Pressed=false,WindowId=app.GetWindow().GetWindowId()},true);await Frame();
        Check(notes.Text=="Two lines\naé","ordinary native hardware-event route remains usable beside the spatial keyboard");
        string retained=notes.Text;await Type("hide");Check(!keyboard.IsVisibleInTree()&&notes.HasFocus()&&notes.Text==retained,"local Hide preserves the exact focused field and draft");
        await Pixel(notes);Check(keyboard.IsVisibleInTree(),"clicking the same field can reopen a locally hidden keyboard");
        gui.Move(KeyButton("char-97").GetGlobalRect().GetCenter());gui.Press();gui.Release();
        form.Lock(true);await Frame();await Frame();
        Check(notes.Text==retained&&!keyboard.IsVisibleInTree()&&gui.Captures==0,"locking the real form revokes an already queued key without editing or capture");
        form.Lock(false);await Pixel(notes);gui.Move(KeyButton("char-97").GetGlobalRect().GetCenter());gui.Press();
        form.Hide();await Frame();gui.Release();await Frame();
        Check(notes.Text==retained&&!keyboard.IsVisibleInTree()&&gui.Captures==0,"withdrawn visibility cancels a held key without click-through");
        form.Show();await Frame();await Pixel(field);field.Editable=false;await Frame();
        Check(!keyboard.IsVisibleInTree(),"native readonly LineEdit state withdraws keyboard eligibility");field.Editable=true;
        await Pixel(notes);notes.Editable=false;await Frame();await Frame();
        Check(!keyboard.IsVisibleInTree(),"native readonly TextEdit state withdraws keyboard eligibility");notes.Editable=true;
        await Pixel(field);
        var popup=FormPanel.Choice("keyboard-choice");popup.Position=new(900,20);popup.Size=new(240,60);gui.Surface.AddChild(popup);popup.AddItem("One");popup.AddItem("Two");gui.Surface.GuiEmbedSubwindows=true;
        int opens=0,hides=0;popup.GetPopup().AboutToPopup+=()=>opens++;popup.GetPopup().PopupHide+=()=>hides++;
        await Pixel(popup);Console.WriteLine("KEYBOARD_POPUP "+System.Text.Json.JsonSerializer.Serialize(new {visible=popup.GetPopup().Visible,keyboard=keyboard.Visible,opens,hides,captures=gui.Captures,focus=gui.Surface.GuiGetFocusOwner()?.Name.ToString()}));
        Check(popup.GetPopup().Visible&&!keyboard.IsVisibleInTree(),"ordinary native popup focus withdraws the text keyboard");
        popup.GetPopup().Hide();popup.Free();await Pixel(field);
        string oldField=field.Text,oldNotes=notes.Text;
        gui.Move(KeyButton("char-97").GetGlobalRect().GetCenter());gui.Press();gui.Release();notes.GrabFocus();await Frame();await Frame();
        Check(field.Text==oldField&&notes.Text==oldNotes&&notes.HasFocus(),"changing the actual native focus revokes a queued key for the previous field");
        await Pixel(field);
        bool priorShift=KeyButton("shift").ButtonPressed;
        gui.Move(KeyButton("shift").GetGlobalRect().GetCenter());gui.Press();gui.Release();notes.GrabFocus();await Frame();await Frame();
        Check(KeyButton("shift").ButtonPressed==priorShift&&KeyButton("char-97").Text=="a","a revoked native Shift release retains a truthful unchanged checked state and letter case");
        await Pixel(field);string priorText=field.Text;field.Secret=true;field.Text="dummy-private-field";
        Check(field.Secret&&keyboard.FindChildren("*","Label",true,false).OfType<Label>().All(l=>!l.Text.Contains(field.Text))&&keyboard.FindChildren("*","Button",true,false).OfType<Button>().All(b=>!b.Text.Contains(field.Text)),"masked native field text is not copied into keyboard labels or previews");
        field.Text=priorText;field.Secret=false;
        var keyboardId=keyboard.GetInstanceId();var themeId=gui.Appearance.GetInstanceId();int sorts=0;
        keyboard.Connect(Container.SignalName.SortChildren,Callable.From(()=>sorts++));
        await Frame();await Frame();int stableSorts=sorts;
        for(int i=0;i<10;i++){field.GrabFocus();gui.PresentSpatial(true);await Frame();}
        Check(keyboard.GetInstanceId()==keyboardId&&gui.Appearance.GetInstanceId()==themeId&&sorts==stableSorts,"unchanged focus and spatial frames reuse controls theme and installed layout");
        var geometries=new List<object>();
        foreach(int font in new[]{26,48}) {
            gui.TextSize(font-gui.Appearance.DefaultFontSize);await Frame();await Frame();await Pixel(field);await Frame();
            Rect2 Clip(Control control) {
                var r=new Rect2(Vector2.Zero,gui.Surface.Size);
                for(Node? p=control.GetParent();p!=null;p=p.GetParent())if(p is Control c&&c.ClipContents)r=r.Intersection(c.GetGlobalRect());return r;
            }
            foreach(var control in keyboard.FindChildren("*","Button",true,false).OfType<Button>().Append<Control>(field)) {
                var r=control.GetGlobalRect();geometries.Add(new {font,name=control.Name.ToString(),rect=r.ToString(),clip=Clip(control).ToString()});
                Check(Clip(control).Encloses(r),"keyboard/active native target enclosed at "+font+": "+control.Name);
            }
            Check(keyboard.Position.Y>=800&&field.GetGlobalRect().End.Y<=800,"adjacent keyboard does not obscure or shrink the working field at "+font);
            Check(((StyleBoxFlat)keyboard.GetThemeStylebox("panel")).BgColor.A==1,"keyboard background is opaque at "+font);
            if(DisplayServer.GetName()!="headless"){
                await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=gui.Surface.GetTexture().GetImage();
                Check(image.SavePng(System.IO.Path.Combine(Env("GUI_IMAGES"),"keyboard-"+font+".png"))==Error.Ok,"actual keyboard "+font+" raster retained");
            }
        }
        Check(ReferenceEquals(draft,form.Draft)&&field.GetInstanceId()==fieldId&&submits==0&&changes>0,"native edit events preserve the exact form/control/draft and never submit");
        gui.PresentSpatial(false);await Frame();Check(!keyboard.IsVisibleInTree()&&gui.Surface.Size==gui.WorkspaceSize,"desktop restoration retires the keyboard extension");
        gui.PresentSpatial(true);await Frame();await Pixel(field);gui.Move(KeyButton("char-97").GetGlobalRect().GetCenter());gui.Press();gui.Release();
        form.Clear();await Frame();await Frame();Check(!keyboard.IsVisibleInTree()&&gui.Captures==0,"retiring the exact consumer revokes queued input before a replacement form");
        gui.Free();
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {passed=true,checks,geometries}));
        Console.WriteLine("KEYBOARD_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task KeyboardRay()
    {
        var gui=new SpatialGui();app.AddChild(gui);
        var root=new Control();root.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);gui.SetContent(root);
        var field=new LineEdit {Position=new(24,200),Size=new(1152,80),Text="draft"};root.AddChild(field);
        var status=new Label {Position=new(24,300),Text="Local draft — no operation submitted."};root.AddChild(status);
        var scene=new ScenePanel();app.AddChild(scene);await Frame();
        var bytes=await File.ReadAllBytesAsync(Env("M4_MODEL"));
        var mapping=ControllerMapping.Decode(Term.Parse(await File.ReadAllTextAsync(Env("M4_MAPPING"))))!;
        using var models=new RenderModels((asset,cancellation)=>Task.FromResult(bytes));
        var adapter=new OpenXRInput();scene.Viewport.AddChild(adapter);
        adapter.Configure(scene,gui,models,()=>null,()=>false,()=>new[]{("Close menu",(Func<bool>)(()=>true),(Action)(()=>{}))});
        Check(XRServer.GetTracker("head")==null,"software fixture owns an unused head tracker name");
        var head=new XRPositionalTracker {Name="head",Type=XRServer.TrackerType.Head};XRServer.AddTracker(head);
        head.SetPose("default",new(Basis.Identity,new(0,1.6f,0)),Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
        XRControllerTracker Tracker(string name,XRPositionalTracker.TrackerHand hand) {
            var t=new XRControllerTracker {Name=name,Type=XRServer.TrackerType.Controller,Profile="/interaction_profiles/htc/vive_controller",Hand=hand};
            t.SetInput("trigger_press",false);t.SetInput("trigger_value",0.0);t.SetInput("squeeze_press",false);t.SetInput("pad_press",false);t.SetInput("pad_touch",false);t.SetInput("pad_axes",Vector2.Zero);
            t.SetPose("aim",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);
            t.SetPose("grip",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);XRServer.AddTracker(t);return t;
        }
        var left=Tracker("keyboard_left",XRPositionalTracker.TrackerHand.Left);var right=Tracker("keyboard_right",XRPositionalTracker.TrackerHand.Right);
        adapter.AttachSources();adapter.Install(mapping);adapter.PresentWorkspace(true);
        ulong frame=0;void Advance(bool focused=true,bool running=true,bool tracked=true)=>adapter.Advance(++frame,focused,running,tracked);
        Advance();await Frame();await adapter.Completion;Advance();
        var origin=(Node3D)adapter.FindChild("xr-origin",true,false);
        Vector3 WorldPoint(Control control) {
            var pixels=gui.Surface.Size;var mesh=(QuadMesh)adapter.GuiSurface.Mesh;var p=control.GetGlobalRect().GetCenter();
            return adapter.GuiSurface.GlobalTransform*(mesh.CenterOffset+new Vector3((p.X/pixels.X-.5f)*mesh.Size.X,(.5f-p.Y/pixels.Y)*mesh.Size.Y,0));
        }
        void Aim(Control control) {
            var hit=WorldPoint(control);var pose=new Transform3D(adapter.GuiSurface.GlobalBasis,hit+adapter.GuiSurface.GlobalBasis.Z);
            left.SetPose("aim",origin.GlobalTransform.AffineInverse()*pose,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);Advance();
        }
        void Trigger(bool down){left.SetInput("trigger_press",down);Advance();}
        async Task Click(Control control){Aim(control);Trigger(true);await Frame();Trigger(false);await Frame();await Frame();Advance();}
        var before=WorldPoint(field);var panelPose=adapter.GuiSurface.GlobalTransform;
        await Click(field);var keyboard=(Control)gui.FindChild("spatial-keyboard",true,false);
        Check(field.HasFocus()&&keyboard.IsVisibleInTree(),"actual signed mapping and injected tracked ray focus the existing native editor");
        Check(WorldPoint(field).DistanceTo(before)<.00001f&&adapter.GuiSurface.GlobalTransform.IsEqualApprox(panelPose),"opening the adjacent surface preserves actual field world position and stable panel transform");
        Button KeyButton(string name)=>(Button)gui.FindChild("keyboard-"+name,true,false);
        field.CaretColumn=field.Text.Length;await Click(KeyButton("char-97"));
        Check(field.Text=="drafta"&&gui.Captures==0&&adapter.Blocked,"one mapped release types once and the existing travel owner is blocked during text entry");
        foreach(int font in new[]{26,48}) {
            gui.TextSize(font-gui.Appearance.DefaultFontSize);await Frame();await Frame();await Click(field);
            string old=field.Text;await Click(KeyButton("char-122"));Check(field.Text==old+"z","actual ray hits enlarged keyboard native target at "+font);
            var mesh=(QuadMesh)adapter.GuiSurface.Mesh;
            Check(Mathf.Abs(mesh.Size.Y/gui.Surface.Size.Y-mesh.Size.X/gui.Surface.Size.X)<.000001f&&
                field.GetGlobalRect().End.Y<keyboard.Position.Y&&status.GetGlobalRect().End.Y<keyboard.Position.Y,
                "current "+font+" keyboard geometry preserves text scale and visible active field/status");
        }
        gui.Surface.GuiEmbedSubwindows=true;var popup=FormPanel.Choice("ray-choice");popup.Position=new(900,20);popup.Size=new(240,60);root.AddChild(popup);popup.AddItem("One");popup.AddItem("Two");
        await Frame();await Click(popup);
        Check(popup.GetPopup().Visible&&!keyboard.Visible,"actual mapped ray opens the native popup while the adjacent keyboard withdraws");
        popup.GetPopup().Hide();popup.Free();await Click(field);
        string retained=field.Text;Aim(KeyButton("char-97"));Trigger(true);Advance(focused:false);Trigger(false);await Frame();
        Check(field.Text==retained&&!keyboard.IsVisibleInTree()&&gui.Captures==0,"native eligibility loss cancels a held key and hides its surface without a release edit");
        Advance();await Click(field);Aim(KeyButton("char-97"));Trigger(true);adapter.Install(null);Trigger(false);await Frame();
        Check(field.Text==retained&&!keyboard.IsVisibleInTree()&&gui.Captures==0,"signed mapping withdrawal cancels the exact native keyboard capture");
        adapter.Install(mapping);Advance();await Click(field);Aim(KeyButton("char-97"));Trigger(true);
        left.InvalidatePose("aim");Advance();Trigger(false);await Frame();
        Check(field.Text==retained&&gui.Captures==0,"tracking loss never turns a held key into a delayed click");
        left.SetPose("aim",Transform3D.Identity,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);Advance();await Click(field);
        var source=adapter.Sources.Single(s=>s.Hand=="right");
        Check(adapter.OpenMenu(source,System.Numerics.Vector2.Zero,.2f)&&!keyboard.IsVisibleInTree(),"existing mapped menu dismisses the keyboard without changing its field");adapter.CancelMenu();
        Advance();await Click(field);adapter.HideWorkspace();await Frame();
        Check(!keyboard.IsVisibleInTree()&&field.Text==retained,"workspace Hide withdraws keyboard presentation and preserves text");
        adapter.ShowWorkspace();Advance();await Click(field);
        string resources=System.Text.Json.JsonSerializer.Serialize(models.Metrics);ulong keyboardId=keyboard.GetInstanceId();int subscriptions=adapter.Subscriptions;
        for(int i=0;i<12;i++){Advance();await Frame();}
        Check(resources==System.Text.Json.JsonSerializer.Serialize(models.Metrics)&&keyboard.GetInstanceId()==keyboardId&&adapter.Subscriptions==subscriptions,"unchanged native frames reuse keyboard model resources and subscriptions");
        adapter.StopSession();await adapter.Completion;await Frame();
        Check(adapter.Subscriptions==0&&models.LiveLeases==0&&models.LiveTemplates==0&&gui.Captures==0&&!keyboard.IsVisibleInTree(),"ordinary input-owner retirement releases sources resources captures and keyboard target");
        XRServer.RemoveTracker(left);XRServer.RemoveTracker(right);XRServer.RemoveTracker(head);left.Dispose();right.Dispose();head.Dispose();
        scene.Free();gui.Free();
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {passed=true,checks}));
        Console.WriteLine("KEYBOARD_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
