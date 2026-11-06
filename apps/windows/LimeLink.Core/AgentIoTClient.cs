using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using LimeIoT.Client;

namespace LimeLink.Core;

public sealed record AgentToolOutcome(bool Success,JsonObject Output);
public sealed record AgentToolRecord(AgentReference Reference,AgentToolCall Call,long RunExpiresAt,CommandIntent? Intent=null,AgentToolOutcome? Outcome=null,bool Delivered=false,string? CommandId=null,string? CommandStatus=null,CommandIntent? ReplyIntent=null) {
    [JsonIgnore] public string Id=>Call.Id;
    [JsonIgnore] public bool CanConfirm=>Call.IsWrite&&Intent is null&&Outcome is null&&Call.ExpiresAt>DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    [JsonIgnore] public bool NeedsRecovery=>Intent is not null&&CommandStatus is not ("confirmed" or "failed" or "expired" or "rejected");
    [JsonIgnore] public string StatusText=>CommandStatus is not null?CommandStatus switch {"confirmed"=>"设备已确认","failed"=>"设备执行失败","expired"=>"设备命令已过期","rejected"=>"设备命令已拒绝","accepted"=>"设备命令已受理","dispatched"=>"设备命令已发送",_=>"设备结果待核实"}:Intent is not null?"原设备命令待核实":Outcome is not null?Outcome.Success?"已读取设备状态":Outcome.Output["error"]?.GetValue<string>()=="user_rejected"?"已拒绝操作":"工具未完成":CanConfirm?"等待确认":"提案已过期";
}

