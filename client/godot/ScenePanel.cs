using Godot;
using Quod.Client;
using BigInteger = System.Numerics.BigInteger;

// Shared mark adapter. Geometry is presentation only: no collision bodies or
// local simulation. Picking resolves the occurrence's exact depicted subject.
public partial class ScenePanel : SubViewportContainer
{
    // Lines are the drawn segments of an edge-only box; Looks its materials:
    // one, or display, pointed at and selected.
    sealed record Occurrence(SceneMark Mark, Node3D Node, Vector3[] Corners, (Vector3 A,Vector3 B)[] Lines, long Identity, MeshInstance3D? Shape, Material[] Looks) { public int Look; }
    // A pick keeps its installed thing, not merely the depicted subject: the
    // mark that names the subject, with the marks beneath it that name none.
    // Placement is always resolved from this owner; a removed/reused ID cannot
    // revive a previous selection or confer authority to an operation.
    public sealed record Selection(ScenePanel Owner,string Id,long Identity,Term Subject)
    {
        public Transform3D? Pose=>Owner.Resolve(this)?.Node.GlobalTransform;
        public Vector3[] Corners=>Owner.Resolve(this) is {} thing ? Owner.Parts(thing).SelectMany(p=>p.Corners.Select(c=>p.Node.GlobalTransform*c)).ToArray() : [];
        public string? Label=>Owner.Resolve(this) is {} thing ? Owner.Parts(thing).Select(p=>p.Mark.Label).FirstOrDefault(l=>l.Name=="label")?.Args[0].TextValue : null;
    }
    // The marks last given, and the marks drawn once any thing's other mode has taken its place.
    SceneMark[] source=[],drawn=[];
    readonly Dictionary<string,SceneMark[]> modes=[];
    long occurrenceIdentity;
    readonly Dictionary<string, Occurrence> occurrences = [];
    readonly SubViewport viewport = new() { Name = "scene-viewport", Size = new(1000, 400), OwnWorld3D = true, TransparentBg = false, HandleInputLocally = false };
    readonly Node3D root = new() { Name = "scene-marks" };
    readonly Camera3D camera = new() { Name = "scene-camera", Current = true, Near = 0.05f, Far = 1000 };
    MeshInstance3D? formSurface;
    Vector2I formPixels;
    internal MeshInstance3D? FormSurface=>formSurface;
    internal bool PresentForm(Texture2D texture,Vector2 size,Vector2I pixels,Vector3 offset,Transform3D pose)
    {
        if(formSurface==null) {
            formSurface=new() {Name="occurrence-form-surface",Mesh=new QuadMesh(),MaterialOverride=new StandardMaterial3D {ShadingMode=BaseMaterial3D.ShadingModeEnum.Unshaded,Transparency=BaseMaterial3D.TransparencyEnum.Alpha,CullMode=BaseMaterial3D.CullModeEnum.Disabled}};
            viewport.AddChild(formSurface);
        }
        bool changed=!formSurface.Visible||formSurface.GlobalTransform!=pose||((QuadMesh)formSurface.Mesh).Size!=size||((QuadMesh)formSurface.Mesh).CenterOffset!=offset;
        var material=(StandardMaterial3D)formSurface.MaterialOverride;if(!ReferenceEquals(material.AlbedoTexture,texture))material.AlbedoTexture=texture;
        if(((QuadMesh)formSurface.Mesh).Size!=size)((QuadMesh)formSurface.Mesh).Size=size;
        if(((QuadMesh)formSurface.Mesh).CenterOffset!=offset)((QuadMesh)formSurface.Mesh).CenterOffset=offset;
        formPixels=pixels;if(formSurface.GlobalTransform!=pose)formSurface.GlobalTransform=pose;formSurface.Show();if(changed)RequestFraming();return changed;
    }
    internal void HideForm(){if(formSurface?.Visible==true){formSurface.Hide();RequestFraming();}}
    internal Vector2? FormHit(Vector2 point)
    {
        if(!available||!IsVisibleInTree()||formSurface?.Visible!=true)return null;
        var hovered=GetViewport().GuiGetHoveredControl();if(hovered!=this&&(hovered==null||!hovered.IsAncestorOf(this)))return null;
        var clip=new Rect2(Vector2.Zero,GetViewport().GetVisibleRect().Size);
        for(Node? n=this;n!=null;n=n.GetParent())if(n is Control c&&(c==this||c.ClipContents))clip=clip.Intersection(c.GetGlobalRect());
        if(!clip.HasPoint(point))return null;
        var pixel=(point-GlobalPosition)*(Vector2)viewport.Size/Size;
        var inverse=formSurface.GlobalTransform.AffineInverse();var origin=inverse*camera.ProjectRayOrigin(pixel);var direction=inverse.Basis*camera.ProjectRayNormal(pixel);
        if(Math.Abs(direction.Z)<.000001f)return null;float distance=-origin.Z/direction.Z;if(distance<0)return null;
        var at=origin+direction*distance-((QuadMesh)formSurface.Mesh).CenterOffset;var size=((QuadMesh)formSurface.Mesh).Size;
        if(Math.Abs(at.X)>size.X/2||Math.Abs(at.Y)>size.Y/2)return null;
        return new Vector2((at.X/size.X+.5f)*formPixels.X,(.5f-at.Y/size.Y)*formPixels.Y);
    }
    WorldProjection? world;
    bool looking;
    Selection? pressedSubject;
    bool navigationBlocked;
    bool available;
    long framing;
    readonly HashSet<Key> held = [];
    public event Action<Vector3,Vector3>? Drive;
    public bool Controlled { get; set; }
    public bool NavigationBlocked { get=>navigationBlocked;set { if(value&&!navigationBlocked)ReleaseInput();navigationBlocked=value; } }
    internal SubViewport Viewport=>viewport;
    internal void PresentXR(bool active)
    {
        if(viewport.UseXR==active)return;
        // The XR runtime owns stereo dimensions; desktop layout owns the
        // stretched mono target. Release layout before changing that contract.
        Stretch=false;
        // Container visibility changes its child's update mode. Establish
        // presentation first, then give the active XR renderer final ownership.
        Visible=!active;
        viewport.UseXR=active;
        if(!active) { viewport.ViewCount=1;camera.Current=true;Stretch=true; }
        viewport.RenderTargetUpdateMode=active ? SubViewport.UpdateMode.Always : SubViewport.UpdateMode.WhenVisible;
    }
    internal Node3D SceneRoot=>root;
    // Where the principal's own agent is placed in the viewed space. A headset
    // stands there; the desktop observer camera frames the whole view instead.
    Transform3D? standpoint;
    internal void Stand(ScenePose? placed)=>standpoint=placed?.Transform is BigInteger[] p ? Pose(p) : null;
    internal Transform3D ViewerPose=>Controlled||standpoint is not Transform3D placed ? camera.GlobalTransform : placed;
    internal Basis DomainBasis {
        get { var basis=Basis.Identity;foreach(var frame in world?.ViewFrames??[])basis*=RotationBasis(frame.Transform!);return basis; }
    }
    internal string? ControlIdentity=>world?.Controlled==null ? null : world.Control+"\n"+world.Sample!.Fence;
    public event Action<Selection>? Selected;
    public enum MenuStep { Open, Move, Release }
    // Right button: open the pointed target's pie, drag through wedges, release.
    public event Action<MenuStep,Selection?,Vector2>? MenuGesture;
    // The cursor's target before any press: the occurrence under it, or none.
    public event Action<Selection?,Vector2>? Hovered;
    bool menuHeld;
    // The pointed-at and selected things show the looks their marks carry;
    // switching reads and changes no domain state.
    Selection? pointed,selected;
    Occurrence? pointedThing,selectedThing;
    public event Action? PresentationChanged;
    public int Rebuilt { get; private set; }
    public int Count => occurrences.Count;
    public string[] Ids => occurrences.Keys.ToArray();
    public override void _Ready()
    {
        CustomMinimumSize = new(0, 360); SizeFlagsHorizontal = SizeFlags.ExpandFill; Stretch = true; MouseFilter = MouseFilterEnum.Stop; FocusMode = FocusModeEnum.All;
        AddChild(viewport); viewport.AddChild(root); viewport.AddChild(camera);
        viewport.FindWorld3D().Environment = new Godot.Environment {
            BackgroundMode = Godot.Environment.BGMode.Color, BackgroundColor = Colors.Black,
            AmbientLightSource = Godot.Environment.AmbientSource.Color, AmbientLightColor = Colors.White, AmbientLightEnergy = .3f };
        // Neutral presentation lighting reveals solid normals without adding
        // a domain sun, sky or physical environment to the empty black space.
        viewport.AddChild(new DirectionalLight3D {Name="presentation-light",RotationDegrees=new(-45,-30,0),LightEnergy=1});
        camera.Position = new(0, 0, 5);
        viewport.SizeChanged += () => { if(!viewport.UseXR && world?.Controlled==null)RequestFraming(); };
        FocusExited += ReleaseInput;
        MouseExited += () => Hovered?.Invoke(null,new(float.NaN,float.NaN));
    }
    static Vector3[] Corners(Vector3 size) => [
        new Vector3(-size.X,-size.Y,-size.Z)/2,new Vector3(size.X,-size.Y,-size.Z)/2,
        new Vector3(-size.X,size.Y,-size.Z)/2,new Vector3(size.X,size.Y,-size.Z)/2,
        new Vector3(-size.X,-size.Y,size.Z)/2,new Vector3(size.X,-size.Y,size.Z)/2,
        new Vector3(-size.X,size.Y,size.Z)/2,new Vector3(size.X,size.Y,size.Z)/2];
    static readonly (int A, int B)[] Edges = [(0,1),(2,3),(4,5),(6,7),(0,2),(1,3),(4,6),(5,7),(0,4),(1,5),(2,6),(3,7)];
    // A wire box draws its edges whole; a corner box draws a third of each edge from both corners.
    static (Vector3 A,Vector3 B)[] Lines(string kind,Vector3[] c) => kind switch {
        "wire_box" => Edges.Select(e=>(c[e.A],c[e.B])).ToArray(),
        "corner_box" => Edges.SelectMany(e=>new[]{(c[e.A],c[e.A].Lerp(c[e.B],1/3f)),(c[e.B],c[e.B].Lerp(c[e.A],1/3f))}).ToArray(),
        _ => [] };
    static StandardMaterial3D Look(SceneMark mark,SceneSurface surface)
    {
        // Below full opacity a surface is translucent; both sides already draw.
        // A corner line fades along its length through its vertex alpha.
        var colour=new Color(surface.Colour) with {A=surface.Opacity/1000f};bool fading=mark.Kind=="corner_box";
        return new() {
            ShadingMode = mark.Edges ? BaseMaterial3D.ShadingModeEnum.Unshaded : BaseMaterial3D.ShadingModeEnum.PerPixel,
            AlbedoColor=colour,Metallic=surface.Metallic/1000f,Roughness=surface.Roughness/1000f,
            EmissionEnabled=surface.Emission>0,Emission=colour,EmissionEnergyMultiplier=surface.Emission/1000f,
            Transparency=fading||surface.Opacity<1000 ? BaseMaterial3D.TransparencyEnum.Alpha : BaseMaterial3D.TransparencyEnum.Disabled,
            VertexColorUseAsAlbedo=fading,CullMode = BaseMaterial3D.CullModeEnum.Disabled };
    }
    static float Finite(double value)
    { float result = (float)value; if (!float.IsFinite(result)) throw new FormatException("Scene coordinate exceeds the engine's numeric range."); return result; }
    static Basis RotationBasis(float x,float y,float z) => new Basis(Vector3.Back,z)*new Basis(Vector3.Up,y)*new Basis(Vector3.Right,x);
    static Basis RotationBasis(BigInteger[] p) => RotationBasis(Mathf.DegToRad((float)p[3]),Mathf.DegToRad((float)p[4]),Mathf.DegToRad((float)p[5]));
    static Transform3D Pose(BigInteger[] p)
    {
        return new(RotationBasis(p), new(Finite((double)p[0]/1000), Finite((double)p[1]/1000), Finite((double)p[2]/1000)));
    }
    static Transform3D BodyInFrame(PhysicsSample sample,BodySample body,ScenePose[] chain)
    {
        // Subtract the exact common integer anchor before float conversion,
        // matching the native frame owner rather than rounding a world origin.
        BigInteger[] anchor = chain.Length == 0 ? [0,0,0] : chain[0].Transform![..3];
        var source = Transform3D.Identity;
        for (int i=0;i<chain.Length;i++) {
            var p = chain[i].Transform!.ToArray(); if (i==0) { p[0]=p[1]=p[2]=0; }
            source *= Pose(p);
        }
        var position = new Vector3(Finite((double)(sample.Origin[0]-anchor[0])/1000+body.Position[0]),
            Finite((double)(sample.Origin[1]-anchor[1])/1000+body.Position[1]),Finite((double)(sample.Origin[2]-anchor[2])/1000+body.Position[2]));
        var q = body.Rotation;
        return source.AffineInverse() * new Transform3D(new Basis(new Quaternion((float)q[0],(float)q[1],(float)q[2],(float)q[3]).Normalized()),position);
    }
    static Dictionary<string,Transform3D> Transforms(SceneMark[] marks,WorldProjection? projection)
    {
        var transforms = new Dictionary<string,Transform3D>();
        foreach (var mark in marks) {
            var parent = mark.Parent == null ? Transform3D.Identity : transforms[mark.Parent];
            Transform3D pose;
            if (mark.Pose.Transform is BigInteger[] authored) pose = parent * Pose(authored);
            else {
                var sample = projection?.Sample ?? throw new FormatException("Authoritative frame unavailable.");
                var key = (mark.Pose.Body!.Value,mark.Pose.Revision);
                var chain = mark.Pose.Reframed ? projection!.BodyFrames[key] : projection!.ViewFrames;
                pose = BodyInFrame(sample,sample.Bodies[key],chain);
                if (mark.Pose.Reframed) pose = parent * pose;
            }
            if (!pose.IsFinite()) throw new FormatException("Scene frame exceeds the engine's numeric range.");
            transforms.Add(mark.Id,pose);
        }
        return transforms;
    }
    public void Apply(Term terms) => Apply(SceneMark.Decode(terms),null);
    public void Apply(WorldProjection projection) => Apply(projection.Marks,projection);
    public WorldProjection ApplyProjection(System.Text.Json.Nodes.JsonNode message,Actor target,Actor principal,Action<System.Text.Json.Nodes.JsonObject> processed)
    {
        var next=new WorldProjection(message,target,principal);
        Apply(next);
        if(next.Sample!=null)processed(next.Acknowledgement());
        return next;
    }
    public bool ApplyFrame(System.Text.Json.Nodes.JsonNode message,Action<System.Text.Json.Nodes.JsonObject> processed)
    {
        if(world?.Advance(message)!=true)return false;
        ApplyFrame();processed(world.Acknowledgement());return true;
    }
    void Apply(SceneMark[] marks,WorldProjection? projection){source=marks;Install(InMode(marks),projection);}
    // Each shown thing has a mode, display by default. Another mode's model of
    // one thing takes the place of that thing's own parts, where it stands,
    // until it is withdrawn with null. Returns whether the model is drawn here.
    public bool ShowMode(Selection thing,Term? model)
    {
        if(Resolve(thing) is not {} shown)return false;
        if(model==null){if(modes.Remove(shown.Mark.Id))Install(InMode(source),world);return true;}
        if(ModeParts(shown.Mark,model) is not {} parts)return false;
        var before=modes.GetValueOrDefault(shown.Mark.Id);modes[shown.Mark.Id]=parts;
        var next=InMode(source);var seen=new HashSet<string>();
        // A thing whose other marks hang from a replaced part keeps its display.
        if(next.All(m=>(m.Parent==null||seen.Contains(m.Parent))&&seen.Add(m.Id))){Install(next,world);return true;}
        if(before==null)modes.Remove(shown.Mark.Id);else modes[shown.Mark.Id]=before;
        return false;
    }
    // The model of one thing arrives under its own root group, which depicts
    // it. Its parts move under the shown thing; the root's own pose is unused.
    static SceneMark[]? ModeParts(SceneMark thing,Term model)
    {
        var marks=SceneMark.Decode(model);
        if(marks.Length==0||marks[0].Kind!="group"||marks[0].Parent!=null||marks[0].Subject?.ToString()!=thing.Subject!.ToString())return null;
        string root=marks[0].Id;
        bool Inside(string? id)=>id!=null&&(id==root||id.StartsWith(root+"/"));
        if(marks.Skip(1).Any(m=>m.Subject!=null||m.Id==root||!Inside(m.Id)||!Inside(m.Parent)))return null;
        Term Moved(Term id)=>Term.Text(thing.Id+id.TextValue[root.Length..]);
        var stand=Term.Call("mark",Term.Text(thing.Id),Term.Text("group"),Term.List(),Term.Parse("transform(0,0,0,0,0,0)"),Term.Atom("no_surface"),Term.Atom("unlabelled"),Term.Atom("depicts_nothing"));
        // Decoding the moved terms keeps one validation and makes an unchanged part compare equal to the one already drawn.
        return SceneMark.Decode(Term.List(model.Items.Skip(1).Select(term=>{
            var a=term.Require("mark",7);var at=a[3].Require("relative",2);
            return Term.Call("mark",Moved(a[0]),a[1],a[2],Term.Call("relative",Moved(at[0]),at[1]),a[4],a[5],a[6]);
        }).Prepend(stand).ToArray())).Skip(1).ToArray();
    }
    SceneMark[] InMode(SceneMark[] marks)
    {
        if(modes.Count==0)return marks;
        var byId=marks.ToDictionary(m=>m.Id);
        foreach(var gone in modes.Keys.Where(id=>!byId.ContainsKey(id)).ToArray())modes.Remove(gone);
        string? ThingOf(SceneMark mark){while(mark.Subject==null){if(mark.Parent==null)return null;mark=byId[mark.Parent];}return mark.Id;}
        var shown=new List<SceneMark>();
        foreach(var mark in marks) {
            if(mark.Subject==null&&ThingOf(mark) is {} thing&&modes.ContainsKey(thing))continue;
            shown.Add(mark);if(modes.TryGetValue(mark.Id,out var parts))shown.AddRange(parts);
        }
        return shown.ToArray();
    }
    void Install(SceneMark[] marks,WorldProjection? projection)
    {
        var next = new Dictionary<string, Occurrence>();
        // Validate and convert the complete candidate before changing the scene.
        var transforms = Transforms(marks,projection);
        var sizes = marks.ToDictionary(m => m.Id, m => m.Size.Length == 0 ? Vector3.Zero : m.Kind=="sphere"
            ? Vector3.One*m.Size[0].RenderMetres() : new Vector3(m.Size[0].RenderMetres(), m.Size[1].RenderMetres(), m.Size[2].RenderMetres()));
        bool changed = false,availabilityChanged=!available;
        var markById=marks.ToDictionary(m=>m.Id);
        Term? NextSubject(SceneMark mark) {
            while(true){if(mark.Subject!=null)return mark.Subject;if(mark.Parent==null)return null;mark=markById[mark.Parent];}
        }
        foreach (var mark in marks) {
            if (occurrences.TryGetValue(mark.Id, out var old) && old.Mark.Signature == mark.Signature && Subject(old)?.ToString()==NextSubject(mark)?.ToString()) { next.Add(mark.Id, old); continue; }
            changed = true; var node = new Node3D { Name = "occurrence" }; root.AddChild(node);
            var corners = mark.Kind == "group" ? [] : Corners(sizes[mark.Id]);
            var lines = Lines(mark.Kind,corners);MeshInstance3D? shape=null;
            var looks = mark.Looks.Select(surface=>(Material)Look(mark,surface)).ToArray();
            if (mark.Kind != "group") {
                Mesh mesh;
                if (mark.Edges) {
                    var drawn = new ImmediateMesh(); drawn.SurfaceBegin(Mesh.PrimitiveType.Lines);
                    foreach (var line in lines) {
                        if(mark.Kind=="corner_box")drawn.SurfaceSetColor(Colors.White);
                        drawn.SurfaceAddVertex(line.A);
                        if(mark.Kind=="corner_box")drawn.SurfaceSetColor(new Color(1,1,1,0));
                        drawn.SurfaceAddVertex(line.B);
                    }
                    drawn.SurfaceEnd(); mesh = drawn;
                } else if (mark.Kind=="sphere") mesh=new SphereMesh { Radius=sizes[mark.Id].X/2,Height=sizes[mark.Id].X };
                else mesh = new BoxMesh { Size = sizes[mark.Id] };
                shape=new MeshInstance3D { Mesh = mesh, MaterialOverride = looks[0] };node.AddChild(shape);
            }
            if(mark.Label.Kind!="atom" || mark.Label.Name!="unlabelled") {
                var label=mark.Label.Require("label",2);float y=label[1].TextValue switch {"above"=>sizes[mark.Id].Y/2+.15f,"below"=>-sizes[mark.Id].Y/2-.15f,_=>0};
                node.AddChild(new Label3D {Text=label[0].TextValue,Position=new(0,y,0),FontSize=32,PixelSize=.005f,
                    Billboard=BaseMaterial3D.BillboardModeEnum.Enabled,Modulate=new Color("#F5F1EB"),Shaded=false});
            }
            long identity=old!=null && Subject(old)?.ToString()==NextSubject(mark)?.ToString() ? old.Identity : ++occurrenceIdentity;
            next.Add(mark.Id, new(mark, node, corners,lines,identity,shape,looks)); Rebuilt++;
        }
        foreach (var item in next.Values) {
            var parent = item.Mark.Parent == null ? root : next[item.Mark.Parent].Node;
            if (item.Node.GetParent() != parent) item.Node.Reparent(parent, false);
            var pose = item.Mark.Parent == null ? transforms[item.Mark.Id]
                : transforms[item.Mark.Parent].AffineInverse() * transforms[item.Mark.Id];
            changed|=item.Node.Transform!=pose;item.Node.Transform=pose;
        }
        foreach (var old in occurrences.Values) if (!next.TryGetValue(old.Mark.Id, out var current) || old.Node != current.Node) { old.Node.GetParent()?.RemoveChild(old.Node); old.Node.QueueFree(); changed = true; }
        occurrences.Clear(); foreach (var pair in next) occurrences.Add(pair.Key, pair.Value);
        world = projection;drawn=marks;
        available=true;
        ShowLooks(true);
        if (changed) RequestFraming();
        MountCamera();
        if(changed||availabilityChanged)PresentationChanged?.Invoke();
    }
    public void ApplyFrame()
    {
        if (world == null) return;
        var transforms = Transforms(drawn,world);
        bool changed=false;
        foreach (var item in occurrences.Values) {
            var pose=item.Mark.Parent == null ? transforms[item.Mark.Id] : transforms[item.Mark.Parent].AffineInverse() * transforms[item.Mark.Id];
            changed|=item.Node.Transform!=pose;item.Node.Transform=pose;
        }
        MountCamera();
        if(changed)PresentationChanged?.Invoke();
    }
    void MountCamera()
    {
        Controlled=world?.Controlled != null;
        if (world?.Controlled is not ControlBinding binding) return;
        var sample=world.Sample!; var pose=BodyInFrame(sample,sample.Bodies[(binding.Body,binding.Revision)],world.ViewFrames);
        var local=binding.Viewpoint.Require("pose",2);
        var p=local[0].Require("vector",3).Select(v=>Finite((double)v.Integer/1000)).ToArray();
        var r=local[1].Require("rotation",3).Select(v=>Finite((double)v.Integer/1000)).ToArray();
        camera.Transform=pose*new Transform3D(RotationBasis(r[0],r[1],r[2]),new(p[0],p[1],p[2]));
    }
    void RequestFraming()
    {
        long expected=++framing;
        // Native Label3D shaping is already queued before this callback.
        Callable.From(()=>{if(available&&expected==framing&&IsInstanceValid(this)&&IsInsideTree()){FrameScene();MountCamera();}}).CallDeferred();
    }
    void FrameScene()
    {
        camera.Basis=Basis.Identity;
        var points = occurrences.Values.SelectMany(o => o.Corners.Select(p => o.Node.GlobalTransform * p)
            .Concat(o.Node.GetChildren().OfType<Label3D>().SelectMany(label=>{
                var padding=new Vector3(1,1,0)*label.OutlineSize*label.PixelSize;
                return (label.GenerateTriangleMesh()?.GetFaces()??[]).SelectMany(p=>new[]{label.GlobalPosition+p-padding,label.GlobalPosition+p+padding});
            }))).Concat(formSurface?.Visible==true ? Corners(new(((QuadMesh)formSurface.Mesh).Size.X,((QuadMesh)formSurface.Mesh).Size.Y,0)).Select(p=>formSurface.GlobalTransform*(p+((QuadMesh)formSurface.Mesh).CenterOffset)) : []).ToArray();
        if (points.Length == 0) { camera.Position = new(0,0,5); camera.Rotation = Vector3.Zero; camera.Near = 0.05f; camera.Far = 1000; return; }
        if (points.Any(p => !p.IsFinite())) throw new FormatException("Scene frame exceeds the engine's numeric range.");
        var min = points[0]; var max = points[0]; foreach (var point in points) { min = min.Min(point); max = max.Max(point); }
        double dx=(double)max.X-min.X, dy=(double)max.Y-min.Y, dz=(double)max.Z-min.Z;
        float diameter=(float)Math.Max(Math.Sqrt(dx*dx+dy*dy+dz*dz),0.00001);
        if (!float.IsFinite(diameter*10)) throw new FormatException("Scene frame exceeds the engine's numeric range.");
        var centre = min/2 + max/2;
        camera.Position = centre + Vector3.Back;
        camera.LookAt(centre);
        // Fit both projected axes to the actual viewport, keeping a small margin.
        var inverse=camera.Basis.Inverse();var projection=camera.GetCameraProjection();
        var scale=new Vector2(Math.Abs(projection.X.X),Math.Abs(projection.Y.Y))*1.1f;
        var upper=new Vector2(float.NegativeInfinity,float.NegativeInfinity);var lower=-upper;float front=float.NegativeInfinity;
        foreach(var point in points) {
            var local=inverse*(point-centre);
            var xy=new Vector2(local.X,local.Y)*scale;
            upper=upper.Max(xy+Vector2.One*local.Z);lower=lower.Min(xy-Vector2.One*local.Z);front=Math.Max(front,local.Z);
        }
        float distance=Math.Max(Math.Max((upper.X-lower.X)/2,(upper.Y-lower.Y)/2),front+diameter/10000);
        if(!float.IsFinite(distance+diameter*2))throw new FormatException("Scene frame exceeds the engine's numeric range.");
        var offset=(upper+lower)/2/scale;
        camera.Position=centre+camera.Basis*new Vector3(offset.X,offset.Y,distance);
        camera.Near=Math.Max(diameter/10000,0.00000001f);camera.Far=Math.Max(distance+diameter*2,camera.Near*100);
    }
    Occurrence? Resolve(Selection selected)=>available && ReferenceEquals(selected.Owner,this) && occurrences.TryGetValue(selected.Id,out var current) &&
        current.Identity==selected.Identity && Subject(current)?.ToString()==selected.Subject.ToString() ? current : null;
    public Selection? Pick(Vector2 point)=>PickRay(camera.ProjectRayOrigin(point),camera.ProjectRayNormal(point),point);
    public Selection? PickRay(Vector3 origin,Vector3 direction,Vector2? screenPoint=null)
    {
        if(!available)return null;
        if(!origin.IsFinite() || !direction.IsFinite() || direction.LengthSquared()==0)return null;
        direction=direction.Normalized();
        Occurrence? hit = null; float nearest = float.PositiveInfinity;
        foreach (var item in occurrences.Values.Where(o => o.Corners.Length > 0)) {
            if (item.Mark.Edges) {
                foreach (var line in item.Lines) {
                    var a = item.Node.GlobalTransform * line.A; var b = item.Node.GlobalTransform * line.B;
                    if(screenPoint is not Vector2 point) {
                        var closest=Geometry3D.GetClosestPointsBetweenSegments(origin,origin+direction*camera.Far,a,b);
                        float distance=(closest[0]-origin).Dot(direction);
                        float tolerance=distance*Mathf.Tan(Mathf.DegToRad(camera.Fov/2))*12/Math.Max(1,viewport.Size.Y);
                        if(distance>0 && distance<nearest && closest[0].DistanceTo(closest[1])<=tolerance) { nearest=distance;hit=item; }
                        continue;
                    }
                    if (camera.IsPositionBehind(a) || camera.IsPositionBehind(b)) continue;
                    var start = camera.UnprojectPosition(a); var segment = camera.UnprojectPosition(b) - start;
                    float fraction = segment.LengthSquared() == 0 ? 0 : Math.Clamp((point - start).Dot(segment) / segment.LengthSquared(), 0, 1);
                    float depth = -(camera.GlobalTransform.AffineInverse()*a.Lerp(b,fraction)).Z;
                    if (point.DistanceTo(start + segment * fraction) <= 6 && depth < nearest) { nearest = depth; hit = item; }
                }
            } else {
                var inverse = item.Node.GlobalTransform.AffineInverse();
                var localOrigin = inverse * origin; var localDirection = inverse.Basis * direction;
                var size = item.Corners[7] - item.Corners[0];
                if (item.Mark.Kind=="sphere") {
                    float b=localOrigin.Dot(localDirection),c=localOrigin.LengthSquared()-size.X*size.X/4,disc=b*b-localDirection.LengthSquared()*c;
                    if (disc>=0) { float distance=(-b-Mathf.Sqrt(disc))/localDirection.LengthSquared();
                        if (distance>=0 && distance<nearest) { nearest=distance; hit=item; } }
                    continue;
                }
                float near = 0, far = float.PositiveInfinity;
                for (int axis = 0; axis < 3; axis++) {
                    if (Math.Abs(localDirection[axis]) < 1e-12f) { if (Math.Abs(localOrigin[axis]) > size[axis] / 2) { far = -1; break; } }
                    else { float a = (-size[axis]/2-localOrigin[axis])/localDirection[axis], b = (size[axis]/2-localOrigin[axis])/localDirection[axis]; near = Math.Max(near,Math.Min(a,b)); far = Math.Min(far,Math.Max(a,b)); }
                }
                if (near <= far && near < nearest) { nearest = near; hit = item; }
            }
        }
        return Thing(hit) is {} thing ? new(this,thing.Mark.Id,thing.Identity,thing.Mark.Subject!) : null;
    }
    Term? Subject(Occurrence? item)
    { while (item!=null) { if (item.Mark.Subject!=null) return item.Mark.Subject; item=item.Mark.Parent==null ? null : occurrences[item.Mark.Parent]; } return null; }
    // One id per shown thing: the mark that names the subject, whatever parts its recipe draws beneath.
    public string[] SubjectIds(Term subject) => occurrences.Values.Where(o=>o.Mark.Subject?.ToString()==subject.ToString()).Select(o=>o.Mark.Id).ToArray();
    public string? SubjectLabel(Term subject)
    {
        if(!available)return null;
        var labels=occurrences.Values.Where(o=>Subject(o)?.ToString()==subject.ToString()&&o.Mark.Label.Name=="label")
            .Select(o=>o.Mark.Label.Args[0].TextValue).Distinct().ToArray();
        return labels.Length==1 ? labels[0] : null;
    }
    public Vector2 Project(string id, Vector3 local) => camera.UnprojectPosition(occurrences[id].Node.GlobalTransform * local);
    public Vector3[] WorldCorners(string id) => occurrences[id].Corners.Select(p => occurrences[id].Node.GlobalTransform * p).ToArray();
    public Transform3D WorldPose(string id) => occurrences[id].Node.GlobalTransform;
    public void ReleaseInput()
    { bool active = held.Count != 0; held.Clear(); looking=false;menuHeld=false;pressedSubject=null; if (active && Controlled) Drive?.Invoke(Vector3.Zero,Vector3.Zero); }
    public override void _Process(double delta)
    {
        if (Controlled || navigationBlocked || held.Count == 0) return;
        var input = Direction(); camera.Position += camera.Basis * input * (float)delta * 3;
    }
    Vector3 Direction() => new((held.Contains(Key.D)?1:0)-(held.Contains(Key.A)?1:0),
        (held.Contains(Key.E)?1:0)-(held.Contains(Key.Q)?1:0),(held.Contains(Key.S)?1:0)-(held.Contains(Key.W)?1:0));
    Vector3 DomainDirection()
    {
        return DomainBasis*camera.Basis*Direction();
    }
    public override void _GuiInput(InputEvent @event)
    {
        if(!available)return;
        if (@event is InputEventKey key && key.PhysicalKeycode is Key.W or Key.A or Key.S or Key.D or Key.Q or Key.E) {
            if (key.Echo) return;
            if(key.Pressed && navigationBlocked)return;
            if (key.Pressed) held.Add(key.PhysicalKeycode); else held.Remove(key.PhysicalKeycode);
            if (Controlled) Drive?.Invoke(DomainDirection(),Vector3.Zero); AcceptEvent();
        }
        if (@event is InputEventMouseButton { ButtonIndex: MouseButton.Middle } look) { looking=look.Pressed; GrabFocus(); AcceptEvent(); }
        if (@event is InputEventMouseButton { ButtonIndex: MouseButton.Right } menu) {
            GrabFocus();menuHeld=menu.Pressed;
            MenuGesture?.Invoke(menu.Pressed ? MenuStep.Open : MenuStep.Release,
                menu.Pressed ? Pick(menu.Position * ((Vector2)viewport.Size / Size)) : null,menu.Position);
            AcceptEvent();
        }
        if (@event is InputEventMouseMotion dragged && menuHeld) { MenuGesture?.Invoke(MenuStep.Move,null,dragged.Position); AcceptEvent(); }
        else if (@event is InputEventMouseMotion hover && !looking) Hovered?.Invoke(Pick(hover.Position * ((Vector2)viewport.Size / Size)),hover.Position);
        if (@event is InputEventMouseMotion motion && looking && !Controlled) {
            camera.RotateY(-motion.Relative.X*.004f); camera.RotateObjectLocal(Vector3.Right,-motion.Relative.Y*.004f); AcceptEvent();
        }
        if (@event is InputEventMouseButton { ButtonIndex: MouseButton.Left } click) {
            GrabFocus();
            var scaled = click.Position * ((Vector2)viewport.Size / Size); var subject = Pick(scaled);
            if(click.Pressed)pressedSubject=subject;
            else { var before=pressedSubject;pressedSubject=null;if(before!=null && subject==before && new Rect2(Vector2.Zero,Size).HasPoint(click.Position))Selected?.Invoke(before); }
            AcceptEvent();
        }
    }
    public void Suspend(){framing++;bool was=available;available=false;ReleaseInput();Controlled=false;world=null;HideForm();ShowLooks();if(was)PresentationChanged?.Invoke();}
    public void Withdraw()
    { Suspend();foreach (var item in occurrences.Values) if (IsInstanceValid(item.Node)) { item.Node.GetParent()?.RemoveChild(item.Node); item.Node.QueueFree(); } occurrences.Clear();source=drawn=[];modes.Clear(); }
    internal void Select(Selection selected){if(Resolve(selected)!=null)Selected?.Invoke(selected);}
    public void PointAt(Selection? target){pointed=target;ShowLooks();}
    public void ShowSelected(Selection? target){selected=target;ShowLooks();}
    // A shown thing is the mark naming a subject, with the marks beneath it
    // that name none. All of them change look together; selected wins.
    Occurrence? Thing(Occurrence? item)
    { while(item!=null&&item.Mark.Subject==null)item=item.Mark.Parent==null ? null : occurrences[item.Mark.Parent]; return item; }
    Occurrence? Thing(Selection? target)=>target==null ? null : Resolve(target);
    IEnumerable<Occurrence> Parts(Occurrence thing)=>occurrences.Values.Where(o=>ReferenceEquals(Thing(o),thing));
    void ShowLooks(bool rebuilt=false)
    {
        var point=Thing(pointed);var chosen=Thing(selected);
        if(!rebuilt&&ReferenceEquals(point,pointedThing)&&ReferenceEquals(chosen,selectedThing))return;
        pointedThing=point;selectedThing=chosen;
        foreach(var item in occurrences.Values.Where(o=>o.Looks.Length==3)) {
            var thing=Thing(item);int look=thing==null ? 0 : ReferenceEquals(thing,chosen) ? 2 : ReferenceEquals(thing,point) ? 1 : 0;
            if(item.Look!=look){item.Look=look;item.Shape!.MaterialOverride=item.Looks[look];}
        }
    }
    internal int ShownLook(string id)=>occurrences[id].Look;
}
