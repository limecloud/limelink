using System.Text.Json;
using System.Text.Json.Nodes;
using LimeIoT.Client;

namespace LimeLink.Core;

public sealed record CloudLinkSnapshot(string Space,string Principal,ControlGateway Gateway,IReadOnlyList<Device> Devices,JsonObject Models);

/// <summary>消费 IoT 正式云合同；产品只拥有目标选择与按本地空间绑定的协同签名。</summary>
public sealed class CloudLinkClient:IDisposable {
    public ControlClient Control {get;}
    private readonly ISessionStore storage;
    private readonly SemaphoreSlim gate=new(1,1);
    private CloudLinkSnapshot? selected;
    public CloudLinkClient(string origin,ISessionStore storage,HttpMessageHandler? transport=null,bool development=false){this.storage=storage;Control=new(origin,storage,transport,development);}
    public async Task<CloudLinkSnapshot> SnapshotAsync(string space,CancellationToken cancellation=default) {
        var session=await Control.RestoreSessionAsync(cancellation);
        var gateways=(await Control.GatewaysAsync(space,cancellation)).Where(g=>g.Active).ToArray();
        if(gateways.Length!=1)throw new InvalidOperationException("select_single_active_gateway");var gateway=gateways[0];
        if(gateway.SpaceId!=space||gateway.PrincipalId!=session.Principal.PrincipalId||!gateway.Scopes.Contains("devices.read")||!gateway.Scopes.Contains("commands.write"))throw new InvalidOperationException("gateway_scope_mismatch");
        List<Device> devices=[];HashSet<string> cursors=[];string? after=null;
        do {
            cancellation.ThrowIfCancellationRequested();var page=await Control.DevicesAsync(space,after,cancellation);
            if(page.BindingRevision!=gateway.Revision||devices.Count+page.Items.Count>1024)throw new InvalidOperationException("gateway_binding_changed");
            devices.AddRange(page.Items);after=page.Next;
            if(after is not null&&(cursors.Count>=128||!cursors.Add(after)))throw new InvalidOperationException("invalid_device_cursor");
        }while(after is not null);
        if(devices.Select(d=>d.Id).Distinct().Count()!=devices.Count)throw new InvalidOperationException("duplicate_remote_device");
        var models=new JsonObject();foreach(var revision in devices.Select(d=>d.ModelRevision).Distinct())models[revision]=(await Control.ModelAsync(space,revision,cancellation)).DeepClone();
        var latest=(await Control.GatewaysAsync(space,cancellation)).Where(g=>g.Active).ToArray();
        if(latest.Length!=1||latest[0].GatewayId!=gateway.GatewayId||latest[0].Revision!=gateway.Revision||latest[0].LocalSpaceId!=gateway.LocalSpaceId||latest[0].PrincipalId!=gateway.PrincipalId)throw new InvalidOperationException("gateway_binding_changed");
        selected=new(space,session.Principal.PrincipalId,gateway,devices,models);return selected;
    }
    private async Task<LinkIdentity> Identity(CloudLinkSnapshot snapshot,string device,CancellationToken cancellation) {
        var principal=(await Control.RestoreSessionAsync(cancellation)).Principal.PrincipalId;
        if(principal!=snapshot.Principal)throw new InvalidOperationException("cloud_identity_changed");
        var tuple=JsonSerializer.Serialize(new[]{Control.Origin,principal,snapshot.Space,snapshot.Gateway.GatewayId,snapshot.Gateway.LocalSpaceId,device});
        var scope=Control.Origin+"#limelink.cloud.identity:"+LinkIdentity.Hash(tuple);var saved=await storage.LoadAsync(scope,cancellation);
        if(saved is not null)return JsonSerializer.Deserialize<LinkIdentity>(saved)??throw new InvalidOperationException("identity_corrupt");
        var identity=LinkIdentity.Create();var data=JsonSerializer.Serialize(identity);await storage.SaveAsync(scope,data,cancellation);
        if(await storage.LoadAsync(scope,cancellation)!=data)throw new InvalidOperationException("identity_not_durable");return identity;
    }
    public async Task<string> FingerprintAsync(string device,CancellationToken cancellation=default)=>(await Identity(selected??throw new InvalidOperationException("refresh_target_required"),device,cancellation)).Fingerprint;
    public async Task<IReadOnlyList<ControlCommandRecord>> RecordsAsync(CancellationToken cancellation=default)=>(await Control.CommandRecordsAsync(cancellation:cancellation)).Where(r=>r.Reference.Request.Operation["type"]?.ToString()=="action.invoke"&&r.Reference.Request.Operation["path"]?.ToString()=="link.exchange").ToArray();
    public async Task<ControlCommandRecord> PerformAsync(string space,Device device,string kind,JsonObject payload,CancellationToken cancellation=default) {
        if(!await gate.WaitAsync(0,cancellation))throw new InvalidOperationException("request_in_progress");
        try {
            var previous=selected;if(previous?.Space!=space||!device.Ready)throw new InvalidOperationException("refresh_target_required");
            if((await RecordsAsync(cancellation)).Any(r=>r.IsPrepared||!r.CanForget))throw new InvalidOperationException("resolve_original_request_first");
            var snapshot=await SnapshotAsync(space,cancellation);
            if(snapshot.Principal!=previous.Principal||snapshot.Gateway.GatewayId!=previous.Gateway.GatewayId||snapshot.Gateway.Revision!=previous.Gateway.Revision||snapshot.Gateway.LocalSpaceId!=previous.Gateway.LocalSpaceId)throw new InvalidOperationException("gateway_binding_changed");
            var current=snapshot.Devices.SingleOrDefault(d=>d.Id==device.Id&&d.Ready&&d.ModelRevision==device.ModelRevision)??throw new InvalidOperationException("target_changed");
            if(snapshot.Models[current.ModelRevision]?["model_id"]?.ToString()!="urn:limelink:model:desktop:1")throw new InvalidOperationException("target_capability_changed");
            var identity=await Identity(snapshot,current.Id,cancellation);
            var input=identity.Exchange(snapshot.Gateway.LocalSpaceId,current.Id,current.ModelRevision,kind,payload.ToJsonString());
            var record=await Control.PrepareCommandAsync(space,snapshot.Gateway,current,"link.exchange",input,"action.invoke",cancellation);
            cancellation.ThrowIfCancellationRequested();return await Control.SubmitCommandAsync(record.Id,cancellation);
        }finally{gate.Release();}
    }
    public Task<ControlCommandRecord> ResolveAsync(string key,bool reconcile=false,CancellationToken cancellation=default)=>Control.ResolveCommandAsync(key,reconcile,cancellation);
    public Task ForgetAsync(string key,CancellationToken cancellation=default)=>Control.ForgetCommandAsync(key,cancellation);
    public async Task LogoutAsync(CancellationToken cancellation=default){await Control.LogoutAsync(cancellation);selected=null;}
    public static JsonObject? Response(ControlCommandRecord record)=>record.Result?.Status=="confirmed"&&record.Result.LocalResult?["evidence"]?["output"]?["response"] is JsonValue value?JsonNode.Parse(value.GetValue<string>())?.AsObject():null;
    public void Dispose(){Control.Dispose();gate.Dispose();}
}
