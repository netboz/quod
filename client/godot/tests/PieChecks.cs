using Godot;
using Quod.Client;

public partial class ExportChecks
{
    // The pie as the headset shows it: the real control on a surface of the
    // VR pie's own size and text size, drawn by the engine and kept as images.
    // Pointed by position, as a ray or cursor does; no native input is needed.
    async Task PieRender()
    {
        Check(DisplayServer.GetName()!="headless","the pie raster comes from the actual renderer");
        static MenuNode Wedge(int slot,string label,string icon,bool enabled=true,bool confirm=false,MenuNode[]? children=null,int back=0)=>
            new(Term.Atom("render_"+icon),label,enabled ? "" : "Not allowed here.",enabled,slot,8,back,
                children==null ? new MenuTarget(Term.Atom("render"),Term.Atom(icon)) : null,confirm,children??[],"res://assets/icons/"+icon+".png");
        var authored=new MenuNode(Term.Atom("render"),"Workshop","",true,0,8,0,null,false,[Wedge(1,"Enter space","enter"),
            Wedge(2,"Show as","show_as",children:[Wedge(1,"Wire","wireframe"),Wedge(3,"Matrix","matrix"),Wedge(4,"Default","default")],back:6),
            Wedge(3,"Inspect","inspect"),Wedge(4,"Create a space with exact lengths","create_exact",enabled:false),
            Wedge(5,"Leave space","leave",confirm:true),Wedge(7,"Me","me"),
            new(Term.Atom("render_plain"),"Add to my commands","",true,8,8,0,new MenuTarget(Term.Atom("render"),Term.Atom("plain")),false,[])]);
        string directory=Env("PIE_IMAGES");System.IO.Directory.CreateDirectory(directory);
        async Task Render(string name,Vector2I pixels,float radius,int text,bool transparent)
        {
            var surface=new SubViewport {Size=pixels,TransparentBg=transparent,Disable3D=true,HandleInputLocally=true,RenderTargetUpdateMode=SubViewport.UpdateMode.Always};
            app.AddChild(surface);
            if(!transparent)surface.AddChild(new ColorRect {Color=new("#0B3954"),Size=pixels});
            var pie=new PieMenu {Theme=new Theme {DefaultFontSize=text},Icons=node=>node.Image is string image ? GD.Load<Texture2D>(image) : null};
            surface.AddChild(pie);await Frame();
            var middle=(Vector2)pixels/2;float margin=radius*1.08f;
            Vector2 On(Vector2 from,int slot){var toward=MenuNode.Toward(slot,8);return from+new Vector2(toward.X,toward.Y)*radius*.74f;}
            async Task Raster(string state) {
                await Frame();await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);using var image=surface.GetTexture().GetImage();
                Check(image.SavePng(System.IO.Path.Combine(directory,name+"-"+state+".png"))==Error.Ok,"actual "+name+" "+state+" raster retained");
            }
            pie.Open(middle,radius,"Reading Workshop…");await Raster("reading");
            pie.Present(authored,"");pie.PointerAt(middle);await Raster("icons");
            Check(pie.Title=="Workshop" && pie.Note=="","with nothing pointed the hub names the menu");
            pie.PointerAt(On(middle,1));Check(pie.Title=="Enter space","a pointed wedge is named in the hub");await Raster("pointed");
            pie.PointerAt(On(middle,8));Check(pie.Title=="Add to my commands","a wedge without an authored icon is still named");await Raster("initials");
            pie.PointerAt(On(middle,4));Check(pie.Note=="Not allowed here.","an unavailable wedge shows its reason");await Raster("unavailable");
            Check(pie.CommitAt(On(middle,5))==PieOutcome.Open && pie.Note=="Press again","a click on a wedge that asks a second press arms it");await Raster("press-again");
            Check(pie.CommitAt(On(middle,2))==PieOutcome.Open && pie.Navigator!.Level.Label=="Show as","a click on a sub-pie's wedge opens it");
            var nested=On(middle,2).Clamp(new Vector2(margin,margin),(Vector2)pixels-new Vector2(margin,margin));
            pie.PointerAt(On(nested,3));Check(pie.Title=="Matrix","the sub-pie's wedges are pointed from its own centre");await Raster("nested");
            pie.PointerAt(On(nested,6));Check(pie.Title=="Back" && pie.Note=="Workshop","the back wedge names where it returns");await Raster("back");
            Check(pie.CommitAt(nested+new Vector2(0,radius*1.03f))==PieOutcome.Cancelled && !pie.IsOpen,"a click just past the drawn edge cancels the pie");
            surface.QueueFree();
        }
        // The headset's pie surface, radius and text size; then the desktop pie in a 1200×800 window.
        await Render("vr",new(800,800),300,26,true);
        await Render("desktop",new(1200,800),176,20,false);
        Console.WriteLine("PIE_RENDER_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }
}
