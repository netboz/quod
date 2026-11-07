using Godot;
using Quod.Client;

// The human's HUD strip, after the approved sketch: a thin gradient along the
// bottom edge, each command a round glass button showing its authored icon
// (the label's initials until one exists), its label appearing beneath while
// pointed at, a gold count on the attention command, the one client-authored
// "This device" command last, and the last status sentence floating above at
// the left. On desktop the strip fades until the pointer comes near. A
// command is committed through the pie, so it keeps its authored confirmation
// and nesting.
public partial class HudBar : Control
{
    public const float Height=104;
    const float Icon=44;
    static readonly Color Glass=new(0x19/255f,0x2B/255f,0x32/255f,.9f),Edge=new(0x84/255f,0x8F/255f,0xA5/255f,.5f),
        Ink=new(0xF5/255f,0xF1/255f,0xEB/255f),Muted=new(0xC9/255f,0xD2/255f,0xDB/255f),
        Gold=new(0xF9/255f,0xC8/255f,0x0E/255f),Teal=new(0x0B/255f,0x39/255f,0x54/255f),Night=new(0x04/255f,0x13/255f,0x1C/255f);
    static readonly MenuNode DeviceCommand=new(Term.Atom("device"),"This device","Text size, panels, VR",true,0,8,0,null,false,[],"res://assets/icons/device.png");
    readonly HBoxContainer row=new() {Name="hud-commands",Alignment=BoxContainer.AlignmentMode.Center,MouseFilter=MouseFilterEnum.Ignore};
    readonly Label status=new() {Name="hud-status",AutowrapMode=TextServer.AutowrapMode.Off,ClipText=true,MouseFilter=MouseFilterEnum.Ignore};
    readonly Control device;
    readonly List<(Button Button,MenuNode Node)> shown=[];
    Label? attentionBadge;
    MenuNode? root;
    string presented="";
    float faded=1;
    public string Attention { get; set; }="";
    // Desktop only: the strip fades until the pointer nears the bottom edge.
    public bool AutoDim { get; set; }
    // The texture for a command's authored image, when the host has it.
    public Func<MenuNode,Texture2D?>? Icons { get; set; }
    public int Rebuilds { get; private set; }
    public MenuNode? Commands=>root;
    public event Action<MenuNode,Control>? Activated;
    public event Action<Control>? DeviceRequested;
    public HudBar() { device=Command(DeviceCommand,"hud-this-device",button=>DeviceRequested?.Invoke(button)); }
    public override void _Ready()
    {
        Name="hud";MouseFilter=MouseFilterEnum.Ignore;
        var gradient=new Gradient();gradient.SetColor(0,Night with {A=0});gradient.SetColor(1,Night with {A=.8f});
        var backdrop=new TextureRect {Name="hud-backdrop",MouseFilter=MouseFilterEnum.Ignore,StretchMode=TextureRect.StretchModeEnum.Scale,
            ExpandMode=TextureRect.ExpandModeEnum.IgnoreSize,Texture=new GradientTexture2D {Gradient=gradient,Width=4,Height=64,FillFrom=new(0,0),FillTo=new(0,1)}};
        backdrop.SetAnchorsAndOffsetsPreset(LayoutPreset.FullRect);AddChild(backdrop);
        status.SetAnchorsPreset(LayoutPreset.TopWide);status.OffsetLeft=18;status.OffsetRight=-18;status.OffsetTop=2;status.OffsetBottom=26;
        status.AddThemeColorOverride("font_color",Muted);AddChild(status);
        row.SetAnchorsPreset(LayoutPreset.BottomWide);row.OffsetTop=-(Height-26);row.OffsetBottom=-4;
        row.AddThemeConstantOverride("separation",22);AddChild(row);
        row.AddChild(device);RefreshIcons();
    }
    public string Status { get=>status.Text; set { status.Text=value;status.TooltipText=value; } }
    // An unchanged projection rebuilds nothing.
    public void Present(MenuNode? next)
    {
        string signature=next?.Signature??"";
        if(signature==presented){RefreshAttention();return;}
        presented=signature;root=next;Rebuilds++;attentionBadge=null;
        foreach(var child in row.GetChildren()){if(child==device)continue;row.RemoveChild(child);child.QueueFree();}
        shown.RemoveAll(s=>s.Node!=DeviceCommand);
        foreach(var command in (next?.Children??[]).OrderBy(c=>c.Slot)) {
            var chosen=command;
            var item=Command(command,"hud-"+command.Slot,button=>Activated?.Invoke(chosen,button));
            var button=Button(item);button.Disabled=!command.Enabled;button.SetMeta("label",command.Label);
            if(IsAttention(command))attentionBadge=Badge(button,"",new Vector2(Icon-12,-8));
            row.AddChild(item);
        }
        row.MoveChild(device,-1);
        RefreshIcons();RefreshAttention();
    }
    // Authored images that arrived after the strip was built.
    public void RefreshIcons()
    {
        foreach(var (button,node) in shown) {
            var icon=Icons?.Invoke(node);
            button.Icon=icon;button.Text=icon==null ? MenuNode.InitialsOf(node.Label) : "";
        }
    }
    // The authored command whose count is the waiting questions.
    static bool IsAttention(MenuNode command)=>command.Target?.Choice is {} choice && choice.Name=="eidolon" && choice.Args.Length==3 && choice.Args[0].Name=="attention";
    // The count badge appears only while something waits.
    void RefreshAttention()
    {
        if(attentionBadge==null)return;
        attentionBadge.Text=Attention;attentionBadge.Visible=Attention.Length>0&&Attention!="0";
    }
    static Button Button(Control item)=>item.GetChild<Button>(0);
    // One command: a round button carrying its icon, a gold "more" mark when it
    // opens a sub-pie, and its label beneath, shown while the pointer is on it.
    Control Command(MenuNode node,string name,Action<Button> pressed)
    {
        var item=new VBoxContainer {MouseFilter=MouseFilterEnum.Ignore,Alignment=BoxContainer.AlignmentMode.End};
        item.AddThemeConstantOverride("separation",4);
        var button=new Button {Name=name,CustomMinimumSize=new(Icon,Icon),SizeFlagsHorizontal=SizeFlags.ShrinkCenter,ExpandIcon=true,
            IconAlignment=HorizontalAlignment.Center,TooltipText=node.Help.Length>0 ? node.Label+" · "+node.Help : node.Label,FocusMode=FocusModeEnum.None};
        Round(button);button.Pressed+=()=>pressed(button);item.AddChild(button);shown.Add((button,node));
        if(!node.Leaf)Badge(button,"▸",new Vector2(Icon-14,Icon-14));
        var caption=new Label {Text=node.Label,HorizontalAlignment=HorizontalAlignment.Center,MouseFilter=MouseFilterEnum.Ignore,CustomMinimumSize=new(84,0),Modulate=new(1,1,1,0)};
        caption.AddThemeFontSizeOverride("font_size",12);caption.AddThemeColorOverride("font_color",Ink);
        caption.AddThemeColorOverride("font_shadow_color",new Color(0,0,0,.75f));caption.AddThemeConstantOverride("shadow_offset_y",1);
        button.MouseEntered+=()=>caption.Modulate=Colors.White;button.MouseExited+=()=>caption.Modulate=new(1,1,1,0);
        item.AddChild(caption);
        return item;
    }
    static void Round(Button button)
    {
        StyleBoxFlat Disc(Color fill,Color border,int width) {
            var box=new StyleBoxFlat {BgColor=fill,BorderColor=border,ContentMarginLeft=7,ContentMarginRight=7,ContentMarginTop=7,ContentMarginBottom=7};
            box.SetBorderWidthAll(width);box.SetCornerRadiusAll((int)(Icon/2));return box;
        }
        button.AddThemeStyleboxOverride("normal",Disc(Glass,Edge,1));
        button.AddThemeStyleboxOverride("hover",Disc(Glass,Gold,1));
        button.AddThemeStyleboxOverride("pressed",Disc(new(0x2A/255f,0x3F/255f,0x48/255f,.95f),Gold,2));
        button.AddThemeStyleboxOverride("focus",Disc(Glass,Gold,1));
        button.AddThemeStyleboxOverride("disabled",Disc(Glass with {A=.6f},Edge with {A=.3f},1));
        button.AddThemeFontSizeOverride("font_size",15);
        foreach(string state in new[]{"font_color","font_hover_color","font_pressed_color","font_focus_color"})button.AddThemeColorOverride(state,Ink);
        button.AddThemeColorOverride("font_disabled_color",new(0x8A/255f,0x9A/255f,0xA3/255f));
        button.AddThemeColorOverride("icon_disabled_color",new(1,1,1,.55f));
    }
    // A small gold disc on a command: the sub-pie mark or the attention count.
    static Label Badge(Control host,string text,Vector2 at)
    {
        var badge=new Label {Text=text,HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center,
            MouseFilter=MouseFilterEnum.Ignore,CustomMinimumSize=new(20,20),Position=at,Visible=text.Length>0};
        badge.AddThemeFontSizeOverride("font_size",11);badge.AddThemeColorOverride("font_color",Teal);
        var disc=new StyleBoxFlat {BgColor=Gold,ContentMarginLeft=5,ContentMarginRight=5};disc.SetCornerRadiusAll(10);
        badge.AddThemeStyleboxOverride("normal",disc);
        host.AddChild(badge);return badge;
    }
    public override void _Process(double delta)
    {
        float target=1;
        if(AutoDim&&Visible) {
            var mouse=GetLocalMousePosition();
            bool near=mouse.Y>-Height*.5f&&mouse.X>=-40&&mouse.X<=Size.X+40;
            target=near||(Attention.Length>0&&Attention!="0") ? 1 : .55f;
        }
        if(Math.Abs(faded-target)<.01f)return;
        faded=Mathf.MoveToward(faded,target,(float)delta*3);Modulate=new(1,1,1,faded);
    }
}
