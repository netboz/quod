using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Quod.Client;

public sealed class Identity : IDisposable
{
    readonly byte[] seed;
    public byte[] PublicKey { get; }
    public string PublicText => Encode(PublicKey);
    public Identity(byte[] material)
    {
        if (material.Length != 32) throw new CryptographicException("Invalid Ed25519 seed.");
        seed = material.ToArray(); PublicKey = new Ed25519PrivateKeyParameters(seed, 0).GeneratePublicKey().GetEncoded();
    }
    public static Identity Create() => new(RandomNumberGenerator.GetBytes(32));
    public byte[] Sign(byte[] bytes)
    {
        var signer = new Ed25519Signer(); signer.Init(true, new Ed25519PrivateKeyParameters(seed, 0));
        signer.BlockUpdate(bytes, 0, bytes.Length); return signer.GenerateSignature();
    }
    public static bool Verify(byte[] key, byte[] bytes, byte[] signature)
    {
        var verifier = new Ed25519Signer(); verifier.Init(false, new Ed25519PublicKeyParameters(key, 0));
        verifier.BlockUpdate(bytes, 0, bytes.Length); return verifier.VerifySignature(signature);
    }
    public string Payload() => JsonSerializer.Serialize(new { private_jwk = new {
        kty = "OKP", crv = "Ed25519", x = PublicText, d = Encode(seed), ext = true, key_ops = new[] { "sign" } } });
    public static Identity FromPayload(string json)
    {
        using var d = JsonDocument.Parse(json);
        var j = d.RootElement.GetProperty("private_jwk");
        if (j.GetProperty("kty").GetString() != "OKP" || j.GetProperty("crv").GetString() != "Ed25519")
            throw new CryptographicException("Unsupported identity.");
        var result = new Identity(Decode(j.GetProperty("d").GetString()!));
        if (result.PublicText != j.GetProperty("x").GetString()) { result.Dispose(); throw new CryptographicException("Public key mismatch."); }
        return result;
    }
    public static string Encode(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    public static byte[] Decode(string value)
    {
        var bytes = Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/') + new string('=', (4 - value.Length % 4) % 4));
        if (Encode(bytes) != value) throw new FormatException("Noncanonical base64url."); return bytes;
    }
    public static string Digest(byte[] bytes) => Encode(SHA256.HashData(bytes));
    public void Dispose() => CryptographicOperations.ZeroMemory(seed);
}

public static class Backup
{
    static readonly byte[] Aad = Encoding.UTF8.GetBytes("quod-client-key-v1");
    public static string Export(Identity identity, string passphrase, string? payload = null)
    {
        if (passphrase.Length < 12) throw new CryptographicException("Use at least 12 characters for a backup passphrase.");
        byte[] salt = RandomNumberGenerator.GetBytes(16), iv = RandomNumberGenerator.GetBytes(12);
        byte[] plain = Encoding.UTF8.GetBytes(payload ?? identity.Payload()), ciphertext = new byte[plain.Length], tag = new byte[16];
        byte[] key = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(passphrase), salt, 600000, HashAlgorithmName.SHA256, 32);
        try { using var aes = new AesGcm(key, 16); aes.Encrypt(iv, plain, ciphertext, tag, Aad);
            return JsonSerializer.Serialize(new { version = 1, kdf = "PBKDF2-SHA-256", iterations = 600000,
                salt = Identity.Encode(salt), cipher = "AES-256-GCM", iv = Identity.Encode(iv),
                ciphertext = Identity.Encode(ciphertext.Concat(tag).ToArray()), public_key = identity.PublicText }); }
        finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plain); }
    }
    public static Identity Import(string bundle, string passphrase) => Identity.FromPayload(Decrypt(bundle, passphrase));
    public static string Decrypt(string bundle, string passphrase)
    {
        using var d = JsonDocument.Parse(bundle); var b = d.RootElement;
        string S(string key) => b.GetProperty(key).GetString()!;
        if (b.GetProperty("version").GetInt32() != 1 || S("kdf") != "PBKDF2-SHA-256" ||
            b.GetProperty("iterations").GetInt32() != 600000 || S("cipher") != "AES-256-GCM")
            throw new CryptographicException("Unsupported backup format.");
        byte[] salt = Identity.Decode(S("salt")), iv = Identity.Decode(S("iv")), ct = Identity.Decode(S("ciphertext"));
        if (salt.Length != 16 || iv.Length != 12 || ct.Length < 16) throw new CryptographicException("Invalid backup lengths.");
        var key = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(passphrase), salt, 600000, HashAlgorithmName.SHA256, 32);
        var plain = new byte[ct.Length - 16];
        try { using var aes = new AesGcm(key, 16); aes.Decrypt(iv, ct.AsSpan(0, plain.Length), ct.AsSpan(plain.Length), plain, Aad);
            var payload = new UTF8Encoding(false, true).GetString(plain); using var identity = Identity.FromPayload(payload); return payload; }
        finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plain); }
    }
}

public sealed record Actor(string Namespace, string Anchor, string InstanceText)
{
    [JsonIgnore] public Term Entity => Term.Call("entity_ref", Term.Text(Namespace), Term.Binary(Identity.Decode(Anchor)), Term.Parse(InstanceText.TrimEnd('.')));
    [JsonIgnore] public Term Ontology => Term.Call("ontology_ref", Term.Text(Namespace), Term.Binary(Identity.Decode(Anchor)));
    public static Actor FromTerm(Term value)
    {
        if (value.Name is not ("agent_instance_ref" or "entity_ref")) throw new FormatException("Expected exact actor reference.");
        var args = value.Require(value.Name, 3);
        if (args[1].Kind != "binary" || args[1].Bytes.Length != 32) throw new FormatException("Invalid history anchor.");
        value.Ground(); return new(args[0].TextValue, Identity.Encode(args[1].Bytes), args[2] + ".");
    }
}

public static class Wire
{
    public static byte[] Encode(byte[] network, byte[] key, byte[] operation, Actor actor, byte mode, ulong deadline, string goal)
    {
        byte[] anchor = Identity.Decode(actor.Anchor), ns = Encoding.UTF8.GetBytes(actor.Namespace),
            instance = Encoding.UTF8.GetBytes(actor.InstanceText), text = Encoding.UTF8.GetBytes(goal);
        // Exact identity widths and retained directory policy; length writes below are checked.
        if (network.Length != 32 || key.Length != 32 || operation.Length != 32 || anchor.Length != 32 ||
            ns.Length is < 1 or > 255 || instance.Length < 1 || text.Length < 1 || mode > 3 || deadline == 0)
            throw new FormatException("Invalid signed request.");
        using var s = new MemoryStream(); s.Write(Encoding.UTF8.GetBytes("quod.agent.goal.v1\0"));
        s.Write(network); s.Write(key); s.Write(operation);
        var length = new byte[4]; BinaryPrimitives.WriteUInt16BigEndian(length, checked((ushort)ns.Length)); s.Write(length, 0, 2); s.Write(ns);
        s.Write(anchor); BinaryPrimitives.WriteUInt32BigEndian(length, checked((uint)instance.Length)); s.Write(length); s.Write(instance);
        s.WriteByte(mode); s.WriteByte(3); var expiry = new byte[8]; BinaryPrimitives.WriteUInt64BigEndian(expiry, deadline); s.Write(expiry);
        BinaryPrimitives.WriteUInt32BigEndian(length, checked((uint)text.Length)); s.Write(length); s.Write(text); return s.ToArray();
    }
}
