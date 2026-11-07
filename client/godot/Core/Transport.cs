using System.Buffers.Binary;
using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json.Nodes;

namespace Quod.Client;

public sealed class ApiError(string message, int status, bool definite = false) : Exception(message)
{ public int Status { get; } = status; public bool Definite { get; } = definite; }
public sealed record ProofPreview(string Cursor,SignedWork Work,ulong Deadline,JsonNode Reply);
public static class Json
{
    public static string S(JsonNode? value, string key) => value?[key]?.GetValue<string>() ?? throw new FormatException("Missing " + key);
    public static ulong U(JsonNode? value, string key) => ulong.Parse(value?[key]?.ToString() ?? throw new FormatException("Missing " + key));
    public static string Error(JsonNode value)
    {
        string code=S(value,"error");
        if(code!="material_limit")return code;
        string actual=S(value,"actual"),limit=S(value,"limit");
        if(!System.Numerics.BigInteger.TryParse(actual,System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out var quantity) ||
           !System.Numerics.BigInteger.TryParse(limit,System.Globalization.NumberStyles.None,System.Globalization.CultureInfo.InvariantCulture,out var allowance) || quantity<=allowance)
            throw new FormatException("Invalid resource allowance refusal.");
        return $"Resource allowance exceeded ({S(value,"kind")}, {S(value,"resource").Replace('_',' ')}): needed {actual}; allowed {limit}.";
    }
    public static bool Committed(JsonNode value) =>
        (value["aggregate"] == null || value["aggregate"]?.ToString() == "all_applied") &&
        (value["result"]?.ToString() == "ok" || (value["terminal"]?.ToString() == "true" &&
        (value["status"]?.ToString() == "committed" || (value["result"]?.ToString() == "operation_outcome" &&
        value["status"]?.ToString() == "completed" && value["aggregate"]?.ToString() == "all_applied"))));
    public static bool Terminal(JsonNode value) => value["result"]?.ToString() is "ok" or "fail" || value["terminal"]?.ToString() == "true";
    public static Term Binding(JsonNode value, string name)
    {
        var rows = value["bindings"]?.AsArray();
        if (rows?.Count != 1 || rows[0]?[name] == null) throw new FormatException("Expected one binding: " + name);
        return Term.Parse(S(rows[0], name));
    }
}

