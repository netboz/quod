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
        string Box(string kind, string w, string h, string d) => $"mark(<<\"subject/shape\">>,<<\"{kind}\">>,[f(<<\"width\">>,{w}),f(<<\"height\">>,{h}),f(<<\"depth\">>,{d})],relative(<<\"subject\">>,transform(0,0,0,0,0,0)),surface(<<\"#6A90D9\">>,0,700,1000,1000,[]),unlabelled,depicts_nothing)";
        Term Marks(string pose, string kind, string w, string h, string d) => Term.Parse("[" + Group(pose) + "," + Box(kind,w,h,d) + "]");
        var normal = Marks("transform(0,0,0,0,0,0)","wire_box","100000","100000","100000");
        scene.Apply(normal); await Frame();
        var corners = scene.WorldCorners("subject/shape");
        Check(corners[0].IsEqualApprox(new(-50,-50,-50)) && corners[7].IsEqualApprox(new(50,50,50)), "a hundred metre wireframe spans minus50 to plus50 metres");
        var mesh=scene.SceneRoot.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>().Single().Mesh;
        var surface=RenderingServer.MeshGetSurface(mesh.GetRid(),0);
        Console.WriteLine($"M2_WIRE_SURFACE primitive={surface["primitive"]} vertices={surface["vertex_count"]} expected={(int)RenderingServer.PrimitiveType.Lines}");
        Check(surface["primitive"].AsInt32()==(int)RenderingServer.PrimitiveType.Lines && surface["vertex_count"].AsInt32()==24,"actual engine wire surface contains twelve lines and no face primitives");
        Check(scene.PickRay(new(0,0,200),Vector3.Forward)==null,"spatial ray cannot pick a wireframe face interior");
        Check(scene.PickRay(new(0,-50,200),Vector3.Forward)?.Subject.ToString()==subject.ToString(),"spatial ray picks a wire edge through the same exact subject owner");
        // Before sign-in the scene is hidden behind the card, so ask its viewport for one frame.
        async Task<Image> Raster() {
            var viewport=scene.GetChildren().OfType<SubViewport>().Single();
            await Frame(); viewport.RenderTargetUpdateMode=SubViewport.UpdateMode.Once;
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            return viewport.GetTexture().GetImage();
        }
        if(DisplayServer.GetName()!="headless") {
            Console.WriteLine($"M2_SCENE_VISIBLE {scene.IsVisibleInTree()}");
            using var raster=await Raster();
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
        Check(scene.Pick(scene.Project("subject/shape",midpoint))?.Subject.ToString() == subject.ToString(), "wire edge picking resolves exact ancestor subject and history");
        Check(scene.Pick(new(-100,-100)) == null, "wireframe does not invent a picking surface away from its edges");
        scene.Apply(Marks("transform(1000,2000,3000,0,0,90)","corner_box","'/'(1,3)","1001","'/'(1001,2)")); await Frame(); corners = scene.WorldCorners("subject/shape");
        Check(Math.Abs(corners[7].Y-corners[0].Y - 1f/3000) < 0.000001f && Math.Abs(corners[7].Z-corners[0].Z - .5005f) < 0.000001f, "a real-size corner box keeps the same exact rational extents at render boundary");
        scene.Apply(Marks("transform(0,0,0,0,0,0)","box","500","500","500")); await Frame();
        Check(scene.Pick(scene.Project("subject/shape",Vector3.Zero))?.Subject.ToString() == subject.ToString(), "default solid cube uses the same exact-subject picking adapter");
        // The shared marker as the vocabulary sends it: see-through sides and
        // fading corner lines, each carrying its display, pointed-at and selected surfaces.
        string Looks(string colour,int emission,int shown,int pointed,int chosen) => $"surfaces(surface(<<\"{colour}\">>,0,700,{emission},{shown},[]),surface(<<\"#F9C80E\">>,0,700,{emission},{pointed},[]),surface(<<\"#F9C80E\">>,0,700,{emission},{chosen},[]))";
        string Part(string thing,string name,string kind,string looks,string label) => $"mark(<<\"{thing}/{name}\">>,<<\"{kind}\">>,[f(<<\"width\">>,500),f(<<\"height\">>,500),f(<<\"depth\">>,500)],relative(<<\"{thing}\">>,transform(0,0,0,0,0,0)),{looks},{label},depicts_nothing)";
        string Marker(string thing,string pose,string entity) => $"mark(<<\"{thing}\">>,<<\"group\">>,[],{pose},no_surface,unlabelled,depicts(<<\"scene-fixture\">>,{anchor},{entity}))," +
            Part(thing,"sides","box",Looks("#848FA5",0,30,40,120),"unlabelled") + "," + Part(thing,"corners","corner_box",Looks("#C9D2DB",1000,1000,1000,1000),"label(<<\"Space\">>,<<\"above\">>)");
        var markers = Term.Parse("[" + Marker("subject","transform(0,0,0,0,30,0)","artifact") + "," + Marker("other","transform(1500,0,0,0,30,0)","neighbour") + "," + Marker("third","transform(3000,0,0,0,30,0)","bystander") + "]");
        scene.Apply(markers); await Frame();
        // A label stands with its thing: never turned toward the camera, written
        // twice back to back so it reads from the front and from behind.
        var named=scene.SceneRoot.FindChildren("*","Label3D",true,false).OfType<Label3D>().Where(l=>l.Text=="Space").GroupBy(l=>l.GetParent()).ToArray();
        Check(named.Length==3 && named.All(g=>g.Count()==2 && g.All(l=>l.Billboard==BaseMaterial3D.BillboardModeEnum.Disabled && !l.DoubleSided)),
            "each thing's label is fixed in the world, written twice, each copy seen from one side only");
        var facing=named.OrderBy(g=>g.First().GlobalPosition.DistanceTo(scene.WorldPose("subject").Origin)).First().ToArray();
        var thingFront=scene.WorldPose("subject").Basis.Z;
        Check(facing[0].GlobalBasis.Z.DistanceTo(thingFront)<.001f && facing[1].GlobalBasis.Z.Dot(thingFront)<-.999f,
            "the label turns with its thing: one copy faces the thing's front, its twin the back");
        var fading=scene.SceneRoot.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>().First(m=>m.Mesh is ImmediateMesh);
        var drawn=RenderingServer.MeshGetSurface(fading.Mesh.GetRid(),0);
        Check(drawn["primitive"].AsInt32()==(int)RenderingServer.PrimitiveType.Lines && drawn["vertex_count"].AsInt32()==48 &&
              (drawn["format"].AsInt64()&(long)RenderingServer.ArrayFormat.FormatColor)!=0,"a corner box is twenty-four line segments whose colour fades along their length");
        string[] ours=["subject/sides","subject/corners"],theirs=["other/sides","other/corners"],third=["third/sides","third/corners"];
        bool Shown(string[] ids,int look)=>ids.All(id=>scene.ShownLook(id)==look);
        var here=scene.Pick(scene.Project("subject/sides",Vector3.Zero));var there=scene.Pick(scene.Project("other/sides",Vector3.Zero));
        Check(here?.Subject.ToString()==subject.ToString() && there!=null && there.Subject.ToString()!=subject.ToString(),"a marker is picked through its see-through sides as its exact subject");
        Check(scene.Pick(scene.Project("subject/corners",new Vector3(.25f,.25f,.25f)))?.Subject.ToString()==subject.ToString(),"a marker corner resolves the same subject");
        Check(Shown(ours,0) && Shown(theirs,0),"marks start in their display look");
        built = scene.Rebuilt;
        scene.PointAt(here);Check(Shown(ours,1) && Shown(theirs,0),"pointing switches every mark of that one thing to its pointed-at look");
        scene.ShowSelected(here);Check(Shown(ours,2) && Shown(theirs,0),"the selected look wins while the same thing is pointed at");
        scene.PointAt(there);Check(Shown(ours,2) && Shown(theirs,1) && Shown(third,0),"pointing elsewhere leaves the selection shown and other things untouched");
        if(DisplayServer.GetName()!="headless") {
            using var raster=await Raster();
            Color Brightest(Vector2 at) { var best=Colors.Black;
                for(int x=(int)at.X-2;x<=(int)at.X+2;x++) for(int y=(int)at.Y-2;y<=(int)at.Y+2;y++)
                    if(x>=0 && y>=0 && x<raster.GetWidth() && y<raster.GetHeight() && raster.GetPixel(x,y).Luminance>best.Luminance) best=raster.GetPixel(x,y);
                return best; }
            var corner=Brightest(scene.Project("third/corners",new Vector3(-.25f,-.25f,.25f)));var middle=Brightest(scene.Project("third/corners",new Vector3(0,-.25f,.25f)));
            var gold=Brightest(scene.Project("other/corners",new Vector3(-.25f,-.25f,.25f)));
            Console.WriteLine($"M2_MARKER_RASTER corner={corner} middle={middle} pointed={gold}");
            Check(corner.Luminance>.5f && middle.Luminance<corner.Luminance/2,"actual marker raster draws each corner and leaves the middle of its edge empty");
            Check(gold.R>gold.B*2 && corner.B>corner.R*.9f,"actual marker raster shows the pointed-at thing in gold and its neighbour in gray-blue");
            if(System.Environment.GetEnvironmentVariable("M2_MARKER_CAPTURE") is string path) Check(raster.SavePng(path)==Error.Ok,"desktop marker raster retained");
        }
        scene.Apply(markers);Check(scene.Rebuilt==built && Shown(ours,2) && Shown(theirs,1),"an unchanged scene keeps its resources and its shown looks");
        scene.ShowSelected(null);scene.PointAt(null);Check(Shown(ours,0) && Shown(theirs,0) && Shown(third,0) && scene.Rebuilt==built,"looks return to display without rebuilding anything");
        // Another mode's model of one thing, as client_eidolon returns it: its own root group, then its parts.
        string Model(string entity,string extra) => "[" + Marker("selected","transform(900,900,900,0,0,0)",entity) + extra + "]";
        string sizeLine=",mark(<<\"selected/size\">>,<<\"group\">>,[],relative(<<\"selected\">>,transform(0,-250,0,0,0,0)),no_surface,label(<<\"10 m\">>,<<\"below\">>),depicts_nothing)";
        int count=scene.Count;var place=scene.WorldPose("subject");
        Check(scene.ShowMode(here!,Term.Parse(Model("artifact",""))) && scene.Count==count && scene.Rebuilt==built,"the display model shown again in place changes and rebuilds nothing");
        Check(scene.ShowMode(here,Term.Parse(Model("artifact",sizeLine))) && scene.Count==count+1 && scene.Rebuilt==built+1,"another mode adds only its own new part to that one thing");
        Check(scene.WorldPose("subject").IsEqualApprox(place) && scene.WorldPose("subject/size").Origin.IsEqualApprox(place.Origin+new Vector3(0,-.25f,0)),"the mode is drawn where the thing stands, not at the model's own pose");
        Check(scene.SceneRoot.FindChildren("*","Label3D",true,false).OfType<Label3D>().Count(l=>l.Text=="10 m")==2 && here.Pose!=null && here.Label=="Space","the thing keeps its selection and shows the mode's line");
        scene.ShowSelected(here);Check(Shown(ours,2) && Shown(theirs,0),"a thing drawn in another mode still shows its selected look");
        scene.Apply(markers);Check(scene.Count==count+1 && scene.Rebuilt==built+1,"an unchanged world view keeps the thing in its mode and rebuilds nothing");
        Check(!scene.ShowMode(here,Term.Parse(Model("neighbour",sizeLine))) && !scene.ShowMode(here,markers) && scene.Count==count+1,"a model of another thing, or of several, is not drawn in this thing's place");
        Check(scene.ShowMode(here,null) && scene.Count==count && Shown(ours,2) && scene.WorldPose("subject").IsEqualApprox(place),"withdrawing the mode returns the thing to display");
        scene.ShowSelected(null);
        if(DisplayServer.GetName()!="headless") await RainChecks(scene,Raster);
        var all = new List<Node>(); void Visit(Node node) { all.Add(node); foreach(var child in node.GetChildren()) Visit(child); }
        Visit(scene); Check(!all.Any(n => n is CollisionObject3D), "exterior adapter creates no collision bodies or walls");
        scene.Withdraw(); await Frame(); Check(scene.Count == 0 && scene.Pick(Vector2.Zero) == null, "withdrawal removes geometry and picking together");
        await File.WriteAllTextAsync(Env("M1B_RESULT"), System.Text.Json.JsonSerializer.Serialize(new { passed=true, checks }));
        Console.WriteLine("M2_SCENE_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }
}
