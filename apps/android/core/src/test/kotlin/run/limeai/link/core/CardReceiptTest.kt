package run.limeai.link.core

import kotlinx.serialization.json.*
import run.limeai.iot.core.*
import kotlin.test.*

class CardReceiptTest {
    private fun receipt(status:String="confirmed",kind:String="card",ok:JsonPrimitive=JsonPrimitive(true),id:JsonElement=JsonPrimitive("card-1"),payload:String="{\"text\":\"原始草稿\"}",path:String="link.exchange"):Command {
        val exchange=buildJsonObject{put("kind",kind);put("payload",payload)}
        val response=buildJsonObject{put("ok",ok);put("value",buildJsonObject{put("id",id)})}
        return Command("fixture",status,CommandInput("desktop","sha256:fixture","2030-01-01T00:00:00Z",Operation("action.invoke",path,exchange)),evidence=buildJsonObject{put("output",buildJsonObject{put("response",response.toString())})})
    }
    @Test fun onlySuccessfulOriginalCardProvidesTextForDraftCompletion(){
        assertEquals("原始草稿",LinkClient.completedCardText(receipt()))
        for(status in listOf("accepted","dispatched","unknown","failed","expired","rejected"))assertNull(LinkClient.completedCardText(receipt(status=status)),status)
        assertNull(LinkClient.completedCardText(receipt(ok=JsonPrimitive(false))))
        assertNull(LinkClient.completedCardText(receipt(ok=JsonPrimitive("true"))))
        assertNull(LinkClient.completedCardText(receipt(kind="status")))
        assertNull(LinkClient.completedCardText(receipt(path="agent.exchange")))
        assertNull(LinkClient.completedCardText(receipt(id=JsonNull)))
        assertNull(LinkClient.completedCardText(receipt(id=JsonPrimitive(1))))
        assertNull(LinkClient.completedCardText(receipt(id=JsonPrimitive(""))))
        assertNull(LinkClient.completedCardText(receipt(payload="invalid")))
        assertNull(LinkClient.completedCardText(receipt(payload="{\"text\":true}")))
    }
}
