using Godot;
using Quod.Client;

// Shared mark adapter. Geometry is presentation only: no collision bodies or
// local simulation. Picking resolves the occurrence's exact depicted subject.
public partial class ScenePanel : SubViewportContainer
{
    sealed record Occurrence(SceneMark Mark, Node3D Node, Vector3[] Corners);
    readonly Dictionary<string, Occurrence> occurrences = [];
    readonly SubViewport viewport = new() { Name = "scene-viewport", Size = new(1000, 400), OwnWorld3D = true, TransparentBg = false, HandleInputLocally = false };
    readonly Node3D root = new() { Name = "scene-marks" };
    readonly Camera3D camera = new() { Name = "scene-camera", Current = true, Near = 0.05f, Far = 1000 };
    public event Action<Term>? Selected;
    public int Rebuilt { get; private set; }
    public int Count => occurrences.Count;
    public string[] Ids => occurrences.Keys.ToArray();
    public override void _Ready()
    {
        CustomMinimumSize = new(600, 360); SizeFlagsHorizontal = SizeFlags.ExpandFill; Stretch = true; MouseFilter = MouseFilterEnum.Stop;
        AddChild(viewport); viewport.AddChild(root); viewport.AddChild(camera);
        viewport.FindWorld3D().Environment = new Godot.Environment { BackgroundMode = Godot.Environment.BGMode.Color, BackgroundColor = Colors.Black };
        camera.Position = new(0, 0, 5);
    }
    static Vector3[] Corners(Vector3 size) => [
        new Vector3(-size.X,-size.Y,-size.Z)/2,new Vector3(size.X,-size.Y,-size.Z)/2,
        new Vector3(-size.X,size.Y,-size.Z)/2,new Vector3(size.X,size.Y,-size.Z)/2,
        new Vector3(-size.X,-size.Y,size.Z)/2,new Vector3(size.X,-size.Y,size.Z)/2,
        new Vector3(-size.X,size.Y,size.Z)/2,new Vector3(size.X,size.Y,size.Z)/2];
    static readonly (int A, int B)[] Edges = [(0,1),(2,3),(4,5),(6,7),(0,2),(1,3),(4,6),(5,7),(0,4),(1,5),(2,6),(3,7)];
    static Transform3D Pose(int[] p)
    {
        var basis = new Basis(Vector3.Back, Mathf.DegToRad(p[5])) * new Basis(Vector3.Up, Mathf.DegToRad(p[4])) * new Basis(Vector3.Right, Mathf.DegToRad(p[3]));
        return new(basis, new(p[0] / 1000f, p[1] / 1000f, p[2] / 1000f));
    }
    public void Apply(Term terms)
    {
        var marks = SceneMark.Decode(terms); var next = new Dictionary<string, Occurrence>();
        // Validate and convert the complete candidate before changing the scene.
        var sizes = marks.ToDictionary(m => m.Id, m => m.Size.Length == 0 ? Vector3.Zero : new Vector3(m.Size[0].RenderMetres(), m.Size[1].RenderMetres(), m.Size[2].RenderMetres()));
        bool changed = false;
        foreach (var mark in marks) {
            if (occurrences.TryGetValue(mark.Id, out var old) && old.Mark.Signature == mark.Signature) { next.Add(mark.Id, old); continue; }
            changed = true; var node = new Node3D { Name = "occurrence" }; root.AddChild(node);
            var corners = mark.Kind == "group" ? [] : Corners(sizes[mark.Id]);
            if (mark.Kind != "group") {
                Mesh mesh;
                if (mark.Kind == "wire_box") {
                    var lines = new ImmediateMesh(); lines.SurfaceBegin(Mesh.PrimitiveType.Lines);
                    foreach (var edge in Edges) { lines.SurfaceAddVertex(corners[edge.A]); lines.SurfaceAddVertex(corners[edge.B]); }
                    lines.SurfaceEnd(); mesh = lines;
                } else mesh = new BoxMesh { Size = sizes[mark.Id] };
                node.AddChild(new MeshInstance3D { Mesh = mesh, MaterialOverride = new StandardMaterial3D {
                    ShadingMode = BaseMaterial3D.ShadingModeEnum.Unshaded, AlbedoColor = Color.FromString(mark.Colour, Colors.White), CullMode = BaseMaterial3D.CullModeEnum.Disabled } });
            }
            if (mark.Label.Kind == "compound") node.AddChild(new Label3D { Text = mark.Label.Args[0].TextValue, Billboard = BaseMaterial3D.BillboardModeEnum.Enabled, NoDepthTest = true });
            next.Add(mark.Id, new(mark, node, corners)); Rebuilt++;
        }
        foreach (var item in next.Values) {
            var parent = item.Mark.Parent == null ? root : next[item.Mark.Parent].Node;
            if (item.Node.GetParent() != parent) item.Node.Reparent(parent, false);
            item.Node.Transform = Pose(item.Mark.Transform);
        }
        foreach (var old in occurrences.Values) if (!next.TryGetValue(old.Mark.Id, out var current) || old.Node != current.Node) { old.Node.GetParent()?.RemoveChild(old.Node); old.Node.QueueFree(); changed = true; }
        occurrences.Clear(); foreach (var pair in next) occurrences.Add(pair.Key, pair.Value);
        if (changed) FrameScene();
    }
    void FrameScene()
    {
        var points = occurrences.Values.SelectMany(o => o.Corners.Select(p => o.Node.GlobalTransform * p)).ToArray();
        if (points.Length == 0) { camera.Position = new(0,0,5); camera.Rotation = Vector3.Zero; camera.Near = 0.05f; camera.Far = 1000; return; }
        if (points.Any(p => !p.IsFinite())) throw new FormatException("Scene frame exceeds the engine's numeric range.");
        var min = points[0]; var max = points[0]; foreach (var point in points) { min = min.Min(point); max = max.Max(point); }
        double dx=(double)max.X-min.X, dy=(double)max.Y-min.Y, dz=(double)max.Z-min.Z;
        float diameter=(float)Math.Max(Math.Sqrt(dx*dx+dy*dy+dz*dz),0.00001);
        if (!float.IsFinite(diameter*10)) throw new FormatException("Scene frame exceeds the engine's numeric range.");
        var centre = min/2 + max/2;
        camera.Position = centre + new Vector3(0.7f, 0.5f, 0.9f).Normalized() * diameter;
        camera.LookAt(centre); camera.Near = Math.Max(diameter / 10000, 0.00000001f); camera.Far = Math.Max(diameter * 10, camera.Near * 100);
    }
    public Term? Pick(Vector2 point)
    {
        Occurrence? hit = null; float nearest = float.PositiveInfinity;
        foreach (var item in occurrences.Values.Where(o => o.Corners.Length > 0)) {
            if (item.Mark.Kind == "wire_box") {
                foreach (var edge in Edges) {
                    var a = item.Node.GlobalTransform * item.Corners[edge.A]; var b = item.Node.GlobalTransform * item.Corners[edge.B];
                    if (camera.IsPositionBehind(a) || camera.IsPositionBehind(b)) continue;
                    var start = camera.UnprojectPosition(a); var segment = camera.UnprojectPosition(b) - start;
                    float fraction = segment.LengthSquared() == 0 ? 0 : Math.Clamp((point - start).Dot(segment) / segment.LengthSquared(), 0, 1);
                    float depth = -(camera.GlobalTransform.AffineInverse()*a.Lerp(b,fraction)).Z;
                    if (point.DistanceTo(start + segment * fraction) <= 6 && depth < nearest) { nearest = depth; hit = item; }
                }
            } else {
                var inverse = item.Node.GlobalTransform.AffineInverse();
                var origin = inverse * camera.ProjectRayOrigin(point); var direction = inverse.Basis * camera.ProjectRayNormal(point);
                var size = item.Corners[7] - item.Corners[0];
                float near = 0, far = float.PositiveInfinity;
                for (int axis = 0; axis < 3; axis++) {
                    if (Math.Abs(direction[axis]) < 1e-12f) { if (Math.Abs(origin[axis]) > size[axis] / 2) { far = -1; break; } }
                    else { float a = (-size[axis]/2-origin[axis])/direction[axis], b = (size[axis]/2-origin[axis])/direction[axis]; near = Math.Max(near,Math.Min(a,b)); far = Math.Min(far,Math.Max(a,b)); }
                }
                if (near <= far && near < nearest) { nearest = near; hit = item; }
            }
        }
        while (hit != null) { if (hit.Mark.Subject != null) return hit.Mark.Subject; hit = hit.Mark.Parent == null ? null : occurrences[hit.Mark.Parent]; }
        return null;
    }
    public Vector2 Project(string id, Vector3 local) => camera.UnprojectPosition(occurrences[id].Node.GlobalTransform * local);
    public Vector3[] WorldCorners(string id) => occurrences[id].Corners.Select(p => occurrences[id].Node.GlobalTransform * p).ToArray();
    public override void _GuiInput(InputEvent @event)
    {
        if (@event is InputEventMouseButton { Pressed: false, ButtonIndex: MouseButton.Left } click) {
            var scaled = click.Position * ((Vector2)viewport.Size / Size); var subject = Pick(scaled);
            if (subject != null) Selected?.Invoke(subject); AcceptEvent();
        }
    }
    public void Withdraw()
    { foreach (var item in occurrences.Values) if (IsInstanceValid(item.Node)) item.Node.QueueFree(); occurrences.Clear(); }
}
