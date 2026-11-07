using Godot;
using Quod.Client;
using NumericsVector2=System.Numerics.Vector2;

// The one pie control for desktop and VR. It draws the current level of an
// authored menu on the surface that hosts it and reports the chosen wedge.
// Direction sources (pad, cursor, controller ray) feed the same navigator;
// whichever moved last wins.
public partial class PieMenu : Control
{
    // Interaction timing, not domain policy: how long a pointer rests on a
    // sub-pie before marking mode opens it (Kando: "when you stop moving").
    const double MarkingDwellMs=300;
    // The sketch's tokens: glass discs over the world, gold for the chosen path,
    // rose for a command that asks to be pressed again.
    static readonly Color Text=new(0xF5/255f,0xF1/255f,0xEB/255f),Glass=new(0x19/255f,0x2B/255f,0x32/255f,.9f),
        Accent=new(0xF9/255f,0xC8/255f,0x0E/255f),Edge=new(0x84/255f,0x8F/255f,0xA5/255f),
        Danger=new(0xC1/255f,0x49/255f,0x53/255f),Teal=new(0x0B/255f,0x39/255f,0x54/255f);
    PieNavigator? navigator;
    string waiting="",presented="";
    readonly List<Vector2> centres=[];
    float radius=150;
    Vector2 pointer;
    bool pointerKnown;
    NumericsVector2 direction;
    NumericsVector2? axesSeen;
    public float Threshold { get; set; }=.3f;
    // The texture for a node's authored image, when the host has it.
    public Func<MenuNode,Texture2D?>? Icons { get; set; }
    public bool ShowDigits { get; set; }
    public bool IsOpen=>Visible;
    // Presentation work requested: unchanged input and projections add none.
    public int Redraws { get; private set; }
    public PieNavigator? Navigator=>navigator;
    public string Caption=>navigator?.Caption??waiting;
    public event Action<MenuTarget>? Selected;
    public event Action? Dismissed;
    readonly Label caption=new() {Name="pie-caption",HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center,
        AutowrapMode=TextServer.AutowrapMode.WordSmart,MouseFilter=MouseFilterEnum.Ignore};
    public override void _Ready()
    {
        Name="pie-menu";Visible=false;FocusMode=FocusModeEnum.All;MouseFilter=MouseFilterEnum.Stop;
        SetAnchorsAndOffsetsPreset(LayoutPreset.FullRect);
        caption.AddThemeColorOverride("font_color",Text);AddChild(caption);
    }
    static double Now=>Time.GetTicksMsec();
    Vector2 Centre=>centres.Count==0 ? Size/2 : centres[^1];
    // Opens at a point of this control while the subject's menu is read.
    public void Open(Vector2 at,float size,string reading)
    {
        navigator=null;waiting=reading;presented="";radius=size;pointerKnown=false;axesSeen=null;direction=NumericsVector2.Zero;
        centres.Clear();centres.Add(Clamp(at));Visible=true;GrabFocus();Refresh();
    }
    // An unchanged projection does no work; a changed one keeps the user's
    // place and pointed direction when the same levels remain.
    public void Present(MenuNode? root,string empty)
    {
        if(!Visible)return;
        string signature=root==null ? "none:"+empty : root.Signature;
        if(signature==presented)return;presented=signature;
        if(root==null){navigator=null;waiting=empty;centres.RemoveRange(1,centres.Count-1);Refresh();return;}
        var previous=navigator?.Path.Skip(1).Select(n=>n.Id.ToString()).ToArray()??[];
        navigator=new(root,Threshold,MarkingDwellMs);centres.RemoveRange(1,centres.Count-1);
        foreach(var id in previous) {
            var next=navigator.Level.Children.FirstOrDefault(c=>!c.Leaf&&c.Id.ToString()==id);
            if(next==null||!navigator.Choose(next.Slot)||navigator.Commit()!=PieOutcome.Open)break;
            centres.Add(Clamp(centres[^1]+ToScreen(MenuNode.Toward(next.Slot,next.Wedges))*radius*.62f));
        }
        navigator.Move(direction,Now);Refresh();
    }
    public void Close(){if(!Visible)return;Visible=false;navigator=null;centres.Clear();ReleaseFocus();Refresh();}
    // Pad axes: absolute direction from the pad centre. Repeated unchanged
    // samples are not movement, so a moving ray can take over.
    public void MoveAxes(NumericsVector2 axes)
    {
        if(axesSeen is {} seen&&NumericsVector2.Distance(seen,axes)<.01f)return;
        axesSeen=axes;Move(axes);
    }
    // Cursor or ray point on this control: direction from the current centre.
    // The first observation is only a baseline; the pointer has not moved yet.
    public void PointerAt(Vector2 point)
    {
        if(!pointerKnown){pointer=point;pointerKnown=true;return;}
        if(point.DistanceTo(pointer)<1)return;
        pointer=point;
        var offset=(point-Centre)/radius;
        Move(offset.Length()>1.6f ? NumericsVector2.Zero : new(offset.X,offset.Y));
    }
    void Move(NumericsVector2 next)
    {
        direction=next;if(navigator==null)return;int depth=navigator.Path.Count;
        if(navigator.Move(next,Now)){Follow(depth);Refresh();}
    }
    // A resting pointer still advances marking mode.
    public override void _Process(double delta){if(Visible&&navigator!=null)Move(direction);}
    public bool Choose(int slot){if(navigator?.Choose(slot)!=true)return false;Refresh();return true;}
    public void Back(){if(navigator?.Back()==true){centres.RemoveAt(centres.Count-1);Refresh();}}
    public PieOutcome Commit()
    {
        if(navigator==null){Close();Dismissed?.Invoke();return PieOutcome.Cancelled;}
        int depth=navigator.Path.Count;var outcome=navigator.Commit();
        if(outcome==PieOutcome.Open){Follow(depth);Refresh();return outcome;}
        var chosen=navigator.Selection;Close();
        if(outcome==PieOutcome.Selected)Selected?.Invoke(chosen!);else Dismissed?.Invoke();
        return outcome;
    }
    // A sub-pie opens where its item was; going back returns to the parent centre.
    void Follow(int depth)
    {
        if(navigator==null)return;
        while(centres.Count>navigator.Path.Count)centres.RemoveAt(centres.Count-1);
        if(navigator.Path.Count>depth) {
            var entered=navigator.Level;
            centres.Add(Clamp(Centre+ToScreen(MenuNode.Toward(entered.Slot,navigator.Path[^2].Wedges))*radius*.62f));
        }
    }
    static Vector2 ToScreen(NumericsVector2 v)=>new(v.X,v.Y);
    Vector2 Clamp(Vector2 at)
    { float margin=radius*1.08f;return new(Math.Clamp(at.X,margin,Math.Max(margin,Size.X-margin)),Math.Clamp(at.Y,margin,Math.Max(margin,Size.Y-margin))); }
    void Refresh()
    {
        Redraws++;caption.Text=Caption;float side=radius*.58f;
        caption.Position=Centre-new Vector2(side,side)/2;caption.Size=new(side,side);
        QueueRedraw();
    }
    // The sketch: commands are glass discs on a ring, each with its label beneath,
    // linked to a hub that names the level; the hovered command and its link turn
    // gold, a sub-pie carries a small gold mark, the back disc is smaller.
    public override void _Draw()
    {
        if(!Visible)return;
        var font=GetThemeDefaultFont();int size=GetThemeDefaultFontSize();
        float item=radius*.19f,ring=radius*.74f,hub=radius*.4f,back=radius*.11f;
        for(int i=0;i+1<centres.Count;i++) {
            DrawLine(centres[i],centres[i+1],Edge with {A=.65f},2);DrawCircle(centres[i],back,Glass);DrawArc(centres[i],back,0,Mathf.Tau,32,Edge,1);
        }
        var centre=Centre;
        if(navigator!=null) {
            var level=navigator.Level;int wedges=level.Wedges;
            for(int slot=1;slot<=wedges;slot++) {
                var node=level.At(slot);bool isBack=slot==level.Back,hovered=slot==navigator.Hovered;
                if(node==null&&!isBack)continue;
                float angle=Mathf.Tau*(slot-1)/wedges-Mathf.Pi/2;
                var direction=new Vector2(Mathf.Cos(angle),Mathf.Sin(angle));var at=centre+direction*ring;
                DrawLine(centre+direction*hub,at-direction*(isBack ? back : item),hovered ? Accent with {A=.7f} : Edge with {A=.45f},hovered ? 3 : 2);
                if(isBack) {
                    DrawCircle(at,back,hovered ? Glass.Lerp(Accent,.25f) : Glass);DrawArc(at,back,0,Mathf.Tau,32,hovered ? Accent : Edge,hovered ? 2 : 1);
                    Centred(font,"‹",at,size,Text);
                    Centred(font,"Back",at+new Vector2(0,back+size*.7f),Math.Max(10,(int)(size*.75f)),Text with {A=.8f},radius*.8f,true);
                    continue;
                }
                bool armed=navigator.Armed?.ToString()==node!.Id.ToString();
                var border=!node.Enabled ? Edge with {A=.5f} : armed||(node.Confirm&&hovered) ? Danger : hovered ? Accent : Edge;
                if(hovered&&node.Enabled)DrawCircle(at,item+5,Accent with {A=.18f});
                DrawCircle(at,item,!node.Enabled ? Glass with {A=.6f} : hovered ? Glass.Lerp(Accent,.18f) : Glass);
                DrawArc(at,item,0,Mathf.Tau,48,border,hovered||armed ? 2 : 1);
                var ink=node.Enabled ? Text : Text with {A=.55f};
                if(Icons?.Invoke(node) is Texture2D icon){float half=item*.62f;DrawTextureRect(icon,new Rect2(at-new Vector2(half,half),new Vector2(2*half,2*half)),false,node.Enabled ? Colors.White : new Color(1,1,1,.55f));}
                else Centred(font,node.Initials,at,Math.Max(10,(int)(item*.78f)),ink);
                if(!node.Leaf) {
                    var mark=at+new Vector2(item*.72f,item*.72f);DrawCircle(mark,item*.3f,Accent);
                    Centred(font,"▸",mark,Math.Max(9,(int)(item*.4f)),Teal);
                }
                Centred(font,node.Label,at+new Vector2(0,item+size*.75f),Math.Max(10,(int)(size*.8f)),ink,radius*.95f,true);
                if(ShowDigits)Centred(font,slot.ToString(),at+new Vector2(-item*.9f,-item*.9f),Math.Max(9,size/2),Edge);
            }
        }
        DrawCircle(centre,hub,Glass);DrawArc(centre,hub,0,Mathf.Tau,64,Accent,2);
    }
    // Text centred on a point; labels over the world take the sketch's dark shadow.
    void Centred(Font font,string text,Vector2 at,int size,Color colour,float width=-1,bool shadow=false)
    {
        var extent=font.GetStringSize(text,HorizontalAlignment.Center,width,size);
        var origin=new Vector2(at.X-(width>0 ? width : extent.X)/2,at.Y+extent.Y/4);
        if(shadow)DrawString(font,origin+new Vector2(0,1),text,HorizontalAlignment.Center,width,size,new Color(0,0,0,.75f));
        DrawString(font,origin,text,HorizontalAlignment.Center,width,size,colour);
    }
    // Desktop: cursor direction, clicks, Backspace, Enter and digits 1–8.
    public override void _GuiInput(InputEvent input)
    {
        if(!Visible)return;
        switch(input) {
            case InputEventMouseMotion motion: PointerAt(motion.Position);break;
            case InputEventMouseButton {ButtonIndex:MouseButton.Left,Pressed:true} click: PointerAt(click.Position);Commit();break;
            case InputEventMouseButton {ButtonIndex:MouseButton.Right,Pressed:true}: Close();Dismissed?.Invoke();break;
            case InputEventKey {Pressed:true} key: if(!Key(key))return;break;
            default: return;
        }
        AcceptEvent();
    }
    bool Key(InputEventKey key)
    {
        int wedges=navigator?.Level.Wedges??8;
        switch(key.Keycode) {
            case Godot.Key.Escape: Close();Dismissed?.Invoke();return true;
            case Godot.Key.Backspace: Back();return true;
            case Godot.Key.Enter or Godot.Key.KpEnter: Commit();return true;
            case Godot.Key.Up: Choose(MenuNode.Direction(new(0,-1),.5f,wedges));return true;
            case Godot.Key.Right: Choose(MenuNode.Direction(new(1,0),.5f,wedges));return true;
            case Godot.Key.Down: Choose(MenuNode.Direction(new(0,1),.5f,wedges));return true;
            case Godot.Key.Left: Choose(MenuNode.Direction(new(-1,0),.5f,wedges));return true;
        }
        int digit=(int)(key.Keycode-Godot.Key.Key0);
        if(digit is >=1 and <=9 && Choose(digit)){Commit();return true;}
        return false;
    }
}
