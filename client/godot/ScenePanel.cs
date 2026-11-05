using Godot;
using Quod.Client;
using BigInteger = System.Numerics.BigInteger;

// Shared mark adapter. Geometry is presentation only: no collision bodies or
// local simulation. Picking resolves the occurrence's exact depicted subject.
public partial class ScenePanel : SubViewportContainer
{
    sealed record Occurrence(SceneMark Mark, Node3D Node, Vector3[] Corners, long Identity);
    // A pick keeps its installed occurrence, not merely the depicted subject.
    // Placement is always resolved from this owner; a removed/reused ID cannot
    // revive a previous selection or confer authority to an operation.
    public sealed record Selection(ScenePanel Owner,string Id,long Identity,Term Subject)
    {
        public Transform3D? Pose=>Owner.Resolve(this)?.Node.GlobalTransform;
        public Vector3[] Corners=>Owner.Resolve(this) is {} current ? current.Corners.Select(p=>current.Node.GlobalTransform*p).ToArray() : [];
        public string? Label=>Owner.Resolve(this) is {} current && current.Mark.Label.Name=="label" ? current.Mark.Label.Args[0].TextValue : null;
    }
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
    internal Transform3D CameraPose=>camera.GlobalTransform;
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
    Occurrence? highlighted;
    // A local tint on the pointed mark; it reads and changes no domain state.
    static readonly StandardMaterial3D Highlight=new() { ShadingMode=BaseMaterial3D.ShadingModeEnum.Unshaded,
        AlbedoColor=new(0xF9/255f,0xC8/255f,0x0E/255f,.28f),Transparency=BaseMaterial3D.TransparencyEnum.Alpha };
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
    void Apply(SceneMark[] marks,WorldProjection? projection)
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
            if (mark.Kind != "group") {
                Mesh mesh;
                if (mark.Kind == "wire_box") {
                    var lines = new ImmediateMesh(); lines.SurfaceBegin(Mesh.PrimitiveType.Lines);
                    foreach (var edge in Edges) { lines.SurfaceAddVertex(corners[edge.A]); lines.SurfaceAddVertex(corners[edge.B]); }
                    lines.SurfaceEnd(); mesh = lines;
                } else if (mark.Kind=="sphere") mesh=new SphereMesh { Radius=sizes[mark.Id].X/2,Height=sizes[mark.Id].X };
                else mesh = new BoxMesh { Size = sizes[mark.Id] };
                // Below full opacity a surface is translucent; both sides already draw.
                var colour=new Color(mark.Colour) with {A=mark.Opacity/1000f};
                node.AddChild(new MeshInstance3D { Mesh = mesh, MaterialOverride = new StandardMaterial3D {
                    ShadingMode = mark.Kind=="wire_box" ? BaseMaterial3D.ShadingModeEnum.Unshaded : BaseMaterial3D.ShadingModeEnum.PerPixel,
                    AlbedoColor=colour,Metallic=mark.Metallic/1000f,Roughness=mark.Roughness/1000f,
                    EmissionEnabled=mark.Emission>0,Emission=colour,EmissionEnergyMultiplier=mark.Emission/1000f,
                    Transparency=mark.Opacity<1000 ? BaseMaterial3D.TransparencyEnum.Alpha : BaseMaterial3D.TransparencyEnum.Disabled,
                    CullMode = BaseMaterial3D.CullModeEnum.Disabled } });
            }
            if(mark.Label.Kind!="atom" || mark.Label.Name!="unlabelled") {
                var label=mark.Label.Require("label",2);float y=label[1].TextValue switch {"above"=>sizes[mark.Id].Y/2+.15f,"below"=>-sizes[mark.Id].Y/2-.15f,_=>0};
                node.AddChild(new Label3D {Text=label[0].TextValue,Position=new(0,y,0),FontSize=32,PixelSize=.005f,
                    Billboard=BaseMaterial3D.BillboardModeEnum.Enabled,Modulate=new Color("#F5F1EB"),Shaded=false});
            }
            long identity=old!=null && Subject(old)?.ToString()==NextSubject(mark)?.ToString() ? old.Identity : ++occurrenceIdentity;
            next.Add(mark.Id, new(mark, node, corners,identity)); Rebuilt++;
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
        world = projection;
        available=true;
        if (changed) RequestFraming();
        MountCamera();
        if(changed||availabilityChanged)PresentationChanged?.Invoke();
    }
    public void ApplyFrame()
    {
        if (world == null) return;
        var transforms = Transforms(world.Marks,world);
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
            if (item.Mark.Kind == "wire_box") {
                foreach (var edge in Edges) {
                    var a = item.Node.GlobalTransform * item.Corners[edge.A]; var b = item.Node.GlobalTransform * item.Corners[edge.B];
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
        return hit!=null && Subject(hit) is {} subject ? new(this,hit.Mark.Id,hit.Identity,subject) : null;
    }
    Term? Subject(Occurrence? item)
    { while (item!=null) { if (item.Mark.Subject!=null) return item.Mark.Subject; item=item.Mark.Parent==null ? null : occurrences[item.Mark.Parent]; } return null; }
    public string[] SubjectIds(Term subject) => occurrences.Values.Where(o=>o.Corners.Length>0 && Subject(o)?.ToString()==subject.ToString()).Select(o=>o.Mark.Id).ToArray();
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
    public void Suspend(){framing++;bool was=available;available=false;ReleaseInput();Controlled=false;world=null;HideForm();if(was)PresentationChanged?.Invoke();}
    public void Withdraw()
    { Suspend();foreach (var item in occurrences.Values) if (IsInstanceValid(item.Node)) { item.Node.GetParent()?.RemoveChild(item.Node); item.Node.QueueFree(); } occurrences.Clear(); }
    internal void Select(Selection selected){if(Resolve(selected)!=null)Selected?.Invoke(selected);}
    public void Outline(Selection? selected)
    {
        var next=selected==null ? null : Resolve(selected);
        if(ReferenceEquals(next,highlighted))return;
        foreach(var item in new[]{highlighted,next})
            if(item!=null&&IsInstanceValid(item.Node))
                foreach(var mesh in item.Node.FindChildren("*","GeometryInstance3D",true,false).OfType<GeometryInstance3D>().Prepend(item.Node as GeometryInstance3D).OfType<GeometryInstance3D>())
                    mesh.MaterialOverlay=item==next ? Highlight : null;
        highlighted=next;
    }
}
