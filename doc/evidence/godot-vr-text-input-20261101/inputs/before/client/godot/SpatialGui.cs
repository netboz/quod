using Godot;

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
    int desktopTextSize=20,spatialTextSize=26;
    float spatialOpacity=.78f;
    readonly Theme workspaceTheme=SharedAppearance();
    readonly StyleBoxFlat background=new() { BgColor=new(25f/255,43f/255,50f/255,.78f),CornerRadiusTopLeft=10,CornerRadiusTopRight=10,CornerRadiusBottomLeft=10,CornerRadiusBottomRight=10 };
    readonly Panel tint=new() { MouseFilter=MouseFilterEnum.Ignore,Visible=false };
    public bool Spatial { get; private set; }
    public Theme Appearance=>workspaceTheme;
    public int Captures { get; private set; }
    public int Cancellations { get; private set; }
    public bool NativePressed { get; private set; }
    public event Action? NativeCaptureChanged;
    public event Action? LayoutChanging;
    internal static Button ActionButton(string text,string name="")
    {
        var button=new Button {Text=text,AutowrapMode=TextServer.AutowrapMode.WordSmart,SizeFlagsHorizontal=SizeFlags.ExpandFill,CustomMinimumSize=new(0,44)};
        if(name.Length>0)button.Name=name;
        button.Ready+=()=>{
            var parent=(Control)button.GetParent();var clips=new List<Control>();
            for(Node? p=parent;p!=null;p=p.GetParent())if(p is Control c&&c.ClipContents)clips.Add(c);
            void Fit() {
                float width=parent.Size.X;
                foreach(var clip in clips)width=Math.Min(width,clip.GetGlobalRect().End.X-parent.GlobalPosition.X);
                var font=button.GetThemeFont("font");int size=button.GetThemeFontSize("font_size");
                float preferred=button.Text.Split('\n').Max(line=>font.GetStringSize(line,HorizontalAlignment.Left,-1,size).X)+button.GetThemeStylebox("normal").GetMinimumSize().X;
                var next=new Vector2(Math.Max(0,Math.Min(width,Mathf.Ceil(preferred))),44);
                if(button.CustomMinimumSize!=next)button.CustomMinimumSize=next;
            }
            parent.Resized+=Fit;foreach(var clip in clips)if(clip!=parent)clip.Resized+=Fit;
            button.ThemeChanged+=Fit;button.MinimumSizeChanged+=Fit;
            button.TreeExiting+=()=>{parent.Resized-=Fit;foreach(var clip in clips)if(clip!=parent)clip.Resized-=Fit;button.ThemeChanged-=Fit;button.MinimumSizeChanged-=Fit;};
            Fit();
        };
        return button;
    }
    // Adapter defaults for the shared GUI palette. Authored controls retain
    // their labels, roles, enabled state and explicit native overrides.
    static Theme SharedAppearance()
    {
        var theme=new Theme { DefaultFontSize=20 };
        Color ink=new("#F5F1EB"),edge=new("#848FA5"),gold=new("#F9C80E"),well=new("#0F1B20");
        StyleBoxFlat Box(Color fill,Color border,int width=1) {
            var box=new StyleBoxFlat { BgColor=fill,BorderColor=border };
            box.SetBorderWidthAll(width);box.SetCornerRadiusAll(8);
            box.ContentMarginLeft=16;box.ContentMarginRight=16;box.ContentMarginTop=10;box.ContentMarginBottom=10;return box;
        }
        foreach(string kind in new[]{"Label","Button","LineEdit","TextEdit","OptionButton","CheckButton","CheckBox","ItemList","PopupMenu","TabContainer"}) {
            theme.SetColor("font_color",kind,ink);theme.SetColor("font_hover_color",kind,ink);theme.SetColor("font_focus_color",kind,ink);
            theme.SetColor("font_pressed_color",kind,ink);theme.SetColor("font_disabled_color",kind,new("#BAC4C8"));
            theme.SetColor("font_uneditable_color",kind,new("#C9D2DB"));theme.SetColor("font_placeholder_color",kind,new("#C9D2DB"));
        }
        foreach(string kind in new[]{"Button","OptionButton","CheckButton","CheckBox"}) {
            theme.SetStylebox("normal",kind,Box(new("#304C56"),edge));
            theme.SetStylebox("hover",kind,Box(new("#416471"),ink));
            theme.SetStylebox("pressed",kind,Box(well,gold,2));
            theme.SetStylebox("hover_pressed",kind,Box(well,gold,2));
            theme.SetStylebox("disabled",kind,Box(new("#263940"),new("#596B74")));
            var focus=Box(Colors.Transparent,gold,3);focus.DrawCenter=false;theme.SetStylebox("focus",kind,focus);
        }
        theme.SetTypeVariation("PrimaryAction","Button");
        theme.SetTypeVariation("Heading","Label");theme.SetFontSize("font_size","Heading",24);
        theme.SetStylebox("normal","PrimaryAction",Box(gold,gold));
        theme.SetStylebox("hover","PrimaryAction",Box(new("#FBD85D"),ink));
        theme.SetStylebox("pressed","PrimaryAction",Box(new("#D4A900"),ink,2));
        foreach(string state in new[]{"font_color","font_hover_color","font_focus_color","font_pressed_color"})theme.SetColor(state,"PrimaryAction",well);
        foreach(string kind in new[]{"LineEdit","TextEdit","ItemList"}) {
            theme.SetStylebox("normal",kind,Box(well,edge));theme.SetStylebox("read_only",kind,Box(new("#263940"),edge));
            var focus=Box(Colors.Transparent,gold,2);focus.DrawCenter=false;theme.SetStylebox("focus",kind,focus);
            theme.SetColor("caret_color",kind,gold);theme.SetColor("selection_color",kind,new("#416471"));
        }
        theme.SetStylebox("panel","PanelContainer",Box(new("#192B32"),edge));
        theme.SetStylebox("panel","PopupMenu",Box(well,edge));theme.SetStylebox("hover","PopupMenu",Box(new("#416471"),gold));
        theme.SetColor("font_hover_color","PopupMenu",ink);theme.SetConstant("v_separation","PopupMenu",12);
        foreach(string kind in new[]{"VBoxContainer","HBoxContainer"})theme.SetConstant("separation",kind,12);
        foreach(string kind in new[]{"HFlowContainer","GridContainer"}) {
            theme.SetConstant("h_separation",kind,12);theme.SetConstant("v_separation",kind,12);
        }
        return theme;
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
    }
    public void SetContent(Control next) { content=next;next.Theme??=workspaceTheme;Surface.AddChild(next); }
    public void PresentSpatial(bool next)
    {
        if(Spatial==next)return;LayoutChanging?.Invoke();Cancel();Spatial=next;Surface.TransparentBg=next;
        workspaceTheme.DefaultFontSize=next ? spatialTextSize : desktopTextSize;
        workspaceTheme.SetFontSize("font_size","Heading",workspaceTheme.DefaultFontSize+4);
        background.BgColor=new(background.BgColor,next ? spatialOpacity : 1);
        ResizeSurface();
    }
    public void TextSize(int change)
    { int next=Math.Clamp(workspaceTheme.DefaultFontSize+change,16,48);if(next==workspaceTheme.DefaultFontSize)return;LayoutChanging?.Invoke();Cancel();workspaceTheme.DefaultFontSize=next;workspaceTheme.SetFontSize("font_size","Heading",next+4);if(Spatial)spatialTextSize=next;else desktopTextSize=next; }
    public void Opaque(bool value) { spatialOpacity=value ? 1 : .78f;background.BgColor=new(25f/255,43f/255,50f/255,Spatial ? spatialOpacity : 1); }
    public void ToggleOpacity()=>Opaque(spatialOpacity<1);
    void ResizeSurface()
    {
        if(mirrorSize!=Size) { LayoutChanging?.Invoke();Cancel();mirrorSize=Size; }
        var pixels=Spatial ? new Vector2I(1200,800) : new Vector2I(Math.Max(1,(int)Size.X),Math.Max(1,(int)Size.Y));
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
        if(captured!=null && IsInstanceValid(captured)){captured.TreeExiting-=Cancel;captured.VisibilityChanged-=CaptureVisibility;}captured=null;
        Surface.PushInput(new InputEventMouseButton { ButtonIndex=MouseButton.Left,Pressed=false,Position=point,GlobalPosition=point },true);
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
    public override void _ExitTree()=>Cancel();
}
