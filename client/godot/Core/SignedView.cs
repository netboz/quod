using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;

namespace Quod.Client;

// One socket is one consumer incarnation. The existing server view owner
// subscribes before snapshot and scopes its retained dependencies to real owners.
[System.Runtime.Versioning.SupportedOSPlatform("linux")]
public sealed class SignedView : IDisposable
{
    readonly SignedSession session;
    readonly Actor human, target;
    readonly string kind, goal;
    readonly CancellationTokenSource lifetime = new();
    readonly SemaphoreSlim sends = new(1);
    readonly ClientWebSocket socket;
    CancellationTokenSource? authorization;
    string? expected, current;
    ulong expires;
    long version;
    long opening;
    bool disposed, suspended;
    readonly TaskCompletionSource connected = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public event Action<JsonNode>? Projection;
    public event Action<string>? Withdrawn;
    public event Action<JsonNode>? Message;
    public Task? Completion { get; private set; }
    // Completes once the socket to the node is open, before the signed read is sent.
    public Task Connected => connected.Task;
    public Func<CancellationToken, Task<(Actor Target,string Goal)?>>? BeforeOpen { get; init; }
    public Actor Target { get; private set; }
    public static int LiveSockets { get; private set; }
    public static long IgnoredProjections { get; private set; }
    // Refresh withdraws authority while the same consumer awaits a replacement.
    // Retained presentation resources must remain hidden and non-interactive.
    public bool Updating { get; private set; }
    public SignedView(SignedSession session, Actor human, Actor target, string kind, string goal)
    {
        this.session = session; this.human = human; this.target = target; this.kind = kind; this.goal = goal;
        Target=target;
        socket = session.Transport.Socket();
    }
    public Task Start() => Completion = Receive();
    public Task Renew() => Open();
    async Task Receive()
    {
        LiveSockets++;
        try {
            await socket.ConnectAsync(session.Transport.SocketUri, lifetime.Token); connected.TrySetResult(); await Open();
            var buffer = new byte[16384];
            while (!lifetime.IsCancellationRequested) {
                using var text = new MemoryStream(); WebSocketReceiveResult part;
                do { part = await socket.ReceiveAsync(buffer, lifetime.Token);
                    if (part.MessageType == WebSocketMessageType.Close) throw new IOException("View disconnected. Reconnect explicitly.");
                    if (part.MessageType != WebSocketMessageType.Text) throw new FormatException("Unsupported view frame.");
                    text.Write(buffer, 0, part.Count);
                } while (!part.EndOfMessage);
                await Handle(JsonNode.Parse(text.ToArray()) ?? throw new FormatException("Invalid view message."));
            }
        } catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception error) { if (!disposed) Discard(error.Message); }
        finally { connected.TrySetCanceled(); socket.Dispose(); LiveSockets--; }
    }
    async Task Open()
    {
        if (disposed || suspended) return;
        long attempt = ++opening;
        (Actor Target,string Goal)? prepared = BeforeOpen == null ? (target,goal) : await BeforeOpen(lifetime.Token);
        if (disposed || suspended || attempt != opening) return;
        if(prepared==null) { Discard("No placed view is selected."); await Send(new() { ["type"]="close" }); return; }
        Target=prepared.Value.Target;
        var signed = session.Sign(human, prepared.Value.Goal); expected = Identity.Digest(signed.Bytes);
        await Send(new() { ["type"] = "open", ["view_kind"] = kind, ["session_id"] = session.SessionId,
            ["request"] = Json.S(signed.Body, "request"), ["signature"] = Json.S(signed.Body, "signature"),
            ["view_namespace"] = Target.Namespace, ["view_anchor"] = Target.Anchor });
    }
    // Reuse the socket so the server releases its prior native registration
    // before attaching the next exact interior, in transport order.
    // A caller refreshing the same selected view may retain hidden presentation
    // resources. Authorization and input are withdrawn in either case.
    public async Task Reopen(bool refreshing=false)
    { suspended=false; Discard("Updating authorized view…",refreshing); await connected.Task.WaitAsync(lifetime.Token); await Open(); }
    public async Task Suspend(bool refreshing=false)
    { suspended=true; Discard("View suspended.",refreshing); await connected.Task.WaitAsync(lifetime.Token); await Send(new() { ["type"]="close" }); }
    public async Task Send(JsonObject message)
    {
        await sends.WaitAsync(lifetime.Token);
        try { if (!disposed) await socket.SendAsync(Encoding.UTF8.GetBytes(message.ToJsonString()), WebSocketMessageType.Text, true, lifetime.Token); }
        finally { sends.Release(); }
    }
    async Task Handle(JsonNode message)
    {
        if (disposed) return;
        switch (Json.S(message, "type")) {
            case "refresh": Discard("Updating authorized view…",true); await Open(); break;
            case "unavailable": Discard("Unavailable: " + Json.S(message, "reason")); break;
            case "projection":
                if (message["view"]?.ToString() != expected) { IgnoredProjections++; return; }
                ulong nextExpiry = Json.U(message, "expires_ms");
                _ = Json.U(message, "height");
                if (nextExpiry <= SignedSession.Now || (current != null && nextExpiry <= expires)) throw new FormatException("Stale view authorization.");
                if (kind != "world" && Json.S(message, "kind") != kind) throw new FormatException("Unexpected view kind.");
                authorization?.Cancel(); authorization?.Dispose(); authorization = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                current = expected; expected = null; expires = nextExpiry; Updating=false;long installed = ++version;
                Projection?.Invoke(message); _ = ExpireOrRenew(installed, authorization.Token); break;
            default: if (current != null && SignedSession.Now < expires && (message["view"] == null || message["view"]!.ToString() == current)) Message?.Invoke(message); break;
        }
    }
    async Task ExpireOrRenew(long installed, CancellationToken cancellation)
    {
        try {
            ulong remaining = expires - SignedSession.Now;
            bool renew = expires < session.Expires;
            await Task.Delay(TimeSpan.FromMilliseconds(renew ? remaining / 2 : remaining), cancellation);
            if (disposed || installed != version) return;
            if (renew) { await Open(); await Task.Delay(TimeSpan.FromMilliseconds(expires > SignedSession.Now ? expires - SignedSession.Now : 0), cancellation); }
            if (!disposed && installed == version) Discard("View authorization expired.");
        } catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error) { if (!disposed && installed == version) Discard(error.Message); }
    }
    void Discard(string reason,bool updating=false)
    {
        version++; opening++; current = expected = null; expires = 0;Updating=updating;authorization?.Cancel(); Withdrawn?.Invoke(reason);
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; version++; current = expected = null; authorization?.Cancel(); lifetime.Cancel(); socket.Abort();
        Projection = null; Withdrawn = null; Message = null;
    }
}