// A node serves HTTPS with its own self-signed certificate, re-signed in place
// from one long-lived key. The client trusts that key on first use, like SSH:
// an empty pin accepts and records the first key; a pin accepts only that key.
public sealed class Transport : IDisposable
{
    readonly HttpClient client;
    readonly Uri origin;
    readonly object keyLock = new();
    string pinnedKey;
    public Uri Origin => origin;
    // The key this transport has accepted: the given pin, or the first key seen.
    public string NodeKey { get { lock (keyLock) return pinnedKey; } }
    public bool KeyChanged { get; private set; }
    public Transport(string address, string pinnedKey)
    {
        origin = new Uri(NodeOrigin(address));
        this.pinnedKey = pinnedKey;
        var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false,
            ServerCertificateCustomValidationCallback = (_, certificate, _, _) => Accept(certificate) };
        client = new HttpClient(handler) { BaseAddress = origin, Timeout = Timeout.InfiniteTimeSpan,
            DefaultRequestVersion = HttpVersion.Version11, DefaultVersionPolicy = HttpVersionPolicy.RequestVersionExact };
    }
    // `host`, `host:port` or `https://host:port` (port 443 by default), normalized to the HTTPS origin.
    public static string NodeOrigin(string address)
    {
        string text = address.Trim();
        if (!text.Contains("://")) text = "https://" + text;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Host.Length == 0 ||
            uri.AbsolutePath != "/" || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0)
            throw new FormatException("Enter the node address, e.g. quod-0.service.consul or IP:port.");
        return uri.GetLeftPart(UriPartial.Authority);
    }
    public static string KeyOf(X509Certificate certificate)
    {
        using var leaf = new X509Certificate2(certificate);
        return Convert.ToHexStringLower(SHA256.HashData(leaf.PublicKey.ExportSubjectPublicKeyInfo()));
    }
    bool Accept(X509Certificate? certificate)
    {
        if (certificate == null) return false;
        string key = KeyOf(certificate);
        lock (keyLock) {
            if (pinnedKey.Length == 0) pinnedKey = key;
            if (pinnedKey == key) return true;
        }
        KeyChanged = true; return false;
    }
    public ClientWebSocket Socket()
    {
        var socket = new ClientWebSocket();
        socket.Options.RemoteCertificateValidationCallback = (_, certificate, _, _) => Accept(certificate);
        return socket;
    }
    public Uri SocketUri => new UriBuilder(origin) { Scheme = "wss", Path = "/api/views" }.Uri;
    public Task<byte[]> Model(string digest,long allowance,CancellationToken cancellation)=>Asset("/assets/models/"+digest+".glb",digest,allowance,cancellation);
    public Task<byte[]> Icon(string file,long allowance,CancellationToken cancellation)=>Asset("/assets/icons/"+file,file.Split('.')[0],allowance,cancellation);
    // A content-addressed asset: the bytes must hash to the digest the ontology named.
    async Task<byte[]> Asset(string route,string digest,long allowance,CancellationToken cancellation)
    {
        if(!System.Text.RegularExpressions.Regex.IsMatch(digest,"^[a-f0-9]{64}$") || allowance<=0)throw new FormatException("Invalid asset request.");
        using var response=await client.GetAsync(route,HttpCompletionOption.ResponseHeadersRead,cancellation);
        response.EnsureSuccessStatusCode();
        if(response.Content.Headers.ContentLength is long length && length>allowance)throw new FormatException("Asset transfer bytes exceeded.");
        using var stream=await response.Content.ReadAsStreamAsync(cancellation);using var output=new MemoryStream();var buffer=new byte[16384];
        for(int count;(count=await stream.ReadAsync(buffer,cancellation))>0;) {
            if(output.Length+count>allowance)throw new FormatException("Asset transfer bytes exceeded.");output.Write(buffer,0,count);
        }
        byte[] bytes=output.ToArray();if(Convert.ToHexStringLower(SHA256.HashData(bytes))!=digest)throw new FormatException("Asset digest mismatch.");return bytes;
    }
    public async Task<JsonNode> Send(string route, JsonObject? body, CancellationToken cancellation, HttpMethod? method = null)
    {
        using var request = new HttpRequestMessage(method ?? (body == null ? HttpMethod.Get : HttpMethod.Post), route);
        if (body != null) request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await client.SendAsync(request, cancellation);
        var value = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellation)) ?? throw new FormatException("Invalid API response.");
        if (!response.IsSuccessStatusCode) throw new ApiError(Json.Error(value), (int)response.StatusCode,
            value["submitted"]?.ToString() == "false" || (int)response.StatusCode is 400 or 401 or 403 or 410 or 413 or 429);
        return value;
    }
    public void Dispose() => client.Dispose();
}

