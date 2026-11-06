using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LimeIoT.Client;
using LimeLink.Core;

static class PairingReceiptChecks {
    private enum Outcome { Confirmed,Delayed,Rejected,Unknown,Failed,Lost,NotFound,Changed,StringOk }
    private static void Check(bool value,string message){if(!value)throw new Exception(message);}
    internal static async Task Run(){
        foreach(var outcome in Enum.GetValues<Outcome>()){
            var store=new Store();var handler=new Handler(outcome);using var link=new LinkClient("https://gateway.example",store,handler);
            await link.Gateway.LoginAsync("fixture");var device=(await link.SnapshotAsync("chosen")).Devices.Single();
            try{var command=await link.PerformAsync("chosen",device,"pair",new(){{"name","测试手机"}});Check(outcome!=Outcome.Lost,"expected response loss");if(command.Status=="accepted"&&outcome==Outcome.Delayed)Check((await link.ResolveAsync()).Status=="confirmed","delayed receipt");}
            catch(HttpRequestException){Check(outcome==Outcome.Lost,"unexpected transport loss");}
            var original=await link.PendingAsync();var successful=outcome is Outcome.Confirmed or Outcome.Delayed;
            if(outcome==Outcome.NotFound){try{await link.FinishSuccessfulPairingAsync();throw new Exception("expected 404");}catch(GatewayException e)when(e.Status==404){}}
            else if(outcome!=Outcome.Lost)Check(await link.FinishSuccessfulPairingAsync()==successful,"pairing outcome:"+outcome);
            Check(handler.Posts==1,"one pairing POST");
            if(successful){
                Check(await link.PendingAsync() is null,"successful pairing unblocks next task");
                await link.PerformAsync("chosen",device,"card",new(){{"text","配对后继续"}});var before=handler.Queries;
                Check(!await link.FinishSuccessfulPairingAsync()&&await link.PendingAsync() is not null&&handler.Queries==before,"card remains without automatic query");
            }else Check(JsonSerializer.Serialize(await link.PendingAsync())==JsonSerializer.Serialize(original),"unresolved pairing retained");
            try{await link.PerformAsync("chosen",device,"card",new());throw new Exception("unresolved original accepted");}catch(InvalidOperationException e)when(e.Message=="resolve_original_request_first"){}
            Check(handler.Posts==(successful?2:1),"no duplicate POST");
        }
        foreach(var cancel in new[]{false,true}){
            var store=new Store();using var cancellation=new CancellationTokenSource();var handler=new Handler(Outcome.Confirmed);using var link=new LinkClient("https://gateway.example",store,handler);
            await link.Gateway.LoginAsync("fixture");var device=(await link.SnapshotAsync("chosen")).Devices.Single();
            await link.PerformAsync("chosen",device,"pair",new(){{"name","测试手机"}});var original=await link.PendingAsync();
            if(cancel){handler.CancelQuery=cancellation;try{await link.FinishSuccessfulPairingAsync(cancellation.Token);throw new Exception("cancellation ignored");}catch(OperationCanceledException){}}
            else{store.FailClear=true;try{await link.FinishSuccessfulPairingAsync();throw new Exception("clear failure ignored");}catch(IOException){}}
            Check(JsonSerializer.Serialize(await link.PendingAsync())==JsonSerializer.Serialize(original)&&handler.Posts==1,"failed clear or cancellation preserves original");
        }
        Console.WriteLine("{\"pairing_receipt_checks\":true,\"outcomes\":11,\"original_get_only\":true,\"next_task_unblocked\":true,\"native_ui\":false}");
    }
    private sealed class Store:ISessionStore {
        private readonly Dictionary<string,string> values=new();public bool FailClear;
        public Task<string?> LoadAsync(string scope,CancellationToken cancellation=default)=>Task.FromResult(values.GetValueOrDefault(scope));
        public Task SaveAsync(string scope,string? value,CancellationToken cancellation=default){cancellation.ThrowIfCancellationRequested();if(FailClear&&value is null)throw new IOException("clear_failed");if(value is null)values.Remove(scope);else values[scope]=value;return Task.CompletedTask;}
    }
    private sealed class Handler(Outcome outcome):HttpMessageHandler {
        public int Posts,Queries;public CancellationTokenSource? CancelQuery;
        private JsonObject? original;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation){
            var path=request.RequestUri!.AbsolutePath;JsonObject body;var status=HttpStatusCode.OK;
            if(path.EndsWith("/auth/session",StringComparison.Ordinal))body=new(){{"authenticated",true},{"csrf_token","fixture"}};
            else if(path.EndsWith("/capabilities",StringComparison.Ordinal))body=new(){{"models",new JsonObject{{"sha256:fixture",JsonNode.Parse(File.ReadAllText(Path.Combine(AgentChecks.Root,"contracts/desktop.json")))}}}};
            else if(path.EndsWith("/devices",StringComparison.Ordinal))body=new(){{"items",new JsonArray(new JsonObject{{"device_id","desktop"},{"model_revision","sha256:fixture"},{"ready",true}})}};
            else if(path.EndsWith("/commands",StringComparison.Ordinal)&&request.Method==HttpMethod.Post){
                Posts++;original=JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellation))!.AsObject();original["space_id"]="chosen";original["idempotency_key"]=request.Headers.GetValues("Idempotency-Key").Single();
                if(outcome==Outcome.Lost)throw new HttpRequestException("lost_response");body=Receipt(false);
            }else{
                Queries++;Check(path.EndsWith(original!["idempotency_key"]!.GetValue<string>(),StringComparison.Ordinal),"query original key");CancelQuery?.Cancel();
                if(outcome==Outcome.NotFound){status=HttpStatusCode.NotFound;body=new(){{"error",new JsonObject{{"code","command_not_found"}}}};}else body=Receipt(true);
            }
            var response=new HttpResponseMessage(status){Content=new StringContent(body.ToJsonString(),Encoding.UTF8,"application/json")};response.Headers.TryAddWithoutValidation("Set-Cookie","__Host-limeiot_session="+new string('a',64)+"; Secure; HttpOnly");return response;
        }
        private JsonObject Receipt(bool queried){
            var state=!queried&&outcome is Outcome.Delayed or Outcome.NotFound?"accepted":outcome==Outcome.Unknown||queried&&outcome==Outcome.Changed?"unknown":outcome==Outcome.Failed?"failed":"confirmed";
            var response=new JsonObject{{"ok",outcome==Outcome.StringOk?JsonValue.Create("true"):JsonValue.Create(outcome!=Outcome.Rejected)},{"value",new JsonObject{{"state","pending"}}}};
            return new(){{"command_id","pair-"+Posts},{"status",state},{"request_digest","sha256:"+new string('b',64)},{"request",original!.DeepClone()},{"error",null},{"evidence",state!="confirmed"?null:new JsonObject{{"type","action_result"},{"path","link.exchange"},{"input_digest","sha256:"+new string('c',64)},{"output",new JsonObject{{"response",response.ToJsonString()}}},{"completion","submitted"},{"observed_at",DateTimeOffset.UtcNow.ToString("O")}}}};
        }
    }
}
