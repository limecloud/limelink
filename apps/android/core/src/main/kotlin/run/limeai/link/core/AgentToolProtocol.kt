package run.limeai.link.core

import java.time.OffsetDateTime
import kotlinx.serialization.*
import kotlinx.serialization.json.*

@Serializable data class AgentToolCall(val id:String,val tool:String,val arguments:JsonObject,@SerialName("expires_at") val expiresAt:Long) {
    val isWrite get()=tool=="limeiot_command"
    val device get()=arguments["device_id"]!!.jsonPrimitive.content
    val path get()=arguments["path"]?.jsonPrimitive?.content?:""
    val revision get()=arguments["model_revision"]?.jsonPrimitive?.content?:""
    val value get()=arguments["value"]?:JsonNull
}
data class AgentToolCapabilities(val enabled:Boolean)
data class AgentToolBatch(val id:String,val calls:List<AgentToolCall>,val expiresAt:Long)

/** 模型输出只作为有界数据；设备范围以原任务耐久记录为准。 */
object AgentToolProtocol {
    private val json=Json { ignoreUnknownKeys=false }
    private fun valid(value:Boolean){require(value){"invalid_agent_tool_response"}}
    internal fun identifier(value:String)=value.matches(Regex("[A-Za-z0-9_.:-]{1,128}"))
    private fun revision(value:JsonElement?)=(value as? JsonPrimitive)?.let{it.isString && it.content.matches(Regex("sha256:[a-f0-9]{64}"))}==true
    private fun path(value:JsonElement?)=(value as? JsonPrimitive)?.let{it.isString && it.content.matches(Regex("[A-Za-z0-9_]{1,64}\\.[A-Za-z0-9_]{1,64}"))}==true
    internal fun scalar(value:JsonElement?):Boolean {
        if(value !is JsonPrimitive || value is JsonNull || value.toString().toByteArray(Charsets.UTF_8).size>512)return false
        return value.isString || value.booleanOrNull!=null || value.doubleOrNull?.isFinite()==true
    }
    internal fun timestamp(value:JsonElement?):Boolean=value is JsonNull || value is JsonPrimitive && value.isString && runCatching{OffsetDateTime.parse(value.content)}.isSuccess
    private fun number(value:JsonElement?)=value is JsonPrimitive && !value.isString && value.doubleOrNull?.isFinite()==true
    private fun schema(value:JsonObject):Boolean {
        if(!setOf("type","minimum","maximum","minLength","maxLength","enum").containsAll(value.keys) || value["type"] !in listOf("boolean","integer","number","string").map(::JsonPrimitive))return false
        for(key in listOf("minimum","maximum"))if(key in value&&!number(value[key]))return false
        for(key in listOf("minLength","maxLength"))if(key in value){val n=value[key];if(n !is JsonPrimitive || n.isString || n.longOrNull?.let{it>=0}!=true)return false}
        if("enum" in value){val items=value["enum"] as? JsonArray?:return false;if(items.size !in 1..16||!items.all(::scalar))return false}
        return true
    }
    fun validGrant(devices:List<String>)=devices.size<=4 && devices.distinct().size==devices.size && devices.all(::identifier)
    fun capabilities(value:JsonObject):AgentToolCapabilities {
        valid(value.keys==setOf("enabled","tools","approval_required","max_devices") && value["enabled"] in listOf(JsonPrimitive(true),JsonPrimitive(false)) && value["approval_required"]==JsonPrimitive(true) && value["max_devices"]==JsonPrimitive(4) && value["tools"]==JsonArray(listOf(JsonPrimitive("limeiot_read"),JsonPrimitive("limeiot_command"))))
        return AgentToolCapabilities(value["enabled"]!!.jsonPrimitive.boolean)
    }
    fun call(value:JsonObject,devices:List<String>):AgentToolCall {
        val call=json.decodeFromJsonElement<AgentToolCall>(value);validate(call,devices);return call
    }
    fun validate(call:AgentToolCall,devices:List<String>) {
        valid(call.id.matches(Regex("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")) && call.expiresAt>=0 && call.arguments.toString().toByteArray(Charsets.UTF_8).size<=1024 && call.arguments["device_id"] in devices.map(::JsonPrimitive))
        if(call.tool=="limeiot_read" && call.arguments.keys==setOf("device_id"))return
        valid(call.isWrite && call.arguments.keys==setOf("device_id","model_revision","path","value") && revision(call.arguments["model_revision"]) && path(call.arguments["path"]) && scalar(call.value))
    }
    fun pending(value:JsonObject,reference:AgentReference):AgentToolBatch {
        val required=setOf("id","devices","calls","expires_at")
        valid(value.keys.containsAll(required) && (required+"content_expired").containsAll(value.keys) && value["id"]==JsonPrimitive(reference.id))
        val expires=value["expires_at"]!!.jsonPrimitive.let{valid(!it.isString);it.long}
        val devices=value["devices"]!!.jsonArray;val calls=value["calls"]!!.jsonArray
        valid(expires>=0 && calls.size<=1)
        if("content_expired" in value){valid(value["content_expired"]==JsonPrimitive(true) && devices.isEmpty() && calls.isEmpty());return AgentToolBatch(reference.id,emptyList(),expires)}
        valid(devices==JsonArray(reference.iotDevices.map(::JsonPrimitive)) || expires<=java.time.Instant.now().epochSecond && devices.isEmpty() && calls.isEmpty())
        val decoded=calls.map{call(it.jsonObject,reference.iotDevices).also{c->valid(c.expiresAt<=expires)}}
        return AgentToolBatch(reference.id,decoded,expires)
    }
    fun completion(value:JsonObject,id:String,call:String){valid(value.keys==setOf("id","call_id","recorded") && value["id"]==JsonPrimitive(id) && value["call_id"]==JsonPrimitive(call) && value["recorded"]==JsonPrimitive(true))}
    fun result(call:AgentToolCall,success:Boolean,output:JsonObject) {
        valid(output.toString().toByteArray(Charsets.UTF_8).size<=1600)
        if(!success && output.keys==setOf("error") && (output["error"] as? JsonPrimitive)?.let{it.isString&&it.content.matches(Regex("[a-z0-9_]{1,96}"))}==true)return
        valid(output["device_id"]==JsonPrimitive(call.device))
        if(!call.isWrite){
            valid(success && output.keys==setOf("device_id","model_revision","ready","properties") && revision(output["model_revision"]) && output["ready"] in listOf(JsonPrimitive(true),JsonPrimitive(false)))
            val properties=output["properties"]!!.jsonArray;valid(properties.size<=8)
            val paths=mutableSetOf<JsonElement>()
            for(raw in properties){val p=raw.jsonObject
                valid(p.keys==setOf("path","schema","writable","value","observed_at","quality") && path(p["path"]) && paths.add(p["path"]!!) && schema(p["schema"]!!.jsonObject) && p["writable"] in listOf(JsonPrimitive(true),JsonPrimitive(false)) && (p["value"] is JsonNull || scalar(p["value"])) && timestamp(p["observed_at"]))
                valid((p["quality"] as? JsonPrimitive)?.let{it.isString&&it.content.toByteArray(Charsets.UTF_8).size<=32}==true)
            }
        }else{
            valid(output.keys==setOf("device_id","model_revision","path","value","command_id","status","observed_at") && listOf("model_revision","path","value").all{output[it]==call.arguments[it]} && (output["command_id"] as? JsonPrimitive)?.let{it.isString&&identifier(it.content)}==true && output["status"] in listOf("confirmed","failed","expired","rejected","unknown").map(::JsonPrimitive) && success==(output["status"]==JsonPrimitive("confirmed")) && timestamp(output["observed_at"]))
        }
    }
}
