package run.limeai.link.core

import java.time.Instant
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import run.limeai.iot.core.*

@Serializable data class AgentToolOutcome(val success:Boolean,val output:JsonObject)
@Serializable data class AgentToolRecord(val reference:AgentReference,val call:AgentToolCall,val runExpiresAt:Long,val intent:CommandIntent?=null,val outcome:AgentToolOutcome?=null,val delivered:Boolean=false,val commandID:String?=null,val commandStatus:String?=null,val replyIntent:CommandIntent?=null) {
    val id get()=call.id
    val canConfirm get()=call.isWrite && intent==null && outcome==null && call.expiresAt>Instant.now().epochSecond
    val needsRecovery get()=intent!=null && commandStatus !in setOf("confirmed","failed","expired","rejected")
    val statusText get()=when {
        commandStatus!=null->mapOf("confirmed" to "设备已确认","unknown" to "设备结果待核实","failed" to "设备执行失败","expired" to "设备命令已过期","rejected" to "设备命令已拒绝","accepted" to "设备命令已受理","dispatched" to "设备命令已发送")[commandStatus]?:"设备结果待核实"
        intent!=null->"原设备命令待核实"
        outcome!=null->if(outcome.success)"已读取设备状态"else if(outcome.output["error"]==JsonPrimitive("user_rejected"))"已拒绝操作"else "工具未完成"
        canConfirm->"等待确认"
        else->"提案已过期"
    }
}

