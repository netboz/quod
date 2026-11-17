using System.Net;
using System.Reflection;
using System.Text.Json.Nodes;
using Quod.Client;

static class ResourceErrorChecks
{
    sealed class Reply(HttpStatusCode status, JsonObject body) : HttpMessageHandler
    {
        public int Calls;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        { Calls++; return Task.FromResult(new HttpResponseMessage(status) { Content=new StringContent(body.ToJsonString()) }); }
    }
    static int checks;
    static void Check(bool value,string message)
    { if(!value)throw new Exception(message);checks++;Console.WriteLine("PASS "+message); }
    public static async Task Run()
    {
        foreach(string actual in new[]{"80041","9007199254740993"}) {
            var body=new JsonObject { ["error"]="material_limit",["kind"]="proof",["resource"]="answer_bytes",["actual"]=actual,["limit"]="1000" };
            var error=await Error(HttpStatusCode.RequestEntityTooLarge,body);
            Check(error.Message==$"Resource allowance exceeded (proof, answer bytes): needed {actual}; allowed 1000.","actual Transport reports exact resource quantity and allowance without numeric loss");
            Check(error.Definite && error.Status==413,"existing definite resource refusal remains definite");
        }
        var busy=await Error(HttpStatusCode.Conflict,new(){["error"]="cursor_busy"});
        Check(busy.Message=="cursor_busy"&&!busy.Definite,"unchanged uncertain refusal is not relabelled unsent");
        try { await Error(HttpStatusCode.RequestEntityTooLarge,new(){["error"]="material_limit",["actual"]="not a number",["limit"]="1000"});throw new Exception("Malformed refusal accepted"); }
        catch(FormatException) {Check(true,"malformed resource data does not become a definite authenticated refusal");}
        Console.WriteLine("RESOURCE_ERROR_PASS checks="+checks);
    }
    static async Task<ApiError> Error(HttpStatusCode status,JsonObject body)
    {
        using var transport=new Transport("https://localhost:14570","");
        var field=typeof(Transport).GetField("client",BindingFlags.Instance|BindingFlags.NonPublic)!;
        ((HttpClient)field.GetValue(transport)!).Dispose();
        var reply=new Reply(status,body);
        field.SetValue(transport,new HttpClient(reply){BaseAddress=transport.Origin});
        try { await transport.Send("/api/goals/read",null,CancellationToken.None);throw new Exception("Expected refusal"); }
        catch(ApiError error) {Check(reply.Calls==1,"one existing HTTP response owner, no replay");return error;}
    }
}
