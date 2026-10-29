using Godot;
using Quod.Client;
using System.Text.Json;
using System.Text.Json.Nodes;
using File=System.IO.File;
using Json=Quod.Client.Json;
using Matrix=System.Numerics.Matrix4x4;
using Vec=System.Numerics.Vector3;

public partial class ExportChecks
{
    PhysicsInput? testedInput;
    public override void _Process(double delta)=>testedInput?.Tick(delta);
    async Task PhysicsJourney()
    {
        var metadata=JsonNode.Parse(await File.ReadAllTextAsync(Env("M3_PHYSICS_META")))!;
        var human=Actor.FromTerm(Term.Parse(Json.S(metadata,"viewer")));
        var outer=Actor.FromTerm(Term.Parse(Json.S(metadata,"s0")));var leaf=Term.Parse(Json.S(metadata,"leaf"));
        using var identity=Identity.FromPayload(await File.ReadAllTextAsync(Env("M3_PHYSICS_KEY")));
        using var store=new LocalStore(profile+"-physical-viewer");store.Create(identity.Payload());
        using var session=new SignedSession(identity,store,new Transport(Env("M3_NODE"),Env("M3_CA")));
        using var deadline=new CancellationTokenSource(TimeSpan.FromMinutes(5));await session.Authenticate(deadline.Token);
        var scene=(ScenePanel)app.FindChild("space-scene",true,false);
        using var input=new PhysicsInput(session,human);testedInput=input;
        void Drive(Vector3 direction,Vector3 _) => input.Drive(direction.X,direction.Y,direction.Z);
        scene.Drive+=Drive;
        Actor selected=outer;WorldProjection? current=null;string? failure=null;int withdrawn=0,frames=0;
        var changed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Notice(){var old=changed;changed=new(TaskCreationOptions.RunContinuationsAsynchronously);old.TrySetResult();}
        async Task Wait(Func<bool> condition)
        { while(!condition()) { if(failure!=null)throw new Exception(failure);await changed.Task.WaitAsync(deadline.Token); } }
        using var view=new SignedView(session,human,outer,"world","") {
            BeforeOpen=_=>Task.FromResult<(Actor Target,string Goal)?>((selected,SignedSession.ViewGoal(selected,Term.Call("client_world_view",Term.Parse(selected.InstanceText.TrimEnd('.')),Term.Atom("playing"),Term.List(),Term.Variable("View"))))) };
        async Task Credit(WorldProjection projection) { try{await view.Send(projection.Acknowledgement());}catch(Exception error){failure=error.Message;Notice();} }
        view.Projection+=message=> {
            try {var next=new WorldProjection(message,selected,human);scene.Apply(next);current=next;input.Present(next);_=Credit(next);}
            catch(Exception error){scene.Withdraw();input.Withdraw();current=null;if(Json.S(message,"selection")=="active")failure=error.Message;}
            Notice();
        };
        view.Message+=message=> {
            if(Json.S(message,"type")!="simulation_frame" || current==null)return;
            try{if(current.Advance(message)){scene.ApplyFrame();input.Present(current);frames++;_=Credit(current);}}
            catch(Exception error){failure=error.Message;scene.Withdraw();input.Withdraw();current=null;}Notice();
        };
        view.Withdrawn+=_=>{withdrawn++;current=null;scene.Withdraw();input.Withdraw();Notice();};
        input.Suspended+=reason=>{failure="Actual signed control suspended: "+reason;Notice();};
        _=view.Start();await Wait(()=>current?.Sample!=null);
        Check(scene.SubjectIds(leaf).Length==3 && current!.Sample!.Bodies.Count==2,"real shared-domain view streams one leaf and one explicitly controlled body for three independent appearances");
        var independentSpace=Actor.FromTerm(Term.Parse(Json.S(metadata,"independent")));WorldProjection? other=null;
        using var independentView=new SignedView(session,human,independentSpace,"world",SignedSession.ViewGoal(independentSpace,
            Term.Call("client_world_view",Term.Parse(independentSpace.InstanceText.TrimEnd('.')),Term.Atom("playing"),Term.List(),Term.Variable("View"))));
        independentView.Projection+=message=>{try{other=new(message,independentSpace,human);_=independentView.Send(other.Acknowledgement());}catch(Exception error){failure=error.Message;}Notice();};
        independentView.Withdrawn+=_=>{other=null;Notice();};
        _=independentView.Start();await Wait(()=>other?.Sample!=null);
        string independentFence=other!.Sample!.Fence;
        Check(other.Selection=="active" && other.Marks.Length==0,"independent configured world has its own authorized active client view and intentionally empty contents");
        var receipts=new List<JsonNode>();
        void Agreement()
        {
            var world=current!;var sample=world.Sample!;
            var key=world.Marks.Where(m=>m.Subject?.ToString()==leaf.ToString() && m.Pose.Body!=null)
                .Select(m=>(m.Pose.Body!.Value,m.Pose.Revision)).Distinct().Single();
            var source=world.BodyFrames.GetValueOrDefault(key,[]);
            var body=sample.Bodies[key];var p=body.Position;var origin=sample.Origin;
            var point=new Vec((float)((double)origin[0]/1000+p[0]),(float)((double)origin[1]/1000+p[1]),(float)((double)origin[2]/1000+p[2]));
            Matrix Chain(ScenePose[] chain) {
                var result=Matrix.Identity;
                foreach(var frame in chain) {
                    var t=frame.Transform!;
                    var local=Matrix.CreateRotationX((float)t[3]*MathF.PI/180)*Matrix.CreateRotationY((float)t[4]*MathF.PI/180)*Matrix.CreateRotationZ((float)t[5]*MathF.PI/180)*Matrix.CreateTranslation((float)t[0]/1000,(float)t[1]/1000,(float)t[2]/1000);
                    result=local*result;
                }return result;
            }
            Matrix.Invert(Chain(world.ViewFrames),out var inverse);
            var expected=Vec.Transform(point,inverse);
            var q=body.Rotation;var orientation=Matrix.CreateFromQuaternion(System.Numerics.Quaternion.Normalize(new((float)q[0],(float)q[1],(float)q[2],(float)q[3])))*inverse;
            var axes=new[]{Vec.TransformNormal(Vec.UnitX,orientation),Vec.TransformNormal(Vec.UnitY,orientation),Vec.TransformNormal(Vec.UnitZ,orientation)};
            var poses=scene.SubjectIds(leaf).Select(scene.WorldPose).ToArray();
            Check(poses.Any(p=>p.Origin.DistanceTo(new(expected.X,expected.Y,expected.Z))<.0001f &&
                new[]{p.Basis.X,p.Basis.Y,p.Basis.Z}.Zip(axes,(actual,axis)=>actual.DistanceTo(new(axis.X,axis.Y,axis.Z))<.0001f).All(v=>v)),"actual rendered position and orientation agree with the native sample through the selected nonidentity interior frame");
            receipts.Add(JsonSerializer.SerializeToNode(new {view=selected.Entity.ToString(),tick=sample.Tick,body=key.ToString(),native_position=body.Position,native_rotation_xyzw=q,origin_mm=origin.Select(x=>x.ToString()).ToArray(),rendered_poses=poses.Select(p=>new[]{p.Origin,p.Basis.X,p.Basis.Y,p.Basis.Z}.Select(v=>new[]{v.X,v.Y,v.Z}).ToArray()).ToArray(),source_chain=source.Select(v=>v.Transform!.Select(x=>x.ToString()).ToArray()).ToArray()})!);
        }
        Agreement();
        selected=Actor.FromTerm(Term.Parse(Json.S(metadata,"s1")));await view.Reopen();await Wait(()=>current!=null);Agreement();
        selected=Actor.FromTerm(Term.Parse(Json.S(metadata,"s2")));await view.Reopen();await Wait(()=>current!=null);Agreement();
        selected=outer;await view.Reopen();await Wait(()=>current!=null);
        Check(current!.Controlled!=null && scene.Controlled,"exact signed viewer owns the selected streamed control binding");
        int rebuilt=scene.Rebuilt;string registration=current.Sample!.Registration,fence=current.Sample.Fence;
        using(var probe=new System.Net.Sockets.TcpClient()) {
            await probe.ConnectAsync("127.0.0.1",int.Parse(Env("M1B_CONTROL_PORT")),deadline.Token);
            using var stream=probe.GetStream();using var reader=new StreamReader(stream);
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("{\"measure\":true}\n"),deadline.Token);
            Check(JsonNode.Parse((await reader.ReadLineAsync(deadline.Token))!)!["ready"]!.GetValue<bool>(),"physical owner work observation precedes unchanged client renewals");
            for(int i=0;i<3;i++) {
                var received=new TaskCompletionSource();void Projected(JsonNode _)=>received.TrySetResult();view.Projection+=Projected;
                try { await view.Renew();await received.Task.WaitAsync(deadline.Token); }
                finally { view.Projection-=Projected; }
            }
            await stream.WriteAsync(System.Text.Encoding.UTF8.GetBytes("finish\n"),deadline.Token);
            var work=JsonNode.Parse((await reader.ReadLineAsync(deadline.Token))!)!;receipts.Add(work);
            work["engine_rebuilt_before"]=rebuilt;work["engine_rebuilt_after"]=scene.Rebuilt;
            work["registration_retained"]=current.Sample!.Registration==registration;
            await File.WriteAllTextAsync(Env("M1B_RESULT")+".renewals.json",work.ToJsonString());
            Check(work["work"]!["calls"]!.AsArray().Count==0,"unchanged live physical renewals have zero watched history/install/write/sync work");
            Check(scene.Rebuilt==rebuilt,"unchanged live physical renewals retain engine resources");
            Check(current.Sample!.Fence==fence,"unchanged live physical renewals preserve the world run structure and native incarnation while renewing delivery custody");
        }
        ulong sequence=ulong.TryParse(current.Sample!.ControlState?["sequence"]?.GetValue<string>(),out var prior)?prior:0;
        input.Drive(1,0,0);input.Drive(0,0,0);await input.Completion;
        await Wait(()=>ulong.TryParse(current?.Sample?.ControlState?["sequence"]?.GetValue<string>(),out var accepted) && accepted>=sequence+2);
        Check(true,"a desired stop received during an in-flight drive is admitted next through the same signed serial lane");
        // Exercise the production input adapter through an actual OS key event.
        for(Node? parent=scene.GetParent();parent!=null;parent=parent.GetParent())if(parent is ScrollContainer scroll)scroll.EnsureControlVisible(scene);
        scene.GrabFocus();await Frame();Check(scene.HasFocus(),"desktop physics scene holds keyboard focus");var before=current!.Sample!.Bodies[(2,1)].Position.ToArray();
        Console.WriteLine("M2_NATIVE_KEY hold-w");Console.Out.Flush();
        await Wait(()=>current?.Sample?.Bodies.TryGetValue((2,1),out var body)==true && body.Position.Zip(before,(a,b)=>(a-b)*(a-b)).Sum()>.0025);
        Console.WriteLine("M2_NATIVE_KEY release-w");Console.Out.Flush();await Frame();scene.ReleaseInput();await input.Completion;
        Check(frames>0,"native desktop key input advances the server-controlled body through actual streamed frames");
        var baseline=await SpaceControl(new(){["sample"]=true});receipts.Add(baseline);
        var independent=baseline["independent"]!.ToJsonString();
        int oldWithdrawn=withdrawn;
        await SpaceControl(new(){["mutate"]="source"});await Wait(()=>withdrawn>oldWithdrawn && current?.Sample?.Bodies.Keys.Any(k=>k.Item1==4 && k.Item2==3)==true);
        Check(scene.FindChildren("*","MeshInstance3D",true,false).OfType<MeshInstance3D>().Count(m=>m.Mesh is SphereMesh)==3,"real source geometry change updates every independent appearance through the retained view");Agreement();
        oldWithdrawn=withdrawn;await SpaceControl(new(){["mutate"]="frame_update"});await Wait(()=>withdrawn>oldWithdrawn && current?.Sample?.Bodies.Keys.Any(k=>k.Item1==4 && k.Item2==4)==true);Agreement();
        await Wait(()=>current?.Sample?.Bodies.TryGetValue((4,4),out var falling)==true && falling.Position[1]+(double)current.Sample.Origin[1]/1000<=.601);
        var contact=await SpaceControl(new(){["sample"]=true});receipts.Add(contact);
        Check(contact["sample"]!["contacts"]!.AsArray().Any(row=>new[]{row![0]!.GetValue<int>(),row[2]!.GetValue<int>()}.Order().SequenceEqual(new[]{1,4})),"a real nested body traverses its source frame and contacts the root-domain floor while client poses track that same native world");
        Check(contact["independent"]!.ToJsonString()==independent,"source and frame changes preserve the independent world's native identity and work");
        foreach(string fault in new[]{"revoke","frame_fail"}) {
            oldWithdrawn=withdrawn;await SpaceControl(new(){["mutate"]=fault});await Wait(()=>withdrawn>oldWithdrawn && current==null);
            Check(scene.Count==0 && !scene.Controlled,"unavailable source withdraws affected presentation picking and control");
            await Wait(()=>other?.Sample!=null);
            Check(other!.Sample!.Fence==independentFence && other.Selection=="active","source failure preserves the independent authorized client view and its exact native world");
            string repair=fault=="revoke" ? "restore" : "frame_repair";
            var repaired=await SpaceControl(new(){["mutate"]=repair});await Wait(()=>current!=null);Agreement();receipts.Add(repaired);
            Check(repaired["independent"]!.ToJsonString()==independent,"genuine committed repair preserves independent native identity and work");
        }
        string oldFence=current!.Sample!.Fence;
        await SpaceControl(new(){["restart"]=true});await Wait(()=>current!=null && current.Sample!.Fence!=oldFence);Agreement();
        if(DisplayServer.GetName()!="headless") {
            await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);await ToSignal(RenderingServer.Singleton,RenderingServer.SignalName.FramePostDraw);
            using var raster=scene.GetChildren().OfType<SubViewport>().Single().GetTexture().GetImage();
            bool visible=false;for(int x=0;x<raster.GetWidth();x+=4)for(int y=0;y<raster.GetHeight();y+=4)visible|=raster.GetPixel(x,y).B>.2f;
            Check(visible,"actual desktop raster contains the authoritative shared-domain geometry");
            Check(raster.SavePng(Env("M3_SCENE_CAPTURE"))==Error.Ok,"GPU raster of real shared-domain native body appearances retained");
        }
        await File.WriteAllTextAsync(Env("M1B_RESULT"),JsonSerializer.Serialize(new{passed=true,checks,receipts,frames,withdrawn}));
        scene.Drive-=Drive;input.Dispose();testedInput=null;view.Dispose();independentView.Dispose();await Task.WhenAll(view.Completion!,independentView.Completion!);await input.Completion;scene.Withdraw();
        Console.WriteLine("M3_PHYSICS_PASS");Console.Out.Flush();GetTree().Quit();
    }
}
