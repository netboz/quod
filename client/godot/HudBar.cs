using Godot;
using Quod.Client;

// The human's HUD strip: their authored commands in order, then the one
// client-authored "This device" command, and the last status sentence. A
// command is committed through the pie, so it keeps its authored
// confirmation and nesting.
public partial class HudBar : PanelContainer
{
    readonly HBoxContainer row=new() {Name="hud-commands",Alignment=BoxContainer.AlignmentMode.Center};
    readonly Label status=new() {Name="hud-status",AutowrapMode=TextServer.AutowrapMode.Off,ClipText=true,SizeFlagsHorizontal=SizeFlags.ExpandFill};
    readonly Button device=SpatialGui.ActionButton("TD","hud-this-device");
    MenuNode? root;
    string presented="";
    public string Attention { get; set; }="";
    public int Rebuilds { get; private set; }
    public MenuNode? Commands=>root;
    public event Action<MenuNode,Control>? Activated;
    public event Action<Control>? DeviceRequested;
    public override void _Ready()
    {
        Name="hud";MouseFilter=MouseFilterEnum.Pass;
        AddThemeStyleboxOverride("panel",new StyleBoxFlat {BgColor=new(0x19/255f,0x2B/255f,0x32/255f,.86f),
            ContentMarginLeft=16,ContentMarginRight=16,ContentMarginTop=6,ContentMarginBottom=6});
        var layout=new HBoxContainer();AddChild(layout);
        layout.AddChild(status);layout.AddChild(row);
        layout.AddChild(new Control {SizeFlagsHorizontal=SizeFlags.ExpandFill,MouseFilter=MouseFilterEnum.Ignore});
        device.TooltipText="This device · text size, panels, VR";device.CustomMinimumSize=new(44,44);
        device.Pressed+=()=>DeviceRequested?.Invoke(device);
    }
    public string Status { get=>status.Text; set { status.Text=value;status.TooltipText=value; } }
    // An unchanged projection rebuilds nothing.
    public void Present(MenuNode? next)
    {
        string signature=next?.Signature??"";
        if(signature==presented){RefreshAttention();return;}
        presented=signature;root=next;Rebuilds++;
        foreach(var child in row.GetChildren()){if(child==device)continue;row.RemoveChild(child);child.QueueFree();}
        foreach(var command in (next?.Children??[]).OrderBy(c=>c.Slot)) {
            var button=SpatialGui.ActionButton(command.Initials+(command.Leaf ? "" : " ▸"),"hud-"+command.Slot);
            button.CustomMinimumSize=new(44,44);button.Disabled=!command.Enabled;
            button.TooltipText=command.Label+(command.Help.Length>0 ? " · "+command.Help : "");
            button.SetMeta("label",command.Label);
            var chosen=command;button.Pressed+=()=>Activated?.Invoke(chosen,button);row.AddChild(button);
        }
        if(device.GetParent()!=row)row.AddChild(device);else row.MoveChild(device,-1);
        RefreshAttention();
    }
    // The question count shows "0" rather than vanishing.
    void RefreshAttention()
    {
        foreach(var button in row.GetChildren().OfType<Button>())
            if(button.HasMeta("label")&&button.GetMeta("label").AsString()=="Your attention")
                button.Text="YA "+(Attention.Length>0 ? Attention : "0");
    }
}
