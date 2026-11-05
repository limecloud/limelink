using LimeIoT.Client;
using LimeLink.Core;

static class CloudLiveChecks {
    public static async Task Run() {
        var origin=Environment.GetEnvironmentVariable("LIMELINK_CLOUD_CHECK_ORIGIN");if(origin is null)return;
        var store=new CloudStore();using var client=new CloudLinkClient(origin,store,development:true);
        await client.Control.BeginAuthorizationAsync();await client.Control.PollAuthorizationAsync();
        var snapshot=await client.SnapshotAsync("cloud-space");var device=snapshot.Devices.Single();var fingerprint=await client.FingerprintAsync(device.Id);
        try{await client.PerformAsync("cloud-space",device,"pair",new(){{"name","Windows"}});throw new InvalidOperationException("expected response loss");}catch(HttpRequestException){}
        using var recovered=new CloudLinkClient(origin,store,development:true);var records=await recovered.RecordsAsync();
        if(records.Count!=1||!records[0].Attempted)throw new InvalidOperationException("missing original");
        try{await recovered.ResolveAsync(records[0].Id);throw new InvalidOperationException("expected original 404");}catch(GatewayException error)when(error.Status==404){}
        if((await recovered.ResolveAsync(records[0].Id)).Result?.Status!="unknown")throw new InvalidOperationException("original unknown missing");
        await recovered.SnapshotAsync("cloud-space");if(await recovered.FingerprintAsync(device.Id)!=fingerprint)throw new InvalidOperationException("identity changed");
        await recovered.SnapshotAsync("another-space");
        try{await recovered.PerformAsync("another-space",device,"pair",new());throw new InvalidOperationException("expected original block");}catch(InvalidOperationException error)when(error.Message=="resolve_original_request_first"){}
    }
}
