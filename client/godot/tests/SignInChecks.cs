using Godot;
using System.Reflection;

public partial class ExportChecks
{
    // The sign-in card as the headset shows it: the real workspace surface in
    // VR presentation, drawn by the engine over a striped scene so its glass
    // shows, and kept as images. No native input is needed.
    async Task SignInRender()
    {
        Check(DisplayServer.GetName()!="headless","the sign-in raster comes from the actual renderer");
        var gui=(SpatialGui)app.FindChild("shared-gui",true,false);
        var actual=(OpenXRInput)app.FindChild("openxr-input",true,false);
        string directory=Env("SIGNIN_IMAGES");System.IO.Directory.CreateDirectory(directory);
        actual.PresentWorkspace(true);await Frame();await Frame();
        var backdrop=(StyleBoxFlat)((PanelContainer)app.FindChild("login",true,false)).GetThemeStylebox("panel");
        Check(backdrop.BgColor.A==0,"in VR the sign-in card has no backing of its own: the panel's glass backs it");
        async Task Raster(string state) {
            await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            using var surface=gui.Surface.GetTexture().GetImage();surface.Convert(Image.Format.Rgba8);
            int w=surface.GetWidth(),h=surface.GetHeight();
            // A scene behind the panel: bright and dark bands, as a lit room would give.
            using var scene=Image.CreateEmpty(w,h,false,Image.Format.Rgba8);
            for(int y=0;y<h;y++)for(int x=0;x<w;x++)scene.SetPixel(x,y,(x/80+y/80)%2==0 ? new Color("#D9D4C7") : new Color("#3A4E5C"));
            scene.BlendRect(surface,new Rect2I(0,0,w,h),Vector2I.Zero);
            Check(scene.SavePng(System.IO.Path.Combine(directory,state+".png"))==Error.Ok,"actual sign-in "+state+" raster retained");
        }
        await Raster("welcome");
        var options=(Button)app.FindChild("connection-details",true,false);
        options.EmitSignal(BaseButton.SignalName.Pressed);await Frame();await Frame();
        await Raster("options");
        // A refusal while Options is open lands at the card's foot: it is brought into view.
        var status=(Label)app.FindChild("login-status",true,false);
        var field=typeof(Main).GetField("statusText",BindingFlags.Instance|BindingFlags.NonPublic)!;
        field.SetValue(app,"This server looks different from the one you used before. Your own key is safe. If you expected the rebuild, choose Trust this server.");
        typeof(Main).GetMethod("Notify",BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(app,null);
        for(int i=0;i<10;i++)await Frame();
        Check(status.IsVisibleInTree() && gui.Surface.GetVisibleRect().Encloses(status.GetGlobalRect()),"a new status sentence on a card taller than its panel is scrolled into view");
        await Raster("status");
        Console.WriteLine("SIGNIN_RENDER_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }
}
