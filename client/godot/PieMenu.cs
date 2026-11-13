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
    // The drawn pie, in units of its radius: the hub names what is pointed,
    // the icon discs sit on the ring, and the edge is where the pie ends. A
    // cursor or ray on the hub or beyond the edge points nothing.
    const float Hub=.46f,Ring=.74f,Item=.19f,BackItem=.13f,Edge=1;
    // The house palette, as the sketches use it: glass discs over the world,
    // gold for the pointed path, rose for a command that asks to be pressed again.
    static readonly Color Ink=new("#F5F1EB"),Muted=new("#C9D2DB"),Glass=new("#192B32"),Lit=new("#2A3F48"),Gold=new("#F9C80E"),
        Gray=new("#848FA5"),Rose=new("#C14953"),RoseLight=new("#D4737B"),Teal=new("#0B3954");
    Texture2D? backIcon;
    PieNavigator? navigator;
    string waiting="",presented="";
    readonly List<Vector2> centres=[];
    float radius=150;
    Vector2 pointer;
    bool pointerKnown,pointerAway;
    // The cursor or ray has moved since this pie opened: where it is now is a choice.
    public bool PointerMoved { get; private set; }
    NumericsVector2 direction;
    NumericsVector2? axesSeen;
    public float Threshold { get; set; }=.3f;
    // The texture for a node's authored image, when the host has it.
    public Func<MenuNode,Texture2D?>? Icons { get; set; }
    public bool IsOpen=>Visible;
    // Presentation work requested: unchanged input and projections add none.
    public int Redraws { get; private set; }
    public PieNavigator? Navigator=>navigator;
    // The hub's words: see PieNavigator.Title and Note.
    public string Title=>navigator?.Title??waiting;
    public string Note=>navigator?.Note??"";
    public event Action<MenuTarget>? Selected;
    public event Action? Dismissed;
    public override void _Ready()
    {
        Name="pie-menu";Visible=false;FocusMode=FocusModeEnum.All;MouseFilter=MouseFilterEnum.Stop;
        SetAnchorsAndOffsetsPreset(LayoutPreset.FullRect);backIcon=GD.Load<Texture2D>("res://assets/icons/back.png");
    }
    static double Now=>Time.GetTicksMsec();
    Vector2 Centre=>centres.Count==0 ? Size/2 : centres[^1];
    // Opens at a point of this control while the subject's menu is read.
    public void Open(Vector2 at,float size,string reading)
    {
        navigator=null;waiting=reading;presented="";radius=size;pointerKnown=pointerAway=PointerMoved=false;axesSeen=null;direction=NumericsVector2.Zero;
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
            centres.Add(Clamp(centres[^1]+ToScreen(MenuNode.Toward(next.Slot,next.Wedges))*radius*Ring));
        }
        navigator.Move(direction,Now);Refresh();
    }
    public void Close(){if(!Visible)return;Visible=false;navigator=null;centres.Clear();ReleaseFocus();Refresh();}
    // The user gave the pie up: nothing is chosen.
    public void Dismiss(){if(!Visible)return;Close();Dismissed?.Invoke();}
    // Pad axes: absolute direction from the pad centre. Repeated unchanged
    // samples are not movement, so a moving ray can take over.
    public void MoveAxes(NumericsVector2 axes)
    {
        if(axesSeen is {} seen&&NumericsVector2.Distance(seen,axes)<.01f)return;
        axesSeen=axes;Move(axes);
    }
    // Where a point of this control aims: a wedge's direction while it is on
    // the drawn ring, nothing on the hub or beyond the edge.
    NumericsVector2 Aim(Vector2 point)
    { var offset=(point-Centre)/radius;float distance=offset.Length();return distance<Hub||distance>Edge ? NumericsVector2.Zero : new(offset.X,offset.Y); }
    public bool OnHub(Vector2 point)=>point.DistanceTo(Centre)<radius*Hub;
    // Cursor or ray point on this control. The first observation is only a
    // baseline; the pointer has not moved yet.
    public void PointerAt(Vector2 point)
    {
        if(!pointerKnown){pointer=point;pointerKnown=true;return;}
        if(!pointerAway&&point.DistanceTo(pointer)<1)return;
        pointerAway=false;PointerMoved=true;pointer=point;Move(Aim(point));
    }
    // The ray left this control's surface: it points nothing until it returns.
    public void PointerAway(){if(!pointerKnown||pointerAway)return;pointerAway=true;Move(NumericsVector2.Zero);}
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
        if(navigator==null){Dismiss();return PieOutcome.Cancelled;}
        int depth=navigator.Path.Count;var outcome=navigator.Commit();
        if(outcome==PieOutcome.Open){Follow(depth);Refresh();return outcome;}
        var chosen=navigator.Selection;Close();
        if(outcome==PieOutcome.Selected)Selected?.Invoke(chosen!);else Dismissed?.Invoke();
        return outcome;
    }
    // A click or trigger release decides where it lands: on a wedge it commits
    // that wedge; anywhere else, or off this control's surface, it cancels.
    public PieOutcome CommitAt(Vector2? point)
    {
        if(point is Vector2 at){pointer=at;pointerKnown=true;}
        pointerAway=point==null;int depth=navigator?.Path.Count??0;
        Move(point is Vector2 on ? Aim(on) : NumericsVector2.Zero);
        // Marking mode opened the pointed sub-pie at this very moment: that is the outcome.
        return navigator!=null&&navigator.Path.Count!=depth ? PieOutcome.Open : Commit();
    }
    // A sub-pie opens where its item was; going back returns to the parent centre.
    void Follow(int depth)
    {
        if(navigator==null)return;
        while(centres.Count>navigator.Path.Count)centres.RemoveAt(centres.Count-1);
        if(navigator.Path.Count>depth) {
            var entered=navigator.Level;
            centres.Add(Clamp(Centre+ToScreen(MenuNode.Toward(entered.Slot,navigator.Path[^2].Wedges))*radius*Ring));
        }
    }
    static Vector2 ToScreen(NumericsVector2 v)=>new(v.X,v.Y);
    Vector2 Clamp(Vector2 at)
    { float margin=radius*1.08f;return new(Math.Clamp(at.X,margin,Math.Max(margin,Size.X-margin)),Math.Clamp(at.Y,margin,Math.Max(margin,Size.Y-margin))); }
    void Refresh(){Redraws++;QueueRedraw();}
    // The sketch, icons only: a faint disc marks the pie, the pointed wedge's
    // part of it lights up, each command is a glass disc carrying its icon, and
    // the hub says in words what is pointed. A sub-pie carries a small gold
    // mark; the smaller disc with the arrow goes back, along the gold stroke
    // that leads to the parent pie.
    public override void _Draw()
    {
        if(!Visible)return;
        var font=GetThemeDefaultFont();int size=GetThemeDefaultFontSize();var centre=Centre;
        for(int i=0;i+1<centres.Count;i++) {
            bool parent=i+2==centres.Count;
            DrawLine(centres[i],centres[i+1],(parent ? Gold : Gray) with {A=.6f},parent ? 3 : 2,true);
            Disc(centres[i],radius*BackItem*.8f,Glass with {A=.9f},Gray with {A=.5f},1);
        }
        Disc(centre,radius*Edge,Glass with {A=.4f},Gray with {A=.3f},1);
        var pointed=navigator?.HoveredItem;bool armed=pointed!=null&&navigator!.Armed?.ToString()==pointed.Id.ToString();
        bool warns=pointed is {Enabled:true,Confirm:true};
        if(navigator!=null) {
            var level=navigator.Level;int wedges=level.Wedges;
            float Angle(int slot)=>Mathf.Tau*(slot-1)/wedges-Mathf.Pi/2;
            if(navigator.Hovered>0)Sector(centre,Angle(navigator.Hovered),Mathf.Pi/wedges,pointed is {Enabled:false} ? Gray : warns ? Rose : Gold);
            for(int slot=1;slot<=wedges;slot++) {
                var node=level.At(slot);bool isBack=slot==level.Back,hovered=slot==navigator.Hovered;
                if(node==null&&!isBack)continue;
                var at=centre+new Vector2(Mathf.Cos(Angle(slot)),Mathf.Sin(Angle(slot)))*radius*Ring;
                if(isBack) {
                    float small=radius*BackItem*(hovered ? 1.08f : 1);
                    Disc(at,small,hovered ? Lit : Glass with {A=.9f},hovered ? Gold : Gray with {A=.5f},hovered ? 2 : 1,radius*.03f);
                    Picture(backIcon,"‹",font,at,small,Ink);
                    continue;
                }
                float item=radius*Item*(hovered&&node!.Enabled ? 1.08f : 1);
                if(!node!.Enabled) {
                    Disc(at,item,Glass with {A=.65f},Colors.Transparent,0);
                    for(int dash=0;dash<16;dash++)DrawArc(at,item-1,Mathf.Tau*dash/16,Mathf.Tau*(dash+.55f)/16,4,(hovered ? Muted : Gray) with {A=.7f},1.5f,true);
                } else {
                    var accent=node.Confirm ? Rose : Gold;
                    if(hovered)DrawArc(at,item+3,0,Mathf.Tau,64,accent with {A=.33f},4,true);
                    Disc(at,item,hovered ? armed ? Glass.Lerp(Rose,.4f) : Lit : Glass with {A=.9f},
                        hovered||node.Confirm ? accent : Gray with {A=.5f},hovered ? 2 : 1,radius*.035f);
                }
                Picture(Icons?.Invoke(node),node.Initials,font,at,item,node.Enabled ? Ink : Ink with {A=.5f});
                if(!node.Leaf) {
                    // The sub-pie mark: a gold dot with an arrowhead, at the disc's lower right.
                    var mark=at+new Vector2(item,item)*.72f;float dot=item*.3f;DrawCircle(mark,dot,Gold,true,-1,true);
                    DrawColoredPolygon([mark+new Vector2(-.3f,-.45f)*dot,mark+new Vector2(.5f,0)*dot,mark+new Vector2(-.3f,.45f)*dot],Teal);
                }
            }
        }
        Disc(centre,radius*Hub,Glass,warns ? Rose : Gold,2,radius*.05f);
        bool named=navigator?.Hovered>0;
        Words(font,centre,Title,Note,named ? size*3/2 : size,size,named ? pointed is {Enabled:false} ? Ink with {A=.7f} : Ink : Muted,armed ? RoseLight : Muted);
    }
    // A round disc with a smooth edge and, when asked, a soft shadow beneath:
    // a few widening rings of shade, densest at the disc.
    void Disc(Vector2 at,float size,Color fill,Color border,float width,float shadow=0)
    {
        if(shadow>0)for(int ring=1;ring<=5;ring++)DrawCircle(at+new Vector2(0,shadow/3),size+shadow*ring/5,new Color(0,0,0,.07f),true,-1,true);
        DrawCircle(at,size,fill,true,-1,true);
        if(width>0)DrawArc(at,size-width/2,0,Mathf.Tau,96,border,width,true);
    }
    // The pointed wedge's part of the pie, from the hub to the edge, with a lit rim.
    void Sector(Vector2 centre,float angle,float half,Color colour)
    {
        const int steps=24;var points=new Vector2[2*steps+2];
        for(int i=0;i<=steps;i++) {
            float turn=angle-half+2*half*i/steps;var toward=new Vector2(Mathf.Cos(turn),Mathf.Sin(turn));
            points[i]=centre+toward*radius*Edge;points[2*steps+1-i]=centre+toward*radius*Hub;
        }
        DrawColoredPolygon(points,colour with {A=.18f});
        DrawArc(centre,radius*Edge-2,angle-half,angle+half,steps,colour with {A=.85f},3,true);
    }
    // A command's authored icon inside its disc; its initials until one exists.
    void Picture(Texture2D? icon,string initials,Font font,Vector2 at,float size,Color tint)
    {
        if(icon==null){Centred(font,initials,at,Math.Max(10,(int)(size*.78f)),tint);return;}
        float half=size*.62f;DrawTextureRect(icon,new Rect2(at-new Vector2(half,half),new Vector2(2*half,2*half)),false,tint);
    }
    void Centred(Font font,string text,Vector2 at,int size,Color colour)
    {
        var extent=font.GetStringSize(text,HorizontalAlignment.Left,-1,size);
        DrawString(font,new(at.X-extent.X/2,at.Y-extent.Y/2+font.GetAscent(size)),text,HorizontalAlignment.Left,-1,size,colour);
    }
    // The hub's words, centred: the title as large as asked while it fits the
    // hub, wrapped between words; the note smaller beneath it.
    void Words(Font font,Vector2 centre,string title,string note,int asked,int plain,Color ink,Color quiet)
    {
        float width=radius*Hub*1.6f,height=radius*Hub*1.2f;int small=Math.Max(12,plain*3/4),gap=note.Length>0 ? small/3 : 0;
        float noteHeight=note.Length>0 ? font.GetMultilineStringSize(note,HorizontalAlignment.Center,width,small).Y : 0;
        bool Fits(int at)=>font.GetMultilineStringSize(title,HorizontalAlignment.Center,width,at).Y+gap+noteHeight<=height&&
            title.Split(' ').All(word=>font.GetStringSize(word,HorizontalAlignment.Left,-1,at).X<=width);
        int chosen=asked;while(chosen>12&&!Fits(chosen))chosen-=2;
        float titleHeight=font.GetMultilineStringSize(title,HorizontalAlignment.Center,width,chosen).Y;
        var top=new Vector2(centre.X-width/2,centre.Y-(titleHeight+gap+noteHeight)/2);
        DrawMultilineString(font,top+new Vector2(0,font.GetAscent(chosen)),title,HorizontalAlignment.Center,width,chosen,-1,ink);
        if(note.Length>0)DrawMultilineString(font,top+new Vector2(0,titleHeight+gap+font.GetAscent(small)),note,HorizontalAlignment.Center,width,small,-1,quiet);
    }
    // Desktop: cursor direction, clicks, Backspace, Enter and digits 1–8.
    public override void _GuiInput(InputEvent input)
    {
        if(!Visible)return;
        switch(input) {
            case InputEventMouseMotion motion: PointerAt(motion.Position);break;
            case InputEventMouseButton {ButtonIndex:MouseButton.Left,Pressed:true} click: CommitAt(click.Position);break;
            case InputEventMouseButton {ButtonIndex:MouseButton.Right,Pressed:true}: Dismiss();break;
            case InputEventKey {Pressed:true} key: if(!Key(key))return;break;
            default: return;
        }
        AcceptEvent();
    }
    bool Key(InputEventKey key)
    {
        int wedges=navigator?.Level.Wedges??8;
        switch(key.Keycode) {
            case Godot.Key.Escape: Dismiss();return true;
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
