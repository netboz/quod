using Godot;
using File=System.IO.File;

public partial class ExportChecks
{
    async Task WorkspaceAdapter()
    {
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        scene.Hide(); // Same layout visibility as XR; no runtime is initialized.
        gui.SetAnchorsAndOffsetsPreset(Control.LayoutPreset.TopLeft);
        var reports=new List<object>();
        foreach(var dimensions in new[]{new Vector2(1850,496),new Vector2(600,900)}) {
            gui.Size=dimensions;
            await Frame();await Frame();
            var target=(Button)app.FindChild("location-operations",true,false);
            var rectangle=target.GetGlobalRect();
            var scroll=target.GetParent().GetParent().GetParent() as ScrollContainer
                ??throw new Exception("Expected the existing Main scroll owner");
            var clip=new Rect2(Vector2.Zero,gui.Surface.Size).Intersection(scroll.GetGlobalRect());
            bool accessible=clip.Encloses(rectangle);
            reports.Add(new { pixels=new[]{gui.Surface.Size.X,gui.Surface.Size.Y},target=rectangle.ToString(),clip=clip.ToString(),accessible });
            await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new {
                reports,checks,coverage="actual offline Main/native Control layout; no sign-in, runtime or physical claim" }));
            Check(accessible,"the actual Current space operations control remains fully inside the shared workspace at "+dimensions);
        }
        await File.WriteAllTextAsync(Env("M1B_RESULT"),System.Text.Json.JsonSerializer.Serialize(new { passed=true,reports,checks }));
        Console.WriteLine("M4_WORKSPACE_OBSERVED");Console.Out.Flush();
        Console.WriteLine("M4_WORKSPACE_PASS");Console.Out.Flush();await app.CloseApplication();
    }
}
