using Godot;
using Quod.Client;
using System.Net;
using System.Net.Http;
using System.Reflection;
using HttpClient = System.Net.Http.HttpClient;

public partial class ExportChecks
{
    sealed class IconReply(byte[] bytes) : HttpMessageHandler
    {
        public int Calls;
        public byte[] Bytes = bytes;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            Calls++;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Bytes) });
        }
    }
    async Task IconAllowances()
    {
        var repo = System.IO.Path.GetFullPath("../..", ProjectSettings.GlobalizePath("res://"));
        string[] files = System.IO.Directory.GetFiles(System.IO.Path.Combine(repo, "priv/explorer/assets/icons"), "*.png");
        byte[] bytes = await System.IO.File.ReadAllBytesAsync(files[0]);
        string image = System.IO.Path.GetFileName(files[0]);
        long pixels = StaticGlb.ImagePixels(bytes, "image/png");
        using var key = Identity.Create();
        using var transport = new Transport("https://localhost:14570", "");
        var client = typeof(Transport).GetField("client", BindingFlags.Instance | BindingFlags.NonPublic)!;
        ((HttpClient)client.GetValue(transport)!).Dispose();
        var replies = new IconReply(bytes);
        client.SetValue(transport, new HttpClient(replies) { BaseAddress = transport.Origin });
        using var consumer = new SignedSession(key, app.ActiveStore, transport);
        var fetch = typeof(Main).GetMethod("FetchIcon", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var icon = typeof(Main).GetMethod("Icon", BindingFlags.Instance | BindingFlags.NonPublic)!;
        Task Fetch(MenuNode node) => (Task)fetch.Invoke(app, [consumer, node])!;
        Texture2D? Cached(MenuNode node) => (Texture2D?)icon.Invoke(app, [node]);
        var node = new MenuNode(Term.Atom("test_icon"), "Icon", "", true, 0, 8, 0, null, false, [], image, bytes.LongLength, pixels);
        await Fetch(node with { Transfer = bytes.LongLength - 1 });
        Check(Cached(node) == null && replies.Calls == 1, "actual icon consumer refuses transfer above its authored allowance");
        await Fetch(node with { Pixels = pixels - 1 });
        Check(Cached(node) == null && replies.Calls == 2, "actual icon consumer refuses pixels above its authored allowance before decoding");
        replies.Bytes = (byte[])bytes.Clone(); replies.Bytes[^1] ^= 1;
        await Fetch(node);
        Check(Cached(node) == null && replies.Calls == 3, "actual icon consumer refuses a digest mismatch");
        replies.Bytes = bytes;
        await Fetch(node);
        var texture = Cached(node);
        Check(texture != null && replies.Calls == 4, "actual icon consumer admits the declared bytes and pixels");
        for (int i = 0; i < 3; i++) Check(ReferenceEquals(texture, Cached(node)) && replies.Calls == 4, "unchanged icon reuses the same verified texture without another fetch");
        Check(Cached(node with { Transfer = node.Transfer - 1 }) == null && Cached(node with { Pixels = node.Pixels - 1 }) == null && replies.Calls == 4,
            "cached verification cannot bypass a smaller authored allowance");
        replies.Bytes = await System.IO.File.ReadAllBytesAsync(files[1]);
        var changed = node with { Image = System.IO.Path.GetFileName(files[1]), Transfer = replies.Bytes.LongLength, Pixels = StaticGlb.ImagePixels(replies.Bytes, "image/png") };
        await Fetch(changed);
        Check(Cached(changed) != null && !ReferenceEquals(texture, Cached(changed)) && replies.Calls == 5, "a changed icon fetches and installs its own verified texture");
        Console.WriteLine("ICON_ALLOWANCES_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }
}
