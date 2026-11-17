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
    Theme? desktopTheme;
    readonly Theme workspaceTheme=new() { DefaultFontSize=26 };
    readonly StyleBoxFlat background=new() { BgColor=new(25f/255,43f/255,50f/255,.78f),CornerRadiusTopLeft=10,CornerRadiusTopRight=10,CornerRadiusBottomLeft=10,CornerRadiusBottomRight=10 };
    readonly Panel tint=new() { MouseFilter=MouseFilterEnum.Ignore,Visible=false };
    public bool Spatial { get; private set; }
    public Theme Appearance=>workspaceTheme;
    public int Captures { get; private set; }
    public int Cancellations { get; private set; }
    public bool NativePressed { get; private set; }
    public event Action? NativeCaptureChanged;
    public event Action? LayoutChanging;
    public override void _Ready()
    {
        SetAnchorsAndOffsetsPreset(LayoutPreset.FullRect);ExpandMode=ExpandModeEnum.IgnoreSize;StretchMode=StretchModeEnum.Scale;
        FocusMode=FocusModeEnum.None;MouseFilter=MouseFilterEnum.Stop;AddChild(Surface);Texture=Surface.GetTexture();
        Surface.RenderTargetUpdateMode=SubViewport.UpdateMode.Always;Resized+=ResizeSurface;ResizeSurface();
        tint.SetAnchorsAndOffsetsPreset(LayoutPreset.FullRect);tint.AddThemeStyleboxOverride("panel",background);Surface.AddChild(tint);
        foreach(string kind in new[]{"Label","Button","LineEdit","TextEdit","OptionButton","CheckButton"})workspaceTheme.SetColor("font_color",kind,new(245f/255,241f/255,235f/255));
        var menuBackground=(StyleBoxFlat)background.Duplicate();menuBackground.BgColor=new(background.BgColor,1);menuBackground.SetContentMarginAll(12);
        workspaceTheme.SetStylebox("panel","PanelContainer",menuBackground);
    }
    public void SetContent(Control next) { content=next;desktopTheme=next.Theme;Surface.AddChild(next); }
    public void PresentSpatial(bool next)
    {
        if(Spatial==next)return;LayoutChanging?.Invoke();Cancel();Spatial=next;Surface.TransparentBg=next;tint.Visible=next;
        if(content!=null)content.Theme=next ? workspaceTheme : desktopTheme;
        ResizeSurface();
    }
    public void TextSize(int change)
    { int next=Math.Clamp(workspaceTheme.DefaultFontSize+change,16,48);if(next==workspaceTheme.DefaultFontSize)return;LayoutChanging?.Invoke();Cancel();workspaceTheme.DefaultFontSize=next; }
    public void Opaque(bool value)=>background.BgColor=new(25f/255,43f/255,50f/255,value ? 1 : .78f);
    public void ToggleOpacity()=>Opaque(background.BgColor.A<1);
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
