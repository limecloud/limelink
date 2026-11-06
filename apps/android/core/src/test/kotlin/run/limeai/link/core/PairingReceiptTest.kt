package run.limeai.link.core

import java.io.File
import java.io.IOException
import java.net.URI
import java.time.Instant
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import run.limeai.iot.core.*
import kotlin.test.*

class PairingReceiptTest {
    private enum class Outcome { CONFIRMED, DELAYED, REJECTED, UNKNOWN, FAILED, LOST, NOT_FOUND, CHANGED, STRING_OK }
    private class Store:SessionStore {
        private val values=mutableMapOf<String,String>()
        var failClear=false
        override suspend fun load(origin:String)=values[origin]
        override suspend fun save(origin:String,value:String?){
            if(failClear && value==null)throw IOException("clear_failed")
            if(value==null)values.remove(origin)else values[origin]=value
        }
    }
    private class Handler(val outcome:Outcome):GatewayTransport {
        var posts=0;var queries=0;var cancelQuery=false
        private var original:JsonObject?=null
        private var key=""
        override suspend fun send(request:GatewayRequest):GatewayResponse {
            val path=URI(request.url).path
            var status=200
            val body=when {
                path.endsWith("/auth/session")->buildJsonObject{put("authenticated",true);put("csrf_token","fixture");put("expires_at","2030-01-01T00:00:00Z")}
                path.endsWith("/capabilities")->{
                    val root=generateSequence(File(System.getProperty("user.dir"))){it.parentFile}.first{File(it,"contracts/desktop.json").exists()}
                    buildJsonObject{put("models",buildJsonObject{put("sha256:fixture",Json.parseToJsonElement(File(root,"contracts/desktop.json").readText()))})}
                }
                path.endsWith("/devices")->buildJsonObject{put("items",buildJsonArray{add(buildJsonObject{put("device_id","desktop");put("model_revision","sha256:fixture");put("ready",true)})});put("next_cursor",JsonNull)}
                path.endsWith("/commands") && request.method=="POST"->{
                    posts++;original=Json.parseToJsonElement(request.body!!).jsonObject;key=request.headers.getValue("Idempotency-Key")
                    if(outcome==Outcome.LOST)throw IOException("lost_response")
                    receipt(false)
                }
                path.contains("/commands/by-key/")->{
                    queries++;assertTrue(path.endsWith(key))
                    if(cancelQuery)currentCoroutineContext().cancel()
                    if(outcome==Outcome.NOT_FOUND){status=404;buildJsonObject{put("error",buildJsonObject{put("code","command_not_found")})}}else receipt(true)
                }
                else->buildJsonObject{put("items",JsonArray(emptyList()));put("next_cursor",JsonNull)}
            }
            return GatewayResponse(status,body.toString(),"__Host-limeiot_session="+"a".repeat(64)+"; Secure; HttpOnly")
        }
        private fun receipt(queried:Boolean):JsonObject {
            val state=when {
                !queried && outcome in setOf(Outcome.DELAYED,Outcome.NOT_FOUND)->"accepted"
                outcome==Outcome.UNKNOWN || queried && outcome==Outcome.CHANGED->"unknown"
                outcome==Outcome.FAILED->"failed"
                else->"confirmed"
            }
            val response=buildJsonObject{put("ok",if(outcome==Outcome.STRING_OK)JsonPrimitive("true")else JsonPrimitive(outcome!=Outcome.REJECTED));put("value",buildJsonObject{put("state","pending")})}
            return buildJsonObject{
                put("command_id","pair-$posts");put("status",state);put("request_digest","sha256:"+"b".repeat(64))
                put("request",JsonObject(checkNotNull(original)+mapOf("space_id" to JsonPrimitive("chosen"),"idempotency_key" to JsonPrimitive(key))))
                put("error",JsonNull)
                put("evidence",if(state!="confirmed")JsonNull else buildJsonObject{
                    put("type","action_result");put("path","link.exchange");put("input_digest","sha256:"+"c".repeat(64))
                    put("output",buildJsonObject{put("response",response.toString())});put("completion","submitted");put("observed_at",Instant.now().toString())
                })
            }
        }
    }
    @Test fun verifiedPairingUnblocksNextTaskAndOtherCommandsRemain()=runBlocking {
        for(outcome in listOf(Outcome.CONFIRMED,Outcome.DELAYED)){
            val store=Store();val handler=Handler(outcome);val link=LinkClient("https://gateway.example",store,handler)
            link.login("fixture");val device=link.snapshot("chosen").devices.single()
            val command=link.perform("chosen",device,"pair",buildJsonObject{put("name","测试手机")})
            if(command.status=="accepted")assertEquals("confirmed",link.resolve().status)
            assertTrue(link.finishSuccessfulPairing());assertNull(link.pending());assertEquals(1,handler.posts)
            link.perform("chosen",device,"card",buildJsonObject{put("text","配对后继续")})
            val before=handler.queries
            assertFalse(link.finishSuccessfulPairing());assertNotNull(link.pending());assertEquals(before,handler.queries)
            assertEquals("resolve_original_request_first",assertFailsWith<IllegalStateException>{link.perform("chosen",device,"card",buildJsonObject{})}.message)
            assertEquals(2,handler.posts)
        }
    }
    @Test fun unresolvedPairingPreservesOriginalWithoutResubmission()=runBlocking {
        for(outcome in Outcome.entries.filter{it !in setOf(Outcome.CONFIRMED,Outcome.DELAYED)}){
            val store=Store();val handler=Handler(outcome);val link=LinkClient("https://gateway.example",store,handler)
            link.login("fixture");val device=link.snapshot("chosen").devices.single()
            try{link.perform("chosen",device,"pair",buildJsonObject{put("name","测试手机")});assertNotEquals(Outcome.LOST,outcome)}catch(e:IOException){assertEquals(Outcome.LOST,outcome)}
            val original=link.pending()
            if(outcome==Outcome.NOT_FOUND)assertEquals(404,assertFailsWith<GatewayException>{link.finishSuccessfulPairing()}.status)
            else if(outcome!=Outcome.LOST)assertFalse(link.finishSuccessfulPairing(),outcome.name)
            assertEquals(original,link.pending())
            assertEquals("resolve_original_request_first",assertFailsWith<IllegalStateException>{link.perform("chosen",device,"card",buildJsonObject{})}.message)
            assertEquals(1,handler.posts)
        }
    }
    @Test fun failedStorageAndCancellationKeepPairing()=runBlocking {
        for(cancel in listOf(false,true)){
            val store=Store();val handler=Handler(Outcome.CONFIRMED);val link=LinkClient("https://gateway.example",store,handler)
            link.login("fixture");val device=link.snapshot("chosen").devices.single()
            link.perform("chosen",device,"pair",buildJsonObject{put("name","测试手机")});val original=link.pending()
            if(cancel){handler.cancelQuery=true;val completion=async{link.finishSuccessfulPairing()};assertFailsWith<CancellationException>{completion.await()}}
            else{store.failClear=true;assertFailsWith<IOException>{link.finishSuccessfulPairing()}}
            assertEquals(original,link.pending());assertEquals(1,handler.posts)
        }
    }
    @Test fun automaticCompletionUsesOriginalReceiptAndNeverReplays()=runBlocking {
        for(kind in listOf("pair","status","card"))for(outcome in Outcome.entries){
            val store=Store();val handler=Handler(outcome);val link=LinkClient("https://gateway.example",store,handler)
            link.login("fixture");val device=link.snapshot("chosen").devices.single()
            try{link.perform("chosen",device,kind,buildJsonObject{})}catch(_:IOException){assertEquals(Outcome.LOST,outcome)}
            val original=link.pending()
            if(outcome==Outcome.NOT_FOUND){assertEquals(404,assertFailsWith<GatewayException>{link.finishKnownExchange()}.status);assertEquals(original,link.pending())}
            else{
                val known=outcome in setOf(Outcome.CONFIRMED,Outcome.DELAYED,Outcome.FAILED,Outcome.LOST)
                assertEquals(known,link.finishKnownExchange(),"$kind/$outcome")
                if(known)assertNull(link.pending())else assertEquals(original,link.pending())
            }
            assertEquals(1,handler.posts,"$kind/$outcome")
        }
    }
    @Test fun automaticCompletionKeepsOriginalWhenClearFailsOrCancelled()=runBlocking {
        for(cancel in listOf(false,true)){
            val store=Store();val handler=Handler(Outcome.CONFIRMED);val link=LinkClient("https://gateway.example",store,handler)
            link.login("fixture");val device=link.snapshot("chosen").devices.single()
            link.perform("chosen",device,"status",buildJsonObject{});val original=link.pending()
            if(cancel){handler.cancelQuery=true;val completion=async{link.finishKnownExchange()};assertFailsWith<CancellationException>{completion.await()}}
            else{store.failClear=true;assertFailsWith<IOException>{link.finishKnownExchange()}}
            assertEquals(original,link.pending());assertEquals(1,handler.posts)
        }
    }
}
