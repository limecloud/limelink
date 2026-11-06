using System.Text.Json.Nodes;
using LimeIoT.Client;
using LimeLink.Core;

/// <summary>实际产品核心和隔离网关旅程；软件批准，不代表 WinUI 窗口或实物验收。</summary>
static class AgentIoTLiveChecks {
    private sealed class Store:ISessionStore {
        private readonly Dictionary<string,string> values=new();
        public Task<string?> LoadAsync(string scope,CancellationToken cancellation=default)=>Task.FromResult(values.GetValueOrDefault(scope));
        public Task SaveAsync(string scope,string? value,CancellationToken cancellation=default){if(value is null)values.Remove(scope);else values[scope]=value;return Task.CompletedTask;}
    }
    private sealed class LostResponseHandler:HttpMessageHandler {
        private readonly HttpMessageInvoker inner=new(new HttpClientHandler{AllowAutoRedirect=false,UseCookies=false});public bool LostDevice,LostReply;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellation){
            var response=await inner.SendAsync(request,cancellation);
            if(request.Method==HttpMethod.Post&&request.RequestUri!.AbsolutePath.EndsWith("/commands",StringComparison.Ordinal)){
                var operation=JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellation))!["operation"]!;
                if(operation["type"]!.GetValue<string>()=="property.set"&&!LostDevice){LostDevice=true;response.Dispose();throw new HttpRequestException("lost_device_response");}
                var exchange=operation["value"]as JsonObject;
                if(exchange?["kind"]?.GetValue<string>()=="agent.tool_result"&&JsonNode.Parse(exchange["payload"]!.GetValue<string>())?["output"]?["status"]?.GetValue<string>()=="confirmed"&&!LostReply){LostReply=true;response.Dispose();throw new HttpRequestException("lost_reply_response");}
            }
            return response;
        }
        protected override void Dispose(bool disposing){if(disposing)inner.Dispose();base.Dispose(disposing);}
    }
    private static void Check(bool condition,string message){if(!condition)throw new Exception(message);}
    internal static async Task Run(string endpoint){
        using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(190));var cancellation=deadline.Token;var store=new Store();var transport=new LostResponseHandler();using var link=new LinkClient(endpoint,store,transport,development:true);
        await link.Gateway.LoginAsync(Environment.GetEnvironmentVariable("LIMELINK_AGENT_CHECK_TOKEN")??"",cancellation);var snapshot=await link.SnapshotAsync("space-demo",cancellation);var execution=snapshot.Devices.Single(d=>d.Id=="device-lamp");Check(snapshot.Devices.Any(d=>d.Id=="device-button"),"independent device missing");
        var pair=await link.PerformAsync("space-demo",execution,"pair",new(){{"name",".NET 设备工具验收"}},cancellation);
        for(var i=0;i<20&&pair.Status is "accepted" or "dispatched";i++){await Task.Delay(200,cancellation);pair=await link.ResolveAsync(cancellation);}Check(LinkClient.Response(pair)?["ok"]?.GetValue<bool>()==true,"pair failed");Check(await link.FinishSuccessfulPairingAsync(cancellation),"pair not resolved");await Task.Delay(300,cancellation);
        var agent=new AgentClient(link,store);Check((await agent.DiscoverToolsAsync("space-demo",execution,cancellation)).Enabled,"tools disabled");
        var real=Environment.GetEnvironmentVariable("LIMELINK_AGENT_CHECK_REAL")=="1";
        var prompt=real?"Use limeiot_read for device-button exactly once. Then propose limeiot_command for light.power=true using its returned model_revision. Wait for client confirmation. Do not use other tools, files or external resources. After the device tool returns confirmed, reply exactly LIMELINK_IOT_DEVICE_OK.":"iot-live";
        var run=await agent.SubmitAsync("space-demo",execution,"work",prompt,"read-only",cancellation:cancellation,iotDevices:["device-button"]);Check(run.State=="awaiting_approval","local approval missing");var reference=(await agent.ReferencesAsync(cancellation)).Single(r=>r.Id==run.Id);Check(reference.Devices.SequenceEqual(["device-button"]),"scope missing");
        var tools=new AgentIoTClient(link.Gateway,agent,store);var events=new SortedDictionary<int,AgentEvent>();AgentToolRecord? proposal=null;
        for(var i=0;i<300&&proposal is null;i++){
            await Task.Delay(250,cancellation);run=await agent.QueryAsync(reference,"space-demo",execution,run.Cursor,cancellation:cancellation);foreach(var e in run.Events)events[e.Seq]=e;Check(run.State is not ("failed" or "unknown" or "succeeded"),"proposal missing:"+run.State+":"+run.Error);
            if(run.State=="running")await tools.ReceiveAsync(reference,"space-demo",execution,cancellation);proposal=(await tools.RecordsAsync(cancellation)).SingleOrDefault(r=>r.CanConfirm);
        }
        Check(proposal is not null&&proposal.Intent is null,"proposal timeout");Check((await tools.RecordsAsync(cancellation)).Any(r=>!r.Call.IsWrite&&r.Delivered&&r.Outcome?.Success==true),"read not completed");
        var gate=Environment.GetEnvironmentVariable("LIMELINK_AGENT_IOT_APPROVAL_FILE")??throw new Exception("approval gate missing");await File.WriteAllTextAsync(gate,"awaiting-client-confirmation",cancellation);using(var confirmation=new CancellationTokenSource(TimeSpan.FromSeconds(10))){while(await File.ReadAllTextAsync(gate,confirmation.Token)!="confirm")await Task.Delay(50,confirmation.Token);}
        try{await tools.ConfirmAsync(proposal!.Id,reference,"space-demo",execution,cancellation);throw new Exception("device loss not injected");}catch(HttpRequestException e)when(e.Message=="lost_device_response"){}Check(transport.LostDevice&&!transport.LostReply,"first recovery boundary");
        var restored=new AgentIoTClient(link.Gateway,agent,store);
        try{await restored.RecoverCommandAsync(proposal!.Id,reference,"space-demo",execution,cancellation);throw new Exception("reply loss not injected");}catch(HttpRequestException e)when(e.Message=="lost_reply_response"){}Check(transport.LostReply&&await link.PendingAsync(cancellation)is not null,"second recovery boundary");await agent.RecoverAsync(cancellation);
        Check((await restored.SendResultAsync(proposal!.Id,reference,"space-demo",execution,cancellation)).Delivered,"original reply recovery");var record=(await restored.RecordsAsync(cancellation)).Single(r=>r.Id==proposal.Id);Check(record.CommandStatus=="confirmed"&&record.Outcome?.Success==true,"device not confirmed");
        for(var i=0;i<240&&run.State is not ("succeeded" or "failed" or "unknown");i++){await Task.Delay(250,cancellation);run=await agent.QueryAsync(reference,"space-demo",execution,run.Cursor,cancellation:cancellation);foreach(var e in run.Events)events[e.Seq]=e;}Check(run.State=="succeeded","run failed:"+run.State+":"+run.Error);
        while(run.Events.Count==4){run=await agent.QueryAsync(reference,"space-demo",execution,run.Cursor,cancellation:cancellation);foreach(var e in run.Events)events[e.Seq]=e;}Check(events.Values.Last(e=>e.Kind=="message").Text.Trim()=="LIMELINK_IOT_DEVICE_OK","final reply");
        try{await restored.ReceiveAsync(reference,"other-space",execution,cancellation);throw new Exception("space isolation missing");}catch(InvalidOperationException e)when(e.Message=="agent_target_changed"){}
        Console.WriteLine("{\"passed\":true,\"product_client\":\"dotnet\",\"real_gateway\":true,\"explicit_write_confirmation\":true,\"lost_device_response\":true,\"lost_reply_response\":true,\"original_recovery\":true,\"native_ui\":false,\"physical_device\":false}");
    }
}
