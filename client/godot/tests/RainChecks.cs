using Godot;
using Quod.Client;

// Rain as the real renderer draws it: a box raining a known text.
public partial class ExportChecks
{
    async Task RainChecks(ScenePanel scene,Func<Task<Image>> raster)
    {
        const string text="rain(X) :- falls(X), glows(X).";
        string Rain(string id,string pose,int w,int h,int d,int glyph) =>
            $"mark(<<\"{id}\">>,<<\"box\">>,[f(<<\"width\">>,{w}),f(<<\"height\">>,{h}),f(<<\"depth\">>,{d})],{pose},surface(<<\"#3CFF7A\">>,0,1000,1000,1000,[texture(<<\"rain\">>,text(<<\"{text}\">>),glyph({glyph}))]),unlabelled,depicts_nothing)";
        ShaderMaterial Material() => (ShaderMaterial)scene.SceneRoot.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>().Single(m=>m.MaterialOverride is ShaderMaterial).MaterialOverride;
        async Task<Image> At(float time) { Material().SetShaderParameter("held_time",time); return await raster(); }
        static float Light(Color c) => Math.Max(c.R,Math.Max(c.G,c.B));
        scene.Apply(Term.Parse("[" + Rain("rain","transform(0,0,0,20,30,0)",2000,2000,2000,100) + "]")); await Frame(); await Frame();
        var material=Material();
        Check(material.Shader.ResourcePath=="res://rain.gdshader" && material.GetShaderParameter("cell_count").AsInt32()==RainCells.Of(text).Cells.Length,
            "a box raining a text draws with the rain shader and every letter of that text");
        using var first=await At(100f);using var same=await At(100f);using var later=await At(101.5f);
        Check(first.GetData().SequenceEqual(same.GetData()),"the same moment draws the same rain");
        Check(!first.GetData().SequenceEqual(later.GetData()),"another moment draws other rain");
        if(System.Environment.GetEnvironmentVariable("M2_RAIN_CAPTURE") is string outside) Check(first.SavePng(outside.Replace(".png","-outside.png"))==Error.Ok,"desktop rain box raster retained");
        int lit=0,white=0,wrongHue=0;
        for(int y=0;y<first.GetHeight();y++)for(int x=0;x<first.GetWidth();x++){
            var c=first.GetPixel(x,y);
            if(c.G>.3f)lit++;
            if(c.G>.85f&&c.R>.7f&&c.B>.7f)white++;
            if(Light(c)>.02f&&(c.G<c.R||c.G<c.B))wrongHue++;
        }
        // The ground of the face: a patch at its centre is mostly exactly black.
        var front=scene.Project("rain",new Vector3(0,0,1));int ground=0,patch=0;
        for(int x=(int)front.X-30;x<=(int)front.X+30;x++)for(int y=(int)front.Y-30;y<=(int)front.Y+30;y++){patch++;if(Light(first.GetPixel(x,y))==0)ground++;}
        Console.WriteLine($"M2_RAIN_RASTER lit={lit} white={white} wrong_hue={wrongHue} ground={ground}/{patch}");
        Check(ground*2>patch,"the ground between letters is exactly black, never grey");
        Check(lit>0 && wrongHue==0,"lit letters are green");
        Check(white>0,"the light's leading letters are almost white");
        // Seen from above and from below, the top and bottom faces stay black.
        var camera=(Camera3D)scene.Viewport.FindChild("scene-camera",false,false);bool dark=true;var framed=camera.GlobalTransform;
        foreach(float side in new[]{1f,-1f}){
            var face=scene.WorldPose("rain")*new Vector3(0,side,0);var normal=(scene.WorldPose("rain").Basis*Vector3.Up*side).Normalized();
            camera.LookAtFromPosition(face+normal*3,face,Mathf.Abs(normal.Z)<.9f ? Vector3.Back : Vector3.Up);
            using var seen=await At(100f);var centre=scene.Project("rain",new Vector3(0,side,0));
            for(int x=(int)centre.X-6;x<=(int)centre.X+6;x++)for(int y=(int)centre.Y-6;y<=(int)centre.Y+6;y++)dark&=Light(seen.GetPixel(x,y))==0;
        }
        camera.GlobalTransform=framed;
        Check(dark,"a face looking up or down shows no rain");
        // The engine's TIME wraps; the rain shows no jump there.
        float rollover=ProjectSettings.GetSetting("rendering/limits/time/time_rollover_secs").AsSingle();
        static double Difference(Image a,Image b){var x=a.GetData();var y=b.GetData();double sum=0;for(int i=0;i<x.Length;i++)sum+=Math.Abs(x[i]-y[i]);return sum/x.Length;}
        using var beforeWrap=await At(rollover-.02f);using var afterWrap=await At(.02f);using var ordinaryBefore=await At(500-.02f);using var ordinaryAfter=await At(500.02f);
        double wrap=Difference(beforeWrap,afterWrap),ordinary=Difference(ordinaryBefore,ordinaryAfter);
        Console.WriteLine($"M2_RAIN_WRAP wrap={wrap:F4} ordinary={ordinary:F4}");
        Check(wrap<=ordinary*3+.05,"the rain is continuous across the wrap of the engine's time");
        // Far away: cells of two pixels melt into streaks, never speckle.
        int rows=Math.Max(1,(int)(first.GetHeight()*.4f));
        scene.Apply(Term.Parse("[" + Rain("rain","transform(0,0,0,0,0,0)",2000,2000,2000,Math.Max(1,2000/rows)) + "]")); await Frame(); await Frame();
        using var far=await At(100f);int speckles=0;
        if(System.Environment.GetEnvironmentVariable("M2_RAIN_CAPTURE") is string distant) Check(far.SavePng(distant.Replace(".png","-far.png"))==Error.Ok,"desktop far rain raster retained");
        // Inside the front face, four pixels clear of its edges.
        var low=scene.Project("rain",new Vector3(-1,1,1));var high=scene.Project("rain",new Vector3(1,-1,1));
        for(int y=(int)low.Y+4;y<(int)high.Y-4;y++)for(int x=(int)low.X+4;x<(int)high.X-4;x++){
            // A column is a streak: a letter breaking up shows as a green dot
            // brighter than the column above and below it. The near-white
            // leading cell is the light itself.
            var pixel=far.GetPixel(x,y);float here=Light(pixel),around=Math.Max(Light(far.GetPixel(x,y-1)),Light(far.GetPixel(x,y+1)));
            if(pixel.R<pixel.G*.5f&&here>around+.15f)speckles++;
        }
        Console.WriteLine($"M2_RAIN_FAR rows={rows} face=({low})-({high}) speckles={speckles}");
        Check(speckles==0,"far letters melt into streaks with no dot along a column");
        // The Matrix walls as the space sends them, seen from inside a room.
        string extent="mark(<<\"room/extent\">>,<<\"corner_box\">>,[f(<<\"width\">>,4000),f(<<\"height\">>,3000),f(<<\"depth\">>,5000)],transform(0,0,0,0,0,0),"+
            "surfaces(surface(<<\"#3CFF7A\">>,0,700,1000,1000,[]),surface(<<\"#F9C80E\">>,0,700,1000,1000,[]),surface(<<\"#F9C80E\">>,0,700,1000,1000,[])),unlabelled,depicts_nothing)";
        scene.Apply(Term.Parse("[" + Rain("room/walls","transform(0,0,0,0,0,0)",4000,3000,5000,100) + "," + extent + "]")); await Frame(); await Frame();
        camera.GlobalTransform=new Transform3D(Basis.Identity,new Vector3(0,.1f,1.5f));
        using var inside=await At(100f);
        int litInside=0;for(int y=0;y<inside.GetHeight();y++)for(int x=0;x<inside.GetWidth();x++)if(inside.GetPixel(x,y).G>.3f)litInside++;
        Check(litInside>0,"from inside a room the walls rain");
        if(System.Environment.GetEnvironmentVariable("M2_RAIN_CAPTURE") is string path) Check(inside.SavePng(path)==Error.Ok,"desktop Matrix walls raster retained");
        Material().SetShaderParameter("held_time",-1f);
    }
}
