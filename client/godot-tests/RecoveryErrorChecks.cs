using System.Net;
using System.Reflection;
using System.Text.Json.Nodes;
using Quod.Client;

// Inject HTTP responses only. This proves client recovery, not a server commit.
static class RecoveryErrorChecks
{
    sealed class Replies : HttpMessageHandler
    {
        public List<(string Path, JsonNode Body)> Calls=[];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation)
        {
            string path=request.RequestUri!.AbsolutePath;
            Calls.Add((path,JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellation))!));
            return new(path=="/api/goals/execute" ? HttpStatusCode.ServiceUnavailable : HttpStatusCode.OK) {
                Content=new StringContent(path=="/api/goals/execute" ? "{\"error\":\"result_too_large\"}" :
                    "{\"result\":\"operation_outcome\",\"status\":\"committed\",\"terminal\":true}") };
        }
    }
    static void Check(bool ok,string message) { if(!ok)throw new Exception(message);Console.WriteLine("PASS "+message); }
    static void Session(SignedSession session,string network)
    {
        foreach(var row in new (string,object)[]{("Network",network),("SessionId","fixture"),("Expires",SignedSession.Now+60000)})
            typeof(SignedSession).GetProperty(row.Item1)!.SetValue(session,row.Item2);
    }
    public static async Task Run(string path)
    {
        using var key=Identity.Create();var replies=new Replies();
        Transport Open() {
        var transport=new Transport("https://localhost:14570","");
        var field=typeof(Transport).GetField("client",BindingFlags.Instance|BindingFlags.NonPublic)!;
        ((HttpClient)field.GetValue(transport)!).Dispose();
        field.SetValue(transport,new HttpClient(replies,false){BaseAddress=transport.Origin});return transport;
        }
        string network=Identity.Encode(new byte[32]);SignedWork original;
        using(var store=new LocalStore(path)) {
            store.Create(key.Payload());using var session=new SignedSession(key,store,Open());Session(session,network);
            try { await session.Execute(new("quod:test",network,"human_user(alice)."),"assertz(saved(ok)).","test",CancellationToken.None);throw new Exception("Expected delivery failure"); }
            catch(ApiError error) {Check(error.Status==503&&!error.Definite,"delivery failure is not certified nonexecution");}
            original=store.Snapshot!.Pending.Single();
            Check(replies.Calls.Count==1,"one execution send retains original durable work");
        }
        using(var store=new LocalStore(path)) {
            using var session=new SignedSession(key,store,Open());Session(session,network);
            var retained=store.Snapshot!.Pending.Single();Check(retained==original,"original signed work survives store reopen");
            var result=await session.Resolve(retained,CancellationToken.None);
            Check(Json.Terminal(result),"existing outcome lookup returns terminal recovery");
            session.Finish(retained,result);Check(store.Snapshot!.Pending.Count==0,"terminal recovery retires original durable work");
        }
        Check(replies.Calls.Select(x=>x.Path).SequenceEqual(new[]{"/api/goals/execute","/api/goals/outcomes"}),"recovery never replays execution");
        foreach(var call in replies.Calls) Check(Json.S(call.Body,"request")==original.Request && Json.S(call.Body,"signature")==original.Signature,"HTTP recovery preserves exact request and signature");
        Console.WriteLine("RECOVERY_ERROR_PASS");
    }
}
