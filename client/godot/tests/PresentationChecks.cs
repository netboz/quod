using Godot;
using Quod.Client;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task PresentationAdapter()
    {
        Check(DisplayServer.GetName()!="headless","presentation evidence uses a real renderer");
        var reports=new List<object>();var failures=new List<string>();
        void Probe(bool value,string name) {
            reports.Add(new { name,passed=value });
            Console.WriteLine((value ? "PASS " : "FAIL ")+name);Console.Out.Flush();
            if(!value)failures.Add(name);
        }
        var bytes=await File.ReadAllBytesAsync(Env("M4_MODEL"));
        var mapping=ControllerMapping.Decode(Term.Parse(await File.ReadAllTextAsync(Env("M4_MAPPING"))))!;
        using var models=new RenderModels((asset,cancellation)=>Task.FromResult(bytes));
        using var lease=models.Acquire(mapping.Profiles.Single().Model);
        var model=await lease.Instantiate()??throw new Exception("Admitted controller model unavailable");
        var scene=new ScenePanel { Size=new(640,480) };app.AddChild(scene);
        scene.Viewport.RenderTargetUpdateMode=SubViewport.UpdateMode.Always;
        scene.SceneRoot.AddChild(model);await Frame();
        var meshes=model.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>().ToArray();
        var materials=meshes.SelectMany(m=>Enumerable.Range(0,m.Mesh.GetSurfaceCount()).Select(m.GetActiveMaterial)).Cast<BaseMaterial3D>().ToArray();
        var identities=materials.Select(m=>(m.GetInstanceId(),m.ShadingMode,m.AlbedoColor,m.AlbedoTexture?.GetInstanceId())).ToArray();
        Probe(materials.Length>0 && materials.All(m=>m.ShadingMode!=BaseMaterial3D.ShadingModeEnum.Unshaded),"actual admitted GLB retains its shaded materials and textures");
        var points=meshes.SelectMany(m=>Enumerable.Range(0,8).Select(i=>m.GlobalTransform*m.GetAabb().GetEndpoint(i))).ToArray();
        var min=points.Aggregate((a,b)=>a.Min(b));var max=points.Aggregate((a,b)=>a.Max(b));var centre=(min+max)/2;
        var camera=scene.Viewport.GetCamera3D();camera.Position=centre+Vector3.Back*(max-min).Length()*2;camera.LookAt(centre);
        var environment=scene.Viewport.FindWorld3D().Environment;
        var original=(environment.AmbientLightSource,environment.AmbientLightColor,environment.AmbientLightEnergy);
        var directory=Env("M4_PRESENTATION_IMAGES");System.IO.Directory.CreateDirectory(directory);
        async Task<(int Lit,float Peak,bool BlackBackground)> Raster(string name) {
            await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            using var image=scene.Viewport.GetTexture().GetImage();int lit=0;float peak=0;
            for(int y=0;y<image.GetHeight();y++)for(int x=0;x<image.GetWidth();x++) {
                var pixel=image.GetPixel(x,y);float value=Math.Max(pixel.R,Math.Max(pixel.G,pixel.B));peak=Math.Max(peak,value);if(value>.02f)lit++;
            }
            bool black=new[]{Vector2I.Zero,new Vector2I(image.GetWidth()-1,image.GetHeight()-1)}.All(p=>image.GetPixelv(p).R<.01f && image.GetPixelv(p).G<.01f && image.GetPixelv(p).B<.01f);
            Check(image.SavePng(System.IO.Path.Combine(directory,name+".png"))==Error.Ok,"actual "+name+" raster retained");
            reports.Add(new { raster=name,width=image.GetWidth(),height=image.GetHeight(),lit,peak,black });return(lit,peak,black);
        }
        var initial=await Raster("original");string resources=System.Text.Json.JsonSerializer.Serialize(models.Metrics);
        environment.AmbientLightSource=Godot.Environment.AmbientSource.Disabled;
        var dark=await Raster("ambient-disabled");
        environment.AmbientLightSource=Godot.Environment.AmbientSource.Color;environment.AmbientLightColor=Colors.White;environment.AmbientLightEnergy=1;
        var illuminated=await Raster("ambient-white");
        environment.AmbientLightSource=original.Item1;environment.AmbientLightColor=original.Item2;environment.AmbientLightEnergy=original.Item3;
        var restored=await Raster("restored");
        Probe(initial.Lit>100,"ordinary scene illumination reveals the actual shaded controller");
        Probe(illuminated.Lit>100 && illuminated.Peak>.1f && dark.Lit==0,"renderer counterfactual isolates missing illumination without changing the model");
        Probe(initial.BlackBackground && illuminated.BlackBackground && restored.Lit==initial.Lit,"illumination preserves black background and exact restored raster coverage");
        Probe(identities.SequenceEqual(materials.Select(m=>(m.GetInstanceId(),m.ShadingMode,m.AlbedoColor,m.AlbedoTexture?.GetInstanceId()))) && resources==System.Text.Json.JsonSerializer.Serialize(models.Metrics),"lighting changes retain actual material texture nodes and model work counters");
        models.ReleaseInstance(model);lease.Dispose();await models.Completion;
        Probe(models.LiveLeases==0 && models.LiveTemplates==0,"rendered model retires through its existing owner");
        scene.GetParent().RemoveChild(scene);scene.Free();
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var actualScene=(ScenePanel)app.FindChild("space-scene",true,false);
        var adapter=new OpenXRInput();actualScene.Viewport.AddChild(adapter);
        adapter.Configure(actualScene,gui,models,()=>null,()=>false,()=>[]);adapter.AttachSources();
        gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);
        foreach(var dimensions in new[]{new Vector2(1850,496),new Vector2(800,800),new Vector2(600,900)}) {
            gui.Size=dimensions;await Frame();
            var size=((QuadMesh)adapter.GuiSurface.Mesh).Size;var pixels=gui.Surface.Size;
            reports.Add(new { pixels=new[]{pixels.X,pixels.Y},metres=new[]{size.X,size.Y},aspectFactor=size.X/size.Y/((float)pixels.X/pixels.Y) });
            Probe(Math.Abs(size.X/size.Y-(float)pixels.X/pixels.Y)<.0001f,"actual GUI resize preserves equal horizontal and vertical pixel scale "+pixels);
        }
        adapter.StopSession();Probe(adapter.Subscriptions==0,"panel resize subscription retires with its actual consumer");adapter.GetParent().RemoveChild(adapter);adapter.Free();
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { passed=failures.Count==0,reports,failures,checks,coverage="real renderer and native GUI resize; no physical readability or gesture claim" }));
        Console.WriteLine("M4_PRESENTATION_OBSERVED");Console.Out.Flush();
        if(failures.Count!=0)throw new Exception("Presentation failures: "+string.Join("; ",failures));
        Console.WriteLine("M4_PRESENTATION_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
