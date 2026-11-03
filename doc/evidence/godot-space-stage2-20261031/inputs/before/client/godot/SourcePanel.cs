using Godot;
using Quod.Client;
using Json = Quod.Client.Json;

// Authorization follows the existing GUI inspection proof before its cursor
// snapshot. Retired source readers cannot publish into a replacement consumer.
public partial class SourcePanel : VBoxContainer
{
    readonly CancellationTokenSource lifetime = new();
    readonly LineEdit targetNamespace = new() { Name = "source-namespace", PlaceholderText = "Exact target namespace" };
    readonly LineEdit targetAnchor = new() { Name = "source-anchor", PlaceholderText = "Exact genesis anchor (base64url)" };
    readonly Label status = new() { Name = "source-status", AutowrapMode = TextServer.AutowrapMode.WordSmart };
    readonly TextEdit source = new() { Name = "source-content", Editable = false, CustomMinimumSize = new(0, 300), WrapMode = TextEdit.LineWrappingMode.Boundary };
    SignedSession session = null!;
    Accounts accounts = null!;
    SignedView? view;
    CancellationTokenSource? reader;
    Task reading = Task.CompletedTask, retired = Task.CompletedTask;
    long generation;
    bool disposed;
    public event Action? Changed;
    public string Content => source.Text;
    public string Status => status.Text;
    public Task Completion => Task.WhenAll(reading, retired, view?.Completion ?? Task.CompletedTask);
    public void Open(SignedSession session, Accounts accounts)
    {
        this.session = session; this.accounts = accounts;
        AddChild(new Label { Text = "Source / inspection" }); AddChild(targetNamespace); AddChild(targetAnchor); AddChild(status); AddChild(source);
        var row = new HBoxContainer(); AddChild(row);
        foreach (string command in new[] { "Read predicates", "Read complete source", "Close" }) {
            var button = new Button { Text = command }; row.AddChild(button);
            button.Pressed += () => { if (command == "Close") { DisposeView(); QueueFree(); } else Observe(command); };
        }
        targetNamespace.Text = accounts.Human!.Namespace; targetAnchor.Text = accounts.Human.Anchor;
    }
    public void Inspect(Actor target, bool complete)
    { targetNamespace.Text = target.Namespace; targetAnchor.Text = target.Anchor; Observe(complete ? "Read complete source" : "Read predicates"); }
    void Observe(string command)
    {
        if (disposed) return;
        Retire(); source.Text = "";
        try {
            var target = new Actor(targetNamespace.Text, targetAnchor.Text, "me.");
            var tools = accounts.Catalogue.Single(x => x.Namespace == "quod:gui");
            view = new(session, accounts.Human!, tools, "source_access", SignedSession.ViewGoal(tools,
                Term.Call("prolog_inspect", target.Ontology, Term.Atom("presentation"), Term.Variable("View"))));
            view.Projection += message => {
                var access = Term.Parse(Json.S(message, "value"));
                if (access.Kind != "atom" || access.Name is not ("read_only" or "editable")) throw new FormatException("Unsupported source-access descriptor.");
                // A renewal preserves the same subscribed owner/dependencies.
                // Real changes arrive through Withdrawn before a fresh projection.
                if (reader != null) return;
                reader = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                reading = Read(command, target, tools, ++generation, reader.Token);
            };
            view.Withdrawn += reason => { Invalidate(); status.Text = "Source withdrawn: " + reason; Changed?.Invoke(); };
            status.Text = "Reading source authorization…"; _ = view.Start();
        } catch (Exception error) { status.Text = "Source unavailable: " + error.Message; }
        Changed?.Invoke();
    }
    async Task Read(string command, Actor target, Actor tools, long expected, CancellationToken cancellation)
    {
        try {
            string text;
            if (command == "Read predicates") {
                var reply = await session.Read(accounts.Human!, SignedSession.ViewGoal(tools,
                    Term.Call("prolog_predicates", target.Ontology, Term.Variable("Predicates"))), cancellation);
                text = Json.Binding(reply, "Predicates").ToString();
            } else text = await session.ReadSource(accounts.Human!, tools, target, cancellation);
            if (!disposed && expected == generation && !cancellation.IsCancellationRequested) {
                source.Text = text; status.Text = command == "Read predicates" ? "Authorized predicate catalogue. Its access remains subscribed." : "Complete authorized source snapshot. Its access remains subscribed."; Changed?.Invoke();
            }
        } catch (Exception error) { if (!disposed && expected == generation) { source.Text = ""; status.Text = "Source unavailable: " + error.Message; Changed?.Invoke(); } }
    }
    void Retire()
    {
        Invalidate();
        var previous = Task.WhenAll(reading, view?.Completion ?? Task.CompletedTask); view?.Dispose(); view = null;
        retired = retired.IsCompleted ? previous : Task.WhenAll(retired, previous);
    }
    void Invalidate()
    {
        generation++; reader?.Cancel(); reader?.Dispose(); reader = null; source.Text = "";
        retired = retired.IsCompleted ? reading : Task.WhenAll(retired, reading);
    }
    public void DisposeView() { if (disposed) return; disposed = true; lifetime.Cancel(); Retire(); source.Text = ""; }
    public override void _ExitTree() => DisposeView();
}
