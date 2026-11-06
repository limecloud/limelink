package run.limeai.link.core

import java.security.*
import java.security.interfaces.ECPublicKey
import java.security.spec.*
import java.time.Instant
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import run.limeai.iot.core.*

fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 255) }
fun hash(text: String): String = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).hex()
@Serializable data class LinkIdentity(val id: String, val privateKey: String, val publicKey: String) {
    companion object {
        fun create(): LinkIdentity {
            val generator = KeyPairGenerator.getInstance("EC"); generator.initialize(ECGenParameterSpec("secp256r1"))
            val pair = generator.generateKeyPair(); val public = pair.public as ECPublicKey
            fun coordinate(value: java.math.BigInteger) = value.toByteArray().takeLast(32).toByteArray().let { ByteArray(32-it.size) + it }
            return LinkIdentity(UUID.randomUUID().toString(), Base64.getEncoder().encodeToString(pair.private.encoded), (byteArrayOf(4)+coordinate(public.w.affineX)+coordinate(public.w.affineY)).hex())
        }
    }
    fun exchange(space: String, device: String, revision: String, kind: String, payload: String, now: Instant = Instant.now()): JsonObject {
        require(payload.toByteArray().size <= 4096) { "payload_too_large" }
        val nonce = UUID.randomUUID().toString(); val expires = now.epochSecond+20
        val message = listOf("limelink.exchange/v1",space,device,revision,id,kind,nonce,expires.toString(),hash(payload)).joinToString("\n")
        val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(Base64.getDecoder().decode(privateKey)))
        val signer = Signature.getInstance("SHA256withECDSA"); signer.initSign(key); signer.update(message.toByteArray(Charsets.UTF_8))
        return buildJsonObject { put("client_id",id);put("public_key",publicKey);put("kind",kind);put("nonce",nonce);put("expires_at",expires);put("payload",payload);put("signature",signer.sign().hex()) }
    }
}
@Serializable data class PendingAction(val origin: String,val space: String,val intent: CommandIntent)
class LinkClient(endpoint: String, private val storage: SessionStore, transport: GatewayTransport = OkHttpTransport(), development: Boolean = false) {
    val gateway = GatewayClient(endpoint,transport,storage,development)
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = false }
    private val scope = endpoint+"#limelink.pending"
    private var space: String? = null
    suspend fun login(token: String) = gateway.login(token)
    suspend fun restore() = gateway.restore()
    suspend fun spaces() = gateway.spaces()
    suspend fun snapshot(selected: String): Snapshot = gateway.snapshot(selected).also { space=selected }
    suspend fun pending(): PendingAction? = storage.load(scope)?.let { json.decodeFromString<PendingAction>(it).also { require(it.origin==gateway.origin) { "pending_origin_mismatch" } } }
    private suspend fun identity(space: String, device: String): LinkIdentity {
        val slot = gateway.origin+"#limelink.identity:$space:$device"
        storage.load(slot)?.let { return json.decodeFromString(it) }
        val identity = LinkIdentity.create(); val data = json.encodeToString(identity)
        storage.save(slot,data); check(storage.load(slot)==data) { "identity_not_durable" }; return identity
    }
    suspend fun fingerprint(space: String,device: String): String = hash(identity(space,device).publicKey)
    suspend fun perform(space: String,device: Device,kind: String,payload: JsonObject,path: String = "link.exchange",onPrepared:(suspend (PendingAction)->Unit)?=null): Command = mutex.withLock {
        require(path in setOf("link.exchange","agent.exchange") && kind.startsWith("agent.") == (path=="agent.exchange")) { "invalid_exchange_path" }
        check(this.space==space && device.ready) { "refresh_target_required" }
        check(pending()==null) { "resolve_original_request_first" }
        val snapshot = gateway.snapshot(space)
        val current = snapshot.devices.singleOrNull { it.deviceId==device.deviceId && it.ready && it.modelRevision==device.modelRevision } ?: error("target_changed")
        val model=snapshot.models[current.modelRevision];val parts=path.split('.')
        check(model?.modelId=="urn:limelink:model:desktop:1" && model.services.any { it.id==parts[0] && it.actions.any { action -> action.id==parts[1] } }) { "target_capability_changed" }
        val value = identity(space,current.deviceId).exchange(space,current.deviceId,current.modelRevision,kind,payload.toString())
        val intent = CommandIntent.create(current,path,value,type="action.invoke")
        val data = json.encodeToString(PendingAction(gateway.origin,space,intent))
        storage.save(scope,data); check(storage.load(scope)==data) { "intent_not_durable" }
        onPrepared?.invoke(PendingAction(gateway.origin,space,intent))
        gateway.create(space,intent)
    }
    suspend fun resolve(): Command = mutex.withLock { val original = pending() ?: error("no_pending_request"); gateway.resolve(original.space,original.intent) }
    suspend fun finish() = mutex.withLock {
        val original = pending() ?: return@withLock
        val result = gateway.resolve(original.space,original.intent)
        check(result.status in setOf("confirmed","failed","expired","rejected")) { "original_request_unresolved" }
        storage.save(scope,null)
    }
    suspend fun finishKnownExchange(): Boolean = mutex.withLock {
        val original=pending()?:return@withLock true
        if(original.intent.input.operation.path!="link.exchange")return@withLock false
        val result=gateway.resolve(original.space,original.intent)
        if(result.status=="confirmed"){
            val response=response(result)?:return@withLock false
            val ok=(response["ok"] as? JsonPrimitive)?.takeUnless{it.isString}?.booleanOrNull?:return@withLock false
            if(ok){if(response.keys!=setOf("ok","value")||response["value"] !is JsonObject)return@withLock false}
            else{val error=(response["error"] as? JsonPrimitive)?.takeIf{it.isString}?.content
                if(response.keys!=setOf("ok","error")||error==null||!error.matches(Regex("^[a-z0-9_]{1,96}$")))return@withLock false}
        }else if(result.status !in setOf("failed","expired","rejected"))return@withLock false
        currentCoroutineContext().ensureActive()
        storage.save(scope,null)
        true
    }
    suspend fun finishSuccessfulPairing(): Boolean = mutex.withLock {
        val original = pending() ?: return@withLock false
        val operation = original.intent.input.operation
        if (operation.path!="link.exchange" || (operation.value as? JsonObject)?.get("kind")!=JsonPrimitive("pair")) return@withLock false
        // 再次核实原配对回执；处理成功与电脑本机批准是两个状态。
        val result = gateway.resolve(original.space,original.intent)
        if (response(result)?.get("ok")!=JsonPrimitive(true)) return@withLock false
        currentCoroutineContext().ensureActive()
        storage.save(scope,null)
        true
    }
    suspend fun logout() = mutex.withLock { gateway.logout(); space=null }
    companion object {
        fun completedCardText(command: Command): String? = runCatching {
            val operation=command.request.operation
            if(operation.type!="action.invoke" || operation.path!="link.exchange")return null
            val exchange=operation.value.jsonObject
            if(exchange["kind"]!=JsonPrimitive("card"))return null
            val response=response(command)?:return null
            if(response.keys!=setOf("ok","value") || response["ok"]!=JsonPrimitive(true))return null
            val value=response["value"] as? JsonObject?:return null
            if((value["id"] as? JsonPrimitive)?.takeIf{it.isString}?.content.isNullOrBlank())return null
            val payload=Json.parseToJsonElement(exchange["payload"]!!.jsonPrimitive.content).jsonObject
            (payload["text"] as? JsonPrimitive)?.takeIf{it.isString}?.content
        }.getOrNull()
        fun response(command: Command): JsonObject? {
            if (command.status!="confirmed") return null
            val text = command.evidence?.jsonObject?.get("output")?.jsonObject?.get("response")?.jsonPrimitive?.content ?: return null
            return Json.parseToJsonElement(text).jsonObject
        }
    }
}
