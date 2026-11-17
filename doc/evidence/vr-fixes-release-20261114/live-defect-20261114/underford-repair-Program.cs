// One signed repair in Yan's own ontology (his approval, 2026-11-14): Underford
// keeps its place, exterior and interior; its stored turn -20 becomes 340.
// Reads first and prints the exact goal; sends only with --send.
using Quod.Client;
using System.Text.Json.Nodes;

string profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local/share/godot/app_userdata/Quod/identity");
const string Id = "01M7DYSG86T013SRC9330BQVV3";
using var store = new LocalStore(profile);
var snapshot = store.Snapshot ?? throw new Exception("no local identity");
using var key = Identity.FromPayload(snapshot.Payload);
using var session = new SignedSession(key, store, new Transport(snapshot.Endpoint, snapshot.NodeKey(snapshot.Endpoint)));
using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(60));
await session.Authenticate(cancel.Token);
var human = store.Snapshot!.Accounts[session.Network].Human;
Console.WriteLine($"network={session.Network} human={human.Namespace}");
var read = await session.Read(human,
    $"attribute(<<\"{Id}\">>,name,Name),attribute(<<\"{Id}\">>,exterior,Style),attribute(<<\"{Id}\">>,transform,Pose),findall(I,attribute(<<\"{Id}\">>,interior,I),Interiors).",
    cancel.Token);
Term Name = Json.Binding(read, "Name"), Style = Json.Binding(read, "Style"), Pose = Json.Binding(read, "Pose"), Interiors = Json.Binding(read, "Interiors");
Console.WriteLine($"stored: name={Name} exterior={Style} pose={Pose} interiors={Interiors}");
var p = Pose.Require("transform", 6).Select(t => t.Integer).ToArray();
if (Name.ToString() != "<<\"Underford\">>" || p[4] != -20 || p[3] != 0 || p[5] != 0) throw new Exception("stored state is not the one to repair; nothing sent");
string interior = Interiors.ToString() == "[]" ? "none" : Interiors.ToString().Trim('[', ']');
string after = $"transform({p[0]},{p[1]},{p[2]},0,340,0)";
string space = Term.Call("entity_ref", Term.Text(human.Namespace), Term.Binary(Identity.Decode(human.Anchor)), Term.Text(Id)).ToString();
string goal = $"<<\"quod:space\">>::space_represent({space},{Style},{Pose},{interior},{Style},{after},{interior}).";
Console.WriteLine("goal: " + goal);
if (!args.Contains("--send")) { Console.WriteLine("dry run: nothing sent"); return; }
var reply = await session.Execute(human, goal, "repair", cancel.Token);
Console.WriteLine("reply: " + reply.ToJsonString());
if (!Json.Terminal(reply)) {
    var work = store.Snapshot!.Pending.Single(w => w.Flow == "repair");
    reply = await session.Resolve(work, cancel.Token);
    Console.WriteLine("resolved: " + reply.ToJsonString());
    if (Json.Terminal(reply)) session.Finish(work, reply);
}
Console.WriteLine(Json.Committed(reply) ? "COMMITTED" : "NOT COMMITTED");
