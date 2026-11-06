package run.limeai.link.core

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import org.junit.jupiter.api.Assumptions.assumeTrue
import run.limeai.iot.core.*
import kotlin.test.*

class AgentLiveTest {
    @Test fun gatewaySubmitQueryReplyAndExplicitResume()=runBlocking {
        val endpoint=System.getenv("LIMELINK_AGENT_CHECK_ENDPOINT")
        assumeTrue(endpoint!=null,"需由 tools/test-iot-link.mjs --android-agent 启动隔离网关")
        requireNotNull(endpoint)
        withTimeout(140000){
            val values=mutableMapOf<String,String>();val store=object:SessionStore{
                override suspend fun load(origin:String)=values[origin]
                override suspend fun save(origin:String,value:String?){if(value==null)values.remove(origin)else values[origin]=value}
            }
            val link=LinkClient(endpoint,store,development=true);link.login(System.getenv("LIMELINK_AGENT_CHECK_TOKEN")?:"")
            val device=link.snapshot("space-demo").devices.single{it.deviceId=="device-lamp"}
            var pair=link.perform("space-demo",device,"pair",buildJsonObject{put("name","Android Agent 验收")})
            repeat(20){if(pair.status in setOf("accepted","dispatched")){delay(200);pair=link.resolve()}}
            assertEquals(JsonPrimitive(true),LinkClient.response(pair)?.get("ok"));assertTrue(link.finishSuccessfulPairing());delay(300)
            val client=AgentClient(link,store);assertEquals("work",client.discover("space-demo",device).workspaces.single().id)
            val real=System.getenv("LIMELINK_AGENT_CHECK_REAL")=="1";val expected=if(real)"LIMELINK_AGENT_OK" else "真实协议夹具".repeat(100)
            val prompt=if(real)"Reply with exactly LIMELINK_AGENT_OK. Do not use tools, read files, or access any external resource." else "normal"
            var resume:AgentReference?=null;var session:String?=null
            repeat(2){index->
                var run=client.submit("space-demo",device,"work",prompt,"read-only",resume);assertEquals("awaiting_approval",run.state)
                val ref=client.references().single{it.id==run.id};val events=sortedMapOf<Int,AgentEvent>()
                for(i in 0 until 200){delay(250);run=client.query(ref,"space-demo",device,run.cursor);run.events.forEach{events[it.seq]=it};if(run.state in setOf("succeeded","failed","unknown"))break}
                assertEquals("succeeded",run.state,run.error)
                while(run.events.size==4){run=client.query(ref,"space-demo",device,run.cursor);run.events.forEach{events[it.seq]=it}}
                assertEquals(expected,events.values.filter{it.kind=="message"}.joinToString(""){it.text}.trim())
                if(index==0)session=run.sessionId else{assertNotNull(session);assertEquals(session,run.sessionId)};resume=ref
            }
            assertEquals("agent_target_changed",assertFailsWith<IllegalStateException>{client.query(resume!!,"different-space",device)}.message)
            println("{\"passed\":true,\"product_client\":\"android\",\"real_gateway\":true,\"submit_query_reply\":true,\"explicit_resume\":true,\"space_isolation\":true,\"native_window\":false}")
        }
    }
}
