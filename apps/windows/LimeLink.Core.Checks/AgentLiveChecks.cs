using System.Text.Json.Nodes;
using LimeIoT.Client;
using LimeLink.Core;

static class AgentLiveChecks {
    private sealed class Store:ISessionStore {
        private readonly Dictionary<string,string> values=new();
        public Task<string?> LoadAsync(string scope,CancellationToken cancellation=default)=>Task.FromResult(values.GetValueOrDefault(scope));
        public Task SaveAsync(string scope,string? value,CancellationToken cancellation=default){if(value is null)values.Remove(scope);else values[scope]=value;return Task.CompletedTask;}
    }
    private static void Check(bool value,string message){if(!value)throw new Exception(message);}
    internal static async Task Run(string endpoint){
        using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(140));var cancellation=deadline.Token;var store=new Store();using var link=new LinkClient(endpoint,store,development:true);
        await link.Gateway.LoginAsync(Environment.GetEnvironmentVariable("LIMELINK_AGENT_CHECK_TOKEN")??"",cancellation);
        var snapshot=await link.SnapshotAsync("space-demo",cancellation);var device=snapshot.Devices.Single(d=>d.Id=="device-lamp");
        var pair=await link.PerformAsync("space-demo",device,"pair",new JsonObject{{"name",".NET Agent 验收"}},cancellation);
        for(var i=0;i<20&&pair.Status is "accepted" or "dispatched";i++){await Task.Delay(200,cancellation);pair=await link.ResolveAsync(cancellation);}
        Check(LinkClient.Response(pair)?["ok"]?.GetValue<bool>()==true,"live_pair_failed");Check(await link.FinishSuccessfulPairingAsync(cancellation),"live_pair_not_resolved");await Task.Delay(300,cancellation);
        var client=new AgentClient(link,store);Check((await client.DiscoverAsync("space-demo",device,cancellation)).Workspaces.Single().Id=="work","live_workspace_missing");
        var real=Environment.GetEnvironmentVariable("LIMELINK_AGENT_CHECK_REAL")=="1";var expected=real?"LIMELINK_AGENT_OK":string.Concat(Enumerable.Repeat("真实协议夹具",100));
        var prompt=real?"Reply with exactly LIMELINK_AGENT_OK. Do not use tools, read files, or access any external resource.":"normal";
        AgentReference? resume=null;string? session=null;
        for(var index=0;index<2;index++){
            var run=await client.SubmitAsync("space-demo",device,"work",prompt,"read-only",resume,cancellation);Check(run.State=="awaiting_approval","receipt_not_queued");
            var reference=(await client.ReferencesAsync(cancellation)).Single(r=>r.Id==run.Id);var events=new SortedDictionary<int,AgentEvent>();
            for(var i=0;i<200;i++){
                await Task.Delay(250,cancellation);run=await client.QueryAsync(reference,"space-demo",device,run.Cursor,cancellation:cancellation);foreach(var e in run.Events)events[e.Seq]=e;
                if(run.State is "succeeded" or "failed" or "unknown")break;
            }
            Check(run.State=="succeeded","live_agent_failed:"+run.State+":"+run.Error);
            while(run.Events.Count==4){run=await client.QueryAsync(reference,"space-demo",device,run.Cursor,cancellation:cancellation);foreach(var e in run.Events)events[e.Seq]=e;}
            Check(string.Concat(events.Values.Where(e=>e.Kind=="message").Select(e=>e.Text)).Trim()==expected,"live_reply_mismatch");
            if(index==0)session=run.SessionId;else Check(session is not null&&session==run.SessionId,"live_session_mismatch");resume=reference;
        }
        try{await client.QueryAsync(resume!,"different-space",device,cancellation:cancellation);throw new Exception("space_leak");}catch(InvalidOperationException e)when(e.Message=="agent_target_changed"){}
        Console.WriteLine("{\"passed\":true,\"product_client\":\"dotnet\",\"real_gateway\":true,\"submit_query_reply\":true,\"explicit_resume\":true,\"space_isolation\":true,\"native_window\":false}");
    }
}
