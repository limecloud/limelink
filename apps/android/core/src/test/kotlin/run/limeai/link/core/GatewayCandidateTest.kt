package run.limeai.link.core

import java.nio.file.Files
import java.nio.file.Path
import kotlinx.serialization.json.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class GatewayCandidateTest {
    @Test fun sharedGatewayAnnouncements() {
        val file = Path.of("../../../contracts/fixtures/gateway-discovery.json")
        val cases = Json.parseToJsonElement(Files.readString(file)).jsonObject["cases"]!!.jsonArray
        assertEquals(16, cases.size)
        for (case in cases) {
            val row = case.jsonObject
            val name = row["name"]!!.jsonPrimitive.content
            val attributes = row["attributes"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content.toByteArray() }
            val candidate = GatewayCandidate.fromAttributes(name, attributes)
            assertEquals(row["valid"]!!.jsonPrimitive.boolean, candidate != null, name)
            if (candidate != null) assertEquals(row["attributes"]!!.jsonObject["origin"]!!.jsonPrimitive.content, candidate.origin)
        }
    }
    @Test fun malformedUtf8AndBoundedDisplayNames() {
        fun attributes(origin: ByteArray) = mapOf("version" to byteArrayOf(49), "origin" to origin)
        assertNull(GatewayCandidate.fromAttributes("网关", attributes(byteArrayOf(0xc3.toByte(), 0x28))))
        assertNull(GatewayCandidate.fromAttributes("网关", attributes(("https://" + "a".repeat(249)).toByteArray())))
        val origin = "https://gateway.example.com".toByteArray()
        assertEquals("LimeIoT 网关", GatewayCandidate.fromAttributes("\n\r\u0000\u202e", attributes(origin))!!.name)
        val label = GatewayCandidate.fromAttributes("\n" + "🟢".repeat(100), attributes(origin))!!.name
        assertEquals(80, label.codePointCount(0, label.length))
        assertEquals("https://gateway.example.com", GatewayCandidate.fromAttributes("网关", attributes(origin))!!.origin)
    }
}
