package run.limeai.link.core

import java.io.File
import java.io.IOException
import java.net.URI
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import run.limeai.iot.core.*
import kotlin.test.*

class AgentClientTest {
    private val root=generateSequence(File(System.getProperty("user.dir"))){it.parentFile}.first{File(it,"contracts/desktop.json").exists()}
    @Test fun sharedResponseVectors() {
        val cases=Json.parseToJsonElement(File(root,"contracts/fixtures/agent-responses.json").readText()).jsonObject["cases"]!!.jsonArray
        for(item in cases){val c=item.jsonObject;val accepted=runCatching{if(c["kind"]!!.jsonPrimitive.content=="run")AgentProtocol.run(c["value"]!!.jsonObject,c["id"]!!.jsonPrimitive.content,c["after"]!!.jsonPrimitive.int)else AgentProtocol.capabilities(c["value"]!!.jsonObject)}.isSuccess;assertEquals(c["valid"]!!.jsonPrimitive.boolean,accepted,c["name"]!!.jsonPrimitive.content)}
    }
    @Test fun durableReferenceRecoveryAndTargetIsolation()=runBlocking {
        val store=Store();val handler=Handler();val link=LinkClient("https://gateway.example",store,handler)
        link.login("fixture");val device=link.snapshot("chosen").devices.single();val client=AgentClient(link,store)
        assertEquals("invalid_exchange_path",assertFailsWith<IllegalArgumentException>{link.perform("chosen",device,"agent.submit",buildJsonObject{})}.message)
        assertTrue(client.discover("chosen",device).localApprovalRequired)
        assertEquals("awaiting_approval",client.submit("chosen",device,"work","一次任务","read-only").state)
        val reference=client.references().first();client.query(reference,"chosen",device)
        var before=handler.posts
        assertEquals("agent_target_changed",assertFailsWith<IllegalStateException>{client.query(reference,"other",device)}.message);assertEquals(before,handler.posts)
        handler.lose=true;assertFailsWith<IOException>{client.submit("chosen",device,"work","只提交一次","read-only")}
        before=handler.posts;val restored=AgentClient(link,store)
        assertEquals(404,assertFailsWith<GatewayException>{restored.recover()}.status);assertNotNull(link.pending())
        assertEquals("awaiting_approval",restored.recover()?.state);assertEquals(before,handler.posts);assertNull(link.pending())
        store.failReferences=true;assertFailsWith<IOException>{client.submit("chosen",device,"work","持久化先于发送","read-only")};assertEquals(before,handler.posts);store.failReferences=false
        handler.missing=true;assertEquals("target_capability_changed",assertFailsWith<IllegalStateException>{client.discover("chosen",device)}.message);assertEquals(before,handler.posts);handler.missing=false
        handler.malformed=true;assertFailsWith<IllegalArgumentException>{client.submit("chosen",device,"work","校验原任务","read-only")};assertNotNull(link.pending())
    }
    private class Store:SessionStore {
        val values=mutableMapOf<String,String>();var failReferences=false
        override suspend fun load(origin:String)=values[origin]
        override suspend fun save(origin:String,value:String?){if(failReferences&&origin.endsWith("#limelink.agent-runs"))throw IOException("storage_unavailable");if(value==null)values.remove(origin)else values[origin]=value}
    }
    private inner class Handler:GatewayTransport {
        var posts=0;var lose=false;var malformed=false;var missing=false;var missingOnce=false;var last:JsonObject?=null
        override suspend fun send(request:GatewayRequest):GatewayResponse {
            val path=URI(request.url).path;var status=200
            val body:JsonObject=when {
                path.endsWith("/auth/session")->buildJsonObject{put("authenticated",true);put("csrf_token","fixture");put("expires_at","2030-01-01T00:00:00Z")}
                path.endsWith("/capabilities")->buildJsonObject{put("models",buildJsonObject{val model=Json.parseToJsonElement(File(root,"contracts/desktop.json").readText()).jsonObject;put("sha256:fixture",if(missing)JsonObject(model+ ("services" to JsonArray(emptyList())))else model)})}
                path.endsWith("/devices")->buildJsonObject{put("items",buildJsonArray{add(buildJsonObject{put("device_id","desktop");put("model_revision","sha256:fixture");put("ready",true)})});put("next_cursor",JsonNull)}
                request.method=="POST"->{
                    posts++;val input=Json.parseToJsonElement(request.body!!).jsonObject;val operation=input["operation"]!!.jsonObject
                    assertEquals("agent.exchange",operation["path"]!!.jsonPrimitive.content)
                    val exchange=operation["value"]!!.jsonObject;val kind=exchange["kind"]!!.jsonPrimitive.content;val payload=Json.parseToJsonElement(exchange["payload"]!!.jsonPrimitive.content).jsonObject
                    val value=if(kind=="agent.capabilities")buildJsonObject{put("adapter","codex-app-server");put("configured",true);put("authentication","managed_by_codex");put("local_approval_required",true);put("workspaces",buildJsonArray{add(buildJsonObject{put("id","work");put("name","工作目录");put("allow_write",false)})})}
                    else buildJsonObject{put("id",if(malformed)UUID.randomUUID().toString()else payload["id"]!!.jsonPrimitive.content);put("state","awaiting_approval");put("workspace_id","work");put("sandbox","read-only");put("session_id",JsonNull);put("error",JsonNull);put("expires_at",2000000000L);put("events",JsonArray(emptyList()));put("cursor",payload["after"]?.jsonPrimitive?.int?:0)}
                    val response=buildJsonObject{put("command_id",UUID.randomUUID().toString());put("status","confirmed");put("request_digest","sha256:"+"b".repeat(64));put("request",JsonObject(input+mapOf("space_id" to JsonPrimitive("chosen"),"idempotency_key" to JsonPrimitive(request.headers.getValue("Idempotency-Key")))));put("error",JsonNull);put("evidence",buildJsonObject{put("type","action_result");put("path","agent.exchange");put("input_digest","sha256:"+"c".repeat(64));put("output",buildJsonObject{put("response",buildJsonObject{put("ok",true);put("value",value)}.toString())});put("completion","submitted");put("observed_at",Instant.now().toString())})};last=response
                    if(lose&&kind=="agent.submit"){lose=false;missingOnce=true;throw IOException("lost_response")};response
                }
                path.contains("/commands/by-key/")->{if(missingOnce){missingOnce=false;status=404;buildJsonObject{put("error",buildJsonObject{put("code","command_not_found")})}}else checkNotNull(last)}
                else->buildJsonObject{put("items",JsonArray(emptyList()));put("next_cursor",JsonNull)}
            }
            return GatewayResponse(status,body.toString(),"__Host-limeiot_session="+"a".repeat(64)+"; Secure; HttpOnly")
        }
    }
}
