package run.limeai.link.core

import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import run.limeai.iot.core.*

@Serializable data class AgentWorkspace(val id:String,val name:String,@SerialName("allow_write") val allowWrite:Boolean)
@Serializable data class AgentCapabilities(val adapter:String,val configured:Boolean,val authentication:String,@SerialName("local_approval_required") val localApprovalRequired:Boolean,val workspaces:List<AgentWorkspace>)
@Serializable data class AgentReference(val origin:String,val space:String,val device:String,val revision:String,val id:String,val iotDevices:List<String> = emptyList())
@Serializable data class AgentEvent(val seq:Int,val kind:String,val text:String)
@Serializable data class AgentRun(val id:String,val state:String,@SerialName("workspace_id") val workspaceId:String,val sandbox:String,@SerialName("session_id") val sessionId:String?,val error:String?,@SerialName("expires_at") val expiresAt:Long,val events:List<AgentEvent>,val cursor:Int,@SerialName("content_expired") val contentExpired:Boolean=false) {
    val canCancel get()=state in setOf("awaiting_approval","approved","starting","running")
    val stateText get()=mapOf("awaiting_approval" to "等待电脑批准","approved" to "已批准，等待执行","starting" to "正在启动","running" to "正在执行","cancelling" to "正在中断","succeeded" to "已完成","failed" to "执行失败","cancelled" to "已停止","unknown" to "结果待核实","rejected" to "已拒绝","expired" to "批准已过期")[state]?:"结果待核实"
}

/** 平台交换确认与 Agent 执行完成分别处理。响应预算和分页顺序在产品边界检查。 */
object AgentProtocol {
    private val json=Json { ignoreUnknownKeys=false; explicitNulls=true }
    fun capabilities(value:JsonObject):AgentCapabilities {
        val result=json.decodeFromJsonElement<AgentCapabilities>(value)
        require(result.adapter=="codex-app-server" && result.configured && result.authentication=="managed_by_codex" && result.localApprovalRequired && result.workspaces.size in 1..8 && result.workspaces.map{it.id}.distinct().size==result.workspaces.size && result.workspaces.all{it.id.matches(Regex("^[A-Za-z0-9_-]{1,64}$")) && it.name.toByteArray(Charsets.UTF_8).size in 1..64}) { "invalid_agent_capabilities" }
        return result
    }
    fun run(value:JsonObject,id:String,after:Int):AgentRun {
        val result=json.decodeFromJsonElement<AgentRun>(value)
        require(result.id==id && result.state in setOf("awaiting_approval","approved","starting","running","cancelling","succeeded","failed","cancelled","unknown","rejected","expired") && result.sandbox in setOf("read-only","workspace-write")) { "invalid_agent_response" }
        require(after in 0..256 && result.events.size<=4 && result.cursor in after..256 && result.cursor==(result.events.lastOrNull()?.seq?:after)) { "invalid_agent_response" }
        var previous=after
        result.events.forEach { require(it.seq>previous && it.seq<=256 && it.kind in setOf("message","tool_started","tool_completed","working") && it.text.toByteArray(Charsets.UTF_8).size<=400) { "invalid_agent_response" };previous=it.seq }
        return result
    }
}

