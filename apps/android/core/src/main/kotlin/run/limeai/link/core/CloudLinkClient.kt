package run.limeai.link.core

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import run.limeai.iot.core.*

data class CloudLinkSnapshot(val space: String, val principal: String, val gateway: ControlGateway, val devices: List<Device>, val models: Map<String, Model>)

/** 消费 IoT 正式云合同；产品只拥有目标选择与按本地空间绑定的协同签名。 */
class CloudLinkClient(endpoint: String, private val storage: SessionStore, transport: GatewayTransport = OkHttpTransport(), development: Boolean = false) {
    val control = ControlClient(endpoint, storage, transport, development)
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = false }
    private var selected: CloudLinkSnapshot? = null
    suspend fun snapshot(space: String): CloudLinkSnapshot {
        val session = control.restoreSession()
        val gateways = control.gateways(space).filter { it.active }
        check(gateways.size == 1) { "select_single_active_gateway" }; val gateway = gateways.single()
        check(gateway.spaceId == space && gateway.principalId == session.principal.principalId && gateway.scopes.containsAll(listOf("devices.read", "commands.write"))) { "gateway_scope_mismatch" }
        val devices = mutableListOf<Device>(); val cursors = mutableSetOf<String>(); var after: String? = null
        do {
            currentCoroutineContext().ensureActive(); val page = control.devices(space, after)
            check(page.bindingRevision == gateway.revision && devices.size + page.items.size <= 1024) { "gateway_binding_changed" }
            devices += page.items; after = page.next
            if (after != null) check(cursors.size < 128 && cursors.add(after)) { "invalid_device_cursor" }
        } while (after != null)
        check(devices.map { it.deviceId }.distinct().size == devices.size) { "duplicate_remote_device" }
        val models = devices.map { it.modelRevision }.distinct().associateWith { control.model(space, it) }
        val latest = control.gateways(space).filter { it.active }
        check(latest.size == 1 && latest[0].gatewayId == gateway.gatewayId && latest[0].revision == gateway.revision && latest[0].localSpaceId == gateway.localSpaceId && latest[0].principalId == gateway.principalId) { "gateway_binding_changed" }
        return CloudLinkSnapshot(space, session.principal.principalId, gateway, devices, models).also { selected = it }
    }
    private suspend fun identity(snapshot: CloudLinkSnapshot, device: String): LinkIdentity {
        val principal = control.restoreSession().principal.principalId
        check(principal == snapshot.principal) { "cloud_identity_changed" }
        val tuple = json.encodeToString(listOf(control.origin, principal, snapshot.space, snapshot.gateway.gatewayId, snapshot.gateway.localSpaceId, device))
        val scope = control.origin + "#limelink.cloud.identity:" + hash(tuple)
        storage.load(scope)?.let { return json.decodeFromString(it) }
        val identity = LinkIdentity.create(); val data = json.encodeToString(identity); storage.save(scope, data)
        check(storage.load(scope) == data) { "identity_not_durable" }; return identity
    }
    suspend fun fingerprint(device: String): String = identity(selected ?: error("refresh_target_required"), device).let { hash(it.publicKey) }
    suspend fun records(): List<ControlCommandRecord> = control.commandRecords().filter { it.reference.request.operation.type == "action.invoke" && it.reference.request.operation.path == "link.exchange" }
    suspend fun perform(space: String, device: Device, kind: String, payload: JsonObject): ControlCommandRecord = mutex.withLock {
        val previous = selected ?: error("refresh_target_required")
        check(previous.space == space && device.ready) { "refresh_target_required" }
        check(records().none { it.isPrepared || !it.canForget }) { "resolve_original_request_first" }
        val snapshot = snapshot(space)
        check(snapshot.principal == previous.principal && snapshot.gateway.gatewayId == previous.gateway.gatewayId && snapshot.gateway.revision == previous.gateway.revision && snapshot.gateway.localSpaceId == previous.gateway.localSpaceId) { "gateway_binding_changed" }
        val current = snapshot.devices.singleOrNull { it.deviceId == device.deviceId && it.ready && it.modelRevision == device.modelRevision } ?: error("target_changed")
        check(snapshot.models[current.modelRevision]?.modelId == "urn:limelink:model:desktop:1") { "target_capability_changed" }
        val input = identity(snapshot, current.deviceId).exchange(snapshot.gateway.localSpaceId, current.deviceId, current.modelRevision, kind, payload.toString())
        val record = control.prepareCommand(space, snapshot.gateway, current, "link.exchange", input, "action.invoke")
        currentCoroutineContext().ensureActive(); control.submitCommand(record.id)
    }
    suspend fun resolve(key: String, reconcile: Boolean = false): ControlCommandRecord = control.resolveCommand(key, reconcile)
    suspend fun forget(key: String) = control.forgetCommand(key)
    suspend fun logout() { control.logout(); selected = null }
    companion object {
        fun response(record: ControlCommandRecord): JsonObject? {
            val result = record.result ?: return null
            if (result.status != ControlCommandStatus.CONFIRMED) return null
            val text = result.localResult?.jsonObject?.get("evidence")?.jsonObject?.get("output")?.jsonObject?.get("response")?.jsonPrimitive?.content ?: return null
            return Json.parseToJsonElement(text).jsonObject
        }
    }
}
