using System.Globalization;
using System.Numerics;
using System.Text.Json.Nodes;

namespace Quod.Client;

public sealed record Navigation(BigInteger Revision, Term Location, Term Modes, Term Dependencies)
{
    public Actor? Space => Location.Name == "placed" ? Actor.FromTerm(Location.Args[0]) : null;
    public static Navigation Decode(JsonNode projection)
    {
        var value = Term.Parse(Json.S(projection,"value")); value.Ground();
        var args = value.Require("navigation",3); var revision = args[0].Integer;
        if (revision<0) throw new FormatException("Invalid assignment revision.");
        if (!args[2].Items.Any(t => t.Kind == "atom" && t.Name == "playing")) throw new FormatException("Playing view is not offered.");
        if (args[1].Kind != "atom" || args[1].Name != "unplaced") {
            var placed = args[1].Require("placed",2); _ = Actor.FromTerm(placed[0]);
            if (ScenePose.Decode(placed[1]).Transform == null) throw new FormatException("Invalid committed location pose.");
        }
        var dependencies = Term.Parse(Json.S(projection,"dependencies")); dependencies.Ground();
        foreach (var row in dependencies.Items) {
            var d = row.Require("dependency",3);
            if (d[0].TextValue.Length == 0 || d[1].Kind != "binary" || d[1].Bytes.Length != 32 || d[2].Integer < 0)
                throw new FormatException("Invalid navigation dependency.");
        }
        return new(revision,args[1],args[2],dependencies);
    }
}

public sealed record BodySample(ulong Id, ulong Revision, double[] Position, double[] Rotation);
public sealed record PhysicsSample(string Fence, string Registration, ulong Tick, ulong OriginSequence,
    BigInteger[] Origin, Dictionary<(ulong,ulong),BodySample> Bodies, JsonNode? ControlState,Term Frame)
{
    static ulong Unsigned(JsonNode value,string key)
    {
        string text = Json.S(value,key);
        ulong number = ulong.Parse(text,CultureInfo.InvariantCulture);
        if (number.ToString(CultureInfo.InvariantCulture) != text) throw new FormatException("Noncanonical " + key);
        return number;
    }
    static double[] Vector(JsonNode? value,int count)
    {
        var numbers = value?.AsArray().Select(x => x!.GetValue<double>()).ToArray() ?? throw new FormatException("Missing physical vector.");
        if (numbers.Length != count || numbers.Any(x => !double.IsFinite(x))) throw new FormatException("Invalid physical vector.");
        return numbers;
    }
    public static PhysicsSample Decode(JsonNode value)
    {
        if (value["schema"]?.GetValue<int>() != 2 || Json.S(value,"units") != "metres_seconds" || Json.S(value,"space") != "local")
            throw new FormatException("Unsupported physics frame.");
        var world = Term.Parse(Json.S(value,"world")).Require("world_ref",3);
        if (world[0].TextValue.Length == 0 || world[1].Kind != "binary" || world[1].Bytes.Length != 32) throw new FormatException("Invalid physical world.");
        _ = Actor.FromTerm(Term.Parse(Json.S(value,"authority")));
        string token = Json.S(value,"incarnation"), registration = Json.S(value,"registration");
        if (Identity.Decode(token).Length != 32 || Identity.Decode(registration).Length != 32) throw new FormatException("Invalid physical incarnation.");
        ulong epoch = Unsigned(value,"epoch"), generation = Unsigned(value,"generation"), structure = Unsigned(value,"structure");
        if (epoch == 0 || structure == 0) throw new FormatException("Invalid physical fence.");
        string fence = string.Join("\n",Json.S(value,"world"),Json.S(value,"authority"),epoch,generation,token,structure);
        var origin = value["origin_mm"]?.AsArray().Select(x => {
            string text = x!.GetValue<string>(); var n = BigInteger.Parse(text,CultureInfo.InvariantCulture);
            if (n.ToString(CultureInfo.InvariantCulture) != text) throw new FormatException("Noncanonical origin."); return n;
        }).ToArray() ?? throw new FormatException("Missing origin.");
        if (origin.Length != 3) throw new FormatException("Invalid physical origin.");
        var bodies = new Dictionary<(ulong,ulong),BodySample>();
        foreach (var row in value["poses"]!.AsArray()) {
            ulong id = Unsigned(row!,"body"), revision = Unsigned(row!,"revision");
            var rotation = Vector(row!["rotation"],4); double norm = rotation.Sum(x => x*x);
            if (revision == 0 || revision > structure || Math.Abs(norm-1) > 1e-6 || bodies.Keys.Any(k => k.Item1 == id))
                throw new FormatException("Invalid or duplicate physical body.");
            bodies.Add((id,revision),new(id,revision,Vector(row["position"],3),rotation));
        }
        var frame = Term.Call("physics_frame",Term.Parse(Json.S(value,"world")),Term.Parse(Json.S(value,"authority")),
            Term.Number(epoch.ToString()),Term.Number(generation.ToString()),Term.Binary(Identity.Decode(token)),Term.Number(structure.ToString()));
        return new(fence,registration,Unsigned(value,"tick"),Unsigned(value,"origin_seq"),origin,bodies,value["control_state"]?.DeepClone(),frame);
    }
}

