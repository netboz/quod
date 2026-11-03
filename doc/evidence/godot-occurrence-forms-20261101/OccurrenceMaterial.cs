using Godot;
using Quod.Client;
using System.Text.Json;
using File=System.IO.File;

public partial class ExportChecks
{
    IEnumerable<Node> AlignmentNodes(Node n)
    { foreach(var c in n.GetChildren()){yield return c;foreach(var d in AlignmentNodes(c))yield return d;} }
    async Task AlignmentRaster(string path,SubViewport viewport)
    { await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=viewport.GetTexture().GetImage();Check(image.SavePng("/work/"+path+".png")==Error.Ok,"retained actual "+path+" raster"); }
    async Task AlignmentMaterial()
    {
        var scene=new ScenePanel {Position=new(0,0),Size=new(1200,740)};app.AddChild(scene);
        var descriptor=Term.Parse("[mark(<<\"solid\">>,<<\"box\">>,[f(<<\"width\">>,1000),f(<<\"height\">>,1000),f(<<\"depth\">>,1000)],transform(0,0,0,20,35,0),surface(<<\"#6A90D9\">>,0,700,0,[]),label(<<\"Solid shape\">>,<<\"above\">>),depicts_nothing)]");
        scene.Apply(descriptor);await Frame();await Frame();await AlignmentRaster("solid-oblique",scene.Viewport);
        using var image=scene.Viewport.GetTexture().GetImage();
        var points=new[]{new Vector3(-.5f,0,0),new Vector3(0,.5f,0),new Vector3(0,0,.5f)};
        var samples=points.Select(p=>{var at=(Vector2I)scene.Project("solid",p);return image.GetPixel(at.X,at.Y);}).ToArray();
        float L(Color c)=>(c.R+c.G+c.B)/3;
        await File.WriteAllTextAsync("/work/material.json",JsonSerializer.Serialize(new {samples=samples.Select(c=>c.ToHtml()).ToArray(),faceDifference=samples.Max(L)-samples.Min(L)}));
        Check(samples.Max(L)-samples.Min(L)>10f/255,"oblique solid faces have measurable directional shading rather than identical unshaded colour");
        if(Env("M1B_PHASE")=="alignment-material-full") {
            MeshInstance3D Mesh()=>AlignmentNodes(scene.SceneRoot).OfType<MeshInstance3D>().Single();
            var mesh=Mesh();var material=(StandardMaterial3D)mesh.MaterialOverride;int rebuilt=scene.Rebuilt;
            for(int i=0;i<3;i++)scene.Apply(descriptor);
            Check(scene.Rebuilt==rebuilt&&ReferenceEquals(mesh,Mesh())&&ReferenceEquals(material,Mesh().MaterialOverride),"three unchanged scene renewals retain mesh and material resources");
            var green=Term.Parse(descriptor.ToString().Replace("#6A90D9","#60C880"));scene.Apply(green);await Frame();await Frame();await AlignmentRaster("green-oblique",scene.Viewport);
            Check(scene.Rebuilt==rebuilt+1&&((StandardMaterial3D)Mesh().MaterialOverride).AlbedoColor.IsEqualApprox(new Color("#60C880")),"a real authored colour update changes only its existing occurrence");
            string materialTerm=green.ToString().Replace(",0,700,0,[])",",650,250,800,[])");var authored=Term.Parse(materialTerm);scene.Apply(authored);await Frame();await Frame();
            var decoded=SceneMark.Decode(authored).Single();material=(StandardMaterial3D)Mesh().MaterialOverride;
            Check(decoded.Metallic==650&&decoded.Roughness==250&&decoded.Emission==800&&Mathf.IsEqualApprox(material.Metallic,.65f)&&Mathf.IsEqualApprox(material.Roughness,.25f)&&material.EmissionEnabled&&Mathf.IsEqualApprox(material.EmissionEnergyMultiplier,.8f)&&material.AlbedoColor.A==1,"existing metallic roughness emission permille reach native material and never become alpha");
            await AlignmentRaster("emissive-solid",scene.Viewport);
            var wire=Term.Parse(descriptor.ToString().Replace("box","wire_box"));scene.Apply(wire);await Frame();await Frame();await AlignmentRaster("wire-label",scene.Viewport);
            var surface=RenderingServer.MeshGetSurface(Mesh().Mesh.GetRid(),0);material=(StandardMaterial3D)Mesh().MaterialOverride;
            Check(surface["primitive"].AsInt32()==(int)RenderingServer.PrimitiveType.Lines&&surface["vertex_count"].AsInt32()==24&&material.ShadingMode==BaseMaterial3D.ShadingModeEnum.Unshaded,"wire box remains twelve unshaded edges with no solid faces");
            Check(AlignmentNodes(scene.SceneRoot).OfType<Label3D>().Single() is {Shaded:false,Modulate.A:1},"authored billboard label stays opaque and unshaded");
            var sphere=Term.Parse("[mark(<<\"sphere\">>,<<\"sphere\">>,[f(<<\"diameter\">>,1000)],transform(0,0,0,0,0,0),surface(<<\"#D89060\">>,0,700,0,[]),unlabelled,depicts_nothing)]");
            scene.Apply(sphere);await Frame();await Frame();await AlignmentRaster("solid-sphere",scene.Viewport);
            Check(((StandardMaterial3D)Mesh().MaterialOverride).ShadingMode==BaseMaterial3D.ShadingModeEnum.PerPixel,"ordinary sphere shares the same lit solid adapter");
            foreach(string bad in new[]{descriptor.ToString().Replace(",0,700,0,[])",",1001,700,0,[])"),descriptor.ToString().Replace(",0,700,0,[])",",0,700,-1,[])")}) {
                bool refused=false;try{scene.Apply(Term.Parse(bad));}catch(FormatException){refused=true;}
                Check(refused&&scene.Ids.SequenceEqual(new[]{"sphere"}),"invalid material is refused before replacing accepted geometry");
            }
            scene.Withdraw();Check(scene.Count==0&&scene.PickRay(new(0,0,5),Vector3.Forward)==null,"retirement withdraws geometry and picking together");
        }
        scene.QueueFree();
    }
    async Task OccurrenceMaterial()
    {
        await AlignmentMaterial();
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks}));
        Console.WriteLine("OCCURRENCE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
