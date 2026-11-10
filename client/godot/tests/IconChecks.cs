using Godot;
using Quod.Client;
using System.Net;
using System.Net.Http;
using System.Reflection;
using HttpClient = System.Net.Http.HttpClient;
using System.Text.Json.Nodes;

public partial class ExportChecks
{
    sealed class IconReply(byte[] bytes) : HttpMessageHandler
    {
        public int Calls;
        public byte[] Bytes = bytes;
        public string Route = "", Request = "";
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            Calls++;
            Route=request.RequestUri!.AbsolutePath;
            Request=await request.Content!.ReadAsStringAsync(cancellation);
            var reply=new JsonObject { ["result"]="ok",["bindings"]=new JsonArray(new JsonObject { ["Bytes"]=Term.Binary(Bytes).ToString() }) };
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(reply.ToJsonString()) };
        }
    }
    async Task IconAllowances()
    {
        var repo = System.IO.Path.GetFullPath("../..", ProjectSettings.GlobalizePath("res://"));
        var source=await System.IO.File.ReadAllLinesAsync(System.IO.Path.Combine(repo,"priv/ontologies/quod_gui.pl"));
        var assets=source.Where(line=>line.StartsWith("gui_asset(")).Select(line=>Term.Parse(line.TrimEnd('.')).Require("gui_asset",3)).ToArray();
        byte[] bytes=assets[0][2].Bytes;
        string image=assets[0][0].TextValue+".png";
        long pixels = StaticGlb.ImagePixels(bytes, "image/png");
        using var key = Identity.Create();
        using var transport = new Transport("https://localhost:14570", "");
        var client = typeof(Transport).GetField("client", BindingFlags.Instance | BindingFlags.NonPublic)!;
        ((HttpClient)client.GetValue(transport)!).Dispose();
        var replies = new IconReply(bytes);
        client.SetValue(transport, new HttpClient(replies) { BaseAddress = transport.Origin });
        using var consumer = new SignedSession(key, app.ActiveStore, transport);
        typeof(SignedSession).GetProperty("Network")!.SetValue(consumer,Identity.Encode(new byte[32]));
        typeof(SignedSession).GetProperty("Expires")!.SetValue(consumer,SignedSession.Now+300000);
        var actor=new Actor("icon-reader",Identity.Encode(new byte[32]),"me.");
        var fetch = typeof(Main).GetMethod("FetchIcon", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var icon = typeof(Main).GetMethod("Icon", BindingFlags.Instance | BindingFlags.NonPublic)!;
        Task Fetch(MenuNode node) => (Task)fetch.Invoke(app, [consumer, actor, node])!;
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
        var request=JsonNode.Parse(replies.Request)!;
        Check(replies.Route=="/api/goals/read" && Identity.Verify(key.PublicKey,Identity.Decode(Quod.Client.Json.S(request,"request")),Identity.Decode(Quod.Client.Json.S(request,"signature"))),
            "icon bytes use the ordinary signed read endpoint and exact request signature");
        for (int i = 0; i < 3; i++) Check(ReferenceEquals(texture, Cached(node)) && replies.Calls == 4, "unchanged icon reuses the same verified texture without another fetch");
        Check(Cached(node with { Transfer = node.Transfer - 1 }) == null && Cached(node with { Pixels = node.Pixels - 1 }) == null && replies.Calls == 4,
            "cached verification cannot bypass a smaller authored allowance");
        replies.Bytes=assets[1][2].Bytes;
        var changed = node with { Image = assets[1][0].TextValue+".png", Transfer = replies.Bytes.LongLength, Pixels = StaticGlb.ImagePixels(replies.Bytes, "image/png") };
        await Fetch(changed);
        Check(Cached(changed) != null && !ReferenceEquals(texture, Cached(changed)) && replies.Calls == 5, "a changed icon fetches and installs its own verified texture");
        Console.WriteLine("ICON_ALLOWANCES_PASS"); Console.Out.Flush(); await app.CloseApplication();
    }
}
