package run.limeai.link.core

import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import run.limeai.iot.core.*
import kotlin.test.*
import org.junit.jupiter.api.Assumptions.assumeTrue

class CloudLinkClientTest {
    @Test fun originalCloudOperationUsesLocalSpaceAndBlocksAcrossSelections() = runBlocking {
        val origin = System.getenv("LIMELINK_CLOUD_CHECK_ORIGIN")
        assumeTrue(origin != null, "需由 tools/test-cloud-clients.mjs 启动共享夹具")
        requireNotNull(origin)
        val values = mutableMapOf<String, String>()
        val store = object : SessionStore {
            override suspend fun load(origin: String) = values[origin]
            override suspend fun save(origin: String, value: String?) { if (value == null) values.remove(origin) else values[origin] = value }
        }
        val client = CloudLinkClient(origin, store, development = true)
        client.control.beginAuthorization(); client.control.pollAuthorization()
        val snapshot = client.snapshot("cloud-space"); val device = snapshot.devices.single(); val fingerprint = client.fingerprint(device.deviceId)
        assertFailsWith<IOException> { client.perform("cloud-space", device, "pair", buildJsonObject { put("name", "Android") }) }
        val recovered = CloudLinkClient(origin, store, development = true); val records = recovered.records()
        assertEquals(1, records.size); assertTrue(records[0].attempted)
        assertEquals(404, assertFailsWith<ControlException> { recovered.resolve(records[0].id) }.status)
        assertEquals(ControlCommandStatus.UNKNOWN, recovered.resolve(records[0].id).result?.status)
        recovered.snapshot("cloud-space"); assertEquals(fingerprint, recovered.fingerprint(device.deviceId))
        recovered.snapshot("another-space")
        assertEquals("resolve_original_request_first", assertFailsWith<IllegalStateException> { recovered.perform("another-space", device, "pair", buildJsonObject {}) }.message)
    }
}