public sealed record ControlBinding(ulong Epoch,ulong Body,ulong Revision,BigInteger Speed,ulong Lease,bool Grounded,Term Viewpoint,
    BigInteger? Snap=null,BigInteger? TeleportReach=null)
{
    public static ControlBinding? Decode(Term control,Actor? principal,PhysicsSample sample)
    {
        if (control.Kind=="atom" && control.Name=="none") return null;
        var c=control.Require("control",3);
        if (principal==null || Actor.FromTerm(c[0])!=principal) throw new FormatException("Control belongs to another principal.");
        ulong epoch=checked((ulong)c[1].Integer); var agent=c[2].Require("controlled_agent",6);
        ulong id=checked((ulong)agent[2].Integer), revision=checked((ulong)agent[3].Integer);
        if (epoch==0 || !sample.Bodies.ContainsKey((id,revision))) throw new FormatException("Controlled body unavailable.");
        var motion=agent[4].Require("motion",6); var view=agent[5].Require("viewpoint",3);
        if(view[2].Kind!="atom" || view[2].Name!="view_only") throw new FormatException("Unsupported desktop tracking mapping.");
        BigInteger speed=motion[1].Integer; ulong lease=checked((ulong)motion[3].Integer);
        if (speed<=0 || lease==0 || (motion[0].Name!="free" && motion[0].Name!="grounded")) throw new FormatException("Unsupported desktop motion profile.");
        var capabilities=new Dictionary<string,Term>();
        foreach(var capability in motion[5].Items) {
            if(!capabilities.TryAdd(capability.Name,capability)) throw new FormatException("Duplicate movement ability.");
            switch(capability.Name) {
                case "snap": case "jump": if(capability.Require(capability.Name,1)[0].Integer<=0) throw new FormatException("Invalid movement ability."); break;
                case "teleport": var t=capability.Require("teleport",3); if(t[0].Integer<=0 || t[1].Integer<0 || t[2].Integer<1 || t[2].Integer>1000) throw new FormatException("Invalid teleport ability."); break;
                case "reposition": if(capability.Kind!="atom") throw new FormatException("Invalid reposition ability."); break;
                default: throw new FormatException("Unsupported movement ability.");
            }
        }
        BigInteger? Ability(string name)=>capabilities.TryGetValue(name,out var term) ? term.Args[0].Integer : null;
        return new(epoch,id,revision,speed,lease,motion[0].Name=="grounded",view[1],Ability("snap"),Ability("teleport"));
    }
}