/// <summary>设备意图与结果回传分别耐久保存；未知结果只能核实原请求。</summary>
public sealed class AgentIoTClient(GatewayClient gateway,AgentClient agent,ISessionStore store) {
    private readonly SemaphoreSlim gate=new(1,1);
    private string Scope=>gateway.Origin+"#limelink.agent-iot";
    private static void Check(bool condition,string error){if(!condition)throw new InvalidOperationException(error);}
    public async Task<IReadOnlyList<AgentToolRecord>> RecordsAsync(CancellationToken cancellation=default){
        var data=await store.LoadAsync(Scope,cancellation);if(data is null)return [];
        var records=JsonSerializer.Deserialize<AgentToolRecord[]>(data)??throw new InvalidOperationException("invalid_agent_tool_records");var references=await agent.ReferencesAsync(cancellation);
        Check(records.Length<=128&&records.Select(r=>r.Id).Distinct().Count()==records.Length,"invalid_agent_tool_records");
        foreach(var record in records){
            Check(record.Reference.Origin==gateway.Origin&&references.Any(r=>r.Matches(record.Reference))&&record.RunExpiresAt>=record.Call.ExpiresAt&&(!record.Delivered||record.Outcome is not null),"invalid_agent_tool_records");AgentToolProtocol.Validate(record.Call,record.Reference.Devices);
            if(record.Intent is CommandIntent intent)Check(record.Call.IsWrite&&Guid.TryParseExact(intent.Key,"D",out _)&&intent.DeviceId==record.Call.Device&&intent.ModelRevision==record.Call.Revision&&intent.Operation["type"]?.GetValue<string>()=="property.set"&&intent.Operation["path"]?.GetValue<string>()==record.Call.Path&&JsonNode.DeepEquals(intent.Operation["value"],record.Call.Value),"agent_tool_intent_mismatch");
            if(record.Outcome is AgentToolOutcome outcome){AgentToolProtocol.Result(record.Call,outcome.Success,outcome.Output);Check(!record.Call.IsWrite||!outcome.Success||record.Intent is not null,"agent_tool_intent_missing");}
        }
        return records;
    }
    private static bool CanDiscard(AgentToolRecord record)=>record.RunExpiresAt<=DateTimeOffset.UtcNow.ToUnixTimeSeconds()&&(record.Intent is null||record.CommandStatus is "confirmed" or "failed" or "expired" or "rejected")&&(record.ReplyIntent is null||record.Delivered);
    private async Task PersistAsync(IEnumerable<AgentToolRecord> records,CancellationToken cancellation){var data=JsonSerializer.Serialize(records);await store.SaveAsync(Scope,data,cancellation);Check(await store.LoadAsync(Scope,cancellation)==data,"agent_tool_record_not_durable");}
    public async Task<int> PruneExpiredAsync(CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{var previous=await RecordsAsync(cancellation);var retained=previous.Where(r=>!CanDiscard(r)).ToArray();if(previous.Count!=retained.Length)await PersistAsync(retained,cancellation);return previous.Count-retained.Length;}finally{gate.Release();}
    }
    private async Task SaveAsync(AgentToolRecord record,CancellationToken cancellation){
        var records=(await RecordsAsync(cancellation)).Where(r=>r.Id==record.Id||!CanDiscard(r)).ToList();var index=records.FindIndex(r=>r.Id==record.Id);
        if(index>=0){Check(records[index].Reference.Matches(record.Reference)&&records[index].Call.Matches(record.Call),"agent_tool_record_conflict");records[index]=record;}else{Check(records.Count<128,"agent_tool_record_capacity");records.Add(record);}
        await PersistAsync(records,cancellation);
    }
    private async Task CheckTargetAsync(AgentReference reference,string space,Device execution,CancellationToken cancellation)=>Check(reference.Origin==gateway.Origin&&reference.Space==space&&reference.Device==execution.Id&&reference.Revision==execution.ModelRevision&&(await agent.ReferencesAsync(cancellation)).Any(r=>r.Matches(reference)),"agent_target_changed");
    private async Task<AgentToolRecord> CurrentAsync(string id,AgentReference reference,CancellationToken cancellation)=>(await RecordsAsync(cancellation)).SingleOrDefault(r=>r.Id==id&&r.Reference.Matches(reference))??throw new InvalidOperationException("agent_tool_record_missing");
    private async Task StillPendingAsync(AgentToolRecord record,Device execution,CancellationToken cancellation){Check(record.Call.ExpiresAt>DateTimeOffset.UtcNow.ToUnixTimeSeconds(),"agent_tool_call_expired");Check((await agent.PendingToolsAsync(record.Reference,record.Reference.Space,execution,cancellation)).Calls.Any(c=>c.Matches(record.Call)),"agent_tool_proposal_changed");}
    private static (Device Device,JsonObject Model) Target(AgentToolRecord record,Snapshot snapshot){
        Check(snapshot.Space==record.Reference.Space,"agent_target_changed");var device=snapshot.Devices.SingleOrDefault(d=>d.Id==record.Call.Device);var model=device is null?null:snapshot.Models[device.ModelRevision]as JsonObject;
        Check(device is not null&&model is not null&&!(model["model_id"]?.GetValue<string>()??"").StartsWith("urn:limelink:model:desktop:",StringComparison.Ordinal),"agent_tool_device_unavailable");return(device!,model!);
    }
    private async Task<AgentToolRecord> ReportAsync(AgentToolRecord original,Device execution,CancellationToken cancellation){
        if(original.Outcome is not AgentToolOutcome outcome||original.Delivered)return original;
        if(original.ReplyIntent is not null)await agent.ResolveToolResultAsync(original.Reference,original.Reference.Space,execution,original.Call,outcome,original.ReplyIntent,cancellation);
        else await agent.CompleteToolAsync(original.Reference,original.Reference.Space,execution,original.Call,outcome,async pending=>{
            var record=await CurrentAsync(original.Id,original.Reference,cancellation);Check(record.ReplyIntent is null&&pending.Origin==record.Reference.Origin&&pending.Space==record.Reference.Space,"agent_tool_reply_intent_mismatch");await SaveAsync(record with {ReplyIntent=pending.Intent},cancellation);
        },cancellation);
        var updated=(await CurrentAsync(original.Id,original.Reference,cancellation))with {Delivered=true};await SaveAsync(updated,cancellation);return updated;
    }
    private async Task<AgentToolRecord> OutcomeAsync(AgentToolRecord record,bool success,JsonObject output,Device execution,CancellationToken cancellation){AgentToolProtocol.Result(record.Call,success,output);var updated=record with {Outcome=new(success,output)};await SaveAsync(updated,cancellation);return await ReportAsync(updated,execution,cancellation);}
    private Task<AgentToolRecord> FailureAsync(AgentToolRecord record,string error,Device execution,CancellationToken cancellation)=>OutcomeAsync(record,false,new(){{"error",error}},execution,cancellation);
    private static IEnumerable<(string Path,JsonObject Property)> Properties(JsonObject model)=>model["services"]!.AsArray().SelectMany(s=>(s!["properties"]as JsonArray??[]).Select(p=>(s["id"]!.GetValue<string>()+"."+p!["id"]!.GetValue<string>(),p.AsObject())));
    private async Task<AgentToolRecord> ReadAsync(AgentToolRecord record,Device execution,CancellationToken cancellation){
        Check(record.Call.ExpiresAt>DateTimeOffset.UtcNow.ToUnixTimeSeconds(),"agent_tool_call_expired");var snapshot=await gateway.SnapshotAsync(record.Reference.Space,cancellation);(Device Device,JsonObject Model) selected;
        try{selected=Target(record,snapshot);}catch(InvalidOperationException e)when(e.Message=="agent_tool_device_unavailable"){return await FailureAsync(record,e.Message,execution,cancellation);}
        var(device,model)=selected;var properties=new JsonArray();
        foreach(var(path,property)in Properties(model)){
            var schema=property["schema"]!.AsObject();var access=property["access"]!.AsArray().Select(a=>a!.GetValue<string>()).ToArray();
            if(schema["type"]?.GetValue<string>()is not ("boolean" or "integer" or "number" or "string")||!access.Any(a=>a is "read" or "write"))continue;
            var observed=access.Contains("read")?device.Reported?[path]as JsonObject:null;
            var projection=new JsonObject();foreach(var key in new[]{"type","minimum","maximum","minLength","maxLength","enum"})if(schema.ContainsKey(key))projection[key]=schema[key]?.DeepClone();
            properties.Add(new JsonObject{{"path",path},{"schema",projection},{"writable",access.Contains("write")},{"value",observed?["value"]?.DeepClone()},{"observed_at",observed?["observed_at"]?.DeepClone()},{"quality",observed?["quality"]?.DeepClone()??JsonValue.Create("unknown")}});
        }
        var output=new JsonObject{{"device_id",device.Id},{"model_revision",device.ModelRevision},{"ready",device.Ready},{"properties",properties}};
        if(properties.Count>8||AgentToolProtocol.Bytes(output)>1600)return await FailureAsync(record,"agent_tool_response_budget",execution,cancellation);
        try{AgentToolProtocol.Result(record.Call,true,output);}catch(Exception e)when(e is InvalidOperationException or FormatException){return await FailureAsync(record,"agent_tool_invalid_observation",execution,cancellation);}
        return await OutcomeAsync(record,true,output,execution,cancellation);
    }
    public async Task<AgentToolRecord?> ReceiveAsync(AgentReference reference,string space,Device execution,CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{
            await CheckTargetAsync(reference,space,execution,cancellation);var batch=await agent.PendingToolsAsync(reference,space,execution,cancellation);var call=batch.Calls.SingleOrDefault();if(call is null)return null;
            var previous=(await RecordsAsync(cancellation)).SingleOrDefault(r=>r.Id==call.Id);
            if(previous is not null){Check(previous.Reference.Matches(reference)&&previous.Call.Matches(call),"agent_tool_record_conflict");return previous.Outcome is not null?await ReportAsync(previous,execution,cancellation):previous.Call.IsWrite?previous:await ReadAsync(previous,execution,cancellation);}
            var record=new AgentToolRecord(reference,call,batch.ExpiresAt);await SaveAsync(record,cancellation);return call.IsWrite?record:await ReadAsync(record,execution,cancellation);
        }finally{gate.Release();}
    }
    private static bool ValidValue(JsonNode? value,JsonObject schema){
        if(!AgentToolProtocol.Scalar(value)||schema["enum"]is JsonArray choices&&!choices.Any(c=>JsonNode.DeepEquals(c,value)))return false;
        var v=(JsonValue)value!;var type=schema["type"]?.GetValue<string>();
        if(type=="boolean")return v.TryGetValue<bool>(out _);
        if(type=="string")return v.TryGetValue<string>(out var text)&&text.EnumerateRunes().Count()>=(schema["minLength"]?.GetValue<int>()??0)&&text.EnumerateRunes().Count()<=(schema["maxLength"]?.GetValue<int>()??int.MaxValue);
        return type is "integer" or "number"&&v.GetValueKind()==JsonValueKind.Number&&(type!="integer"||v.TryGetValue<long>(out _))&&v.TryGetValue<double>(out var n)&&double.IsFinite(n)&&n>=(schema["minimum"]?.GetValue<double>()??-double.MaxValue)&&n<=(schema["maximum"]?.GetValue<double>()??double.MaxValue);
    }
    public async Task<AgentToolRecord> ConfirmAsync(string id,AgentReference reference,string space,Device execution,CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{
            await CheckTargetAsync(reference,space,execution,cancellation);var record=await CurrentAsync(id,reference,cancellation);Check(record.CanConfirm,"resolve_original_iot_command_first");await StillPendingAsync(record,execution,cancellation);
            var(device,model)=Target(record,await gateway.SnapshotAsync(space,cancellation));Check(device.Ready&&record.Call.Revision==device.ModelRevision,"agent_tool_model_or_availability_changed");var properties=Properties(model).Where(p=>p.Path==record.Call.Path).ToArray();
            Check(properties.Length==1&&(properties[0].Property["access"]as JsonArray)!.Any(a=>a?.GetValue<string>()=="write")&&ValidValue(record.Call.Value,properties[0].Property["schema"]!.AsObject()),"agent_tool_property_not_allowed");
            cancellation.ThrowIfCancellationRequested();Check(record.CanConfirm,"agent_tool_call_expired");var intent=CommandIntent.Create(device,record.Call.Path!,record.Call.Value!,"property.set");record=record with {Intent=intent};await SaveAsync(record,cancellation);cancellation.ThrowIfCancellationRequested();Check(record.Call.ExpiresAt>DateTimeOffset.UtcNow.ToUnixTimeSeconds(),"agent_tool_call_expired");
            return await FinishAsync(record,await gateway.CreateAsync(space,intent,cancellation),execution,cancellation);
        }finally{gate.Release();}
    }
    private async Task<AgentToolRecord> FinishAsync(AgentToolRecord original,CommandReceipt initial,Device execution,CancellationToken cancellation){
        var intent=original.Intent??throw new InvalidOperationException("agent_tool_intent_missing");var command=initial;var record=original with {CommandId=command.Id,CommandStatus=command.Status};await SaveAsync(record,cancellation);
        for(var i=0;i<20&&command.Status is "accepted" or "dispatched";i++){await Task.Delay(200,cancellation);command=await gateway.ResolveAsync(record.Reference.Space,intent,cancellation);}
        record=record with {CommandId=command.Id,CommandStatus=command.Status};await SaveAsync(record,cancellation);Check(command.Status is "confirmed" or "failed" or "expired" or "rejected" or "unknown","resolve_original_iot_command_first");
        if(record.Outcome is not null)return record;
        var observed=command.Document["evidence"]?["observed_at"];var output=(JsonObject)record.Call.Arguments.DeepClone();output["command_id"]=command.Id;output["status"]=command.Status;output["observed_at"]=AgentToolProtocol.Timestamp(observed)?observed?.DeepClone():null;
        return await OutcomeAsync(record,command.Status=="confirmed",output,execution,cancellation);
    }
    public async Task<AgentToolRecord> RecoverCommandAsync(string id,AgentReference reference,string space,Device execution,CancellationToken cancellation=default){await gate.WaitAsync(cancellation);try{await CheckTargetAsync(reference,space,execution,cancellation);var record=await CurrentAsync(id,reference,cancellation);return await FinishAsync(record,await gateway.ResolveAsync(space,record.Intent??throw new InvalidOperationException("agent_tool_intent_missing"),cancellation),execution,cancellation);}finally{gate.Release();}}
    public async Task<AgentToolRecord> SendResultAsync(string id,AgentReference reference,string space,Device execution,CancellationToken cancellation=default){await gate.WaitAsync(cancellation);try{await CheckTargetAsync(reference,space,execution,cancellation);return await ReportAsync(await CurrentAsync(id,reference,cancellation),execution,cancellation);}finally{gate.Release();}}
    public async Task<AgentToolRecord> RejectAsync(string id,AgentReference reference,string space,Device execution,CancellationToken cancellation=default){await gate.WaitAsync(cancellation);try{await CheckTargetAsync(reference,space,execution,cancellation);var record=await CurrentAsync(id,reference,cancellation);Check(record.CanConfirm,"resolve_original_iot_command_first");await StillPendingAsync(record,execution,cancellation);return await FailureAsync(record,"user_rejected",execution,cancellation);}finally{gate.Release();}}
}
