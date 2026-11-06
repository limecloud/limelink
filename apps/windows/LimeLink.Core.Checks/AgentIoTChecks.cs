using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LimeIoT.Client;
using LimeLink.Core;

static class AgentIoTChecks {
    private static void Check(bool value,string message){if(!value)throw new Exception(message);}
    private static async Task Fails(Func<Task> action,string? code=null){try{await action();}catch(Exception e)when(code is null||e.Message==code){return;}throw new Exception("expected failure:"+code);}
    public static async Task Run(){
        var fixture=JsonNode.Parse(File.ReadAllText(Path.Combine(AgentChecks.Root,"contracts/fixtures/agent-tools.json")))!;
        var reference=JsonSerializer.Deserialize<AgentReference>(fixture["reference"]!.ToJsonString(),new JsonSerializerOptions{PropertyNameCaseInsensitive=true})!;
        foreach(var raw in fixture["cases"]!.AsArray()){
            var c=raw!.AsObject();var accepted=false;
            try{var value=c["value"]!.AsObject();switch(c["kind"]!.GetValue<string>()){
                case "capabilities":_=AgentToolProtocol.Capabilities(value);break;
                case "call":_=AgentToolProtocol.Call(value,reference.Devices);break;
                case "pending":_=AgentToolProtocol.Pending(value,reference);break;
                case "completion":AgentToolProtocol.Completion(value,reference.Id,fixture["call_id"]!.GetValue<string>());break;
                case "result":AgentToolProtocol.Result(AgentToolProtocol.Call(c["call"]!.AsObject(),reference.Devices),c["success"]!.GetValue<bool>(),value);break;
                default:throw new Exception("unknown vector");
            }accepted=true;}catch(Exception e)when(e is InvalidOperationException or FormatException or KeyNotFoundException){}
            Check(accepted==c["valid"]!.GetValue<bool>(),"tool vector:"+c["name"]);
        }
        using(var f=await Setup()){
            Check(f.Reference.Devices.SequenceEqual(["lamp"])&&(await f.Agent.DiscoverToolsAsync("chosen",f.Execution)).Enabled,"saved scope and discovery");
            f.Handler.Publish("limeiot_read");var read=(await f.Client.ReceiveAsync(f.Reference,"chosen",f.Execution))!;Check(read.Delivered&&read.Outcome!.Success&&f.Handler.DevicePosts==0,"read without device POST");
            f.Handler.Publish();var proposal=(await f.Client.ReceiveAsync(f.Reference,"chosen",f.Execution))!;Check(proposal.CanConfirm&&f.Handler.DevicePosts==0,"confirmation gate");
            var result=await f.Client.ConfirmAsync(proposal.Id,f.Reference,"chosen",f.Execution);Check(result.Delivered&&result.Outcome!.Success&&result.ReplyIntent is not null,"confirmed and returned");
            await Fails(async()=>{await f.Client.ConfirmAsync(proposal.Id,f.Reference,"chosen",f.Execution);},"resolve_original_iot_command_first");Check(f.Handler.DevicePosts==1,"duplicate confirmation");
            await Fails(async()=>{await f.Agent.SubmitAsync("chosen",f.Execution,"work","继续","read-only",f.Reference,iotDevices:[]);},"agent_tool_scope_changed");
        }
        foreach(var lost in new[]{"device","reply"})using(var f=await Setup()){
            f.Handler.Publish();var proposal=(await f.Client.ReceiveAsync(f.Reference,"chosen",f.Execution))!;f.Handler.LoseDevice=lost=="device";f.Handler.LoseReply=lost=="reply";
            await Fails(async()=>{await f.Client.ConfirmAsync(proposal.Id,f.Reference,"chosen",f.Execution);},lost=="device"?"lost_device_response":"lost_reply_response");var restarted=new AgentIoTClient(f.Link.Gateway,f.Agent,f.Store);
            if(lost=="device"){
                await Fails(async()=>{await restarted.RecoverCommandAsync(proposal.Id,f.Reference,"chosen",f.Execution);},"command_not_found");Check((await restarted.RecordsAsync()).Single().Intent is not null,"404 preserves intent");
                Check((await restarted.RecoverCommandAsync(proposal.Id,f.Reference,"chosen",f.Execution)).Delivered,"device recovery");
            }else{
                f.Store.Expire();Check(await restarted.PruneExpiredAsync()==0,"TTL retains unknown reply");await f.Agent.RecoverAsync();
                Check((await restarted.SendResultAsync(proposal.Id,f.Reference,"chosen",f.Execution)).Delivered,"independent reply recovery after generic archive");Check(await restarted.PruneExpiredAsync()==1,"resolved TTL cleanup");
            }
            Check(f.Handler.DevicePosts==1&&f.Handler.ResultPosts==1,"two recovery paths never POST again");
        }
        foreach(var mode in new[]{"save","readback","expired","slow","cancelled","read-only","revision","bad-value","reject","unknown","bad-receipt","scope","read-missing"})using(var f=await Setup()){
            f.Handler.Publish(mode=="read-missing"?"limeiot_read":"limeiot_command",mode=="scope"?"outside":"lamp",mode=="bad-value"?JsonValue.Create(5):JsonValue.Create(true),mode=="slow"?1:120);
            if(mode=="scope"){await Fails(async()=>{await f.Client.ReceiveAsync(f.Reference,"chosen",f.Execution);});continue;}
            if(mode=="read-missing"){f.Handler.OmitLamp=true;Check((await f.Client.ReceiveAsync(f.Reference,"chosen",f.Execution))!.Outcome?.Success==false&&f.Handler.DevicePosts==0,"missing read is explicit failure");continue;}
            var p=(await f.Client.ReceiveAsync(f.Reference,"chosen",f.Execution))!;
            switch(mode){case "save":f.Store.FailJournal=true;break;case "readback":f.Store.LoseReadback=true;break;case "expired":f.Store.Expire();break;case "slow":f.Store.SlowIntent=true;break;case "cancelled":f.Handler.CancelSnapshot=true;break;case "read-only":f.Handler.ReadOnly=true;break;case "revision":f.Handler.ChangedRevision=true;break;case "unknown":f.Handler.Unknown=true;break;case "bad-receipt":f.Handler.WrongReceipt=true;break;}
            if(mode=="reject")Check((await f.Client.RejectAsync(p.Id,f.Reference,"chosen",f.Execution)).Outcome?.Success==false,"explicit rejection");
            else if(mode=="unknown"){
                var r=await f.Client.ConfirmAsync(p.Id,f.Reference,"chosen",f.Execution);Check(r.NeedsRecovery&&r.Outcome?.Success==false,"unknown cannot succeed");f.Store.Expire();Check(await f.Client.PruneExpiredAsync()==0,"unknown device retained");f.Handler.ConfirmOriginal();
                var later=await f.Client.RecoverCommandAsync(p.Id,f.Reference,"chosen",f.Execution);Check(later.CommandStatus=="confirmed"&&later.Outcome?.Success==false&&later.Outcome.Output["status"]!.GetValue<string>()=="unknown"&&f.Handler.ResultPosts==1,"later receipt cannot rewrite returned unknown");
            }else if(mode=="bad-receipt"){
                await Fails(async()=>{await f.Client.ConfirmAsync(p.Id,f.Reference,"chosen",f.Execution);},"invalid_response");Check((await f.Client.RecoverCommandAsync(p.Id,f.Reference,"chosen",f.Execution)).Delivered,"forged receipt only recovered from original");
            }else await Fails(async()=>{await f.Client.ConfirmAsync(p.Id,f.Reference,"chosen",f.Execution);},mode=="slow"?"agent_tool_call_expired":null);
            Check(f.Handler.DevicePosts==(mode is "unknown" or "bad-receipt"?1:0),"zero unintended write:"+mode);
            if(mode=="readback"){Check((await f.Client.RecordsAsync()).Single().Intent is not null,"readback failure preserves saved intent");f.Store.Expire();Check(await f.Client.PruneExpiredAsync()==0,"unknown saved intent retained");}
            if(mode=="expired")Check(await f.Client.PruneExpiredAsync()==1,"expired proposal cleanup");
            if(mode=="slow")Check((await f.Client.RecordsAsync()).Single().Intent is not null,"expiry crossed durable save boundary");
        }
        using(var f=await Setup()){
            f.Handler.Publish();var p=(await f.Client.ReceiveAsync(f.Reference,"chosen",f.Execution))!;f.Handler.CommandEntered=new(TaskCreationOptions.RunContinuationsAsynchronously);f.Handler.ReleaseCommand=new(TaskCreationOptions.RunContinuationsAsynchronously);
            var first=f.Client.ConfirmAsync(p.Id,f.Reference,"chosen",f.Execution);await f.Handler.CommandEntered.Task;var second=Fails(async()=>{await f.Client.ConfirmAsync(p.Id,f.Reference,"chosen",f.Execution);},"resolve_original_iot_command_first");f.Handler.ReleaseCommand.SetResult();await first;await second;Check(f.Handler.DevicePosts==1&&f.Handler.ResultPosts==1,"overlapping confirmations create one command");
        }
        Console.WriteLine("{\"agent_iot_checks\":true,\"shared_vectors\":57,\"explicit_confirmation\":true,\"overlapping_confirmation\":true,\"two_get_only_recoveries\":true,\"unknown_preserved\":true,\"native_ui\":false}");
    }
    private sealed class Store:ISessionStore {
        private readonly Dictionary<string,string> data=new();public bool FailJournal,LoseReadback,SlowIntent;private bool readbackPending;
        public Task<string?> LoadAsync(string scope,CancellationToken cancellation=default){if(scope.EndsWith("#limelink.agent-iot",StringComparison.Ordinal)&&readbackPending){readbackPending=false;return Task.FromResult<string?>(null);}return Task.FromResult(data.GetValueOrDefault(scope));}
        public async Task SaveAsync(string scope,string? value,CancellationToken cancellation=default){if(scope.EndsWith("#limelink.agent-iot",StringComparison.Ordinal)){if(FailJournal)throw new IOException("storage_unavailable");if(LoseReadback){LoseReadback=false;readbackPending=true;}}if(value is null)data.Remove(scope);else data[scope]=value;if(SlowIntent&&scope.EndsWith("#limelink.agent-iot",StringComparison.Ordinal)&&JsonNode.Parse(value!)!.AsArray().Any(r=>r?["Intent"]is not null)){SlowIntent=false;await Task.Delay(1200,cancellation);}}
        public void Expire(){foreach(var key in data.Keys.Where(k=>k.EndsWith("#limelink.agent-iot",StringComparison.Ordinal)).ToArray()){var rows=JsonNode.Parse(data[key])!.AsArray();foreach(var row in rows){row!["RunExpiresAt"]=1;row["Call"]!["ExpiresAt"]=0;}data[key]=rows.ToJsonString();}}
    }
    private sealed record Fixture(Store Store,Handler Handler,LinkClient Link,AgentClient Agent,AgentIoTClient Client,Device Execution,AgentReference Reference):IDisposable {public void Dispose()=>Link.Dispose();}
    private static async Task<Fixture> Setup(){var store=new Store();var handler=new Handler();var link=new LinkClient("https://gateway.example",store,handler);await link.Gateway.LoginAsync("fixture");var execution=(await link.SnapshotAsync("chosen")).Devices.First();var agent=new AgentClient(link,store);await agent.SubmitAsync("chosen",execution,"work","控制所选设备","read-only",iotDevices:["lamp"]);return new(store,handler,link,agent,new(link.Gateway,agent,store),execution,(await agent.ReferencesAsync()).Single());}
    private sealed class Handler:HttpMessageHandler {
        private static readonly string Revision="sha256:"+new string('a',64),LampRevision="sha256:"+new string('b',64);
        public int DevicePosts,ResultPosts;public bool LoseDevice,LoseReply,ReadOnly,ChangedRevision,Unknown,WrongReceipt,OmitLamp,CancelSnapshot;private bool missingDevice;private string run="";private JsonArray grant=[];private JsonObject? proposal;
        private readonly Dictionary<string,JsonObject> commands=new();private readonly HashSet<string> deviceKeys=[];public TaskCompletionSource? CommandEntered,ReleaseCommand;
        public void Publish(string tool="limeiot_command",string device="lamp",JsonNode? value=null,int ttl=120){var arguments=new JsonObject{{"device_id",device}};if(tool=="limeiot_command"){arguments["model_revision"]=LampRevision;arguments["path"]="light.power";arguments["value"]=value??JsonValue.Create(true);}proposal=new(){{"id",Guid.NewGuid().ToString()},{"tool",tool},{"arguments",arguments},{"expires_at",DateTimeOffset.UtcNow.ToUnixTimeSeconds()+ttl}};}
        public void ConfirmOriginal(){foreach(var key in deviceKeys){commands[key]["status"]="confirmed";commands[key]["evidence"]=new JsonObject{{"type","device_result"},{"reported",new JsonObject{{"light.power",true}}}};}}
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation){
            var path=request.RequestUri!.AbsolutePath;JsonObject body;var status=HttpStatusCode.OK;
            if(path.EndsWith("/auth/session",StringComparison.Ordinal))body=new(){{"csrf_token","fixture"}};
            else if(path.EndsWith("/capabilities",StringComparison.Ordinal)){
                var desktop=JsonNode.Parse(File.ReadAllText(Path.Combine(AgentChecks.Root,"contracts/desktop.json")))!;
                var model=new JsonObject{{"model_id","urn:fixture:lamp:1"},{"services",new JsonArray(new JsonObject{{"id","light"},{"properties",new JsonArray(new JsonObject{{"id","power"},{"schema",new JsonObject{{"type","boolean"}}},{"access",ReadOnly?new JsonArray("read"):new JsonArray("read","write")}})}})}};
                body=new(){{"models",new JsonObject{{Revision,desktop},{LampRevision,model},{"sha256:"+new string('c',64),model.DeepClone()}}}};
            }else if(path.EndsWith("/devices",StringComparison.Ordinal)){
                if(CancelSnapshot)throw new OperationCanceledException("cancelled_snapshot");var items=new JsonArray(new JsonObject{{"device_id","desktop"},{"model_revision",Revision},{"ready",true}});
                if(!OmitLamp)items.Add(new JsonObject{{"device_id","lamp"},{"model_revision",ChangedRevision?"sha256:"+new string('c',64):LampRevision},{"ready",true},{"reported",new JsonObject{{"light.power",new JsonObject{{"value",false},{"observed_at",DateTimeOffset.UtcNow.ToString("O")},{"quality","good"},{"source","fixture"}}}}}});body=new(){{"items",items}};
            }else if(request.Method==HttpMethod.Post){
                var key=request.Headers.GetValues("Idempotency-Key").Single();var input=JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellation))!.AsObject();input["space_id"]="chosen";input["idempotency_key"]=key;var operation=input["operation"]!.AsObject();JsonObject? evidence;var kind="";
                if(operation["path"]!.GetValue<string>()=="agent.exchange"){
                    var exchange=operation["value"]!;kind=exchange["kind"]!.GetValue<string>();var payload=JsonNode.Parse(exchange["payload"]!.GetValue<string>())!;JsonObject value;
                    switch(kind){
                        case "agent.submit":run=payload["id"]!.GetValue<string>();grant=(JsonArray)(payload["iot_devices"]?.DeepClone()??new JsonArray());value=new(){{"id",run},{"state","awaiting_approval"},{"workspace_id","work"},{"sandbox","read-only"},{"session_id",null},{"error",null},{"expires_at",DateTimeOffset.UtcNow.ToUnixTimeSeconds()+3600},{"events",new JsonArray()},{"cursor",0}};break;
                        case "agent.tool_capabilities":value=new(){{"enabled",true},{"tools",new JsonArray("limeiot_read","limeiot_command")},{"approval_required",true},{"max_devices",4}};break;
                        case "agent.tool_pending":value=new(){{"id",run},{"devices",grant.DeepClone()},{"calls",proposal is null?new JsonArray():new JsonArray(proposal.DeepClone())},{"expires_at",DateTimeOffset.UtcNow.ToUnixTimeSeconds()+3600}};break;
                        case "agent.tool_result":ResultPosts++;proposal=null;value=new(){{"id",run},{"call_id",payload["call_id"]!.DeepClone()},{"recorded",true}};break;
                        default:throw new Exception("unexpected fixture kind:"+kind);
                    }
                    evidence=new(){{"type","action_result"},{"path","agent.exchange"},{"input_digest","sha256:"+new string('e',64)},{"output",new JsonObject{{"response",new JsonObject{{"ok",true},{"value",value}}.ToJsonString()}}},{"completion","submitted"},{"observed_at",DateTimeOffset.UtcNow.ToString("O")}};
                }else{CommandEntered?.TrySetResult();if(ReleaseCommand is not null)await ReleaseCommand.Task.WaitAsync(cancellation);DevicePosts++;deviceKeys.Add(key);Check(operation["type"]!.GetValue<string>()=="property.set","SDK property operation");evidence=Unknown?null:new(){{"type","device_result"},{"reported",new JsonObject{{"light.power",operation["value"]!.DeepClone()}}}};}
                body=new(){{"command_id",Guid.NewGuid().ToString()},{"status",kind==""&&Unknown?"unknown":"confirmed"},{"request_digest","sha256:"+new string('d',64)},{"request",input},{"error",null},{"evidence",evidence}};commands[key]=(JsonObject)body.DeepClone();
                if(kind==""&&LoseDevice){LoseDevice=false;missingDevice=true;throw new HttpRequestException("lost_device_response");}
                if(kind=="agent.tool_result"&&LoseReply){LoseReply=false;throw new HttpRequestException("lost_reply_response");}
                if(kind==""&&WrongReceipt){WrongReceipt=false;body["evidence"]!["reported"]!["light.power"]=false;}
            }else{var key=Uri.UnescapeDataString(path.Split('/').Last());if(missingDevice&&deviceKeys.Contains(key)){missingDevice=false;status=HttpStatusCode.NotFound;body=new(){{"error",new JsonObject{{"code","command_not_found"}}}};}else body=(JsonObject)commands[key].DeepClone();}
            var response=new HttpResponseMessage(status){Content=new StringContent(body.ToJsonString(),Encoding.UTF8,"application/json")};response.Headers.TryAddWithoutValidation("Set-Cookie","__Host-limeiot_session="+new string('a',64)+"; Secure; HttpOnly");return response;
        }
    }
}