/** 运行引用先持久化；丢失响应后恢复原命令，不重新提交任务。 */
class AgentClient(private val link:LinkClient,private val store:SessionStore) {
    private val mutex=Mutex()
    private val json=Json { ignoreUnknownKeys=false }
    private val scope get()=link.gateway.origin+"#limelink.agent-runs"
    suspend fun references():List<AgentReference> {
        val data=store.load(scope)?:return emptyList()
        val records=json.decodeFromString<List<AgentReference>>(data)
        check(records.size<=128 && records.map{it.id}.distinct().size==records.size && records.all{it.origin==link.gateway.origin && it.id.matches(Regex("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")) && AgentToolProtocol.validGrant(it.iotDevices) && it.iotDevices==it.iotDevices.sorted() && it.device !in it.iotDevices}) { "invalid_agent_records" };return records
    }
    private suspend fun save(record:AgentReference) {
        val records=references();val old=records.singleOrNull{it.id==record.id}
        if(old!=null){check(old==record){"agent_reference_conflict"};return}
        check(records.size<128){"agent_record_capacity"};val data=json.encodeToString(records+record)
        store.save(scope,data);check(store.load(scope)==data){"agent_reference_not_durable"}
    }
    private fun checkTarget(reference:AgentReference,space:String,device:Device){check(reference.origin==link.gateway.origin && reference.space==space && reference.device==device.deviceId && reference.revision==device.modelRevision){"agent_target_changed"}}
    private suspend fun finish(initial:Command,original:PendingAction?=null):JsonObject {
        var command=initial
        repeat(20){if(command.status in setOf("accepted","dispatched")){delay(200);command=if(original==null)link.resolve()else link.gateway.resolve(original.space,original.intent)}}
        check(command.request.operation.path=="agent.exchange"){"agent_original_path_mismatch"}
        if(command.status in setOf("failed","expired","rejected")){link.finish();error("agent_command_"+command.status)}
        val response=LinkClient.response(command)?:error("resolve_original_agent_request_first")
        val ok=response["ok"]?.jsonPrimitive?.takeUnless{it.isString}?.booleanOrNull?:error("invalid_agent_response")
        if(!ok){val error=response["error"]?.jsonPrimitive?.content;check(response.keys==setOf("ok","error") && error!=null && error.matches(Regex("^[a-z0-9_]{1,96}$"))){"invalid_agent_response"};link.finish();error(error)}
        check(response.keys==setOf("ok","value")){"invalid_agent_response"};return response["value"]?.jsonObject?:error("invalid_agent_response")
    }
    private suspend fun request(space:String,device:Device,kind:String,payload:JsonObject,onPrepared:(suspend (PendingAction)->Unit)?=null)=finish(link.perform(space,device,kind,payload,path="agent.exchange",onPrepared=onPrepared))
    suspend fun discover(space:String,device:Device):AgentCapabilities=mutex.withLock {
        val result=AgentProtocol.capabilities(request(space,device,"agent.capabilities",buildJsonObject{}));link.finish();result
    }
    suspend fun submit(space:String,device:Device,workspace:String,text:String,sandbox:String,resume:AgentReference?=null,iotDevices:List<String> = emptyList()):AgentRun=mutex.withLock {
        require(text.isNotBlank() && text.toByteArray(Charsets.UTF_8).size<=2048 && sandbox in setOf("read-only","workspace-write")){"invalid_agent_input"}
        val selected=iotDevices.sorted();require(AgentToolProtocol.validGrant(selected) && device.deviceId !in selected){"invalid_agent_devices"}
        resume?.let{checkTarget(it,space,device);check(it.iotDevices==selected){"agent_tool_scope_changed"}}
        check(link.pending()==null){"resolve_original_request_first"}
        val reference=AgentReference(link.gateway.origin,space,device.deviceId,device.modelRevision,UUID.randomUUID().toString(),selected);save(reference)
        val payload=buildJsonObject{put("id",reference.id);put("workspace_id",workspace);put("text",text);put("sandbox",sandbox);resume?.let{put("resume_from",it.id)};if(selected.isNotEmpty())put("iot_devices",JsonArray(selected.map(::JsonPrimitive)))}
        val result=AgentProtocol.run(request(space,device,"agent.submit",payload),reference.id,0);link.finish();result
    }
    suspend fun query(reference:AgentReference,space:String,device:Device,after:Int=0,cancel:Boolean=false):AgentRun=mutex.withLock {
        checkTarget(reference,space,device);require(after in 0..256 && (!cancel || after==0)){"invalid_agent_cursor"}
        val payload=buildJsonObject{put("id",reference.id);if(!cancel)put("after",after)}
        val result=AgentProtocol.run(request(space,device,if(cancel)"agent.cancel" else "agent.status",payload),reference.id,after);link.finish();result
    }
    private suspend fun checkSaved(reference:AgentReference,space:String,device:Device){checkTarget(reference,space,device);check(reference in references()){"agent_reference_missing"}}
    suspend fun discoverTools(space:String,device:Device):AgentToolCapabilities=mutex.withLock {
        val result=AgentToolProtocol.capabilities(request(space,device,"agent.tool_capabilities",buildJsonObject{}));link.finish();result
    }
    suspend fun pendingTools(reference:AgentReference,space:String,device:Device):AgentToolBatch=mutex.withLock {
        checkSaved(reference,space,device)
        val result=AgentToolProtocol.pending(request(space,device,"agent.tool_pending",buildJsonObject{put("id",reference.id)}),reference);link.finish();result
    }
    suspend fun completeTool(reference:AgentReference,space:String,device:Device,call:AgentToolCall,outcome:AgentToolOutcome,onPrepared:suspend (PendingAction)->Unit)=mutex.withLock {
        checkSaved(reference,space,device);AgentToolProtocol.validate(call,reference.iotDevices);AgentToolProtocol.result(call,outcome.success,outcome.output)
        val result=request(space,device,"agent.tool_result",toolPayload(reference,call,outcome),onPrepared);AgentToolProtocol.completion(result,reference.id,call.id);link.finish()
    }
    private fun toolPayload(reference:AgentReference,call:AgentToolCall,outcome:AgentToolOutcome)=buildJsonObject{put("id",reference.id);put("call_id",call.id);put("success",outcome.success);put("output",outcome.output)}
    suspend fun resolveToolResult(reference:AgentReference,space:String,device:Device,call:AgentToolCall,outcome:AgentToolOutcome,intent:CommandIntent)=mutex.withLock {
        checkSaved(reference,space,device)
        val operation=intent.input.operation;val exchange=operation.value.jsonObject
        check(intent.input.deviceId==device.deviceId && intent.input.modelRevision==device.modelRevision && operation.type=="action.invoke" && operation.path=="agent.exchange" && exchange["kind"]==JsonPrimitive("agent.tool_result") && Json.parseToJsonElement(exchange["payload"]!!.jsonPrimitive.content)==toolPayload(reference,call,outcome)){"agent_tool_reply_intent_mismatch"}
        val pending=link.pending();check(pending==null || pending.intent.key==intent.key){"resolve_original_request_first"}
        val value=finish(link.gateway.resolve(space,intent),PendingAction(link.gateway.origin,space,intent));AgentToolProtocol.completion(value,reference.id,call.id);link.finish()
    }
    suspend fun recover():AgentRun?=mutex.withLock {
        val original=link.pending()?:error("no_original_agent_request")
        check(original.intent.input.operation.path=="agent.exchange"){"no_original_agent_request"}
        val exchange=original.intent.input.operation.value.jsonObject;val kind=exchange["kind"]!!.jsonPrimitive.content
        val payload=Json.parseToJsonElement(exchange["payload"]!!.jsonPrimitive.content).jsonObject
        val value=finish(link.resolve())
        if(kind=="agent.capabilities"){AgentProtocol.capabilities(value);link.finish();return@withLock null}
        if(kind=="agent.tool_capabilities"){AgentToolProtocol.capabilities(value);link.finish();return@withLock null}
        check(kind in setOf("agent.submit","agent.status","agent.cancel","agent.tool_pending","agent.tool_result")){"no_original_agent_request"}
        val id=payload["id"]!!.jsonPrimitive.content
        val ref=references().singleOrNull{it.id==id}?:error("agent_reference_missing")
        check(ref.origin==link.gateway.origin && ref.space==original.space && ref.device==original.intent.input.deviceId && ref.revision==original.intent.input.modelRevision){"agent_target_changed"}
        if(kind=="agent.tool_pending"){AgentToolProtocol.pending(value,ref);link.finish();return@withLock null}
        if(kind=="agent.tool_result"){AgentToolProtocol.completion(value,id,payload["call_id"]!!.jsonPrimitive.content);link.finish();return@withLock null}
        val result=AgentProtocol.run(value,id,payload["after"]?.jsonPrimitive?.int?:0);link.finish();result
    }
}