/** 设备意图和 Agent 回传分别耐久保存。恢复只查询原请求，不重建设备 POST。 */
class AgentIoTClient(private val gateway:GatewayClient,private val agent:AgentClient,private val store:SessionStore) {
    private val mutex=Mutex()
    private val json=Json { ignoreUnknownKeys=false }
    private val scope get()=gateway.origin+"#limelink.agent-iot"
    suspend fun records():List<AgentToolRecord> {
        val data=store.load(scope)?:return emptyList()
        val records=json.decodeFromString<List<AgentToolRecord>>(data);val references=agent.references()
        check(records.size<=128 && records.map{it.id}.distinct().size==records.size){"invalid_agent_tool_records"}
        for(record in records){
            check(record.reference.origin==gateway.origin && record.reference in references && record.runExpiresAt>=record.call.expiresAt && (!record.delivered||record.outcome!=null)){"invalid_agent_tool_records"}
            AgentToolProtocol.validate(record.call,record.reference.iotDevices)
            record.intent?.let{intent->
                check(record.call.isWrite && intent.key.matches(Regex("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")) && intent.input.deviceId==record.call.device && intent.input.modelRevision==record.call.revision && intent.input.operation.type=="property.set" && intent.input.operation.path==record.call.path && intent.input.operation.value==record.call.value){"agent_tool_intent_mismatch"}
            }
            record.outcome?.let{AgentToolProtocol.result(record.call,it.success,it.output);check(!record.call.isWrite||!it.success||record.intent!=null){"agent_tool_intent_missing"}}
        }
        return records
    }
    private fun canDiscard(record:AgentToolRecord)=record.runExpiresAt<=Instant.now().epochSecond && (record.intent==null || record.commandStatus in setOf("confirmed","failed","expired","rejected")) && (record.replyIntent==null || record.delivered)
    private suspend fun persist(records:List<AgentToolRecord>){val data=json.encodeToString(records);store.save(scope,data);check(store.load(scope)==data){"agent_tool_record_not_durable"}}
    suspend fun pruneExpired():Int=mutex.withLock {
        val previous=records();val retained=previous.filterNot(::canDiscard);if(previous.size!=retained.size)persist(retained);previous.size-retained.size
    }
    private suspend fun save(record:AgentToolRecord){
        val records=records().filter{it.id==record.id || !canDiscard(it)}.toMutableList();val index=records.indexOfFirst{it.id==record.id}
        if(index>=0){check(records[index].reference==record.reference && records[index].call==record.call){"agent_tool_record_conflict"};records[index]=record}
        else{check(records.size<128){"agent_tool_record_capacity"};records.add(record)}
        persist(records)
    }
    private suspend fun checkTarget(reference:AgentReference,space:String,execution:Device){check(reference.origin==gateway.origin && reference.space==space && reference.device==execution.deviceId && reference.revision==execution.modelRevision && reference in agent.references()){"agent_target_changed"}}
    private suspend fun current(id:String,reference:AgentReference)=records().singleOrNull{it.id==id && it.reference==reference}?:error("agent_tool_record_missing")
    private suspend fun stillPending(record:AgentToolRecord,execution:Device){check(record.call.expiresAt>Instant.now().epochSecond){"agent_tool_call_expired"};check(record.call in agent.pendingTools(record.reference,record.reference.space,execution).calls){"agent_tool_proposal_changed"}}
    private fun target(record:AgentToolRecord,snapshot:Snapshot):Pair<Device,Model> {
        check(snapshot.space==record.reference.space){"agent_target_changed"}
        val device=snapshot.devices.singleOrNull{it.deviceId==record.call.device}?:error("agent_tool_device_unavailable")
        val model=snapshot.models[device.modelRevision]?:error("agent_tool_device_unavailable")
        check(!model.modelId.startsWith("urn:limelink:model:desktop:")){"agent_tool_device_unavailable"};return device to model
    }
    private suspend fun report(original:AgentToolRecord,execution:Device):AgentToolRecord {
        val outcome=original.outcome?:return original;if(original.delivered)return original
        if(original.replyIntent!=null)agent.resolveToolResult(original.reference,original.reference.space,execution,original.call,outcome,original.replyIntent)
        else agent.completeTool(original.reference,original.reference.space,execution,original.call,outcome){pending->
            val record=current(original.id,original.reference)
            check(record.replyIntent==null && pending.origin==record.reference.origin && pending.space==record.reference.space){"agent_tool_reply_intent_mismatch"}
            save(record.copy(replyIntent=pending.intent))
        }
        return current(original.id,original.reference).copy(delivered=true).also{save(it)}
    }
    private suspend fun outcome(record:AgentToolRecord,success:Boolean,output:JsonObject,execution:Device):AgentToolRecord {
        AgentToolProtocol.result(record.call,success,output)
        val updated=record.copy(outcome=AgentToolOutcome(success,output));save(updated);return report(updated,execution)
    }
    private suspend fun failure(record:AgentToolRecord,error:String,execution:Device)=outcome(record,false,buildJsonObject{put("error",error)},execution)
    private suspend fun read(record:AgentToolRecord,execution:Device):AgentToolRecord {
        check(record.call.expiresAt>Instant.now().epochSecond){"agent_tool_call_expired"}
        val snapshot=gateway.snapshot(record.reference.space)
        val selected=try{target(record,snapshot)}catch(error:IllegalStateException){if(error.message=="agent_tool_device_unavailable")return failure(record,error.message!!,execution);throw error}
        val(device,model)=selected
        val properties=model.services.flatMap{service->service.properties.filter{it.schema.type in setOf("boolean","integer","number","string") && it.access.any{access->access in setOf("read","write")}}.map{p->
            val path=service.id+"."+p.id;val observed=if("read" in p.access)device.reported[path]else null
            buildJsonObject{put("path",path);put("schema",json.encodeToJsonElement(p.schema));put("writable","write" in p.access);put("value",observed?.value?:JsonNull);put("observed_at",observed?.observedAt?.let(::JsonPrimitive)?:JsonNull);put("quality",observed?.quality?:"unknown")}
        }}
        val output=buildJsonObject{put("device_id",device.deviceId);put("model_revision",device.modelRevision);put("ready",device.ready);put("properties",JsonArray(properties))}
        if(properties.size>8 || output.toString().toByteArray(Charsets.UTF_8).size>1600)return failure(record,"agent_tool_response_budget",execution)
        try{AgentToolProtocol.result(record.call,true,output)}catch(_:IllegalArgumentException){return failure(record,"agent_tool_invalid_observation",execution)}
        return outcome(record,true,output,execution)
    }
    suspend fun receive(reference:AgentReference,space:String,execution:Device):AgentToolRecord?=mutex.withLock {
        checkTarget(reference,space,execution);val batch=agent.pendingTools(reference,space,execution);val call=batch.calls.firstOrNull()?:return@withLock null
        val previous=records().singleOrNull{it.id==call.id}
        if(previous!=null){check(previous.reference==reference && previous.call==call){"agent_tool_record_conflict"};return@withLock if(previous.outcome!=null)report(previous,execution)else if(previous.call.isWrite)previous else read(previous,execution)}
        val record=AgentToolRecord(reference,call,batch.expiresAt);save(record);if(call.isWrite)record else read(record,execution)
    }
    private fun validValue(value:JsonElement,schema:ValueSchema):Boolean {
        if(!AgentToolProtocol.scalar(value) || schema.enumValues.isNotEmpty() && value !in schema.enumValues)return false
        val p=value.jsonPrimitive
        return when(schema.type){
            "boolean"->!p.isString && p.booleanOrNull!=null
            "string"->p.isString && p.content.codePointCount(0,p.content.length) in (schema.minLength?:0)..(schema.maxLength?:Int.MAX_VALUE)
            "integer","number"->!p.isString && (schema.type!="integer" || p.longOrNull!=null) && p.doubleOrNull?.let{it.isFinite() && it>=(schema.minimum?:-Double.MAX_VALUE) && it<=(schema.maximum?:Double.MAX_VALUE)}==true
            else->false
        }
    }
    suspend fun confirm(id:String,reference:AgentReference,space:String,execution:Device):AgentToolRecord=mutex.withLock {
        checkTarget(reference,space,execution);var record=current(id,reference);check(record.canConfirm){"resolve_original_iot_command_first"};stillPending(record,execution)
        val(device,model)=target(record,gateway.snapshot(space));check(device.ready && record.call.revision==device.modelRevision){"agent_tool_model_or_availability_changed"}
        val properties=model.services.flatMap{s->s.properties.filter{s.id+"."+it.id==record.call.path}}
        check(properties.size==1 && "write" in properties[0].access && validValue(record.call.value,properties[0].schema)){"agent_tool_property_not_allowed"}
        currentCoroutineContext().ensureActive();check(record.canConfirm){"agent_tool_call_expired"}
        val intent=CommandIntent.create(device,record.call.path,record.call.value)
        record=record.copy(intent=intent);save(record);currentCoroutineContext().ensureActive()
        check(record.call.expiresAt>Instant.now().epochSecond){"agent_tool_call_expired"}
        finish(record,gateway.create(space,intent),execution)
    }
    private suspend fun finish(original:AgentToolRecord,initial:Command,execution:Device):AgentToolRecord {
        var record=original;var command=initial;val intent=checkNotNull(record.intent){"agent_tool_intent_missing"}
        record=record.copy(commandID=command.commandId,commandStatus=command.status);save(record)
        repeat(20){if(command.status in setOf("accepted","dispatched")){delay(200);command=gateway.resolve(record.reference.space,intent)}}
        record=record.copy(commandID=command.commandId,commandStatus=command.status);save(record)
        check(command.status in setOf("confirmed","failed","expired","rejected","unknown")){"resolve_original_iot_command_first"}
        if(record.outcome!=null)return record
        val observed=(command.evidence as? JsonObject)?.get("observed_at")?.takeIf(AgentToolProtocol::timestamp)?:JsonNull
        val output=JsonObject(record.call.arguments+mapOf("command_id" to JsonPrimitive(command.commandId),"status" to JsonPrimitive(command.status),"observed_at" to observed))
        return outcome(record,command.status=="confirmed",output,execution)
    }
    suspend fun recoverCommand(id:String,reference:AgentReference,space:String,execution:Device):AgentToolRecord=mutex.withLock {
        checkTarget(reference,space,execution);val record=current(id,reference);finish(record,gateway.resolve(space,checkNotNull(record.intent){"agent_tool_intent_missing"}),execution)
    }
    suspend fun sendResult(id:String,reference:AgentReference,space:String,execution:Device):AgentToolRecord=mutex.withLock {checkTarget(reference,space,execution);report(current(id,reference),execution)}
    suspend fun reject(id:String,reference:AgentReference,space:String,execution:Device):AgentToolRecord=mutex.withLock {
        checkTarget(reference,space,execution);val record=current(id,reference);check(record.canConfirm){"resolve_original_iot_command_first"};stillPending(record,execution);failure(record,"user_rejected",execution)
    }
}
