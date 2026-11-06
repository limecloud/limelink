package run.limeai.link.core

import java.io.File
import kotlinx.serialization.json.*
import kotlinx.serialization.decodeFromString
import kotlin.test.*

class AgentToolVectorTest {
    @Test fun sharedToolVectors(){
        val root=generateSequence(File(System.getProperty("user.dir"))){it.parentFile}.first{File(it,"contracts/desktop.json").exists()}
        val fixture=Json.parseToJsonElement(File(root,"contracts/fixtures/agent-tools.json").readText()).jsonObject
        val reference=Json.decodeFromString<AgentReference>(fixture["reference"].toString());val devices=reference.iotDevices
        for(raw in fixture["cases"]!!.jsonArray){val c=raw.jsonObject
            val accepted=runCatching{val value=c["value"]!!.jsonObject
                when(c["kind"]!!.jsonPrimitive.content){
                    "capabilities"->AgentToolProtocol.capabilities(value)
                    "call"->AgentToolProtocol.call(value,devices)
                    "result"->AgentToolProtocol.result(AgentToolProtocol.call(c["call"]!!.jsonObject,devices),c["success"]!!.jsonPrimitive.boolean,value)
                    "pending"->AgentToolProtocol.pending(value,reference)
                    "completion"->AgentToolProtocol.completion(value,reference.id,fixture["call_id"]!!.jsonPrimitive.content)
                    else->error("unknown_tool_vector")
                }
            }.isSuccess
            assertEquals(c["valid"]!!.jsonPrimitive.boolean,accepted,c["name"]!!.jsonPrimitive.content)
        }
    }
}
