using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using LimeIoT.Client;

namespace LimeLink.Core;

public sealed record AgentWorkspace(string Id,string Name,bool AllowWrite);
public sealed record AgentCapabilities(IReadOnlyList<AgentWorkspace> Workspaces);
public sealed record AgentReference(string Origin,string Space,string Device,string Revision,string Id,IReadOnlyList<string>? IotDevices=null) {
    [JsonIgnore] public IReadOnlyList<string> Devices=>IotDevices??[];
    public bool Matches(AgentReference other)=>Origin==other.Origin&&Space==other.Space&&Device==other.Device&&Revision==other.Revision&&Id==other.Id&&Devices.SequenceEqual(other.Devices);
}
public sealed record AgentEvent(int Seq,string Kind,string Text);
public sealed record AgentRun(string Id,string State,string WorkspaceId,string Sandbox,string? SessionId,string? Error,long ExpiresAt,IReadOnlyList<AgentEvent> Events,int Cursor) {
    public bool CanCancel=>State is "awaiting_approval" or "approved" or "starting" or "running";
    public string StateText=>State switch {"awaiting_approval"=>"等待电脑批准","approved"=>"已批准，等待执行","starting"=>"正在启动","running"=>"正在执行","cancelling"=>"正在中断","succeeded"=>"已完成","failed"=>"执行失败","cancelled"=>"已停止","rejected"=>"已拒绝","expired"=>"批准已过期",_=>"结果待核实"};
}

/// <summary>产品 Agent 响应边界。平台命令已确认只代表交换完成，任务状态单独校验。</summary>
public static class AgentProtocol {
    private static void Check(bool value){if(!value)throw new InvalidOperationException("invalid_agent_response");}
    private static bool Keys(JsonObject value,params string[] keys)=>value.Select(p=>p.Key).Order().SequenceEqual(keys.Order());
    public static AgentCapabilities Capabilities(JsonObject value){
        try{
            Check(Keys(value,"adapter","configured","authentication","local_approval_required","workspaces"));
            Check(value["adapter"]!.GetValue<string>()=="codex-app-server"&&value["configured"]!.GetValue<bool>()&&value["authentication"]!.GetValue<string>()=="managed_by_codex"&&value["local_approval_required"]!.GetValue<bool>());
            var workspaces=value["workspaces"]!.AsArray().Select(node=>{var w=node!.AsObject();Check(Keys(w,"id","name","allow_write"));return new AgentWorkspace(w["id"]!.GetValue<string>(),w["name"]!.GetValue<string>(),w["allow_write"]!.GetValue<bool>());}).ToArray();
            Check(workspaces.Length is >=1 and <=8&&workspaces.Select(w=>w.Id).Distinct().Count()==workspaces.Length&&workspaces.All(w=>Regex.IsMatch(w.Id,"^[A-Za-z0-9_-]{1,64}$")&&Encoding.UTF8.GetByteCount(w.Name) is >=1 and <=64));
            return new(workspaces);
        }catch(Exception e)when(e is not OperationCanceledException){throw new InvalidOperationException("invalid_agent_capabilities",e);}
    }
    public static AgentRun Run(JsonObject value,string id,int after){
        try{
            var keys=new[]{"id","state","workspace_id","sandbox","session_id","error","expires_at","events","cursor"};
            Check(keys.All(value.ContainsKey)&&value.All(p=>keys.Contains(p.Key)||p.Key=="content_expired"));
            if(value.ContainsKey("content_expired"))_=value["content_expired"]!.GetValue<bool>();
            var events=value["events"]!.AsArray().Select(node=>{var e=node!.AsObject();Check(Keys(e,"seq","kind","text"));return new AgentEvent(e["seq"]!.GetValue<int>(),e["kind"]!.GetValue<string>(),e["text"]!.GetValue<string>());}).ToArray();
            var run=new AgentRun(value["id"]!.GetValue<string>(),value["state"]!.GetValue<string>(),value["workspace_id"]!.GetValue<string>(),value["sandbox"]!.GetValue<string>(),value["session_id"]?.GetValue<string>(),value["error"]?.GetValue<string>(),value["expires_at"]!.GetValue<long>(),events,value["cursor"]!.GetValue<int>());
            Check(run.Id==id&&new[]{"awaiting_approval","approved","starting","running","cancelling","succeeded","failed","cancelled","unknown","rejected","expired"}.Contains(run.State)&&run.Sandbox is "read-only" or "workspace-write");
            Check(after is >=0 and <=256&&events.Length<=4&&run.Cursor>=after&&run.Cursor<=256&&run.Cursor==(events.LastOrDefault()?.Seq??after));
            var previous=after;foreach(var e in events){Check(e.Seq>previous&&e.Seq<=256&&new[]{"message","tool_started","tool_completed","working"}.Contains(e.Kind)&&Encoding.UTF8.GetByteCount(e.Text)<=400);previous=e.Seq;}
            return run;
        }catch(Exception e)when(e is not OperationCanceledException){throw new InvalidOperationException("invalid_agent_response",e);}
    }
}

