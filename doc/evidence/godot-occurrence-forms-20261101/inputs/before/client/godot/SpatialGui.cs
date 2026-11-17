using Godot;
using Quod.Client;

// Desktop and XR feed this same native Control tree. There is no spatial form
// dispatcher: the ordinary buttons, editors, drafts and submission owners run.
public partial class SpatialGui : TextureRect
{
    public SubViewport Surface { get; }=new() { Name="gui-viewport",Size=new(1200,800),TransparentBg=false,HandleInputLocally=true };
    bool pressed;
    bool inside;
    Control? captured;
    Vector2 point;
    Vector2 mirrorSize;
    Control? content;
    readonly Control workspace=new() { Name="workspace-content",MouseFilter=MouseFilterEnum.Ignore };
    int desktopTextSize=20,spatialTextSize=26;
    float spatialOpacity=.78f;
    readonly Theme workspaceTheme=SharedAppearance();
    readonly StyleBoxFlat background=new() { BgColor=new(25f/255,43f/255,50f/255,.78f),CornerRadiusTopLeft=10,CornerRadiusTopRight=10,CornerRadiusBottomLeft=10,CornerRadiusBottomRight=10 };
    readonly Panel tint=new() { MouseFilter=MouseFilterEnum.Ignore,Visible=false };
    public bool Spatial { get; private set; }
    public Vector2I WorkspaceSize=>Spatial ? new(1200,800) : new(Math.Max(1,(int)Size.X),Math.Max(1,(int)Size.Y));
    public Theme Appearance=>workspaceTheme;
    public int Captures { get; private set; }
    public int Cancellations { get; private set; }
    public bool NativePressed { get; private set; }
    public event Action? NativeCaptureChanged;
    public event Action? LayoutChanging;
    public event Action? AppearancePreferencesChanged;
    internal bool OpaquePanels=>!Spatial||spatialOpacity==1;
    internal void AppearanceLayoutChanging() { LayoutChanging?.Invoke();Cancel(); }
    internal static Button ActionButton(string text,string name="")
    {
        var button=new Button {Text=text,AutowrapMode=TextServer.AutowrapMode.WordSmart,SizeFlagsHorizontal=SizeFlags.ExpandFill,CustomMinimumSize=new(0,44)};
        if(name.Length>0)button.Name=name;
        button.Ready+=()=>{
            var parent=(Control)button.GetParent();var clips=new List<Control>();
            // A flow allocates its field wrapper from the child's minimum.
            // Using that wrapper's previous width would prevent larger text
            // from asking the same flow for a wider, reflowed column.
            var layout=parent.GetParent() as HFlowContainer ?? parent;
            for(Node? p=parent;p!=null;p=p.GetParent())if(p is Control c&&c.ClipContents)clips.Add(c);
            void Fit() {
                float width=layout.Size.X;
                foreach(var clip in clips)width=Math.Min(width,clip.GetGlobalRect().End.X-layout.GlobalPosition.X);
                var font=button.GetThemeFont("font");int size=button.GetThemeFontSize("font_size");
                float preferred=button.Text.Split('\n').Max(line=>font.GetStringSize(line,HorizontalAlignment.Left,-1,size).X)+button.GetThemeStylebox("normal").GetMinimumSize().X;
                var next=new Vector2(Math.Max(0,Math.Min(width,Mathf.Ceil(preferred))),44);
                if(button.CustomMinimumSize!=next)button.CustomMinimumSize=next;
            }
            layout.Resized+=Fit;foreach(var clip in clips)if(clip!=layout)clip.Resized+=Fit;
            button.ThemeChanged+=Fit;button.MinimumSizeChanged+=Fit;
            button.TreeExiting+=()=>{layout.Resized-=Fit;foreach(var clip in clips)if(clip!=layout)clip.Resized-=Fit;button.ThemeChanged-=Fit;button.MinimumSizeChanged-=Fit;};
            Fit();
        };
        return button;
    }
    // One adapter for offline defaults and each authored container occurrence.
    // Updating existing resources preserves native controls and editor state.
    static Theme SharedAppearance()
    {
        var theme=new Theme { DefaultFontSize=20 };
        PaintAppearance(theme,new Dictionary<string,Term>(),true);theme.SetFontSize("font_size","Heading",24);return theme;
    }
    internal static void PaintAppearance(Theme theme,IReadOnlyDictionary<string,Term> tokens,bool opaque)
    {
        Color Colour(string role,string fallback) {
            if(!tokens.TryGetValue(role,out var value))return new(fallback);
            var rgb=value.Require("rgb",3);return new((float)rgb[0].Integer/255,(float)rgb[1].Integer/255,(float)rgb[2].Integer/255,1);
        }
        int Extent(string role,int fallback)=>tokens.TryGetValue(role,out var value) ? (int)value.Integer : fallback;
        Color ink=Colour("text","#F5F1EB"),edge=Colour("edge","#848FA5"),accent=Colour("accent","#F9C80E"),well=Colour("field","#0F1B20"),panel=Colour("panel","#192B32");
        Color control=tokens.ContainsKey("panel") ? panel.Lightened(.12f) : new("#304C56");
        Color hover=tokens.ContainsKey("panel") ? panel.Lightened(.24f) : new("#416471");
        StyleBoxFlat Box(string kind,string state,Color fill,Color border,int width=1,bool center=true) {
            var box=theme.HasStylebox(state,kind) ? (StyleBoxFlat)theme.GetStylebox(state,kind) : new StyleBoxFlat();
            box.BgColor=fill;box.BorderColor=border;box.DrawCenter=center;
            box.SetBorderWidthAll(width);box.SetCornerRadiusAll(Extent("corner_radius",8));
            box.ContentMarginLeft=Extent("padding",16);box.ContentMarginRight=Extent("padding",16);
            box.ContentMarginTop=Extent("padding",10);box.ContentMarginBottom=Extent("padding",10);
            theme.SetStylebox(state,kind,box);return box;
        }
        foreach(string kind in new[]{"Label","Button","LineEdit","TextEdit","OptionButton","CheckButton","CheckBox","ItemList","PopupMenu","TabContainer"}) {
            theme.SetColor("font_color",kind,ink);theme.SetColor("font_hover_color",kind,ink);theme.SetColor("font_focus_color",kind,ink);
            theme.SetColor("font_pressed_color",kind,ink);theme.SetColor("font_disabled_color",kind,new("#BAC4C8"));
            theme.SetColor("font_uneditable_color",kind,new("#C9D2DB"));theme.SetColor("font_placeholder_color",kind,new("#C9D2DB"));
        }
        foreach(string kind in new[]{"Button","OptionButton","CheckButton","CheckBox"}) {
            Box(kind,"normal",control,edge);Box(kind,"hover",hover,ink);
            Box(kind,"pressed",well,accent,2);Box(kind,"hover_pressed",well,accent,2);
            Box(kind,"disabled",new("#263940"),new("#596B74"));
            Box(kind,"focus",Colors.Transparent,accent,3,false);
        }
        theme.SetTypeVariation("PrimaryAction","Button");
        theme.SetTypeVariation("Heading","Label");
        Box("PrimaryAction","normal",accent,accent);
        Box("PrimaryAction","hover",tokens.ContainsKey("accent") ? accent.Lightened(.24f) : new("#FBD85D"),ink);
        Box("PrimaryAction","pressed",tokens.ContainsKey("accent") ? accent.Darkened(.15f) : new("#D4A900"),ink,2);
        foreach(string state in new[]{"font_color","font_hover_color","font_focus_color","font_pressed_color"})theme.SetColor(state,"PrimaryAction",well);
        foreach(string kind in new[]{"LineEdit","TextEdit","ItemList"}) {
            Box(kind,"normal",well,edge);Box(kind,"read_only",new("#263940"),edge);
            Box(kind,"focus",Colors.Transparent,accent,2,false);
            theme.SetColor("caret_color",kind,accent);theme.SetColor("selection_color",kind,hover);
        }
        Box("PanelContainer","panel",panel,edge);
        theme.SetTypeVariation("AuthoredPanel","PanelContainer");
        Box("AuthoredPanel","panel",new Color(panel,opaque ? 1 : Extent("panel_opacity",780)/1000f),edge);
        Box("PopupMenu","panel",well,edge);Box("PopupMenu","hover",hover,accent);
        theme.SetTypeVariation("ErrorText","Label");theme.SetColor("font_color","ErrorText",Colour("error","#FFB8BD"));
        theme.SetTypeVariation("CompletionText","Label");theme.SetColor("font_color","CompletionText",Colour("success","#C5E7A0"));
        theme.SetColor("font_hover_color","PopupMenu",ink);theme.SetConstant("v_separation","PopupMenu",12);
        foreach(string kind in new[]{"VBoxContainer","HBoxContainer"})theme.SetConstant("separation",kind,Extent("spacing",12));
        foreach(string kind in new[]{"HFlowContainer","GridContainer"}) {
            theme.SetConstant("h_separation",kind,Extent("spacing",12));theme.SetConstant("v_separation",kind,Extent("spacing",12));
        }
    }
    // Reveal only after the actual outer scroll owner installs its layout.
    // Callers fence a queued reveal to the lifetime that requested it.
    internal static void Reveal(Control control,Func<bool> current,Action? installed=null)
    {
        ScrollContainer? viewport=null;
        for(Node? p=control.GetParent();p!=null;p=p.GetParent())if(p is ScrollContainer scroll)viewport=scroll;
        if(viewport==null){installed?.Invoke();return;}var owner=viewport;
        var containers=new List<Container>();
        for(Node? p=control.GetParent();p!=null;p=p.GetParent()) {if(p is Container c)containers.Add(c);if(p==owner)break;}
        if(control.GetViewport().GetParent() is SpatialGui gui){gui.LayoutChanging?.Invoke();gui.Cancel();}
        // A wrapping child can invalidate ancestors. The pinned native owner
        // clears pending_sort BEFORE this installed-state notification; its
        // earlier sort_children signal would lose a scroll reposition request.
        void Sort(Container container,Action next) {
            container.Connect("_layout_pending_finished",Callable.From(next),(uint)ConnectFlags.OneShot);
            container.QueueSort();
        }
        void Next(int index) {
            if(!current() || !IsInstanceValid(control)){installed?.Invoke();return;}
            if(index==containers.Count){installed?.Invoke();return;}
            var container=containers[index];
            Sort(container,()=>{
                if(!current() || !IsInstanceValid(control)){installed?.Invoke();return;}
                if(container is ScrollContainer scroll && control.IsVisibleInTree()) {
                    scroll.EnsureControlVisible(control);Sort(scroll,()=>Next(index+1));
                } else Next(index+1);
            });
        }
        Next(0);
    }
    public override void _Ready()
    {
        SetAnchorsAndOffsetsPreset(LayoutPreset.FullRect);ExpandMode=ExpandModeEnum.IgnoreSize;StretchMode=StretchModeEnum.Scale;
        FocusMode=FocusModeEnum.None;MouseFilter=MouseFilterEnum.Stop;AddChild(Surface);Texture=Surface.GetTexture();
        Surface.RenderTargetUpdateMode=SubViewport.UpdateMode.Always;Resized+=ResizeSurface;ResizeSurface();
        tint.SetAnchorsAndOffsetsPreset(LayoutPreset.FullRect);tint.AddThemeStyleboxOverride("panel",background);Surface.AddChild(tint);tint.Show();
        background.BgColor=new(background.BgColor,1);
        Surface.AddChild(workspace);workspace.Size=WorkspaceSize;InitializeKeyboard();
    }
    public void SetContent(Control next) { content=next;next.Theme??=workspaceTheme;workspace.AddChild(next); }
    public void PresentSpatial(bool next)
    {
        if(Spatial==next)return;EndTextInput();LayoutChanging?.Invoke();Cancel();Spatial=next;Surface.TransparentBg=next;
        workspaceTheme.DefaultFontSize=next ? spatialTextSize : desktopTextSize;
        workspaceTheme.SetFontSize("font_size","Heading",workspaceTheme.DefaultFontSize+4);
        background.BgColor=new(background.BgColor,next ? spatialOpacity : 1);
        AppearancePreferencesChanged?.Invoke();
        ResizeSurface();
    }
    public void TextSize(int change)
    { int next=Math.Clamp(workspaceTheme.DefaultFontSize+change,16,48);if(next==workspaceTheme.DefaultFontSize)return;LayoutChanging?.Invoke();Cancel();workspaceTheme.DefaultFontSize=next;workspaceTheme.SetFontSize("font_size","Heading",next+4);if(Spatial)spatialTextSize=next;else desktopTextSize=next; }
    public void Opaque(bool value) { float next=value ? 1 : .78f;if(spatialOpacity==next)return;spatialOpacity=next;background.BgColor=new(25f/255,43f/255,50f/255,Spatial ? spatialOpacity : 1);AppearancePreferencesChanged?.Invoke(); }
    public void ToggleOpacity()=>Opaque(spatialOpacity<1);
    void ResizeSurface()
    {
        if(mirrorSize!=Size) { LayoutChanging?.Invoke();Cancel();mirrorSize=Size; }
        var pixels=WorkspaceSize;workspace.Size=pixels;
        pixels.Y+=KeyboardHeight;
        if(Surface.Size!=pixels)Surface.Size=pixels;
    }
    public override void _GuiInput(InputEvent input)
    {
        if(input is not InputEventMouse mouse)return;
        if(pressed && !NativePressed){AcceptEvent();return;}
        if(Size.X<=0 || Size.Y<=0){Cancel();return;}
        Move(mouse.Position*(Vector2)Surface.Size/Size);
        if(input is InputEventMouseButton { ButtonIndex:MouseButton.Left } button) {
            if(button.Pressed) { NativePressed=true;NativeCaptureChanged?.Invoke();Press(); }
            else Release();
        } else if(input is not InputEventMouseMotion) {
            var mapped=(InputEventMouse)input.Duplicate();mapped.Position=point;mapped.GlobalPosition=point;Surface.PushInput(mapped,true);
        }
        AcceptEvent();
    }
    public override void _Input(InputEvent input)
    {
        if(input is not InputEventKey key || key.WindowId!=GetWindow().GetWindowId())return;
        if(TextEntryActive && key.Pressed && key.Keycode==Key.Escape) { EndTextInput();GetViewport().SetInputAsHandled();return; }
        Surface.PushInput(input,true);if(Surface.IsInputHandled())GetViewport().SetInputAsHandled();
    }
    public void Move(Vector2 position)
    {
        var previous=point;point=position;
        bool next=new Rect2(Vector2.Zero,Surface.Size).HasPoint(point);
        if(next&&!inside)Surface.NotifyMouseEntered();else if(!next&&inside)Surface.NotifyMouseExited();inside=next;
        Surface.PushInput(new InputEventMouseMotion { Position=point,GlobalPosition=point,Relative=point-previous,ButtonMask=pressed ? MouseButtonMask.Left : 0 },true);
    }
    public void Leave() { if(inside){inside=false;Surface.NotifyMouseExited();} }
    public void Press()
    {
        if(pressed)return;pressed=true;Captures++;
        Surface.PushInput(new InputEventMouseButton { ButtonIndex=MouseButton.Left,Pressed=true,ButtonMask=MouseButtonMask.Left,Position=point,GlobalPosition=point },true);
        captured=Surface.GuiGetHoveredControl();
        if(captured!=null){captured.TreeExiting+=Cancel;captured.VisibilityChanged+=CaptureVisibility;}
    }
    public void Release()
    {
        if(!pressed)return;pressed=false;Captures--;bool wasNative=NativePressed;NativePressed=false;
        bool fieldClick=captured is LineEdit or TextEdit;
        if(captured!=null && IsInstanceValid(captured)){captured.TreeExiting-=Cancel;captured.VisibilityChanged-=CaptureVisibility;}captured=null;
        Surface.PushInput(new InputEventMouseButton { ButtonIndex=MouseButton.Left,Pressed=false,Position=point,GlobalPosition=point },true);
        if(fieldClick)TextFocusChanged(Surface.GuiGetFocusOwner());else RefreshKeyboard();
        if(wasNative)NativeCaptureChanged?.Invoke();
    }
    public void Cancel()
    {
        if(!pressed)return;
        // Moving outside before native release clears BaseButton's inside
        // state. Unlike a synthetic release at the old hit this cannot click.
        Move(new(-10000,-10000));Release();Surface.GuiCancelDrag();Surface.GuiReleaseFocus();Cancellations++;
    }
    void CaptureVisibility() { if(captured==null || !captured.IsVisibleInTree())Cancel(); }
    public override void _ExitTree() { Cancel();EndTextInput();Surface.GuiFocusChanged-=TextFocusChanged; }
}