// One authenticated session. This is a protocol adapter; it stores no domain KB.
[System.Runtime.Versioning.SupportedOSPlatform("linux")]
public sealed class SignedSession(Identity identity, LocalStore store, Transport transport) : IDisposable
{
    public Identity Key { get; } = identity;
    public Transport Transport { get; } = transport;
    public string Network { get; private set; } = "";
    public string SessionId { get; private set; } = "";
    public ulong Expires { get; private set; }
    readonly CancellationTokenSource lifetime=new();
    bool disposed;
    public event Action? Expired;
    public bool IsExpired=>SessionId.Length!=0 && Expires<=Now;
    public Task Expiration { get; private set; }=Task.CompletedTask;
    public static ulong Now => checked((ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    public ulong Deadline => Math.Min(Expires, Now + 300000);
    public async Task Authenticate(CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromMinutes(5));
        var nonce = RandomNumberGenerator.GetBytes(32);
        var challenge = await Transport.Send("/api/auth/challenge", new() { ["public_key"] = Key.PublicText, ["client_nonce"] = Identity.Encode(nonce) }, timeout.Token);
        var network = Identity.Decode(Json.S(challenge, "network_id"));
        var chunks = new[] { network, Identity.Decode(Json.S(challenge, "node_key")), Identity.Decode(Json.S(challenge, "challenge_id")),
            Key.PublicKey, nonce, Identity.Decode(Json.S(challenge, "server_nonce")) };
        if (chunks.Where((x, index) => x.Length != (index == 2 ? 16 : 32)).Any()) throw new FormatException("Invalid challenge identity.");
        using var bytes = new MemoryStream(); bytes.Write(Encoding.UTF8.GetBytes("quod.agent.challenge.v1\0"));
        foreach (var chunk in chunks) bytes.Write(chunk);
        var expiry = new byte[8]; BinaryPrimitives.WriteUInt64BigEndian(expiry, Json.U(challenge, "expires_ms")); bytes.Write(expiry);
        var session = await Transport.Send("/api/auth/complete", new() { ["challenge_id"] = Json.S(challenge, "challenge_id"),
            ["signature"] = Identity.Encode(Key.Sign(bytes.ToArray())) }, timeout.Token);
        SessionId = Json.S(session, "session_id"); Network = Identity.Encode(network); Expires = Json.U(session, "expires_ms");
        if (Expires <= Now) throw new FormatException("Expired sign-in.");
        Expiration=ObserveExpiry();
    }
    async Task ObserveExpiry()
    {
        try {
            ulong now=Now;
            await Task.Delay(TimeSpan.FromMilliseconds(Expires>now ? Expires-now : 0),lifetime.Token);
            if(!lifetime.IsCancellationRequested)Expired?.Invoke();
        } catch(OperationCanceledException) when(lifetime.IsCancellationRequested) { }
    }
    public (byte[] Bytes, JsonObject Body, ulong Deadline) Sign(Actor actor, string goal, byte mode = 0)
    {
        if (Expires <= Now) throw new InvalidOperationException("Sign-in expired; reconnect explicitly.");
        var deadline = Deadline;
        var bytes = Wire.Encode(Identity.Decode(Network), Key.PublicKey, RandomNumberGenerator.GetBytes(32), actor, mode, deadline, goal);
        return (bytes, new() { ["session_id"] = SessionId, ["request"] = Identity.Encode(bytes), ["signature"] = Identity.Encode(Key.Sign(bytes)) }, deadline);
    }
    public async Task<JsonNode> Read(Actor actor, string goal, CancellationToken cancellation)
    {
        var signed = Sign(actor, goal); return await SendAt("/api/goals/read", signed.Body, signed.Deadline, cancellation);
    }
    public Task<JsonNode> SendDeadline(string route, JsonObject body, CancellationToken cancellation) => SendAt(route, body, Deadline, cancellation);
    public async Task<JsonNode> SendAt(string route, JsonObject body, ulong deadline, CancellationToken cancellation)
    {
        using var timeout = RequestBudget(deadline,cancellation);
        return await Transport.Send(route, body, timeout.Token);
    }
    static CancellationTokenSource RequestBudget(ulong deadline,CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();ulong now=Now;
        if(deadline<=now)throw new TimeoutException("Original request deadline expired.");
        var timeout=CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromMilliseconds(deadline-now));return timeout;
    }
    public async Task<JsonNode> Execute(Actor actor, string goal, string flow, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested(); var signed = Sign(actor, goal, 1);
        return await Dispatch(new(Identity.Digest(signed.Bytes), Network, actor, Json.S(signed.Body, "request"), Json.S(signed.Body, "signature"), flow),
            signed.Body, "/api/goals/execute", cancellation, signed.Deadline);
    }
    public async Task<JsonNode> Personal(Actor human, Actor agent, byte[] key, Actor target, string goal, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        var id = RandomNumberGenerator.GetBytes(32); var deadline = Deadline;
        string atTarget = $"current_ontology_identity({Term.Text(target.Namespace)},{Term.Binary(Identity.Decode(target.Anchor))}),({goal.TrimEnd('.')})";
        string anchored = target.Namespace == agent.Namespace ? atTarget + "." : $"{Term.Text(target.Namespace)}::({atTarget}).";
        var targetBytes = Wire.Encode(Identity.Decode(Network), key, id, agent, 1, deadline, anchored);
        var signed = Sign(human, Term.Call("personal_instruction_accept", Term.Binary(targetBytes), Term.Variable("Signature")) + ".");
        return await Dispatch(new(Identity.Digest(signed.Bytes), Network, human, Json.S(signed.Body, "request"), Json.S(signed.Body, "signature"), "instruction", Identity.Encode(id)),
            signed.Body, "/api/agents/instructions", cancellation, deadline);
    }
    async Task<JsonNode> Dispatch(SignedWork work, JsonObject body, string route, CancellationToken cancellation, ulong? expiry = null)
    {
        ulong deadline=expiry??Deadline;
        using(var admitted=RequestBudget(deadline,cancellation)) { }
        // Recovery is conservative even for a crash between durable save and send.
        store.Update(s => s.Pending.Add(work));
        try {
            // Persistence can consume the remaining allowance. Only this local
            // pre-send refusal is known not to have reached the transport.
            CancellationTokenSource timeout;
            try { timeout=RequestBudget(deadline,cancellation); }
            catch { Forget(work.Id);throw; }
            using var sending=timeout;
            var reply = await Transport.Send(route, body, timeout.Token);
            if (!Json.Terminal(reply) && reply["result"]?.ToString() != "pending" && reply["status"]?.ToString() != "pending")
                throw new FormatException("Unrecognized write reply; original work retained.");
            if (!Json.Terminal(reply) && reply["group_id"] != null) {
                var reference = new JsonObject();
                foreach (string field in new[] { "ns", "anchor", "coordinator", "coordinator_admission", "group_id" })
                    reference[field] = reply[field]?.DeepClone() ?? throw new FormatException("Incomplete portable outcome reference.");
                store.Update(s => { int index = s.Pending.FindIndex(x => x.Id == work.Id);
                    s.Pending[index] = work with { OutcomeReference = reference.ToJsonString() }; });
            }
            // Account handoffs consume results together with their original work.
            if (work.Flow is not ("signup" or "setup") && Json.Terminal(reply)) Finish(work,reply);
            return reply;
        } catch (ApiError error) {
            // Only installed pre-submission refusals can discard original work.
            // Unknown/post-admission errors retain the exact signed bytes.
            if (error.Definite) Forget(work.Id); throw;
        }
    }
    public void Forget(string id) => store.Update(s => s.Pending.RemoveAll(w => w.Id == id));
    public void Finish(SignedWork original,JsonNode reply)
    {
        if(!Json.Terminal(reply))return;
        store.Update(s=>{
            s.Pending.RemoveAll(w=>w.Id==original.Id);
            if(Json.Committed(reply) && original.SourceDraft!=null && s.SourceDrafts.GetValueOrDefault(original.Flow)==original.SourceDraft)s.SourceDrafts.Remove(original.Flow);
        });
    }
    public async Task<JsonNode> Resolve(SignedWork work, CancellationToken cancellation)
    {
        if (work.Network != Network) throw new InvalidOperationException("Work belongs to another network.");
        if (work.Instruction != null) return await ResolveInstruction(work.Actor, work.Instruction, cancellation);
        var body = new JsonObject { ["session_id"] = SessionId, ["request"] = work.Request, ["signature"] = work.Signature };
        if (work.OutcomeReference != null) body["outcome_ref"] = JsonNode.Parse(work.OutcomeReference);
        return await SendDeadline("/api/goals/outcomes", body, cancellation);
    }
    public async Task<JsonNode> ResolveInstruction(Actor human, string id, CancellationToken cancellation)
    {
        var signed = Sign(human, Term.Call("personal_instruction_lookup", Term.Binary(Identity.Decode(id)), Term.Variable("Bytes"), Term.Variable("Signature")) + ".");
        return await SendAt("/api/agents/instructions/outcomes", signed.Body, signed.Deadline, cancellation);
    }
    public static string ViewGoal(Actor target, Term goal) =>
        $"{Term.Text(target.Namespace)}::(current_ontology_identity({Term.Text(target.Namespace)},{Term.Binary(Identity.Decode(target.Anchor))}),{goal}).";
    public async Task<ProofPreview> Preview(Actor actor,string goal,string flow,SourceDraft draft,CancellationToken cancellation)
    {
        var signed=Sign(actor,goal,2);
        var reply=await SendAt("/api/goals/cursors",signed.Body,signed.Deadline,cancellation);
        if(reply["result"]?.ToString()!="solution")throw new InvalidOperationException("Edit preview refused: "+reply.ToJsonString());
        return new(Json.S(reply,"cursor"),new(Identity.Digest(signed.Bytes),Network,actor,Json.S(signed.Body,"request"),Json.S(signed.Body,"signature"),flow,SourceDraft:draft),signed.Deadline,reply);
    }
    public Task<JsonNode> Accept(ProofPreview preview,CancellationToken cancellation) =>
        Dispatch(preview.Work,new() { ["session_id"]=SessionId },"/api/goals/cursors/"+Uri.EscapeDataString(preview.Cursor)+"/accept",cancellation,preview.Deadline);
    public async Task Stop(ProofPreview preview)
    {
        using var until=new CancellationTokenSource(TimeSpan.FromMilliseconds(preview.Deadline>Now ? preview.Deadline-Now : 1));
        await Transport.Send("/api/goals/cursors/"+Uri.EscapeDataString(preview.Cursor),new() { ["session_id"]=SessionId },until.Token,HttpMethod.Delete);
    }
    public Task<string> ReadSource(Actor human, Actor tools, Actor target, CancellationToken cancellation) =>
        ReadSource(human,ViewGoal(tools,Term.Call("prolog_source",target.Ontology,Term.Variable("Source"))),"Source",cancellation);
    public async Task<string> ReadSource(Actor human,string goal,string binding,CancellationToken cancellation)
    {
        var signed = Sign(human,goal,2);
        var reply = await SendAt("/api/goals/cursors", signed.Body, signed.Deadline, cancellation);
        string? cursor = null; var text = new StringBuilder(); var decoder = new UTF8Encoding(false, true).GetDecoder();
        try {
            while (reply["result"]?.ToString() == "solution") {
                cancellation.ThrowIfCancellationRequested(); cursor = Json.S(reply, "cursor");
                var chunk = Json.Binding(reply,binding).Require("source_chunk",2);
                if (chunk[0].Name is not ("more" or "done") || chunk[1].Kind != "binary") throw new FormatException("Invalid source chunk.");
                var chars = new char[Encoding.UTF8.GetMaxCharCount(chunk[1].Bytes.Length)];
                int count = decoder.GetChars(chunk[1].Bytes, chars, chunk[0].Name == "done"); text.Append(chars, 0, count);
                if (chunk[0].Name == "done") return text.ToString();
                reply = await SendAt("/api/goals/cursors/" + Uri.EscapeDataString(cursor) + "/next", new() { ["session_id"] = SessionId }, signed.Deadline, cancellation);
            }
            throw new InvalidOperationException("Source read was refused or incomplete.");
        } finally {
            if (cursor != null) {
                using var cleanup = new CancellationTokenSource(TimeSpan.FromMilliseconds(signed.Deadline > Now ? signed.Deadline - Now : 1));
                await Transport.Send("/api/goals/cursors/" + Uri.EscapeDataString(cursor), new() { ["session_id"] = SessionId }, cleanup.Token, HttpMethod.Delete);
            }
        }
    }
    public void Dispose() {if(disposed)return;disposed=true;lifetime.Cancel();Expired=null;Transport.Dispose();lifetime.Dispose();}
}