/// <summary>运行引用先持久化；失联时查询原平台命令，禁止自动再次提交任务。</summary>
public sealed class AgentClient(LinkClient link,ISessionStore store) {
    private readonly SemaphoreSlim gate=new(1,1);
    private string Scope=>link.Gateway.Origin+"#limelink.agent-runs";
    public async Task<IReadOnlyList<AgentReference>> ReferencesAsync(CancellationToken cancellation=default){
        var data=await store.LoadAsync(Scope,cancellation);if(data is null)return [];
        var records=JsonSerializer.Deserialize<AgentReference[]>(data)??throw new InvalidOperationException("invalid_agent_records");
        if(records.Length>128||records.Select(r=>r.Id).Distinct().Count()!=records.Length||records.Any(r=>r.Origin!=link.Gateway.Origin||!Guid.TryParseExact(r.Id,"D",out _)||!AgentToolProtocol.ValidGrant(r.Devices)||!r.Devices.SequenceEqual(r.Devices.Order(StringComparer.Ordinal))||r.Devices.Contains(r.Device)))throw new InvalidOperationException("invalid_agent_records");return records;
    }
    private async Task SaveAsync(AgentReference record,CancellationToken cancellation){
        var records=(await ReferencesAsync(cancellation)).ToList();var old=records.SingleOrDefault(r=>r.Id==record.Id);
        if(old is not null){if(!old.Matches(record))throw new InvalidOperationException("agent_reference_conflict");return;}
        if(records.Count>=128)throw new InvalidOperationException("agent_record_capacity");records.Add(record);
        var data=JsonSerializer.Serialize(records);await store.SaveAsync(Scope,data,cancellation);if(await store.LoadAsync(Scope,cancellation)!=data)throw new InvalidOperationException("agent_reference_not_durable");
    }
    private void Check(AgentReference reference,string space,Device device){if(reference.Origin!=link.Gateway.Origin||reference.Space!=space||reference.Device!=device.Id||reference.Revision!=device.ModelRevision)throw new InvalidOperationException("agent_target_changed");}
    private async Task<JsonObject> FinishAsync(CommandReceipt initial,CancellationToken cancellation,PendingAction? original=null){
        var command=initial;
        for(var i=0;i<20&&command.Status is "accepted" or "dispatched";i++){await Task.Delay(200,cancellation);command=original is null?await link.ResolveAsync(cancellation):await link.Gateway.ResolveAsync(original.Space,original.Intent,cancellation);}
        if(command.Document["request"]?["operation"]?["path"]?.GetValue<string>()!="agent.exchange")throw new InvalidOperationException("agent_original_path_mismatch");
        if(command.Status is "failed" or "expired" or "rejected"){await link.FinishAsync(cancellation);throw new InvalidOperationException("agent_command_"+command.Status);}
        var response=LinkClient.Response(command)??throw new InvalidOperationException("resolve_original_agent_request_first");
        if(response["ok"] is not JsonValue ok||!ok.TryGetValue<bool>(out var success))throw new InvalidOperationException("invalid_agent_response");
        if(!success){var error=response["error"]?.GetValue<string>();if(response.Count!=2||error is null||!Regex.IsMatch(error,"^[a-z0-9_]{1,96}$"))throw new InvalidOperationException("invalid_agent_response");await link.FinishAsync(cancellation);throw new InvalidOperationException(error);}
        if(response.Count!=2||response["value"] is not JsonObject value)throw new InvalidOperationException("invalid_agent_response");return value;
    }
    private async Task<JsonObject> RequestAsync(string space,Device device,string kind,JsonObject payload,CancellationToken cancellation,Func<PendingAction,Task>? onPrepared=null)=>await FinishAsync(await link.PerformAsync(space,device,kind,payload,cancellation,"agent.exchange",onPrepared),cancellation);
    public async Task<AgentCapabilities> DiscoverAsync(string space,Device device,CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{var value=AgentProtocol.Capabilities(await RequestAsync(space,device,"agent.capabilities",new(),cancellation));await link.FinishAsync(cancellation);return value;}finally{gate.Release();}
    }
    public async Task<AgentRun> SubmitAsync(string space,Device device,string workspace,string text,string sandbox,AgentReference? resume=null,CancellationToken cancellation=default,IReadOnlyList<string>? iotDevices=null){
        await gate.WaitAsync(cancellation);try{
            if(string.IsNullOrWhiteSpace(text)||Encoding.UTF8.GetByteCount(text)>2048||sandbox is not ("read-only" or "workspace-write"))throw new InvalidOperationException("invalid_agent_input");
            var selected=(iotDevices??[]).Order(StringComparer.Ordinal).ToArray();if(!AgentToolProtocol.ValidGrant(selected)||selected.Contains(device.Id))throw new InvalidOperationException("invalid_agent_devices");
            if(resume is not null){Check(resume,space,device);if(!resume.Devices.SequenceEqual(selected))throw new InvalidOperationException("agent_tool_scope_changed");}
            if(await link.PendingAsync(cancellation) is not null)throw new InvalidOperationException("resolve_original_request_first");
            var reference=new AgentReference(link.Gateway.Origin,space,device.Id,device.ModelRevision,Guid.NewGuid().ToString(),selected);await SaveAsync(reference,cancellation);
            var payload=new JsonObject{{"id",reference.Id},{"workspace_id",workspace},{"text",text},{"sandbox",sandbox}};if(resume is not null)payload["resume_from"]=resume.Id;
            if(selected.Length>0)payload["iot_devices"]=new JsonArray(selected.Select(s=>(JsonNode?)JsonValue.Create(s)).ToArray());
            var value=AgentProtocol.Run(await RequestAsync(space,device,"agent.submit",payload,cancellation),reference.Id,0);await link.FinishAsync(cancellation);return value;
        }finally{gate.Release();}
    }
    public async Task<AgentRun> QueryAsync(AgentReference reference,string space,Device device,int after=0,bool cancel=false,CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{
            Check(reference,space,device);if(after is <0 or >256||cancel&&after!=0)throw new InvalidOperationException("invalid_agent_cursor");
            var payload=new JsonObject{{"id",reference.Id}};if(!cancel)payload["after"]=after;
            var value=AgentProtocol.Run(await RequestAsync(space,device,cancel?"agent.cancel":"agent.status",payload,cancellation),reference.Id,after);await link.FinishAsync(cancellation);return value;
        }finally{gate.Release();}
    }
    private async Task CheckSavedAsync(AgentReference reference,string space,Device device,CancellationToken cancellation){Check(reference,space,device);if(!(await ReferencesAsync(cancellation)).Any(r=>r.Matches(reference)))throw new InvalidOperationException("agent_reference_missing");}
    public async Task<AgentToolCapabilities> DiscoverToolsAsync(string space,Device device,CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{var result=AgentToolProtocol.Capabilities(await RequestAsync(space,device,"agent.tool_capabilities",new(),cancellation));await link.FinishAsync(cancellation);return result;}finally{gate.Release();}
    }
    public async Task<AgentToolBatch> PendingToolsAsync(AgentReference reference,string space,Device device,CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{await CheckSavedAsync(reference,space,device,cancellation);var result=AgentToolProtocol.Pending(await RequestAsync(space,device,"agent.tool_pending",new(){{"id",reference.Id}},cancellation),reference);await link.FinishAsync(cancellation);return result;}finally{gate.Release();}
    }
    private static JsonObject ToolPayload(AgentReference reference,AgentToolCall call,AgentToolOutcome outcome)=>new(){{"id",reference.Id},{"call_id",call.Id},{"success",outcome.Success},{"output",outcome.Output.DeepClone()}};
    public async Task CompleteToolAsync(AgentReference reference,string space,Device device,AgentToolCall call,AgentToolOutcome outcome,Func<PendingAction,Task> onPrepared,CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{await CheckSavedAsync(reference,space,device,cancellation);AgentToolProtocol.Validate(call,reference.Devices);AgentToolProtocol.Result(call,outcome.Success,outcome.Output);var result=await RequestAsync(space,device,"agent.tool_result",ToolPayload(reference,call,outcome),cancellation,onPrepared);AgentToolProtocol.Completion(result,reference.Id,call.Id);await link.FinishAsync(cancellation);}finally{gate.Release();}
    }
    public async Task ResolveToolResultAsync(AgentReference reference,string space,Device device,AgentToolCall call,AgentToolOutcome outcome,CommandIntent intent,CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{
            await CheckSavedAsync(reference,space,device,cancellation);var operation=intent.Operation;var exchange=operation["value"]!.AsObject();
            if(intent.DeviceId!=device.Id||intent.ModelRevision!=device.ModelRevision||operation["type"]?.GetValue<string>()!="action.invoke"||operation["path"]?.GetValue<string>()!="agent.exchange"||exchange["kind"]?.GetValue<string>()!="agent.tool_result"||!JsonNode.DeepEquals(JsonNode.Parse(exchange["payload"]!.GetValue<string>()),ToolPayload(reference,call,outcome)))throw new InvalidOperationException("agent_tool_reply_intent_mismatch");
            var pending=await link.PendingAsync(cancellation);if(pending is not null&&pending.Intent.Key!=intent.Key)throw new InvalidOperationException("resolve_original_request_first");
            var result=await FinishAsync(await link.Gateway.ResolveAsync(space,intent,cancellation),cancellation,new(link.Gateway.Origin,space,intent));AgentToolProtocol.Completion(result,reference.Id,call.Id);await link.FinishAsync(cancellation);
        }finally{gate.Release();}
    }
    public async Task<AgentRun?> RecoverAsync(CancellationToken cancellation=default){
        await gate.WaitAsync(cancellation);try{
            var original=await link.PendingAsync(cancellation)??throw new InvalidOperationException("no_original_agent_request");
            if(original.Intent.Operation["path"]?.GetValue<string>()!="agent.exchange")throw new InvalidOperationException("no_original_agent_request");
            var exchange=original.Intent.Operation["value"]!.AsObject();var kind=exchange["kind"]!.GetValue<string>();var payload=JsonNode.Parse(exchange["payload"]!.GetValue<string>())!.AsObject();
            var value=await FinishAsync(await link.ResolveAsync(cancellation),cancellation);
            if(kind=="agent.capabilities"){_=AgentProtocol.Capabilities(value);await link.FinishAsync(cancellation);return null;}
            if(kind=="agent.tool_capabilities"){_=AgentToolProtocol.Capabilities(value);await link.FinishAsync(cancellation);return null;}
            if(kind is not ("agent.submit" or "agent.status" or "agent.cancel" or "agent.tool_pending" or "agent.tool_result"))throw new InvalidOperationException("no_original_agent_request");
            var id=payload["id"]!.GetValue<string>();var reference=(await ReferencesAsync(cancellation)).SingleOrDefault(r=>r.Id==id)??throw new InvalidOperationException("agent_reference_missing");
            Check(reference,original.Space,new(original.Intent.DeviceId,original.Intent.ModelRevision,true));
            if(kind=="agent.tool_pending"){_=AgentToolProtocol.Pending(value,reference);await link.FinishAsync(cancellation);return null;}
            if(kind=="agent.tool_result"){AgentToolProtocol.Completion(value,id,payload["call_id"]!.GetValue<string>());await link.FinishAsync(cancellation);return null;}
            var run=AgentProtocol.Run(value,id,payload["after"]?.GetValue<int>()??0);await link.FinishAsync(cancellation);return run;
        }finally{gate.Release();}
    }
}
