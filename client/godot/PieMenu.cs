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
    static readonly Color Text=new(0xF5/255f,0xF1/255f,0xEB/255f),Panel=new(0x19/255f,0x2B/255f,0x32/255f,.94f),
        Accent=new(0xF9/255f,0xC8/255f,0x0E/255f),Edge=new(0x84/255f,0x8F/255f,0xA5/255f);
    PieNavigator? navigator;
    string waiting="",presented="";
    readonly List<Vector2> centres=[];
    float radius=150;
    Vector2 pointer;
    bool pointerKnown;
    NumericsVector2 direction;
    NumericsVector2? axesSeen;
    public float Threshold { get; set; }=.3f;
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
    public override void _Draw()
    {
        if(!Visible)return;
        var font=GetThemeDefaultFont();int size=GetThemeDefaultFontSize();
        for(int i=0;i+1<centres.Count;i++) {
            DrawLine(centres[i],centres[i+1],Edge,2);DrawCircle(centres[i],radius*.12f,Panel);
            DrawArc(centres[i],radius*.12f,0,Mathf.Tau,32,Edge,2);
        }
        var centre=Centre;float inner=radius*.32f;
        DrawCircle(centre,radius*1.04f,Panel with {A=.55f});
        if(navigator!=null) {
            var level=navigator.Level;int wedges=level.Wedges;float half=Mathf.Pi/wedges;
            for(int slot=1;slot<=wedges;slot++) {
                var item=level.At(slot);bool back=slot==level.Back,hovered=slot==navigator.Hovered;
                if(item==null&&!back)continue;
                float angle=Mathf.Tau*(slot-1)/wedges-Mathf.Pi/2;
                var fill=back ? Panel with {A=.7f} : item!.Enabled ? Panel : Panel with {A=.45f};
                if(hovered)fill=fill.Lerp(Accent,back||item!.Enabled ? .35f : .12f);
                DrawPolygon(Wedge(centre,inner,radius,angle-half+.02f,angle+half-.02f),[fill]);
                if(hovered)DrawArc(centre,radius,angle-half+.02f,angle+half-.02f,16,Accent,3);
                var at=centre+new Vector2(Mathf.Cos(angle),Mathf.Sin(angle))*radius*.66f;
                var colour=back||item!.Enabled ? Text : Text with {A=.5f};
                if(!back) {
                    DrawCircle(at-new Vector2(0,size*.9f),size*.75f,Edge with {A=.35f});
                    Centred(font,item!.Initials,at-new Vector2(0,size*.6f),size,colour);
                }
                string text=back ? "‹ Back" : item!.Label+(item.Leaf ? "" : " ▸");
                Centred(font,text,at+new Vector2(0,size*.8f),Math.Max(10,(int)(size*.8f)),colour,radius*.62f);
                if(ShowDigits&&!back)Centred(font,slot.ToString(),centre+new Vector2(Mathf.Cos(angle),Mathf.Sin(angle))*radius*.92f,Math.Max(9,size/2),Text with {A=.35f});
            }
        }
        DrawCircle(centre,inner*.96f,Panel);DrawArc(centre,inner*.96f,0,Mathf.Tau,48,Edge,2);
    }
    void Centred(Font font,string text,Vector2 at,int size,Color colour,float width=-1)
    {
        var extent=font.GetStringSize(text,HorizontalAlignment.Center,width,size);
        DrawString(font,new(at.X-(width>0 ? width : extent.X)/2,at.Y+extent.Y/4),text,HorizontalAlignment.Center,width,size,colour);
    }
    static Vector2[] Wedge(Vector2 centre,float inner,float outer,float from,float to)
    {
        const int steps=12;var points=new Vector2[(steps+1)*2];
        for(int i=0;i<=steps;i++) {
            float a=from+(to-from)*i/steps;var direction=new Vector2(Mathf.Cos(a),Mathf.Sin(a));
            points[i]=centre+direction*outer;points[(steps+1)*2-1-i]=centre+direction*inner;
        }
        return points;
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
