using System.Numerics;
using System.Globalization;

namespace Quod.Client;

// The desktop adapter submits leased desired input through the existing signed
// control lane. It owns no body state, collision decisions or durable journal.
[System.Runtime.Versioning.SupportedOSPlatform("linux")]
public sealed class PhysicsInput(SignedSession session,Actor principal) : IDisposable
{
    WorldProjection? world;
    string? identity;
    ulong sequence;
    double[] desired=[0,0,0];
    double lease;
    bool busy,uncertain,disposed;
    CancellationTokenSource? cancellation;
    long incarnation,desiredVersion;
    public Task Completion { get; private set; }=Task.CompletedTask;
    public event Action<string>? Suspended;
    public void Present(WorldProjection projection)
    {
        string? next=projection.Controlled==null ? null : projection.Control+"\n"+projection.Sample!.Fence;
        if(next!=identity) { Withdraw(); identity=next; sequence=0; uncertain=false; lease=0; }
        world=projection;
        if(projection.Sample?.ControlState?["sequence"] is System.Text.Json.Nodes.JsonValue value && ulong.TryParse(value.GetValue<string>(),out ulong accepted))
            sequence=Math.Max(sequence,accepted);
    }
    public void Withdraw()
    { incarnation++; world=null; desired=[0,0,0]; desiredVersion++; cancellation?.Cancel(); busy=false; }
    public void Drive(double x,double y,double z)
    {
        if(!double.IsFinite(x+y+z)) throw new FormatException("Invalid input direction.");
        if(world?.Controlled?.Grounded==true) y=0;
        double length=Math.Max(1,Math.Sqrt(x*x+y*y+z*z)); desired=[x/length,y/length,z/length]; desiredVersion++; lease=0; Start();
    }
    public void Tick(double delta)
    { if(desired.Any(v=>v!=0)) { lease-=delta; if(lease<=0) Start(); } }
    void Start()
    {
        if(disposed || busy || uncertain || world?.Controlled is not ControlBinding binding) return;
        busy=true; var next=Send(binding); Completion=Completion.IsCompleted ? next : Task.WhenAll(Completion,next);
    }
    async Task Send(ControlBinding binding)
    {
        long expected=incarnation; string? selected=identity;
        try {
            while(!disposed && expected==incarnation && selected==identity) {
                long sent=desiredVersion;
                var sample=world!.Sample!; ulong current=checked(++sequence);
                string Number(double component)=>new BigInteger(Math.Truncate((double)binding.Speed*component)).ToString(CultureInfo.InvariantCulture);
                var velocity=Term.Call("vector",desired.Select(v=>Term.Number(Number(v))).ToArray());
                var input=Term.Call("drive",velocity,Term.Call("angular",Term.Number("0"),Term.Number("0"),Term.Number("0")));
                var frame=Term.Call("control_frame",sample.Frame,Term.Binary(Identity.Decode(sample.Registration)));
                var goal=Term.Call("physics_control_input",sample.Frame.Args[0].Args[2],frame,Term.Number(binding.Epoch.ToString(CultureInfo.InvariantCulture)),Term.Number(current.ToString(CultureInfo.InvariantCulture)),input,Term.Variable("Queued"));
                var target=Actor.FromTerm(sample.Frame.Args[1]);
                var signed=session.Sign(principal,SignedSession.ViewGoal(target,goal),3);
                cancellation?.Dispose(); cancellation=new(); var running=cancellation;
                lease=binding.Lease/2000.0;
                var reply=await session.SendAt("/api/goals/control",signed.Body,signed.Deadline,running.Token);
                if(!Json.Committed(reply)) throw new InvalidOperationException("Control was refused.");
                if(sent==desiredVersion) break;
            }
        } catch(Exception error) {
            if(!disposed && expected==incarnation && selected==identity) {
                uncertain=true; desired=[0,0,0]; Suspended?.Invoke(error.Message);
            }
        } finally { if(expected==incarnation) busy=false; }
    }
    public void Dispose()
    { if(disposed)return;disposed=true;Withdraw();cancellation?.Dispose();Suspended=null; }
}
