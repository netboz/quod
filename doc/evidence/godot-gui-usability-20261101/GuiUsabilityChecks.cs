using Godot;
using Quod.Client;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task GuiUsability()
    {
        if(System.Environment.GetEnvironmentVariable("GUI_ONLY")=="authored-layout"){await AuthoredGuiLayout();return;}
        var reports=new List<object>();var failures=new List<string>();
        async Task Probe(bool value,string name) {
            reports.Add(new { name,passed=value });
            Console.WriteLine((value?"PASS ":"FAIL ")+name);Console.Out.Flush();
            if(value)checks.Add(name);else failures.Add(name);
            await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { passed=false,checks,reports,failures }));
        }
        async Task Raster(SpatialGui gui,string name) {
            if(DisplayServer.GetName()=="headless")return;
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            using var image=gui.Surface.GetTexture().GetImage();
            Check(image.SavePng(System.IO.Path.Combine(Env("GUI_IMAGES"),name+".png"))==Error.Ok,"actual "+name+" raster retained");
        }
        var shell=(SpatialGui)app.FindChild("shared-gui",true,false);
        await Frame();await Raster(shell,"ordinary-offline");
        var surface=new SpatialGui();app.AddChild(surface);
        var margin=new MarginContainer();margin.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);
        foreach(string edge in new[]{"left","right","top","bottom"})margin.AddThemeConstantOverride("margin_"+edge,24);
        surface.SetContent(margin);
        var form=new FormPanel();margin.AddChild(form);
        form.Present(Form.Decode(Term.Parse("component(f,form,[property(label,<<\"Create a named space\">>),property(help,<<\"A local draft; nothing is created before Create.\">>)],[component(note,text_box,[property(label,<<\"Space name\">>)],[]),component(mode,selection,[property(label,<<\"Access\">>),property(options,[option(private,<<\"Private\">>),option(shared,<<\"Shared\">>)])],[]),component(create,button,[property(label,<<\"Create\">>)],[]),component(cancel,button,[property(label,<<\"Cancel\">>)],[])])"),Term.Parse("[field(note,<<\"Unsent draft\">>),field(mode,private)]"),Term.Atom("create")));
        await Frame();await Frame();
        var primary=(Button)form.Input("create")!;var cancel=(Button)form.Input("cancel")!;var entry=(LineEdit)form.Input("note")!;
        foreach(bool spatial in new[]{false,true}) {
            surface.PresentSpatial(spatial);await Frame();await Frame();
            await Raster(surface,spatial?"spatial-form":"desktop-form");
            var normal=primary.GetThemeStylebox("normal") as StyleBoxFlat;
            var edit=entry.GetThemeStylebox("normal") as StyleBoxFlat;
            await Probe(normal!=null && normal.BgColor.A==1 && normal.BorderWidthLeft>0 && edit!=null && edit.BgColor.A==1 && edit.BorderWidthLeft>0,
                "opaque bounded native button and editable field in "+(spatial?"spatial":"desktop")+" composition");
            var other=cancel.GetThemeStylebox("normal") as StyleBoxFlat;
            await Probe(normal!=null && other!=null && normal.BgColor!=other.BgColor,
                "the actual authored submit has distinct primary-action appearance in "+(spatial?"spatial":"desktop")+" composition");
            await Probe(form.FindChildren("*","Label",true,false).OfType<Label>().Any(l=>l.Text==form.Descriptor.Tree.Label && l.IsVisibleInTree()),
                "the current authored task title is rendered in "+(spatial?"spatial":"desktop")+" composition");
        }
        Check(failures.Count==0,"original six presentation obligations remain strict");
        int invoked=0;form.Invoked+=_=>invoked++;var draft=form.Draft;ulong id=entry.GetInstanceId();
        Rect2 Clip(Control c) {
            var area=new Rect2(Vector2.Zero,surface.Surface.Size);
            for(Node? p=c.GetParent();p!=null;p=p.GetParent())if(p is Control v && v.ClipContents)area=area.Intersection(v.GetGlobalRect());
            return area;
        }
        async Task Pixel(Vector2 p) {surface.Move(p);await Frame();surface.Press();await Frame();surface.Release();await Frame();}
        foreach(var scenario in new[]{(false,new Vector2(1200,800),20),(false,new Vector2(600,900),48),(true,new Vector2(1200,800),26),(true,new Vector2(1200,800),48)}) {
            surface.PresentSpatial(scenario.Item1);surface.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);surface.Size=scenario.Item2;
            surface.TextSize(scenario.Item3-surface.Appearance.DefaultFontSize);await Frame();await Frame();
            string label=(scenario.Item1?"spatial":"desktop")+"-"+scenario.Item3;
            foreach(var c in new Control[]{entry,form.Input("mode")!,primary,cancel}) {
                reports.Add(new {scenario=label,control=c.Name.ToString(),rect=c.GetGlobalRect().ToString(),clip=Clip(c).ToString()});
                await Probe(c.IsVisibleInTree()&&Clip(c).Encloses(c.GetGlobalRect()),"native control enclosed by every clipping ancestor: "+label+" "+c.Name);
            }
            await Raster(surface,label);
        }
        Check(failures.Count==0,"finite actual layout obligations remain strict");
        surface.TextSize(26-surface.Appearance.DefaultFontSize);await Frame();await Frame();
        var normalStyle=(StyleBoxFlat)primary.GetThemeStylebox("normal");
        await Probe(primary.GetThemeStylebox("hover") is StyleBoxFlat hover && hover.BgColor!=normalStyle.BgColor &&
            primary.GetThemeStylebox("pressed") is StyleBoxFlat pressed && pressed.BgColor!=normalStyle.BgColor &&
            primary.GetThemeStylebox("focus") is StyleBoxFlat focus && focus.BorderWidthLeft>=2 && !focus.DrawCenter,
            "hover pressed and keyboard focus have distinct native visual states");
        surface.Move(primary.GetGlobalRect().GetCenter());await Frame();await Raster(surface,"hover");
        surface.Press();await Frame();await Raster(surface,"pressed");surface.Cancel();await Frame();
        await Probe(invoked==0&&surface.Captures==0,"cancelling a held shared pointer does not activate the authored action");
        await Pixel(primary.GetGlobalRect().GetCenter());
        await Probe(invoked==1&&surface.Captures==0,"one fresh native press and release activates exactly once");
        form.Lock(true);await Frame();await Raster(surface,"disabled");await Pixel(primary.GetGlobalRect().GetCenter());
        await Probe(invoked==1&&!entry.Editable&&primary.Disabled&&primary.GetThemeColor("font_disabled_color").A==1,"locked controls remain readable and cannot activate or edit");
        form.Lock(false);await Pixel(entry.GetGlobalRect().GetCenter());
        await Probe(entry.HasFocus()&&form.Draft["note"]=="Unsent draft","ordinary pointer focuses the existing editor without changing its draft");
        surface.Surface.PushInput(new InputEventKey {Keycode=Key.Tab,Pressed=true},true);
        surface.Surface.PushInput(new InputEventKey {Keycode=Key.Tab,Pressed=false},true);await Frame();
        await Probe(surface.Surface.GuiGetFocusOwner()==form.Input("mode"),"native Tab navigation reaches the next existing field");
        primary.GrabFocus();surface.Surface.PushInput(new InputEventKey {Keycode=Key.Space,Pressed=true},true);
        surface.Surface.PushInput(new InputEventKey {Keycode=Key.Space,Pressed=false},true);await Frame();
        await Probe(invoked==2,"one native keyboard activation follows the same authored action owner");
        var choice=(OptionButton)form.Input("mode")!;surface.Surface.GuiEmbedSubwindows=true;
        int selected=0;choice.ItemSelected+=_=>selected++;
        await Pixel(choice.GetGlobalRect().GetCenter());var popup=choice.GetPopup();await Frame();
        await Probe(popup.Visible&&new Rect2(Vector2.Zero,surface.Surface.Size).Encloses(new Rect2(popup.Position,popup.Size)),"actual native popup is visible and enclosed");
        popup.SetFocusedItem(1);surface.Surface.PushInput(new InputEventKey {Keycode=Key.Enter,Pressed=true},true);surface.Surface.PushInput(new InputEventKey {Keycode=Key.Enter,Pressed=false},true);await Frame();
        reports.Add(new {popupSelections=selected,choice.Selected,popup.Visible,draftValue=form.Draft["mode"]});
        await Probe(selected==1&&choice.Selected==1&&!popup.Visible&&form.Draft["mode"]=="shared","actual native popup keyboard selection changes exactly one local choice");
        await Probe(ReferenceEquals(draft,form.Draft)&&entry.GetInstanceId()==id&&invoked==2,"all appearance and layout changes retain the same controls draft and action count");
        var sameStyle=primary.GetThemeStylebox("normal").GetInstanceId();int cancellations=surface.Cancellations;
        for(int i=0;i<5;i++){surface.TextSize(0);surface.PresentSpatial(true);}
        await Probe(primary.GetThemeStylebox("normal").GetInstanceId()==sameStyle&&surface.Cancellations==cancellations,"unchanged presentation calls retain theme resources and do not cancel again");
        surface.Free();
        shell.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);shell.Size=new(600,900);shell.TextSize(48-shell.Appearance.DefaultFontSize);await Frame();await Frame();
        await Raster(shell,"ordinary-narrow-large");
        foreach(var button in app.FindChildren("*","Button",true,false).OfType<Button>().Where(b=>b.IsVisibleInTree())) {
            var r=button.GetGlobalRect();reports.Add(new {shellButton=button.Name.ToString(),rect=r.ToString()});
            await Probe(r.Position.X>=0&&r.End.X<=shell.Surface.Size.X,"narrow large-text shell keeps native button width: "+button.Name);
        }
        ((Button)app.FindChild("workspace-settings",true,false)).GrabFocus();
        shell.Surface.PushInput(new InputEventKey {Keycode=Key.Tab,Pressed=true},true);
        shell.Surface.PushInput(new InputEventKey {Keycode=Key.Tab,Pressed=false},true);await Frame();await Frame();
        var key=(Button)app.FindChild("create-key",true,false);var keyClip=new Rect2(Vector2.Zero,shell.Surface.Size);
        for(Node? p=key.GetParent();p!=null;p=p.GetParent())if(p is Control c&&c.ClipContents)keyClip=keyClip.Intersection(c.GetGlobalRect());
        await Probe(shell.Surface.GuiGetFocusOwner()==key&&keyClip.Encloses(key.GetGlobalRect()),"ordinary Tab reveals the next large-text action through the installed scroll owner");
        Check(failures.Count==0,"shared presentation obligations: "+string.Join("; ",failures));
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { passed=true,checks,reports,failures }));
        Console.WriteLine("GUI_USABILITY_PASS");Console.Out.Flush();await app.CloseApplication();
    }
    async Task AuthoredGuiLayout()
    {
        var surface=new SpatialGui();app.AddChild(surface);surface.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);surface.Size=new(1600,800);
        var margin=new MarginContainer();margin.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.FullRect);surface.SetContent(margin);
        var form=new FormPanel();margin.AddChild(form);
        var records=new List<object>();
        foreach(string layout in new[]{"row","grid","column","implicit"}) {
            string property=layout=="implicit" ? "" : ",property(layout,"+layout+")";
            form.Present(Form.Decode(Term.Parse("component(f,form,[property(label,<<\"Authored "+layout+"\">>)"+property+"],[component(first,text_box,[property(label,<<\"First\">>)],[]),component(apply,button,[property(label,<<\"Apply here\">>)],[]),component(last,text_box,[property(label,<<\"Last\">>)],[])])"),Term.Parse("[field(first,<<\"one\">>),field(last,<<\"two\">>)]"),Term.Atom("apply")));
            await Frame();await Frame();
            var a=form.Input("first")!.GetGlobalRect();var b=form.Input("apply")!.GetGlobalRect();var c=form.Input("last")!.GetGlobalRect();
            bool ordered=layout=="row" ? a.Position.X<b.Position.X&&b.Position.X<c.Position.X : a.Position.Y<b.Position.Y&&b.Position.Y<c.Position.Y;
            records.Add(new {layout,first=a.ToString(),action=b.ToString(),last=c.ToString(),ordered});
            await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {passed=false,checks,records}));
            if(DisplayServer.GetName()!="headless"){await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=surface.Surface.GetTexture().GetImage();Check(image.SavePng(System.IO.Path.Combine(Env("GUI_IMAGES"),"authored-"+layout+".png"))==Error.Ok,"actual authored "+layout+" raster retained");}
            Check(ordered,"explicit authored "+layout+" retains interleaved action and field order");
            if(layout=="grid")Check(form.FindChildren("*","GridContainer",true,false).Count==1,"the explicit grid uses its native grid container rather than a coincidentally vertical substitute");
            Check(form.Draft["first"]=="one"&&form.Draft["last"]=="two","authored layout preserves exact local values");
        }
        surface.Free();await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {passed=true,checks,records}));
        Console.WriteLine("GUI_USABILITY_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
