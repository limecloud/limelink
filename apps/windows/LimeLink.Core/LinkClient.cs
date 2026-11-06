using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LimeIoT.Client;

namespace LimeLink.Core;

public sealed record LinkIdentity(string Id,string PrivateKey,string PublicKey) {
    public static LinkIdentity Create(){using var key=ECDsa.Create(ECCurve.NamedCurves.nistP256);var parameters=key.ExportParameters(false);return new(Guid.NewGuid().ToString(),Convert.ToBase64String(key.ExportPkcs8PrivateKey()),Convert.ToHexStringLower([4,..parameters.Q.X!,..parameters.Q.Y!]));}
    public static string Hash(string text)=>Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    public string Fingerprint=>Hash(PublicKey);
    public JsonObject Exchange(string space,string device,string revision,string kind,string payload,DateTimeOffset? now=null){
        if(Encoding.UTF8.GetByteCount(payload)>4096)throw new InvalidOperationException("payload_too_large");
        var nonce=Guid.NewGuid().ToString();var expires=(now??DateTimeOffset.UtcNow).ToUnixTimeSeconds()+20;
        var message=string.Join('\n',"limelink.exchange/v1",space,device,revision,Id,kind,nonce,expires.ToString(System.Globalization.CultureInfo.InvariantCulture),Hash(payload));
        using var key=ECDsa.Create();key.ImportPkcs8PrivateKey(Convert.FromBase64String(PrivateKey),out _);
        var signature=key.SignData(Encoding.UTF8.GetBytes(message),HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence);
        return new JsonObject{{"client_id",Id},{"public_key",PublicKey},{"kind",kind},{"nonce",nonce},{"expires_at",expires},{"payload",payload},{"signature",Convert.ToHexStringLower(signature)}};
    }
}
public sealed record PendingAction(string Origin,string Space,CommandIntent Intent);
public sealed class LinkClient:IDisposable {
    public GatewayClient Gateway {get;}
    private readonly ISessionStore storage;
    private readonly SemaphoreSlim gate=new(1,1);
    private string? space;
    private string Scope=>Gateway.Origin+"#limelink.pending";
    public LinkClient(string origin,ISessionStore storage,HttpMessageHandler? transport=null,bool development=false){this.storage=storage;Gateway=new(origin,storage,transport,development);}
    public async Task<Snapshot> SnapshotAsync(string selected,CancellationToken cancellation=default){var snapshot=await Gateway.SnapshotAsync(selected,cancellation);space=selected;return snapshot;}
    public async Task<PendingAction?> PendingAsync(CancellationToken cancellation=default){var data=await storage.LoadAsync(Scope,cancellation);if(data is null)return null;var pending=JsonSerializer.Deserialize<PendingAction>(data)??throw new InvalidOperationException("pending_corrupt");if(pending.Origin!=Gateway.Origin)throw new InvalidOperationException("pending_origin_mismatch");return pending;}
    private async Task<LinkIdentity> IdentityAsync(string space,string device,CancellationToken cancellation){
        var scope=Gateway.Origin+"#limelink.identity:"+space+":"+device;var old=await storage.LoadAsync(scope,cancellation);
        if(old is not null)return JsonSerializer.Deserialize<LinkIdentity>(old)??throw new InvalidOperationException("identity_corrupt");
        var identity=LinkIdentity.Create();var data=JsonSerializer.Serialize(identity);await storage.SaveAsync(scope,data,cancellation);if(await storage.LoadAsync(scope,cancellation)!=data)throw new InvalidOperationException("identity_not_durable");return identity;
    }
    public async Task<string> FingerprintAsync(string space,string device,CancellationToken cancellation=default)=>(await IdentityAsync(space,device,cancellation)).Fingerprint;
    public async Task<CommandReceipt> PerformAsync(string space,Device device,string kind,JsonObject payload,CancellationToken cancellation=default,string path="link.exchange",Func<PendingAction,Task>? onPrepared=null){
        await gate.WaitAsync(cancellation);try{
            if(path is not ("link.exchange" or "agent.exchange")||kind.StartsWith("agent.",StringComparison.Ordinal)!=(path=="agent.exchange"))throw new InvalidOperationException("invalid_exchange_path");
            if(this.space!=space||!device.Ready)throw new InvalidOperationException("refresh_target_required");if(await PendingAsync(cancellation)is not null)throw new InvalidOperationException("resolve_original_request_first");
            var snapshot=await Gateway.SnapshotAsync(space,cancellation);var current=snapshot.Devices.SingleOrDefault(d=>d.Id==device.Id&&d.Ready&&d.ModelRevision==device.ModelRevision)??throw new InvalidOperationException("target_changed");
            var model=snapshot.Models[current.ModelRevision];var parts=path.Split('.');
            if(model?["model_id"]?.GetValue<string>()!="urn:limelink:model:desktop:1"||model["services"] is not JsonArray services||!services.Any(s=>s?["id"]?.GetValue<string>()==parts[0]&&s["actions"] is JsonArray actions&&actions.Any(a=>a?["id"]?.GetValue<string>()==parts[1])))throw new InvalidOperationException("target_capability_changed");
            var identity=await IdentityAsync(space,current.Id,cancellation);var input=identity.Exchange(space,current.Id,current.ModelRevision,kind,payload.ToJsonString());var intent=CommandIntent.Create(current,path,input);
            var pending=new PendingAction(Gateway.Origin,space,intent);var data=JsonSerializer.Serialize(pending);await storage.SaveAsync(Scope,data,cancellation);if(await storage.LoadAsync(Scope,cancellation)!=data)throw new InvalidOperationException("intent_not_durable");
            if(onPrepared is not null)await onPrepared(pending);cancellation.ThrowIfCancellationRequested();
            return await Gateway.CreateAsync(space,intent,cancellation);
        }finally{gate.Release();}
    }
    public async Task<CommandReceipt> ResolveAsync(CancellationToken cancellation=default){await gate.WaitAsync(cancellation);try{var pending=await PendingAsync(cancellation)??throw new InvalidOperationException("no_pending_request");return await Gateway.ResolveAsync(pending.Space,pending.Intent,cancellation);}finally{gate.Release();}}
    public async Task FinishAsync(CancellationToken cancellation=default){await gate.WaitAsync(cancellation);try{var pending=await PendingAsync(cancellation);if(pending is null)return;var receipt=await Gateway.ResolveAsync(pending.Space,pending.Intent,cancellation);if(!new[]{"confirmed","failed","expired","rejected"}.Contains(receipt.Status))throw new InvalidOperationException("original_request_unresolved");await storage.SaveAsync(Scope,null,cancellation);}finally{gate.Release();}}
    public async Task<bool> FinishSuccessfulPairingAsync(CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{
            var pending=await PendingAsync(cancellation);if(pending is null)return false;
            var operation=pending.Intent.Operation;
            if(operation["path"]?.GetValue<string>()!="link.exchange"||operation["value"]?["kind"]?.GetValue<string>()!="pair")return false;
            // 再次核实原配对回执；处理成功与电脑本机批准是两个状态。
            var receipt=await Gateway.ResolveAsync(pending.Space,pending.Intent,cancellation);
            if(Response(receipt)?["ok"] is not JsonValue ok||!ok.TryGetValue<bool>(out var success)||!success)return false;
            cancellation.ThrowIfCancellationRequested();await storage.SaveAsync(Scope,null,cancellation);return true;
        }finally{gate.Release();}
    }
    public static JsonObject? Response(CommandReceipt command)=>command.Status=="confirmed"&&command.Document["evidence"]?["output"]?["response"] is JsonValue value?JsonNode.Parse(value.GetValue<string>())?.AsObject():null;
    public void Dispose(){Gateway.Dispose();gate.Dispose();}
}
