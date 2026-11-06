package run.limeai.link.core

import java.io.File
import java.io.IOException
import java.net.URI
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.jupiter.api.Assumptions.assumeTrue
import run.limeai.iot.core.*
import kotlin.test.*

/** 由隔离运行器提供真实网关；本检查运行产品核心，没有 Android 窗口或真机。 */
class AgentIoTLiveTest {
    @Test fun gatewayDeviceConfirmationAndOriginalRecovery()=runBlocking {
        val endpoint=System.getenv("LIMELINK_AGENT_IOT_ENDPOINT")
        assumeTrue(endpoint!=null,"需由 tools/test-agent-iot-android.mjs 提供隔离网关")
        requireNotNull(endpoint)
        withTimeout(190000){
            val values=mutableMapOf<String,String>();val store=object:SessionStore {
                override suspend fun load(origin:String)=values[origin]
                override suspend fun save(origin:String,value:String?){if(value==null)values.remove(origin)else values[origin]=value}
            }
            val realTransport=OkHttpTransport();var lostDevice=false;var lostReply=false
            val transport=object:GatewayTransport {
                override suspend fun send(request:GatewayRequest):GatewayResponse {
                    val response=realTransport.send(request)
                    if(request.method=="POST" && URI(request.url).path.endsWith("/commands")){
                        val operation=Json.parseToJsonElement(request.body!!).jsonObject["operation"]!!.jsonObject
                        if(operation["type"]==JsonPrimitive("property.set")&&!lostDevice){lostDevice=true;throw IOException("lost_device_response")}
                        val exchange=operation["value"] as? JsonObject
                        if(exchange?.get("kind")==JsonPrimitive("agent.tool_result")){
                            val output=Json.parseToJsonElement(exchange["payload"]!!.jsonPrimitive.content).jsonObject["output"]!!.jsonObject
                            if(output["status"]==JsonPrimitive("confirmed")&&!lostReply){lostReply=true;throw IOException("lost_reply_response")}
                        }
                    }
                    return response
                }
            }
            val link=LinkClient(endpoint,store,transport,development=true);link.login(System.getenv("LIMELINK_AGENT_CHECK_TOKEN")?:"")
            val snapshot=link.snapshot("space-demo");val execution=snapshot.devices.single{it.deviceId=="device-lamp"}
            assertTrue(snapshot.devices.any{it.deviceId=="device-button"})
            var pair=link.perform("space-demo",execution,"pair",buildJsonObject{put("name","Android 设备工具验收")})
            repeat(20){if(pair.status in setOf("accepted","dispatched")){delay(200);pair=link.resolve()}}
            assertEquals(JsonPrimitive(true),LinkClient.response(pair)?.get("ok"));assertTrue(link.finishSuccessfulPairing());delay(300)
            val agent=AgentClient(link,store);assertTrue(agent.discoverTools("space-demo",execution).enabled)
            val real=System.getenv("LIMELINK_AGENT_CHECK_REAL")=="1"
            val prompt=if(real)"Use limeiot_read for device-button exactly once. Then propose limeiot_command for light.power=true using its returned model_revision. Wait for client confirmation. Do not use other tools, files or external resources. After the device tool returns confirmed, reply exactly LIMELINK_IOT_DEVICE_OK."else "iot-live"
            var run=agent.submit("space-demo",execution,"work",prompt,"read-only",iotDevices=listOf("device-button"));assertEquals("awaiting_approval",run.state)
            val reference=agent.references().single{it.id==run.id};assertEquals(listOf("device-button"),reference.iotDevices)
            val tools=AgentIoTClient(link.gateway,agent,store);val events=sortedMapOf<Int,AgentEvent>();var proposal:AgentToolRecord?=null
            repeat(300){
                if(proposal==null){delay(250);run=agent.query(reference,"space-demo",execution,run.cursor);run.events.forEach{events[it.seq]=it}
                    assertTrue(run.state !in setOf("failed","unknown","succeeded"),"未收到写入提案: ${run.state} ${run.error}")
                    if(run.state=="running")tools.receive(reference,"space-demo",execution)
                    proposal=tools.records().singleOrNull{it.canConfirm}
                }
            }
            val call=checkNotNull(proposal){"iot_proposal_timeout"};assertNull(call.intent)
            assertTrue(tools.records().any{!it.call.isWrite && it.delivered && it.outcome?.success==true})
            val gate=File(checkNotNull(System.getenv("LIMELINK_AGENT_IOT_APPROVAL_FILE")));gate.writeText("awaiting-client-confirmation")
            withTimeout(10000){while(gate.readText()!="confirm")delay(50)}
            assertFailsWith<IOException>{tools.confirm(call.id,reference,"space-demo",execution)};assertTrue(lostDevice);assertFalse(lostReply)
            val restored=AgentIoTClient(link.gateway,agent,store)
            assertFailsWith<IOException>{restored.recoverCommand(call.id,reference,"space-demo",execution)};assertTrue(lostReply)
            assertNotNull(link.pending());agent.recover()
            assertTrue(restored.sendResult(call.id,reference,"space-demo",execution).delivered)
            val record=restored.records().single{it.id==call.id};assertEquals("confirmed",record.commandStatus);assertTrue(record.outcome!!.success)
            repeat(240){if(run.state !in setOf("succeeded","failed","unknown")){delay(250);run=agent.query(reference,"space-demo",execution,run.cursor);run.events.forEach{events[it.seq]=it}}}
            assertEquals("succeeded",run.state,run.error)
            while(run.events.size==4){run=agent.query(reference,"space-demo",execution,run.cursor);run.events.forEach{events[it.seq]=it}}
            assertEquals("LIMELINK_IOT_DEVICE_OK",events.values.last{it.kind=="message"}.text.trim())
            assertFailsWith<IllegalStateException>{restored.receive(reference,"different-space",execution)}
            println("{\"passed\":true,\"product_client\":\"android\",\"real_gateway\":true,\"explicit_write_confirmation\":true,\"lost_device_response\":true,\"lost_reply_response\":true,\"original_recovery\":true,\"native_ui\":false,\"physical_device\":false}")
        }
    }
}
