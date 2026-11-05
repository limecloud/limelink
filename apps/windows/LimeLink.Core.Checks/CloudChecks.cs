using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using LimeIoT.Client;
using LimeLink.Core;

static class CloudChecks {
    static void Check(bool value,string name){if(!value)throw new InvalidOperationException(name);}
    static async Task Expect(Func<Task> action,string code){try{await action();throw new InvalidOperationException("expected "+code);}catch(InvalidOperationException error)when(error.Message==code){}}
    static async Task Login(CloudLinkClient client){await client.Control.BeginAuthorizationAsync();await client.Control.PollAuthorizationAsync();}
    static bool ValidSignature(JsonObject exchange,string space) {
        var bytes=Convert.FromHexString(exchange["public_key"]!.GetValue<string>());
        using var key=ECDsa.Create(new ECParameters{Curve=ECCurve.NamedCurves.nistP256,Q=new ECPoint{X=bytes[1..33],Y=bytes[33..65]}});
        var message=string.Join('\n',"limelink.exchange/v1",space,"desktop",CloudFixture.Revision,exchange["client_id"]!.ToString(),exchange["kind"]!.ToString(),exchange["nonce"]!.ToString(),exchange["expires_at"]!.ToString(),LinkIdentity.Hash(exchange["payload"]!.GetValue<string>()));
        return key.VerifyData(Encoding.UTF8.GetBytes(message),Convert.FromHexString(exchange["signature"]!.GetValue<string>()),HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence);
    }
    public static async Task Run() {
        var store=new CloudStore();var fixture=new CloudFixture();using var client=new CloudLinkClient(CloudFixture.Origin,store,fixture);await Login(client);
        var snapshot=await client.SnapshotAsync("cloud-space");var device=snapshot.Devices.Single();var fingerprint=await client.FingerprintAsync(device.Id);
        fixture.LoseCommand=true;
        try{await client.PerformAsync("cloud-space",device,"pair",new(){{"name","Windows"}});throw new InvalidOperationException("lost response expected");}catch(HttpRequestException){}
        var records=await client.RecordsAsync();Check(records.Count==1&&records[0].Attempted,"cloud original restored");
        var exchange=records[0].Reference.Request.Operation["value"]!.AsObject();Check(ValidSignature(exchange,"local-space")&&!ValidSignature(exchange,"cloud-space"),"signature uses gateway local space");
        var posted=fixture.Creates;var reads=fixture.DeviceReads;
        using var recovered=new CloudLinkClient(CloudFixture.Origin,store,fixture);
        fixture.Offline=true;await recovered.ResolveAsync(records[0].Id);
        Check(fixture.DeviceReads==reads&&fixture.Creates==posted,"original query independent of selected or online device");fixture.Offline=false;
        var other=await recovered.SnapshotAsync("another-space");
        await Expect(()=>recovered.PerformAsync("another-space",other.Devices.Single(),"pair",new(){{"name","Windows"}}),"resolve_original_request_first");Check(fixture.Creates==1,"other space cannot bypass unknown original");
        fixture.Confirmed=true;var result=await recovered.ResolveAsync(records[0].Id,true);Check(result.Result?.Status=="confirmed"&&CloudLinkClient.Response(result)?["ok"]?.GetValue<bool>()==true,"original product response consumed");
        await recovered.ForgetAsync(records[0].Id);await recovered.SnapshotAsync("cloud-space");Check(await recovered.FingerprintAsync(device.Id)==fingerprint,"identity survives client recreation");
        fixture.LocalSpace="local-rebound";await recovered.SnapshotAsync("cloud-space");Check(await recovered.FingerprintAsync(device.Id)!=fingerprint,"binding to different local space isolates product identity");
        await recovered.LogoutAsync();fixture.Principal="other-owner";await Login(recovered);await recovered.SnapshotAsync("cloud-space");Check(await recovered.FingerprintAsync(device.Id)!=fingerprint,"different principal isolates product identity");
        {
            var nextStore=new CloudStore();var nextFixture=new CloudFixture();using var next=new CloudLinkClient(CloudFixture.Origin,nextStore,nextFixture);await Login(next);var target=await next.SnapshotAsync("cloud-space");
            nextFixture.Binding="changed";await Expect(()=>next.PerformAsync("cloud-space",target.Devices.Single(),"pair",new()),"gateway_binding_changed");Check(nextFixture.Creates==0,"stale selection sends zero creates");
            nextFixture.Binding="initial";nextFixture.ModelId="urn:other:model";await next.SnapshotAsync("cloud-space");await Expect(()=>next.PerformAsync("cloud-space",target.Devices.Single(),"pair",new()),"target_capability_changed");Check(nextFixture.Creates==0,"different model sends zero creates");
        }
        {
            var nextStore=new CloudStore{FailIdentity=true};var nextFixture=new CloudFixture();using var next=new CloudLinkClient(CloudFixture.Origin,nextStore,nextFixture);await Login(next);var target=await next.SnapshotAsync("cloud-space");
            try{await next.PerformAsync("cloud-space",target.Devices.Single(),"pair",new());throw new InvalidOperationException("identity storage failure expected");}catch(IOException){}
            Check(nextFixture.Creates==0&&(await next.RecordsAsync()).Count==0,"identity save failure prevents preparation and send");
        }
        {
            var nextStore=new CloudStore();var nextFixture=new CloudFixture();using var next=new CloudLinkClient(CloudFixture.Origin,nextStore,nextFixture);await Login(next);var target=await next.SnapshotAsync("cloud-space");
            using var cancellation=new CancellationTokenSource();nextStore.CancelOnPrepare=cancellation;
            try{await next.PerformAsync("cloud-space",target.Devices.Single(),"pair",new(),cancellation.Token);throw new InvalidOperationException("prepare cancellation ignored");}catch(OperationCanceledException){}
            Check(nextFixture.Creates==0&&(await next.RecordsAsync()).Single().IsPrepared,"cancellation after durable preparation sends zero creates");
        }
        {
            var nextFixture=new CloudFixture{RepeatCursor=true};using var next=new CloudLinkClient(CloudFixture.Origin,new CloudStore(),nextFixture);await Login(next);
            await Expect(()=>next.SnapshotAsync("cloud-space"),"invalid_device_cursor");Check(nextFixture.DeviceReads==2,"repeated pagination cursor bounded");
        }
    }
}
sealed class CloudStore:ISessionStore {
    readonly Dictionary<string,string> values=[];public bool FailIdentity;public CancellationTokenSource? CancelOnPrepare;
    public Task<string?> LoadAsync(string scope,CancellationToken cancellation=default)=>Task.FromResult(values.GetValueOrDefault(scope));
    public Task SaveAsync(string scope,string? value,CancellationToken cancellation=default){
        if(FailIdentity&&scope.Contains(".cloud.identity:",StringComparison.Ordinal))throw new IOException("fixture storage unavailable");
        if(value is null)values.Remove(scope);else values[scope]=value;
        if(CancelOnPrepare is {} source&&scope.StartsWith("limeiot.control:",StringComparison.Ordinal)&&value is not null&&JsonNode.Parse(value)?["operations"] is JsonArray records&&records.Count>0)source.Cancel();
        return Task.CompletedTask;
    }
}
sealed class CloudFixture:HttpMessageHandler {
    public const string Origin="https://control.example";public static readonly string Revision="sha256:"+new string('a',64);
    public string Principal="owner",LocalSpace="local-space",Binding="initial",ModelId="urn:limelink:model:desktop:1";
    public bool LoseCommand,Offline,Confirmed,RepeatCursor;public int Creates,DeviceReads;
    readonly string expiry=DateTimeOffset.UtcNow.AddMinutes(4).ToString("O"),sessionExpiry=DateTimeOffset.UtcNow.AddSeconds(3500).ToString("O");
    static readonly string Token=new('c',64),Authorization="na-"+new string('b',64),RemoteId="remote-"+new string('d',64);
    JsonObject? original;string originalSpace="";
    JsonObject Remote() {
        var input=original!.DeepClone().AsObject();var result=new JsonObject{{"remote_id",RemoteId},{"space_id",originalSpace},{"principal_id",Principal},{"local_space_id","local-space"},{"request_digest",new string('e',64)},{"request",input},{"status",Confirmed?"confirmed":"unknown"},{"local_result",null}};
        if(Confirmed)result["local_result"]=new JsonObject{{"command_id","cmd-original"},{"status","confirmed"},{"error",null},{"request_digest","sha256:"+new string('f',64)},{"request",new JsonObject{{"space_id","local-space"},{"idempotency_key",RemoteId},{"device_id",input["device_id"]!.DeepClone()},{"model_revision",input["model_revision"]!.DeepClone()},{"expires_at",input["expires_at"]!.DeepClone()},{"operation",input["operation"]!.DeepClone()}}},{"evidence",new JsonObject{{"type","action_result"},{"path","link.exchange"},{"input_digest","sha256:"+new string('a',64)},{"output",new JsonObject{{"response","{\"ok\":true}"}}},{"completion","submitted"},{"observed_at",DateTimeOffset.UtcNow.ToString("O")}}}};
        return result;
    }
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation) {
        var path=request.RequestUri!.AbsolutePath;var parts=path.Split('/');var space=parts.Length>5?parts[5]:"";
        JsonObject body;var status=HttpStatusCode.OK;
        if(path=="/api/native/v1/authorizations")body=new(){{"authorization_id",Authorization},{"user_code","ABCDEF12"},{"verification_uri",Origin+"/console/?native="+Authorization},{"expires_at",expiry},{"interval_seconds",3},{"status","pending"}};
        else if(path.EndsWith("/authorizations/poll",StringComparison.Ordinal))body=new(){{"status","approved"},{"expires_at",expiry},{"material",new JsonObject{{"version",1},{"origin",Origin},{"audience","console"},{"session",Token},{"principal_id",Principal},{"expires_at",sessionExpiry}}}};
        else if(path.EndsWith("/auth/session",StringComparison.Ordinal))body=new(){{"audience","console"},{"principal",new JsonObject{{"principal_id",Principal},{"name","测试账号"}}},{"csrf_token",LinkIdentity.Hash("limeiot-csrf:console:"+Token)},{"expires_at",sessionExpiry}};
        else if(path.EndsWith("/auth/logout",StringComparison.Ordinal))body=new(){{"logged_out",true}};
        else if(path.EndsWith("/gateways",StringComparison.Ordinal))body=new(){{"gateways",new JsonArray(new JsonObject{{"gateway_id","gateway-a"},{"space_id",space},{"local_space_id",LocalSpace},{"principal_id",Principal},{"scopes",new JsonArray("devices.read","commands.write")},{"revision",Binding},{"active",true}})}};
        else if(path.EndsWith("/devices",StringComparison.Ordinal)) {
            DeviceReads++;if(Offline){status=HttpStatusCode.ServiceUnavailable;body=new(){{"error",new JsonObject{{"code","gateway_offline"}}}};}
            else body=new(){{"items",new JsonArray(new JsonObject{{"device_id","desktop"},{"model_revision",Revision},{"ready",true}})},{"next",RepeatCursor?"same":null},{"binding_revision",Binding}};
        }else if(path.Contains("/model-releases/",StringComparison.Ordinal))body=new(){{"revision",Revision},{"model",new JsonObject{{"model_id",ModelId},{"services",new JsonArray()}}}};
        else if(path.EndsWith("/remote-commands",StringComparison.Ordinal)&&request.Method==HttpMethod.Post) {
            Creates++;originalSpace=space;original=JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellation))!.AsObject();if(LoseCommand){LoseCommand=false;throw new HttpRequestException("response_lost");}body=Remote();
        }else if(path.Contains("/remote-commands/",StringComparison.Ordinal))body=Remote();
        else throw new InvalidOperationException("unexpected cloud fixture request");
        return new HttpResponseMessage(status){RequestMessage=request,Content=new StringContent(body.ToJsonString(),Encoding.UTF8,"application/json")};
    }
}
