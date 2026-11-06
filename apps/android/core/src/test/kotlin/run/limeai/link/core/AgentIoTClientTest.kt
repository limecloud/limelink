package run.limeai.link.core

import java.io.File
import java.io.IOException
import java.net.URI
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import run.limeai.iot.core.*
import kotlin.test.*

class AgentIoTClientTest {
    private class Store:SessionStore {
        val values=mutableMapOf<String,String>();var failJournal=false;var loseReadback=false;var readbackPending=false;var slowIntent=false
        override suspend fun load(origin:String):String? {if(origin.endsWith("#limelink.agent-iot")&&readbackPending){readbackPending=false;return null};return values[origin]}
        override suspend fun save(origin:String,value:String?){
            if(origin.endsWith("#limelink.agent-iot")&&failJournal)throw IOException("storage_unavailable")
            if(value==null)values.remove(origin)else values[origin]=value
            if(origin.endsWith("#limelink.agent-iot")&&loseReadback){loseReadback=false;readbackPending=true}
            if(origin.endsWith("#limelink.agent-iot")&&slowIntent&&value!=null&&Json.parseToJsonElement(value).jsonArray.any{it.jsonObject["intent"]?.let{v->v!=JsonNull}==true}){slowIntent=false;delay(1200)}
        }
        fun expire(){for(key in values.keys.filter{it.endsWith("#limelink.agent-iot")})values[key]=JsonArray(Json.parseToJsonElement(values.getValue(key)).jsonArray.map{raw->val r=raw.jsonObject;JsonObject(r+mapOf("runExpiresAt" to JsonPrimitive(1),"call" to JsonObject(r["call"]!!.jsonObject+("expires_at" to JsonPrimitive(0)))))}).toString()}
    }
    private class Transport:GatewayTransport {
        val revision="sha256:"+"a".repeat(64);val lampRevision="sha256:"+"b".repeat(64)
        var devicePosts=0;var resultPosts=0;var run="";var grant=JsonArray(emptyList());var proposal:JsonObject?=null
        var loseDevice=false;var loseReply=false;var missingDevice=false;var readOnly=false;var changedRevision=false;var unknown=false;var wrongReceipt=false;var omitLamp=false;var cancelSnapshot=false
        var commandEntered:CompletableDeferred<Unit>?=null;var releaseCommand:CompletableDeferred<Unit>?=null
        val commands=mutableMapOf<String,JsonObject>();val deviceKeys=mutableSetOf<String>()
        fun publish(tool:String="limeiot_command",device:String="lamp",value:JsonElement=JsonPrimitive(true),ttl:Long=120){
            proposal=buildJsonObject{put("id",UUID.randomUUID().toString());put("tool",tool);put("arguments",buildJsonObject{put("device_id",device);if(tool=="limeiot_command"){put("model_revision",lampRevision);put("path","light.power");put("value",value)}});put("expires_at",Instant.now().epochSecond+ttl)}
        }
        override suspend fun send(request:GatewayRequest):GatewayResponse {
            val path=URI(request.url).path;var status=200
            val body=when {
                path.endsWith("/auth/session")->buildJsonObject{put("authenticated",true);put("csrf_token","fixture");put("expires_at","2030-01-01T00:00:00Z")}
                path.endsWith("/capabilities")->{
                    val root=generateSequence(File(System.getProperty("user.dir"))){it.parentFile}.first{File(it,"contracts/desktop.json").exists()}
                    val desktop=Json.parseToJsonElement(File(root,"contracts/desktop.json").readText())
                    val model=buildJsonObject{put("model_id","urn:fixture:lamp:1");put("services",buildJsonArray{add(buildJsonObject{put("id","light");put("properties",buildJsonArray{add(buildJsonObject{put("id","power");put("schema",buildJsonObject{put("type","boolean")});put("access",JsonArray((if(readOnly)listOf("read")else listOf("read","write")).map(::JsonPrimitive)))})});put("events",JsonArray(emptyList()));put("actions",JsonArray(emptyList()))})})}
                    buildJsonObject{put("models",buildJsonObject{put(revision,desktop);put(lampRevision,model);put("sha256:"+"c".repeat(64),model)})}
                }
                path.endsWith("/devices")->{
                    if(cancelSnapshot)throw CancellationException("cancelled_snapshot")
                    buildJsonObject{put("items",buildJsonArray{
                        add(buildJsonObject{put("device_id","desktop");put("model_revision",revision);put("ready",true)})
                        if(!omitLamp)add(buildJsonObject{put("device_id","lamp");put("model_revision",if(changedRevision)"sha256:"+"c".repeat(64)else lampRevision);put("ready",true);put("reported",buildJsonObject{put("light.power",buildJsonObject{put("value",false);put("observed_at",Instant.now().toString());put("quality","good");put("source","fixture")})})})
                    });put("next_cursor",JsonNull)}
                }
                path.endsWith("/commands") && request.method=="POST"->{
                    val key=request.headers.getValue("Idempotency-Key");val input=JsonObject(Json.parseToJsonElement(request.body!!).jsonObject+mapOf("space_id" to JsonPrimitive("chosen"),"idempotency_key" to JsonPrimitive(key)))
                    val operation=input["operation"]!!.jsonObject
                    val evidence:JsonElement
                    var kind=""
                    if(operation["path"]==JsonPrimitive("agent.exchange")){
                        val exchange=operation["value"]!!.jsonObject;kind=exchange["kind"]!!.jsonPrimitive.content;val payload=Json.parseToJsonElement(exchange["payload"]!!.jsonPrimitive.content).jsonObject
                        val value=when(kind){
                            "agent.submit"->{run=payload["id"]!!.jsonPrimitive.content;grant=payload["iot_devices"]?.jsonArray?:JsonArray(emptyList());buildJsonObject{put("id",run);put("state","awaiting_approval");put("workspace_id","work");put("sandbox","read-only");put("session_id",JsonNull);put("error",JsonNull);put("expires_at",Instant.now().epochSecond+3600);put("events",JsonArray(emptyList()));put("cursor",0)}}
                            "agent.tool_capabilities"->buildJsonObject{put("enabled",true);put("tools",JsonArray(listOf("limeiot_read","limeiot_command").map(::JsonPrimitive)));put("approval_required",true);put("max_devices",4)}
                            "agent.tool_pending"->buildJsonObject{put("id",run);put("devices",grant);put("calls",JsonArray(proposal?.let{listOf(it)}?:emptyList()));put("expires_at",Instant.now().epochSecond+3600)}
                            "agent.tool_result"->{resultPosts++;proposal=null;buildJsonObject{put("id",run);put("call_id",payload["call_id"]!!);put("recorded",true)}}
                            else->error("unexpected_tool_fixture_kind")
                        }
                        evidence=buildJsonObject{put("type","action_result");put("path","agent.exchange");put("input_digest","sha256:"+"e".repeat(64));put("output",buildJsonObject{put("response",buildJsonObject{put("ok",true);put("value",value)}.toString())});put("completion","submitted");put("observed_at",Instant.now().toString())}
                    }else{
                        commandEntered?.complete(Unit);releaseCommand?.await()
                        devicePosts++;deviceKeys.add(key);assertEquals(JsonPrimitive("property.set"),operation["type"])
                        evidence=if(unknown)JsonNull else buildJsonObject{put("type","device_result");put("reported",buildJsonObject{put("light.power",operation["value"]!!)})}
                    }
                    val receipt=buildJsonObject{put("command_id",UUID.randomUUID().toString());put("status",if(kind.isEmpty()&&unknown)"unknown"else "confirmed");put("request_digest","sha256:"+"d".repeat(64));put("request",input);put("error",JsonNull);put("evidence",evidence)}
                    commands[key]=receipt
                    if(kind.isEmpty()&&loseDevice){loseDevice=false;missingDevice=true;throw IOException("lost_device_response")}
                    if(kind=="agent.tool_result"&&loseReply){loseReply=false;throw IOException("lost_reply_response")}
                    if(kind.isEmpty()&&wrongReceipt){wrongReceipt=false;JsonObject(receipt+("evidence" to buildJsonObject{put("type","device_result");put("reported",buildJsonObject{put("light.power",false)})}))}else receipt
                }
                path.contains("/commands/by-key/")->{val key=path.substringAfterLast('/');if(missingDevice&&key in deviceKeys){missingDevice=false;status=404;buildJsonObject{put("error",buildJsonObject{put("code","command_not_found")})}}else checkNotNull(commands[key])}
                else->buildJsonObject{put("items",JsonArray(emptyList()));put("next_cursor",JsonNull)}
            }
            return GatewayResponse(status,body.toString(),"__Host-limeiot_session="+"a".repeat(64)+"; Secure; HttpOnly")
        }
    }
    private class Fixture(val store:Store,val transport:Transport,val link:LinkClient,val agent:AgentClient,val client:AgentIoTClient,val execution:Device,val reference:AgentReference)
    private suspend fun setup():Fixture {
        val store=Store();val t=Transport();val link=LinkClient("https://gateway.example",store,t);link.login("fixture");val execution=link.snapshot("chosen").devices.first();val agent=AgentClient(link,store)
        agent.submit("chosen",execution,"work","控制所选设备","read-only",iotDevices=listOf("lamp"))
        return Fixture(store,t,link,agent,AgentIoTClient(link.gateway,agent,store),execution,agent.references().single())
    }
    @Test fun readsAndExplicitWriteConfirmation()=runBlocking {
        val f=setup();assertEquals(listOf("lamp"),f.reference.iotDevices);assertTrue(f.agent.discoverTools("chosen",f.execution).enabled)
        f.transport.publish("limeiot_read");val read=f.client.receive(f.reference,"chosen",f.execution)!!;assertTrue(read.delivered&&read.outcome!!.success);assertEquals(0,f.transport.devicePosts)
        f.transport.publish();val proposal=f.client.receive(f.reference,"chosen",f.execution)!!;assertTrue(proposal.canConfirm);assertEquals(0,f.transport.devicePosts)
        val result=f.client.confirm(proposal.id,f.reference,"chosen",f.execution);assertTrue(result.delivered&&result.outcome!!.success);assertNotNull(result.replyIntent)
        assertEquals("resolve_original_iot_command_first",assertFailsWith<IllegalStateException>{f.client.confirm(proposal.id,f.reference,"chosen",f.execution)}.message);assertEquals(1,f.transport.devicePosts)
    }
    @Test fun lostDeviceAndReplyResponsesOnlyQueryOriginal()=runBlocking {
        val f=setup();f.transport.publish();val p=f.client.receive(f.reference,"chosen",f.execution)!!;f.transport.loseDevice=true
        assertFailsWith<IOException>{f.client.confirm(p.id,f.reference,"chosen",f.execution)}
        val restarted=AgentIoTClient(f.link.gateway,f.agent,f.store)
        assertEquals(404,assertFailsWith<GatewayException>{restarted.recoverCommand(p.id,f.reference,"chosen",f.execution)}.status);assertNotNull(restarted.records().single().intent)
        assertTrue(restarted.recoverCommand(p.id,f.reference,"chosen",f.execution).delivered);assertEquals(1,f.transport.devicePosts);assertEquals(1,f.transport.resultPosts)
        val r=setup();r.transport.publish();val proposal=r.client.receive(r.reference,"chosen",r.execution)!!;r.transport.loseReply=true
        assertFailsWith<IOException>{r.client.confirm(proposal.id,r.reference,"chosen",r.execution)}
        r.store.expire();assertEquals(0,r.client.pruneExpired());r.agent.recover()
        val restored=AgentIoTClient(r.link.gateway,r.agent,r.store);assertTrue(restored.sendResult(proposal.id,r.reference,"chosen",r.execution).delivered)
        assertEquals(1,r.transport.devicePosts);assertEquals(1,r.transport.resultPosts);assertEquals(1,restored.pruneExpired())
    }
    @Test fun persistenceReadbackAndExpiryNeverCauseAWrite()=runBlocking {
        for(mode in listOf("save","readback","expired","slow","cancelled")){
            val f=setup();f.transport.publish(ttl=if(mode=="slow")1 else 120);val p=f.client.receive(f.reference,"chosen",f.execution)!!
            when(mode){"save"->f.store.failJournal=true;"readback"->f.store.loseReadback=true;"expired"->f.store.expire();"slow"->f.store.slowIntent=true;"cancelled"->f.transport.cancelSnapshot=true}
            val failure=runCatching{f.client.confirm(p.id,f.reference,"chosen",f.execution)}.exceptionOrNull();assertNotNull(failure);assertEquals(0,f.transport.devicePosts,mode)
            if(mode=="slow"){assertEquals("agent_tool_call_expired",failure.message);assertNotNull(f.client.records().single().intent)}
            if(mode=="readback"){assertNotNull(f.client.records().single().intent);f.store.expire();assertEquals(0,f.client.pruneExpired())}
            if(mode=="expired")assertEquals(1,f.client.pruneExpired())
        }
    }
    @Test fun scopeFreshModelRefusalUnknownAndForgedReceipt()=runBlocking {
        for(mode in listOf("scope","read-only","revision","bad-value","reject","unknown","bad-receipt","read-missing")){
            val f=setup();f.transport.publish(if(mode=="read-missing")"limeiot_read"else "limeiot_command",if(mode=="scope")"outside"else "lamp",if(mode=="bad-value")JsonPrimitive(5)else JsonPrimitive(true))
            if(mode=="scope"){assertFailsWith<IllegalArgumentException>{f.client.receive(f.reference,"chosen",f.execution)};continue}
            if(mode=="read-missing"){f.transport.omitLamp=true;assertFalse(f.client.receive(f.reference,"chosen",f.execution)!!.outcome!!.success);assertEquals(0,f.transport.devicePosts);continue}
            val p=f.client.receive(f.reference,"chosen",f.execution)!!
            when(mode){"read-only"->f.transport.readOnly=true;"revision"->f.transport.changedRevision=true;"unknown"->f.transport.unknown=true;"bad-receipt"->f.transport.wrongReceipt=true}
            when(mode){
                "reject"->assertFalse(f.client.reject(p.id,f.reference,"chosen",f.execution).outcome!!.success)
                "unknown"->{
                    val r=f.client.confirm(p.id,f.reference,"chosen",f.execution);assertTrue(r.needsRecovery);assertFalse(r.outcome!!.success);f.store.expire();assertEquals(0,f.client.pruneExpired())
                    for(key in f.transport.deviceKeys){val previous=f.transport.commands.getValue(key);f.transport.commands[key]=JsonObject(previous+mapOf("status" to JsonPrimitive("confirmed"),"evidence" to buildJsonObject{put("type","device_result");put("reported",buildJsonObject{put("light.power",true)})}))}
                    val later=f.client.recoverCommand(p.id,f.reference,"chosen",f.execution);assertEquals("confirmed",later.commandStatus);assertFalse(later.outcome!!.success);assertEquals(JsonPrimitive("unknown"),later.outcome.output["status"]);assertEquals(1,f.transport.resultPosts)
                }
                "bad-receipt"->{assertFailsWith<GatewayException>{f.client.confirm(p.id,f.reference,"chosen",f.execution)};assertTrue(f.client.recoverCommand(p.id,f.reference,"chosen",f.execution).delivered)}
                else->assertFailsWith<IllegalStateException>{f.client.confirm(p.id,f.reference,"chosen",f.execution)}
            }
            assertEquals(if(mode in listOf("unknown","bad-receipt"))1 else 0,f.transport.devicePosts,mode)
            assertFailsWith<IllegalStateException>{f.client.receive(f.reference,"other",f.execution)}
        }
    }
    @Test fun concurrentConfirmationsCreateOneDeviceCommand()=runBlocking {
        val f=setup();f.transport.publish();val p=f.client.receive(f.reference,"chosen",f.execution)!!
        f.transport.commandEntered=CompletableDeferred();f.transport.releaseCommand=CompletableDeferred()
        val results=coroutineScope{
            val first=async{runCatching{f.client.confirm(p.id,f.reference,"chosen",f.execution)}}
            f.transport.commandEntered!!.await()
            val second=async(start=CoroutineStart.UNDISPATCHED){runCatching{f.client.confirm(p.id,f.reference,"chosen",f.execution)}}
            f.transport.releaseCommand!!.complete(Unit);listOf(first,second).awaitAll()
        }
        assertEquals(1,results.count{it.isSuccess});assertEquals(1,f.transport.devicePosts);assertEquals(1,f.transport.resultPosts)
    }
}
