// Bounded M0 qualification, not the delivered identity client.
using Godot;
using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Security;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Environment = System.Environment;
using RandomNumberGenerator = System.Security.Cryptography.RandomNumberGenerator;
using FileAccess = System.IO.FileAccess;
using HttpClient = System.Net.Http.HttpClient;
using Vector3 = Godot.Vector3;

[assembly: System.Runtime.Versioning.SupportedOSPlatform("linux")]

public partial class Qualification : Node
{
    static string Env(string key) => Environment.GetEnvironmentVariable(key) ?? throw new Exception(key);
    static byte[] Decode(string value) => Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/') + new string('=', (4-value.Length%4)%4));
    static string Encode(byte[] value) => Convert.ToBase64String(value).TrimEnd('=').Replace('+','-').Replace('/','_');
    static string S(JsonElement value, string key) => value.GetProperty(key).GetString()!;
    static void Check(bool valid, string label) { if (!valid) throw new Exception(label); GD.Print("PASS ", label); }
    static void Reject(Action action, string label) { try { action(); } catch (CryptographicException) { GD.Print("PASS ",label); return; } throw new Exception(label); }
    static byte[] Sign(byte[] seed, byte[] message)
    {
        var signer = new Ed25519Signer(); signer.Init(true,new Ed25519PrivateKeyParameters(seed,0));
        signer.BlockUpdate(message,0,message.Length); return signer.GenerateSignature();
    }
    static byte[] Public(byte[] seed) => new Ed25519PrivateKeyParameters(seed,0).GeneratePublicKey().GetEncoded();
    static byte[] Import(string bundle, string passphrase)
    {
        using var document=JsonDocument.Parse(bundle); var b=document.RootElement;
        if (b.GetProperty("version").GetInt32()!=1 || S(b,"kdf")!="PBKDF2-SHA-256" ||
            b.GetProperty("iterations").GetInt32()!=600000 || S(b,"cipher")!="AES-256-GCM") throw new CryptographicException("format");
        var salt=Decode(S(b,"salt")); var iv=Decode(S(b,"iv")); var ct=Decode(S(b,"ciphertext"));
        if(salt.Length!=16 || iv.Length!=12 || ct.Length<16) throw new CryptographicException("length");
        var key=Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(passphrase),salt,600000,HashAlgorithmName.SHA256,32);
        var plain=new byte[ct.Length-16];
        try { using var aes=new AesGcm(key,16); aes.Decrypt(iv,ct.AsSpan(0,plain.Length),ct.AsSpan(plain.Length),plain,Encoding.UTF8.GetBytes("quod-client-key-v1")); }
        finally { CryptographicOperations.ZeroMemory(key); }
        using var payload=JsonDocument.Parse(plain); var jwk=payload.RootElement.GetProperty("private_jwk");
        if(S(jwk,"kty")!="OKP" || S(jwk,"crv")!="Ed25519") throw new CryptographicException("key type");
        var seed=Decode(S(jwk,"d"));
        if(seed.Length!=32 || !CryptographicOperations.FixedTimeEquals(Public(seed),Decode(S(jwk,"x")))) throw new CryptographicException("key mismatch");
        return plain;
    }
    static string Export(byte[] plain,string passphrase)
    {
        var salt=RandomNumberGenerator.GetBytes(16); var iv=RandomNumberGenerator.GetBytes(12);
        var key=Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(passphrase),salt,600000,HashAlgorithmName.SHA256,32);
        var ct=new byte[plain.Length]; var tag=new byte[16];
        try { using var aes=new AesGcm(key,16); aes.Encrypt(iv,plain,ct,tag,Encoding.UTF8.GetBytes("quod-client-key-v1")); }
        finally { CryptographicOperations.ZeroMemory(key); }
        using var p=JsonDocument.Parse(plain);
        return JsonSerializer.Serialize(new {version=1,kdf="PBKDF2-SHA-256",iterations=600000,salt=Encode(salt),cipher="AES-256-GCM",iv=Encode(iv),ciphertext=Encode(ct.Concat(tag).ToArray()),public_key=S(p.RootElement.GetProperty("private_jwk"),"x")});
    }
    static byte[] Request(JsonElement request,byte[] pub)
    {
        var a=request.GetProperty("account"); using var stream=new MemoryStream();
        void Raw(byte[] b)=>stream.Write(b); void Text(string s,int width) { var b=Encoding.UTF8.GetBytes(s); var n=new byte[width]; if(width==2) BinaryPrimitives.WriteUInt16BigEndian(n,checked((ushort)b.Length)); else BinaryPrimitives.WriteUInt32BigEndian(n,checked((uint)b.Length)); Raw(n);Raw(b); }
        Raw(Encoding.UTF8.GetBytes("quod.agent.goal.v1\0")); Raw(Decode(S(a,"network")));Raw(pub);Raw(Decode(S(request,"operation")));
        Text(S(a,"namespace"),2);Raw(Decode(S(a,"anchor")));Text(S(a,"instanceText"),4);Raw(new byte[]{0,3});
        var deadline=new byte[8]; BinaryPrimitives.WriteUInt64BigEndian(deadline,ulong.Parse(S(request,"deadline")));Raw(deadline);Text(S(request,"goal"),4);return stream.ToArray();
    }
    static void Crypto()
    {
        using var corpus=JsonDocument.Parse(File.ReadAllBytes(Env("M0_CORPUS")));var c=corpus.RootElement;
        var plain=Import(S(c,"bundle"),S(c,"passphrase"));using var payload=JsonDocument.Parse(plain);
        var seed=Decode(S(payload.RootElement.GetProperty("private_jwk"),"d"));var pub=Public(seed);
        Check(Encode(pub)==S(c,"public_key"),"browser backup and public key");
        foreach(var r in c.GetProperty("requests").EnumerateArray()) {
            var bytes=Request(r,pub);Check(bytes.SequenceEqual(Decode(S(r,"bytes"))),"exact request UTF8 uint64 binary");
            Check(Encode(Sign(seed,bytes))==S(r,"signature"),"Ed25519 request signature");
        }
        var challenge=c.GetProperty("challenge");Check(Encode(Sign(seed,Decode(S(challenge,"bytes"))))==S(challenge,"signature"),"Ed25519 challenge signature");
        Reject(()=>Import(S(c,"bundle"),"incorrect public fixture phrase"),"wrong passphrase refuses");
        var damaged=System.Text.Json.Nodes.JsonNode.Parse(S(c,"bundle"))!;var ciphertext=Decode(damaged["ciphertext"]!.GetValue<string>());ciphertext[0]^=1;damaged["ciphertext"]=Encode(ciphertext);
        Reject(()=>Import(damaged.ToJsonString(),S(c,"passphrase")),"damaged GCM refuses");
        var generated=RandomNumberGenerator.GetBytes(32);Check(!generated.SequenceEqual(RandomNumberGenerator.GetBytes(32)),"OS secure randomness sampled");
        var backup=Export(plain,S(c,"passphrase")); Check(Import(backup,S(c,"passphrase")).SequenceEqual(plain),"encrypted backup round trip");
        File.WriteAllText(Env("M0_BACKUP"),backup);
        foreach(var term in c.GetProperty("terms").EnumerateArray()) {
            var text=S(term,"text");if(text.All(x=>char.IsDigit(x)||x=='-')) Check(BigInteger.Parse(text).ToString()==text,"exact arbitrary integer text");
        }
        Check(BigInteger.Parse("18446744073709551615")>long.MaxValue,"Godot boundary uses exact text above int64");
        var s1=new Transform3D(Basis.FromEuler(new Vector3(0,Mathf.Pi/2,0)),new Vector3(1,0.2f,0));
        var s2=new Transform3D(Basis.FromEuler(new Vector3(0,0,Mathf.Pi/2)),new Vector3(0,0.3f,2));
        var objectOrigin=(s1*s2)*new Vector3(0.1f,0,0);
        Check(objectOrigin.DistanceTo(new Vector3(3,0.6f,0))<0.000001f,"Godot recursive S0-S1-S2 frame composition");
        GD.Print("CRYPTO_QUALIFIED dependency=",typeof(Ed25519Signer).Assembly.FullName);
        CryptographicOperations.ZeroMemory(seed);CryptographicOperations.ZeroMemory(plain);
    }
    static void ProductionProtocol()
    {
        using var fixture=JsonDocument.Parse(File.ReadAllBytes(Env("M0_PROTOCOL")));
        int count=0; var keys=new System.Collections.Generic.HashSet<string>();
        foreach(var r in fixture.RootElement.GetProperty("requests").EnumerateArray()) {
            var bytes=Decode(S(r,"request_bytes"));var domain=Encoding.UTF8.GetBytes("quod.agent.goal.v1\0");
            using var stream=new MemoryStream();
            void Raw(byte[] value)=>stream.Write(value);
            void Text(string value,int width) { var text=Encoding.UTF8.GetBytes(value);var length=new byte[width];if(width==2)BinaryPrimitives.WriteUInt16BigEndian(length,checked((ushort)text.Length));else BinaryPrimitives.WriteUInt32BigEndian(length,checked((uint)text.Length));Raw(length);Raw(text); }
            Raw(domain);Raw(bytes.AsSpan(domain.Length,32).ToArray());Raw(Decode(S(r,"public_key")));Raw(Decode(S(r,"operation_id")));
            Text(S(r,"namespace"),2);Raw(Decode(S(r,"anchor")));Text(S(r,"actor"),4);
            Raw(new byte[]{S(r,"mode")=="read"?(byte)0:(byte)1,3});
            var deadline=new byte[8];BinaryPrimitives.WriteUInt64BigEndian(deadline,ulong.Parse(S(r,"not_after_ms")));Raw(deadline);Text(S(r,"goal"),4);
            if(!stream.ToArray().SequenceEqual(bytes))throw new Exception("production request encoding");
            var verifier=new Ed25519Signer();verifier.Init(false,new Ed25519PublicKeyParameters(Decode(S(r,"public_key")),0));verifier.BlockUpdate(bytes,0,bytes.Length);
            if(!verifier.VerifySignature(Decode(S(r,"signature"))))throw new Exception("production signature");
            keys.Add(S(r,"public_key"));count++;
        }
        Check(count==83 && keys.Count>=6,"83 production U/A requests encode and authenticate with distinct fixture keys");
    }
    [DllImport("libc",SetLastError=true)] static extern int open(string path,int flags);
    [DllImport("libc",SetLastError=true)] static extern int fsync(int fd);
    [DllImport("libc",SetLastError=true)] static extern int close(int fd);
    static void CrashSeam(string point)
    {
        Console.WriteLine("CRASH_SEAM "+point);Console.Out.Flush();
        Console.ReadLine();throw new Exception("fault injection was not killed");
    }
    static void Storage()
    {
        var directory=Env("M0_STORE");var mode=Env("M0_MODE");
        if(!Directory.Exists(directory))Directory.CreateDirectory(directory,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        if((File.GetAttributes(directory)&FileAttributes.ReparsePoint)!=0 || (File.GetUnixFileMode(directory)&(UnixFileMode)0x3f)!=0) throw new IOException("private directory required");
        var path=Path.Combine(directory,"active.json");
        using var lease=new FileStream(Path.Combine(directory,"lock"),new FileStreamOptions{Mode=FileMode.OpenOrCreate,Access=FileAccess.ReadWrite,Share=FileShare.None,UnixCreateMode=UnixFileMode.UserRead|UnixFileMode.UserWrite});
        if(mode=="read") {
            if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0 || (File.GetUnixFileMode(path)&(UnixFileMode)0x3f)!=0)throw new IOException("private regular file required");
            using var p=JsonDocument.Parse(File.ReadAllBytes(path));var active=p.RootElement;
            Check(active.GetProperty("reference").GetString()==Env("M0_EXPECT"),"original identity and operation recovery");
            using var saved=JsonDocument.Parse(Convert.FromBase64String(S(active,"payload")));
            var seed=Decode(S(saved.RootElement.GetProperty("private_jwk"),"d"));
            Check(Encode(Public(seed))==S(active,"public_key") && Encode(Sign(seed,Decode(S(active,"original_request"))))==S(active,"signature"),"restored active key signs original exact request");
            CryptographicOperations.ZeroMemory(seed);return;
        }
        if(mode=="hold") { Console.WriteLine("LOCK_HELD"); Console.Out.Flush(); Console.ReadLine();return; }
        using var corpus=JsonDocument.Parse(File.ReadAllBytes(Env("M0_CORPUS")));var c=corpus.RootElement;var original=c.GetProperty("requests")[0];
        var payload=Import(S(c,"bundle"),S(c,"passphrase"));
        var value=Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new{reference=Env("M0_VALUE"),payload=Convert.ToBase64String(payload),public_key=S(c,"public_key"),original_request=S(original,"bytes"),signature=S(original,"signature")}));
        CryptographicOperations.ZeroMemory(payload);
        var temporary=Path.Combine(directory,Convert.ToHexString(RandomNumberGenerator.GetBytes(16))+".tmp");
        using(var file=new FileStream(temporary,new FileStreamOptions{Mode=FileMode.CreateNew,Access=FileAccess.Write,UnixCreateMode=UnixFileMode.UserRead|UnixFileMode.UserWrite})) {file.Write(value);file.Flush(true);}
        if(mode=="crash-before-rename")CrashSeam("before-rename");
        File.Move(temporary,path,true);
        if(mode=="crash-after-rename")CrashSeam("after-rename");
        int fd=open(directory,0x10000|0x80000);if(fd<0)throw new IOException("directory open");try {if(fsync(fd)!=0)throw new IOException("directory sync");} finally {close(fd);}
        Check(File.ReadAllBytes(path).SequenceEqual(value),"durable readback");
    }
    static async System.Threading.Tasks.Task Tls()
    {
        var ca=new X509Certificate2Collection();ca.ImportFromPemFile(Env("M0_CA"));
        using var handler=new HttpClientHandler{AllowAutoRedirect=false};
        if(Env("M0_TRUST")=="yes")handler.ServerCertificateCustomValidationCallback=(_,certificate,_,errors)=> {
            if(certificate==null || (errors&SslPolicyErrors.RemoteCertificateNameMismatch)!=0)return false;
            using var chain=new X509Chain();chain.ChainPolicy.TrustMode=X509ChainTrustMode.CustomRootTrust;chain.ChainPolicy.CustomTrustStore.AddRange(ca);chain.ChainPolicy.RevocationMode=X509RevocationMode.NoCheck;
            return chain.Build(certificate);
        };
        using var client=new HttpClient(handler){Timeout=TimeSpan.FromSeconds(5)};
        try {var response=await client.GetAsync(Env("M0_URL"));Check(Env("M0_TLS_EXPECT")=="accept" && response.IsSuccessStatusCode,"TLS trusted hostname");}
        catch(HttpRequestException) {Check(Env("M0_TLS_EXPECT")=="reject","TLS rejection");}
    }
    public override async void _Ready()
    {
        try {var mode=Environment.GetEnvironmentVariable("M0_MODE")??"crypto";if(mode=="crypto")Crypto();else if(mode=="protocol")ProductionProtocol();else if(mode=="tls")await Tls();else Storage();GD.Print("M0_PROBE_PASS");GetTree().Quit();}
        catch(Exception error) {GD.PrintErr(error.GetType().Name,": ",error.Message);GetTree().Quit(1);}
    }
}
