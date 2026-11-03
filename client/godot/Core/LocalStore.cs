using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Quod.Client;

public sealed record Account(Actor Human, string? Setup = null);
public sealed record SourceDraft(string Baseline,string Text);
public sealed record SignedWork(string Id, string Network, Actor Actor, string Request, string Signature,
    string Flow, string? Instruction = null, string? OutcomeReference = null, SourceDraft? SourceDraft = null);
public sealed class LocalState
{
    public int Version { get; set; } = 1;
    public string Payload { get; set; } = "";
    public bool CreatedLocally { get; set; }
    public Dictionary<string, Account> Accounts { get; set; } = [];
    public List<SignedWork> Pending { get; set; } = [];
    public Dictionary<string,SourceDraft> SourceDrafts { get; set; } = [];
    public string Endpoint { get; set; } = "https://localhost:14570";
    public string CaFile { get; set; } = "";
}

// Linux active plaintext-key storage, separate from passphrase-encrypted backups.
// The writer lease lives with the application; unchanged reads do no writes.
[System.Runtime.Versioning.SupportedOSPlatform("linux")]
public sealed class LocalStore : IDisposable
{
    const UnixFileMode DirectoryMode = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute;
    const UnixFileMode FileMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
    readonly string directory, path;
    readonly FileStream lease;
    LocalState? state;
    bool writeFaulted;
    public LocalState? Snapshot => state == null ? null : Clone(state);
    public Action<string>? DurabilityBoundary { get; set; }
    public LocalStore(string location)
    {
        directory = Path.GetFullPath(location); path = Path.Combine(directory, "active.json");
        if (!Directory.Exists(directory)) Directory.CreateDirectory(directory, DirectoryMode);
        CheckPath(directory, true);
        var lockPath = Path.Combine(directory, "writer.lock");
        if (Path.Exists(lockPath)) CheckPath(lockPath, false);
        lease = new FileStream(lockPath, new FileStreamOptions { Mode = System.IO.FileMode.OpenOrCreate,
            Access = FileAccess.ReadWrite, Share = FileShare.None, UnixCreateMode = FileMode });
        try {
            if (Path.Exists(path)) { CheckPath(path, false); state = JsonSerializer.Deserialize<LocalState>(File.ReadAllBytes(path))
                ?? throw new IOException("Invalid active identity."); Validate(state); }
            else if (Directory.EnumerateFiles(directory, "*.tmp").Any())
                throw new IOException("An interrupted initial identity save needs explicit local recovery.");
        } catch { lease.Dispose(); throw; }
    }
    static LocalState Clone(LocalState value) => JsonSerializer.Deserialize<LocalState>(JsonSerializer.Serialize(value))!;
    static void CheckPath(string path, bool isDirectory)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0 || ((attributes & FileAttributes.Directory) != 0) != isDirectory ||
            (File.GetUnixFileMode(path) & (UnixFileMode)0x3f) != 0)
            throw new IOException("Identity storage must be private and contain no symlink.");
    }
    static void Validate(LocalState value)
    {
        if (value.Version != 1) throw new IOException("Unsupported active identity version.");
        if(value.SourceDrafts==null || value.SourceDrafts.Any(d=>d.Key.Length==0 || d.Value==null || d.Value.Baseline==null || d.Value.Text==null))
            throw new IOException("Invalid saved source draft.");
        using var identity = Identity.FromPayload(value.Payload);
        foreach (var (network, account) in value.Accounts) {
            if (Identity.Decode(network).Length != 32 || Identity.Decode(account.Human.Anchor).Length != 32)
                throw new IOException("Invalid saved account reference.");
            Term.Parse(account.Human.InstanceText.TrimEnd('.')).Ground();
        }
        var seen = new HashSet<string>();
        foreach (var work in value.Pending) {
            var bytes = Identity.Decode(work.Request);
            if (!seen.Add(work.Id) || Identity.Digest(bytes) != work.Id || !Identity.Verify(identity.PublicKey, bytes, Identity.Decode(work.Signature)))
                throw new IOException("Invalid saved signed work.");
            if(work.SourceDraft is { } draft && (draft.Baseline==null || draft.Text==null))
                throw new IOException("Invalid submitted source draft.");
        }
    }
    public void Create(string payload, bool createdLocally = false)
    {
        if (state != null) throw new IOException("An active identity already exists.");
        var next = new LocalState { Payload = payload, CreatedLocally = createdLocally };
        using var p = JsonDocument.Parse(payload);
        if (p.RootElement.TryGetProperty("accounts", out var rows)) foreach (var a in rows.EnumerateArray()) {
            string S(string key) => a.GetProperty(key).GetString()!;
            next.Accounts.Add(S("network"), new(new(S("namespace"), S("anchor"), S("instanceText"))));
        }
        Save(next);
    }
    public void Update(Action<LocalState> change)
    {
        var next = state == null ? throw new IOException("Create or import a local key first.") : Clone(state);
        change(next); Save(next);
    }
    void Save(LocalState next)
    {
        if (writeFaulted) throw new IOException("A local durability operation failed. Reopen and verify the original store before writing again.");
        Validate(next); var bytes = JsonSerializer.SerializeToUtf8Bytes(next);
        if (state != null && bytes.AsSpan().SequenceEqual(JsonSerializer.SerializeToUtf8Bytes(state))) return;
        CheckPath(directory, true); if (Path.Exists(path)) CheckPath(path, false);
        var temporary = Path.Combine(directory, Convert.ToHexString(RandomNumberGenerator.GetBytes(16)) + ".tmp");
        try {
        using (var file = new FileStream(temporary, new FileStreamOptions { Mode = System.IO.FileMode.CreateNew,
            Access = FileAccess.Write, UnixCreateMode = FileMode })) { file.Write(bytes); file.Flush(true); }
        DurabilityBoundary?.Invoke("before-rename"); File.Move(temporary, path, true);
        DurabilityBoundary?.Invoke("after-rename");
        int fd = open(directory, 0x10000 | 0x80000);
        if (fd < 0) throw new IOException("Could not open identity directory for sync.");
        try { if (fsync(fd) != 0) throw new IOException("Identity directory sync failed."); }
        finally { close(fd); }
        if (!File.ReadAllBytes(path).AsSpan().SequenceEqual(bytes)) throw new IOException("Identity read-back failed.");
        state = next;
        } catch { writeFaulted = true; throw; }
    }
    public string PortablePayload()
    {
        var value = Snapshot ?? throw new IOException("No active identity.");
        var payload = JsonNode.Parse(value.Payload)!.AsObject();
        payload["accounts"] = JsonSerializer.SerializeToNode(value.Accounts.Select(pair => new {
            network = pair.Key, @namespace = pair.Value.Human.Namespace, anchor = pair.Value.Human.Anchor,
            instanceText = pair.Value.Human.InstanceText }));
        return payload.ToJsonString();
    }
    public void Dispose() => lease.Dispose();
    [DllImport("libc", SetLastError = true)] static extern int open(string path, int flags);
    [DllImport("libc", SetLastError = true)] static extern int fsync(int fd);
    [DllImport("libc", SetLastError = true)] static extern int close(int fd);
}
