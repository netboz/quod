using System.Numerics;
using System.Globalization;

namespace Quod.Client;

// Input adapters submit leased desired input through the existing signed
// control lane. It owns no body state, collision decisions or durable journal.
[System.Runtime.Versioning.SupportedOSPlatform("linux")]
public sealed class PhysicsInput(SignedSession session,Actor principal) : IDisposable
{
    WorldProjection? world;
    string? identity;
    ulong sequence;
    ulong? discreteSequence;
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
        if(next!=identity) { Withdraw(); identity=next; sequence=0; uncertain=false; discreteSequence=null; lease=0; }
        world=projection;
        if(projection.Sample?.ControlState?["sequence"] is System.Text.Json.Nodes.JsonValue value && ulong.TryParse(value.GetValue<string>(),out ulong accepted))
        {
            sequence=Math.Max(sequence,accepted);
            if(discreteSequence is ulong pending && accepted>=pending && projection.Sample.ControlState?["pending"]?.GetValue<bool>()==false)discreteSequence=null;
        }
    }
    public void Withdraw()
    { incarnation++; world=null; desired=[0,0,0]; desiredVersion++; cancellation?.Cancel(); busy=false; }
    public void Drive(double x,double y,double z)
    {
        if(!double.IsFinite(x+y+z)) throw new FormatException("Invalid input direction.");
        if(world?.Controlled?.Grounded==true) y=0;
        double length=Math.Max(1,Math.Sqrt(x*x+y*y+z*z)); double[] next=[x/length,y/length,z/length];
        if(desired.SequenceEqual(next))return;
        desired=next; desiredVersion++; lease=0; Start();
    }
    public bool Snap(int direction)=>world?.Controlled?.Snap is BigInteger angle && direction!=0 && Discrete(Term.Call("snap",Term.Number((angle*Math.Sign(direction)).ToString(CultureInfo.InvariantCulture))));
    public bool Teleport(double x,double z,double fraction)
    {
        if(world?.Controlled is not { Grounded:true,TeleportReach:BigInteger reach } binding || !double.IsFinite(x+z+fraction) || fraction<=0 || fraction>=1)return false;
        double length=Math.Sqrt(x*x+z*z);if(length<=0)return false;
        var sample=world.Sample!;var body=sample.Bodies[(binding.Body,binding.Revision)];
        double[] position=[body.Position[0]+x/length*(double)reach/1000*fraction,body.Position[1],body.Position[2]+z/length*(double)reach/1000*fraction];
        if(position.Any(p=>!double.IsFinite(p)))throw new FormatException("Invalid teleport coordinates.");
        return Discrete(Term.Call("teleport",Term.Call("vector",position.Select((p,i)=>Term.Number((sample.Origin[i]+new BigInteger(Math.Truncate(p*1000))).ToString(CultureInfo.InvariantCulture))).ToArray())));
    }
    bool Discrete(Term input)
    {
        if(disposed || busy || uncertain || discreteSequence!=null || world?.Controlled is not ControlBinding binding)return false;
        desired=[0,0,0];desiredVersion++;busy=true;var next=Send(binding,input);Completion=Completion.IsCompleted ? next : Task.WhenAll(Completion,next);return true;
    }
    public void Tick(double delta)
    { if(desired.Any(v=>v!=0)) { lease-=delta; if(lease<=0) Start(); } }
    void Start()
    {
        if(disposed || busy || uncertain || discreteSequence!=null || world?.Controlled is not ControlBinding binding) return;
        busy=true; var next=Send(binding); Completion=Completion.IsCompleted ? next : Task.WhenAll(Completion,next);
    }
    async Task Send(ControlBinding binding,Term? discrete=null)
    {
        long expected=incarnation; string? selected=identity;
        try {
            while(!disposed && expected==incarnation && selected==identity) {
                long sent=desiredVersion;
                var sample=world!.Sample!; ulong current=checked(++sequence);
                string Number(double component)=>new BigInteger(Math.Truncate((double)binding.Speed*component)).ToString(CultureInfo.InvariantCulture);
                var velocity=Term.Call("vector",desired.Select(v=>Term.Number(Number(v))).ToArray());
                var input=discrete??Term.Call("drive",velocity,Term.Call("angular",Term.Number("0"),Term.Number("0"),Term.Number("0")));
                if(discrete!=null)discreteSequence=current;
                var frame=Term.Call("control_frame",sample.Frame,Term.Binary(Identity.Decode(sample.Registration)));
                var goal=Term.Call("physics_control_input",sample.Frame.Args[0].Args[2],frame,Term.Number(binding.Epoch.ToString(CultureInfo.InvariantCulture)),Term.Number(current.ToString(CultureInfo.InvariantCulture)),input,Term.Variable("Queued"));
                var target=Actor.FromTerm(sample.Frame.Args[1]);
                var signed=session.Sign(principal,SignedSession.ViewGoal(target,goal),3);
                cancellation?.Dispose(); cancellation=new(); var running=cancellation;
                lease=binding.Lease/2000.0;
                var reply=await session.SendAt("/api/goals/control",signed.Body,signed.Deadline,running.Token);
                if(reply["result"]?.ToString()=="fail") { discreteSequence=null;Suspended?.Invoke("Control was refused.");break; }
                if(!Json.Committed(reply)) throw new InvalidOperationException("Control outcome unavailable.");
                if(discrete!=null || sent==desiredVersion) break;
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