// One presentation contract for authored, absolute-body and source-frame poses.
// It retains exact authored values; only the engine adapter converts coordinates.
public sealed class WorldProjection
{
    public SceneMark[] Marks { get; }
    public ScenePose[] ViewFrames { get; }
    public Dictionary<(ulong,ulong),ScenePose[]> BodyFrames { get; } = [];
    public PhysicsSample? Sample { get; private set; }
    public Term Control { get; }
    public ControlBinding? Controlled { get; }
    public string View { get; }
    public string Selection { get; }
    public WorldProjection(JsonNode message,Actor space,Actor? principal=null)
    {
        View = Json.S(message,"view"); Selection = Json.S(message,"selection");
        Marks = SceneMark.Decode(Term.Parse(Json.S(message,"marks")));
        Control = Term.Atom("none"); ViewFrames = [];
        if (Selection == "nonphysical") {
            if (Marks.Any(m => m.Pose.Body != null)) throw new FormatException("Body poses require an active authoritative frame.");
            return;
        }
        if (Selection != "active") throw new FormatException("Space unavailable: " + Selection);
        Control = Term.Parse(Json.S(message,"control")); Control.Ground();
        var view = Term.Parse(Json.S(message,"view_frame")).Require("view_frame",3);
        if (Actor.FromTerm(view[0]) != space) throw new FormatException("Physical view names another interior.");
        ViewFrames = Chain(view[1]);
        foreach (var row in view[2].Items) {
            var body = row.Require("body_frame",4); ulong id = checked((ulong)body[0].Integer), revision = checked((ulong)body[1].Integer);
            if (revision == 0 || body[2].TextValue.Length == 0 || !BodyFrames.TryAdd((id,revision),Chain(body[3])))
                throw new FormatException("Invalid or duplicate source frame.");
        }
        Sample = PhysicsSample.Decode(message["frame"]!); ValidateBodies(Sample);
        Controlled=ControlBinding.Decode(Control,principal,Sample);
    }
    static ScenePose[] Chain(Term chain) => chain.Items.Select(t => {
        var pose = ScenePose.Decode(t);
        if (pose.Transform == null) throw new FormatException("Source frame must be authored."); return pose;
    }).ToArray();
    void ValidateBodies(PhysicsSample sample)
    {
        foreach (var mark in Marks.Where(m => m.Pose.Body != null)) {
            var key = (mark.Pose.Body!.Value,mark.Pose.Revision);
            if (!sample.Bodies.ContainsKey(key) || (mark.Pose.Reframed && !BodyFrames.ContainsKey(key)))
                throw new FormatException("Authoritative body or source frame unavailable.");
        }
    }
    public bool Advance(JsonNode message)
    {
        if (Json.S(message,"view") != View || Sample == null) return false;
        var next = PhysicsSample.Decode(message["frame"]!);
        if (next.Fence != Sample.Fence || next.Registration != Sample.Registration) return false;
        if (next.Tick < Sample.Tick || next.OriginSequence < Sample.OriginSequence) return false;
        if(next.OriginSequence==Sample.OriginSequence && !next.Origin.SequenceEqual(Sample.Origin))
            throw new FormatException("Physical origin changed without advancing its sequence.");
        ValidateBodies(next);
        if (next.Tick==Sample.Tick && next.OriginSequence==Sample.OriginSequence) {
            if (next.Bodies.Count!=Sample.Bodies.Count || next.Bodies.Any(pair => !Sample.Bodies.TryGetValue(pair.Key,out var old) ||
                !pair.Value.Position.SequenceEqual(old.Position) || !pair.Value.Rotation.SequenceEqual(old.Rotation)) || !next.Origin.SequenceEqual(Sample.Origin))
                throw new FormatException("A physical cursor changed without advancing.");
            if (next.ControlState?.ToJsonString()==Sample.ControlState?.ToJsonString()) return false;
        }
        Sample = next; return true;
    }
    public JsonObject Acknowledgement() => new() { ["type"]="ack",["view"]=View,
        ["tick"]=Sample!.Tick.ToString(CultureInfo.InvariantCulture),["origin_seq"]=Sample.OriginSequence.ToString(CultureInfo.InvariantCulture) };
}
