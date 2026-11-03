using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace Quod.Client;

[System.Runtime.Versioning.SupportedOSPlatform("linux")]
public sealed class Accounts(SignedSession session, LocalStore store)
{
    public Actor? Human => store.Snapshot!.Accounts.GetValueOrDefault(session.Network)?.Human;
    public Term? Setup => store.Snapshot!.Accounts.GetValueOrDefault(session.Network)?.Setup is string setup ? Term.Parse(setup) : null;
    public List<Actor> Catalogue { get; private set; } = [];
    public string StorageDescription { get; private set; } = "";
    public async Task Discover(CancellationToken cancellation)
    {
        var catalogue = await session.Transport.Send("/api/ontologies/system", null, cancellation);
        if (Json.S(catalogue, "network_id") != session.Network) throw new FormatException("Catalogue belongs to another network.");
        Catalogue = catalogue["ontologies"]!.AsArray().Select(row => new Actor(Json.S(row, "namespace"), Json.S(row, "anchor"), "me.")).ToList();
        if (Catalogue.Select(x => (x.Namespace, x.Anchor)).Distinct().Count() != Catalogue.Count) throw new FormatException("Duplicate catalogue identity.");
        await Resolve(cancellation);
        if (Human == null && !Pending().Any()) {
            var service = Catalogue.Single(x => x.Namespace == "quod:user");
            var applicant = service with { InstanceText = Term.Call("signup", Term.Binary(session.Key.PublicKey)) + "." };
            var allocation = await session.Read(applicant, "signup_status(Token,Account).", cancellation);
            if (Json.Committed(allocation)) {
                var original = Actor.FromTerm(Json.Binding(allocation, "Account"));
                store.Update(s => s.Accounts[session.Network] = new(original));
            } else if (allocation["result"]?.ToString() != "fail") throw new InvalidOperationException("Original account allocation is unavailable.");
        }
        if (Human is Actor human) {
            var result = Json.Binding(await session.Read(human, "account_setup_state(State).", cancellation), "State");
            if (result.Name == "account") RememberSetup(human, result);
            else if (result.Name != "pending") throw new FormatException("Unknown account setup state.");
        }
    }
    public async Task Register(CancellationToken cancellation)
    {
        if (!store.Snapshot!.CreatedLocally) throw new InvalidOperationException("This imported key has no verified account reference. Recover its original reference; registration cannot replace a failed lookup.");
        if (Human != null || Pending().Any()) throw new InvalidOperationException("Resolve the existing account operation first.");
        var service = Catalogue.Single(x => x.Namespace == "quod:user");
        var applicant = service with { InstanceText = Term.Call("signup", Term.Binary(session.Key.PublicKey)) + "." };
        var token = RandomNumberGenerator.GetBytes(32);
        var goal = Term.Call("signup", Term.Binary(token), Term.Text("human:" + Identity.Encode(token)), Term.Variable("Account")) + ".";
        var reply = await session.Execute(applicant, goal, "signup", cancellation);
        Apply(reply, Pending().Single(x => x.Flow == "signup"));
    }
    public bool CanRegister => store.Snapshot!.CreatedLocally && Human == null && !Uncertain;
    public async Task Prepare(CancellationToken cancellation)
    {
        if (Pending().Any()) throw new InvalidOperationException("Original work is unresolved; check its outcome.");
        var human = Human ?? throw new InvalidOperationException("No account reference is saved.");
        var preparation = Json.Binding(await session.Read(human, "account_setup_preparation(Preparation).", cancellation), "Preparation");
        if (preparation.Name == "complete") { RememberSetup(human, preparation.Require("complete", 1)[0]); return; }
        var args = preparation.Require("prepared", 3);
        if (args[0].ToString() != human.Ontology.ToString()) throw new FormatException("Setup selected unexpected account storage.");
        StorageDescription = $"Account policy selected the existing account ontology {human.Namespace}, genesis {human.Anchor}, for S0. This selection applies to initial setup.";
        Prepared = preparation;
    }
    public Term? Prepared { get; private set; }
    public async Task FinishSetup(CancellationToken cancellation)
    {
        if (Pending().Any()) throw new InvalidOperationException("Original work is unresolved.");
        var human = Human ?? throw new InvalidOperationException("No account.");
        var args = (Prepared ?? throw new InvalidOperationException("Prepare account storage first.")).Require("prepared", 3);
        var goal = Term.Call("setup_account", args[0], args[1], args[2], Term.Variable("Setup")) + ".";
        var reply = await session.Execute(human, goal, "setup", cancellation);
        Apply(reply, Pending().Single(x => x.Flow == "setup")); Prepared = null;
    }
    public IEnumerable<SignedWork> Pending() => store.Snapshot!.Pending.Where(w => w.Network == session.Network);
    void Apply(JsonNode reply, SignedWork work)
    {
        if (!Json.Terminal(reply)) return;
        if (Json.Committed(reply)) {
            if (work.Flow == "signup") {
                var human = Actor.FromTerm(Json.Binding(reply, "Account"));
                store.Update(s => { s.Accounts[session.Network] = new(human); s.Pending.RemoveAll(x => x.Id == work.Id); }); return;
            }
            if (work.Flow == "setup") {
                RememberSetup(work.Actor, Json.Binding(reply, "Setup"), work.Id); return;
            }
        }
        if (work.Flow is "signup" or "setup" && reply["aggregate"]?.ToString() == "mixed")
            throw new InvalidOperationException("Original account operation has mixed terminal effects. Its exact outcome is retained; do not replace or resubmit it: " + reply.ToJsonString());
        session.Finish(work,reply);
    }
    public void RememberSetup(Actor human, Term setup, string? originalId = null)
    {
        var args = setup.Require("account", 6); var owner = Actor.FromTerm(args[0]); var agent = Actor.FromTerm(args[1]); var space = Actor.FromTerm(args[2]);
        if (owner != human || agent.Namespace != human.Namespace || agent.Anchor != human.Anchor || agent == human ||
            space.Namespace != human.Namespace || space.Anchor != human.Anchor || args[3].ToString() != human.Ontology.ToString() ||
            args[4].Kind != "binary" || args[4].Bytes.Length != 32 || args[4].Bytes.SequenceEqual(session.Key.PublicKey))
            throw new FormatException("Account identity, storage or key mismatch.");
        setup.Ground();
        var previous = store.Snapshot!.Accounts.GetValueOrDefault(session.Network);
        if (previous?.Setup != null && previous.Setup != setup.ToString()) throw new FormatException("Original setup references changed.");
        store.Update(s => { s.Accounts[session.Network] = new(human, setup.ToString()); if (originalId != null) s.Pending.RemoveAll(w => w.Id == originalId); });
        Prepared = null; StorageDescription = "";
    }
    public List<JsonNode> Outcomes { get; } = [];
    public async Task Resolve(CancellationToken cancellation)
    {
        foreach (var work in Pending().ToArray()) {
            var reply = await session.Resolve(work, cancellation); Outcomes.Add(reply.DeepClone()); Apply(reply, work);
        }
        if (Human is not Actor human) return;
        // Authoritative instruction associations survive loss of this device's journal.
        var rows = Json.Binding(await session.Read(human, "personal_instructions(Instructions).", cancellation), "Instructions").Items;
        foreach (var row in rows) {
            string id = Identity.Encode(row.Require("instruction", 3)[0].Bytes);
            if (terminalInstructions.Contains(id)) continue;
            var reply = await session.ResolveInstruction(human, id, cancellation); Outcomes.Add(reply.DeepClone());
            if (Json.Terminal(reply)) terminalInstructions.Add(id); else unknownInstructions.Add(id);
        }
        unknownInstructions.ExceptWith(terminalInstructions);
    }
    readonly HashSet<string> terminalInstructions = [], unknownInstructions = [];
    public bool Uncertain => Pending().Any() || unknownInstructions.Count != 0;
}
