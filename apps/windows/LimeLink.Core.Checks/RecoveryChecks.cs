using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LimeIoT.Client;
using LimeLink.Core;

static class RecoveryChecks {
    public static async Task Run(){
        static void Check(bool condition,string message){if(!condition)throw new Exception(message);}
        var store=new MemoryStore();var transport=new Handler();using var client=new LinkClient("https://gateway.example",store,transport);
        await client.Gateway.LoginAsync("fixture");var snapshot=await client.SnapshotAsync("chosen");
        try{await client.PerformAsync("chosen",snapshot.Devices[0],"card",new(){{"text","original"},{"ttl",60}});throw new Exception("timeout expected");}catch(HttpRequestException){}
        Check(await client.PendingAsync() is not null&&transport.Posts==1,"durable original survives response loss");
        try{await client.PerformAsync("chosen",snapshot.Devices[0],"card",new(){{"text","second"},{"ttl",60}});throw new Exception("second post accepted");}catch(InvalidOperationException error)when(error.Message=="resolve_original_request_first"){}
        using var restored=new LinkClient("https://gateway.example",store,transport);await restored.Gateway.RestoreAsync();
        try{await restored.ResolveAsync();throw new Exception("404 expected");}catch(GatewayException error)when(error.Status==404){}
        Check(await restored.PendingAsync() is not null&&transport.Posts==1&&transport.Gets==1,"recreation only resolves original and keeps 404");
        using var other=new LinkClient("https://other.example",store,transport);await other.Gateway.LoginAsync("fixture");var otherSnapshot=await other.SnapshotAsync("chosen");
        store.FailIntent=true;var before=transport.Posts;
        try{await other.PerformAsync("chosen",otherSnapshot.Devices[0],"card",new(){{"text","not submitted"},{"ttl",60}});throw new Exception("save failure expected");}catch(IOException){}
        Check(transport.Posts==before,"failed intent save means zero post");store.FailIntent=false;
        transport.Changed=true;
        try{await other.PerformAsync("chosen",otherSnapshot.Devices[0],"card",new(){{"text","wrong model"},{"ttl",60}});throw new Exception("target change accepted");}catch(InvalidOperationException error)when(error.Message=="target_changed"){}
        Check(transport.Posts==before,"target revision frozen");
    }
    private sealed class MemoryStore:ISessionStore {
        private readonly Dictionary<string,string> values=new();public bool FailIntent;
        public Task<string?> LoadAsync(string scope,CancellationToken cancellation=default)=>Task.FromResult(values.GetValueOrDefault(scope));
        public Task SaveAsync(string scope,string? value,CancellationToken cancellation=default){if(FailIntent&&scope.EndsWith("#limelink.pending",StringComparison.Ordinal))throw new IOException("fixture save failure");if(value is null)values.Remove(scope);else values[scope]=value;return Task.CompletedTask;}
    }
    private sealed class Handler:HttpMessageHandler {
        public int Posts,Gets;public bool Changed;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation){
            var path=request.RequestUri!.AbsolutePath;HttpStatusCode status=HttpStatusCode.OK;string text;
            if(path.EndsWith("/auth/session",StringComparison.Ordinal))text="{\"csrf_token\":\"csrf\",\"authenticated\":true}";
            else if(path.EndsWith("/devices",StringComparison.Ordinal))text=new JsonObject{{"items",new JsonArray(new JsonObject{{"device_id","desktop"},{"model_revision",Changed?"sha256:changed":"sha256:fixture"},{"ready",true}})}}.ToJsonString();
            else if(path.EndsWith("/capabilities",StringComparison.Ordinal))text="{\"models\":{\"sha256:fixture\":{\"model_id\":\"urn:limelink:model:desktop:1\"}}}";
            else if(request.Method==HttpMethod.Post){Posts++;throw new HttpRequestException("fixture lost response");}
            else{Gets++;status=HttpStatusCode.NotFound;text="{\"error\":{\"code\":\"command_not_found\"}}";}
            var response=new HttpResponseMessage(status){Content=new StringContent(text,Encoding.UTF8,"application/json")};response.Headers.TryAddWithoutValidation("Set-Cookie","__Host-limeiot_session="+new string('a',64)+"; Secure; HttpOnly");return Task.FromResult(response);
        }
    }
}
