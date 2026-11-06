package run.limeai.link.core

import kotlinx.serialization.json.*
import kotlin.test.*
import java.io.File

class GatewayConnectionRequestTest {
    @Test fun sharedConnectionVectors(){
        val file=File("../../../contracts/fixtures/gateway-connection-links.json")
        val vectors=Json.parseToJsonElement(file.readText()).jsonArray
        for(raw in vectors){
            val test=raw.jsonObject
            val expected=test["origin"]?.jsonPrimitive?.contentOrNull
            val request=runCatching{GatewayConnectionRequest.fromUrl(test.getValue("url").jsonPrimitive.content)}.getOrNull()
            assertEquals(expected,request?.origin,test.toString())
            if(request!=null)assertEquals(request,GatewayConnectionRequest.fromUrl(request.url))
        }
        assertFails{GatewayConnectionRequest.fromOrigin("https://"+"a".repeat(1100)+".example")}
    }
}
