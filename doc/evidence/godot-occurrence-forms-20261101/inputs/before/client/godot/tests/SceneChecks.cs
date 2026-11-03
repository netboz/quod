using Godot;
using Quod.Client;
using File = System.IO.File;

public partial class ExportChecks
{
    async Task SceneAdapter()
    {
        var scene = app.FindChild("space-scene", true, false) as ScenePanel ?? throw new Exception("Missing shared scene adapter");
        string anchor = Term.Binary(new byte[32]).ToString();
        var subject = Term.Call("entity_ref", Term.Text("scene-fixture"), Term.Binary(new byte[32]), Term.Atom("artifact"));
        string Group(string pose) => $"mark(<<\"subject\">>,<<\"group\">>,[],{pose},no_surface,unlabelled,depicts(<<\"scene-fixture\">>,{anchor},artifact))";
        string Box(string kind, string w, string h, string d) => $"mark(<<\"subject/shape\">>,<<\"{kind}\">>,[f(<<\"width\">>,{w}),f(<<\"height\">>,{h}),f(<<\"depth\">>,{d})],relative(<<\"subject\">>,transform(0,0,0,0,0,0)),surface(<<\"#6A90D9\">>,0,700,1000,[]),unlabelled,depicts_nothing)";
        Term Marks(string pose, string kind, string w, string h, string d) => Term.Parse("[" + Group(pose) + "," + Box(kind,w,h,d) + "]");
        var normal = Marks("transform(0,0,0,0,0,0)","wire_box","100000","100000","100000");
        scene.Apply(normal); await Frame();
        var corners = scene.WorldCorners("subject/shape");
        Check(corners[0].IsEqualApprox(new(-50,-50,-50)) && corners[7].IsEqualApprox(new(50,50,50)), "default real-size wireframe spans minus50 to plus50 metres");
        var mesh=scene.SceneRoot.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>().Single().Mesh;
        var surface=RenderingServer.MeshGetSurface(mesh.GetRid(),0);
        Console.WriteLine($"M2_WIRE_SURFACE primitive={surface["primitive"]} vertices={surface["vertex_count"]} expected={(int)RenderingServer.PrimitiveType.Lines}");
        Check(surface["primitive"].AsInt32()==(int)RenderingServer.PrimitiveType.Lines && surface["vertex_count"].AsInt32()==24,"actual engine wire surface contains twelve lines and no face primitives");
        Check(scene.PickRay(new(0,0,200),Vector3.Forward)==null,"spatial ray cannot pick a wireframe face interior");
        Check(scene.PickRay(new(0,-50,200),Vector3.Forward)?.ToString()==subject.ToString(),"spatial ray picks a wire edge through the same exact subject owner");
        if(DisplayServer.GetName()!="headless") {
            for(Node? parent=scene.GetParent();parent!=null;parent=parent.GetParent()) if(parent is ScrollContainer scroll) scroll.EnsureControlVisible(scene);
            await Frame(); await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            var viewport=scene.GetChildren().OfType<SubViewport>().Single();
            using var raster=viewport.GetTexture().GetImage();
            var centre=raster.GetPixel(raster.GetWidth()/2,raster.GetHeight()/2);
            Check(centre.R<.01f && centre.G<.01f && centre.B<.01f,"actual desktop wireframe raster leaves its face interior empty");
            var edge=scene.Project("subject/shape",new Vector3(0,-50,-50)); bool visible=false;
            for(int x=(int)edge.X-2;x<=(int)edge.X+2;x++) for(int y=(int)edge.Y-2;y<=(int)edge.Y+2;y++)
                if(x>=0 && y>=0 && x<raster.GetWidth() && y<raster.GetHeight() && raster.GetPixel(x,y).B>.2f) visible=true;
            Check(visible,"actual desktop wireframe raster draws the projected edge");
            if(System.Environment.GetEnvironmentVariable("M2_SCENE_CAPTURE") is string path) Check(raster.SavePng(path)==Error.Ok,"desktop wireframe raster retained");
        }
        int built = scene.Rebuilt;
        scene.Apply(normal); scene.Apply(normal); await Frame();
        Check(scene.Count == 2 && scene.Rebuilt == built, "unchanged scene occurrences retain actual engine resources");
        var rotated = Marks("transform(1000,2000,3000,0,0,90)","wire_box","'/'(1,3)","1001","'/'(1001,2)");
        scene.Apply(rotated); await Frame(); corners = scene.WorldCorners("subject/shape");
        Check(((corners[0]+corners[7])/2).IsEqualApprox(new(1,2,3)), "rotated asymmetric rational wireframe remains centred on transformed local origin");
        Check(Math.Abs(corners[7].X-corners[0].X + 1.001f) < 0.000001f &&
              Math.Abs(corners[7].Y-corners[0].Y - 1f/3000) < 0.000001f &&
              Math.Abs(corners[7].Z-corners[0].Z - .5005f) < 0.000001f, "axis rotation preserves odd and submillimetre rational extents at render boundary");
        var midpoint = new Vector3(0,-1.001f/2,-.5005f/2);
        Check(scene.Pick(scene.Project("subject/shape",midpoint))?.ToString() == subject.ToString(), "wire edge picking resolves exact ancestor subject and history");
        Check(scene.Pick(new(-100,-100)) == null, "wireframe does not invent a picking surface away from its edges");
        scene.Apply(Marks("transform(0,0,0,0,0,0)","box","500","500","500")); await Frame();
        Check(scene.Pick(scene.Project("subject/shape",Vector3.Zero))?.ToString() == subject.ToString(), "default solid cube uses the same exact-subject picking adapter");
        var all = new List<Node>(); void Visit(Node node) { all.Add(node); foreach(var child in node.GetChildren()) Visit(child); }
        Visit(scene); Check(!all.Any(n => n is CollisionObject3D), "exterior adapter creates no collision bodies or walls");
        scene.Withdraw(); await Frame(); Check(scene.Count == 0 && scene.Pick(Vector2.Zero) == null, "withdrawal removes geometry and picking together");
        await File.WriteAllTextAsync(Env("M1B_RESULT"), System.Text.Json.JsonSerializer.Serialize(new { passed=true, checks }));
        Console.WriteLine("M2_SCENE_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }
}
