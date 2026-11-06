using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LimeIoT.Client;
using LimeLink.Core;

static class AgentChecks {
    internal static string Root=>FindRoot();
    private static string FindRoot(){for(var p=new DirectoryInfo(AppContext.BaseDirectory);p is not null;p=p.Parent)if(File.Exists(Path.Combine(p.FullName,"contracts/desktop.json")))return p.FullName;throw new IOException("repository_root_missing");}
    private static void Check(bool value,string message){if(!value)throw new Exception(message);}
    private static async Task Fails(Func<Task> action,string message){try{await action();}catch(Exception e)when(e.Message==message){return;}throw new Exception("expected:"+message);}
    internal static async Task Run(){
        var vectors=JsonNode.Parse(File.ReadAllText(Path.Combine(Root,"contracts/fixtures/agent-responses.json")))!["cases"]!.AsArray();
        foreach(var item in vectors){var accepted=false;try{var value=item!["value"]!.AsObject();if(item["kind"]!.GetValue<string>()=="run")_=AgentProtocol.Run(value,item["id"]!.GetValue<string>(),item["after"]!.GetValue<int>());else _=AgentProtocol.Capabilities(value);accepted=true;}catch(InvalidOperationException){}Check(accepted==item!["valid"]!.GetValue<bool>(),"shared vector:"+item["name"]);}
        var store=new Store();var handler=new Handler();using var link=new LinkClient("https://gateway.example",store,handler);
        await link.Gateway.LoginAsync("fixture");var device=(await link.SnapshotAsync("chosen")).Devices[0];var client=new AgentClient(link,store);
        await Fails(async()=>{await link.PerformAsync("chosen",device,"agent.submit",new());},"invalid_exchange_path");
        Check((await client.DiscoverAsync("chosen",device)).Workspaces.Count==1,"capabilities");
        var run=await client.SubmitAsync("chosen",device,"work","一次任务","read-only");Check(run.State=="awaiting_approval","receipt not completion");
        var reference=(await client.ReferencesAsync())[0];await client.QueryAsync(reference,"chosen",device);
        var before=handler.Posts;await Fails(async()=>{await client.QueryAsync(reference,"other",device);},"agent_target_changed");Check(before==handler.Posts,"space mismatch zero POST");
        handler.Lose=true;await Fails(async()=>{await client.SubmitAsync("chosen",device,"work","原任务恢复","read-only");},"lost_response");
        before=handler.Posts;var restored=new AgentClient(link,store);
        try{await restored.RecoverAsync();throw new Exception("404 expected");}catch(GatewayException e)when(e.Status==404){}
        Check(await link.PendingAsync() is not null,"404 keeps original");Check((await restored.RecoverAsync())?.State=="awaiting_approval"&&handler.Posts==before&&await link.PendingAsync() is null,"GET-only recovery");
        store.FailReferences=true;await Fails(async()=>{await client.SubmitAsync("chosen",device,"work","保存失败","read-only");},"storage_unavailable");Check(handler.Posts==before,"reference persistence before POST");store.FailReferences=false;
        handler.Missing=true;await Fails(async()=>{await client.DiscoverAsync("chosen",device);},"target_capability_changed");Check(handler.Posts==before,"fresh action required");handler.Missing=false;
        handler.Malformed=true;await Fails(async()=>{await client.SubmitAsync("chosen",device,"work","校验任务","read-only");},"invalid_agent_response");Check(await link.PendingAsync() is not null,"malformed keeps original");
        Console.WriteLine("{\"agent_checks\":true,\"shared_vectors\":"+vectors.Count+",\"recovery_get_only\":true,\"reference_storage_failure\":true,\"target_isolation\":true,\"native_ui\":false}");
    }
    private sealed class Store:ISessionStore {
        private readonly Dictionary<string,string> data=new();public bool FailReferences;
        public Task<string?> LoadAsync(string scope,CancellationToken cancellation=default)=>Task.FromResult(data.GetValueOrDefault(scope));
        public Task SaveAsync(string scope,string? value,CancellationToken cancellation=default){if(FailReferences&&scope.EndsWith("#limelink.agent-runs",StringComparison.Ordinal))throw new IOException("storage_unavailable");if(value is null)data.Remove(scope);else data[scope]=value;return Task.CompletedTask;}
    }
    private sealed class Handler:HttpMessageHandler {
        public int Posts;public bool Lose,Malformed,Missing;private bool missingOnce;private JsonObject? last;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation){
            var path=request.RequestUri!.AbsolutePath;JsonObject body;var status=HttpStatusCode.OK;
            if(path.EndsWith("/auth/session",StringComparison.Ordinal))body=new(){{"authenticated",true},{"csrf_token","fixture"}};
            else if(path.EndsWith("/capabilities",StringComparison.Ordinal)){
                var model=JsonNode.Parse(File.ReadAllText(Path.Combine(Root,"contracts/desktop.json")))!.AsObject();if(Missing)model["services"]=new JsonArray();body=new(){{"models",new JsonObject{{"sha256:fixture",model}}}};
            }else if(path.EndsWith("/devices",StringComparison.Ordinal))body=new(){{"items",new JsonArray(new JsonObject{{"device_id","desktop"},{"model_revision","sha256:fixture"},{"ready",true}})}};
            else if(request.Method==HttpMethod.Post){
                Posts++;var input=JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellation))!.AsObject();input["space_id"]="chosen";input["idempotency_key"]=request.Headers.GetValues("Idempotency-Key").Single();
                Check(input["operation"]!["path"]!.GetValue<string>()=="agent.exchange","independent action");var exchange=input["operation"]!["value"]!;var kind=exchange["kind"]!.GetValue<string>();var payload=JsonNode.Parse(exchange["payload"]!.GetValue<string>())!;
                JsonObject value=kind=="agent.capabilities"?new(){{"adapter","codex-app-server"},{"configured",true},{"authentication","managed_by_codex"},{"local_approval_required",true},{"workspaces",new JsonArray(new JsonObject{{"id","work"},{"name","工作目录"},{"allow_write",false}})}}:new(){{"id",Malformed?Guid.NewGuid().ToString():payload["id"]!.GetValue<string>()},{"state","awaiting_approval"},{"workspace_id","work"},{"sandbox","read-only"},{"session_id",null},{"error",null},{"expires_at",2000000000},{"events",new JsonArray()},{"cursor",payload["after"]?.GetValue<int>()??0}};
                body=new(){{"command_id",Guid.NewGuid().ToString()},{"status","confirmed"},{"request_digest","sha256:"+new string('b',64)},{"request",input},{"error",null},{"evidence",new JsonObject{{"type","action_result"},{"path","agent.exchange"},{"input_digest","sha256:"+new string('c',64)},{"output",new JsonObject{{"response",new JsonObject{{"ok",true},{"value",value}}.ToJsonString()}}},{"completion","submitted"},{"observed_at",DateTimeOffset.UtcNow.ToString("O")}}}};last=(JsonObject)body.DeepClone();
                if(Lose&&kind=="agent.submit"){Lose=false;missingOnce=true;throw new HttpRequestException("lost_response");}
            }else if(missingOnce){missingOnce=false;status=HttpStatusCode.NotFound;body=new(){{"error",new JsonObject{{"code","command_not_found"}}}};}
            else body=(JsonObject)last!.DeepClone();
            var response=new HttpResponseMessage(status){Content=new StringContent(body.ToJsonString(),Encoding.UTF8,"application/json")};response.Headers.TryAddWithoutValidation("Set-Cookie","__Host-limeiot_session="+new string('a',64)+"; Secure; HttpOnly");return response;
        }
    }
}
