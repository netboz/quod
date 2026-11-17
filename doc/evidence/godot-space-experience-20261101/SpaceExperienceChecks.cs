using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;

// Removable observation of ordinary account entry. No subject choice or scroll
// is delivered before the first landing raster and clipping measurements.
public partial class ExportChecks
{
    async Task SpaceExperience()
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        GetTree().Root.Size=new(1200,800);await Frame();await Frame();
        await Press("create-key");await Press("connect");await Press("register");
        await Press("prepare");await Press("setup");
        await Until(()=>State["world_accepted"]?.GetValue<bool>()==true&&!Busy);
        await Frame();await Frame();
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        var pane=app.FindChild("representations",true,false) as EidolonPanel;
        Rect2 Clip(Control c){var r=new Rect2(Vector2.Zero,gui.Surface.Size);for(Node? n=c.GetParent();n!=null;n=n.GetParent())if(n is Control p&&p.ClipContents)r=r.Intersection(p.GetGlobalRect());return r;}
        float[] Box(Rect2 r)=>[r.Position.X,r.Position.Y,r.Size.X,r.Size.Y];
        var clipping=Clip(scene);var rect=scene.GetGlobalRect();
        var observed=new { state=State, scene=Box(rect), clip=Box(clipping), visible=Box(rect.Intersection(clipping)),
            selected=pane?.Current?.Exact.ToString(), inspectorVisible=pane?.IsVisibleInTree(),
            noDiagnosticSelectionOrScroll=true, controls=app.FindChildren("*","Button",true,false).OfType<Button>()
                .Where(b=>b.IsVisibleInTree()).Select(b=>new {name=b.Name.ToString(),b.Text,disabled=b.Disabled,rect=Box(b.GetGlobalRect()),clip=Box(Clip(b))}).ToArray() };
        await File.WriteAllTextAsync("/work/landing.json",JsonSerializer.Serialize(observed));
        await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
        using(var image=gui.Surface.GetTexture().GetImage())Check(image.SavePng("/work/landing.png")==Error.Ok,"ordinary first landing raster retained before selection or scrolling");
        Check(State["current_location"]!=null&&scene.Count>=0,"ordinary signed setup installs current navigation and world");
        Check(scene.IsVisibleInTree()&&clipping.Encloses(rect)&&rect.Size.Y>=300,
            "ordinary first landing exposes the usable current-world region without destination scrolling");
        Check(pane==null||!pane.IsVisibleInTree(),"ordinary landing does not select account tools on the user's behalf");
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new {passed=true,checks}));
        Console.WriteLine("SPACE_EXPERIENCE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
