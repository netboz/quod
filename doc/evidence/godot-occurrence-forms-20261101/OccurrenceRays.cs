using Godot;
using Quod.Client;

public partial class ExportChecks
{
    async Task OccurrenceRays(OpenXRInput adapter,ScenePanel scene,XRControllerTracker source,Action advance)
    {
        string anchor=Term.Binary(new byte[32]).ToString();
        string Box(string id,int x)=>$"mark(<<\"{id}\">>,<<\"box\">>,[f(<<\"width\">>,400),f(<<\"height\">>,400),f(<<\"depth\">>,400)],transform({x},0,0,0,0,0),surface(<<\"#6A90D9\">>,0,700,0,[]),unlabelled,depicts(<<\"occurrence-ray-fixture\">>,{anchor},instrument))";
        var subject=Term.Parse($"entity_ref(<<\"occurrence-ray-fixture\">>,{anchor},instrument)");
        Term Marks(int x){var terms=Term.Parse("["+Box("a",x)+","+Box("b",700)+"]");foreach(var mark in terms.Items)mark.Args[6].Args[2]=subject;return terms;}
        scene.Apply(Marks(-700));await Frame();await Frame();
        bool shown=adapter.GuiSurface.Visible;adapter.GuiSurface.Visible=false;
        var origin=(Node3D)adapter.FindChild("xr-origin",true,false);
        void Aim(string id){advance();var pose=new Transform3D(Basis.Identity,scene.WorldPose(id).Origin+Vector3.Back*2);source.SetPose("aim",origin.GlobalTransform.AffineInverse()*pose,Vector3.Zero,Vector3.Zero,XRPose.TrackingConfidenceEnum.High);advance();}
        void Held(bool value){source.SetInput("trigger_press",value);advance();}
        int choices=0;ScenePanel.Selection? last=null;void Selected(ScenePanel.Selection s){choices++;last=s;}
        scene.Selected+=Selected;
        try {
            Held(false);Aim("a");Held(true);Aim("b");Held(false);
            Check(choices==0,"real mapped ray press on A and release on B of the same exact subject selects neither occurrence");
            Aim("a");Held(true);Held(false);
            Check(choices==1&&last?.Id=="a","neutral followed by one same-occurrence ray gesture selects exactly its initiating occurrence");
            var selected=last!;Aim("a");Held(true);scene.Apply(Marks(-900));await Frame();await Frame();Aim("a");Held(false);
            Check(choices==1&&selected.Pose!=null,"moving hit geometry cancels its initiating ray gesture while retaining the independent selected form binding");
            Aim("a");Held(true);scene.Suspend();Held(false);
            Check(choices==1,"a withdrawn scene cannot deliver the held ray's release");
        } finally {scene.Selected-=Selected;scene.Withdraw();adapter.GuiSurface.Visible=shown;Held(false);}
    }
}
