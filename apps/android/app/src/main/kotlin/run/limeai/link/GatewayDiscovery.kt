package run.limeai.link

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import run.limeai.link.core.GatewayCandidate
import java.util.ArrayDeque

/** 使用系统 DNS-SD 浏览服务；所有回调回到主线程，并核对当前发现轮次。 */
class GatewayDiscovery(context: Context) {
    private val manager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val handler = Handler(Looper.getMainLooper())
    private var generation = 0
    private var listener: NsdManager.DiscoveryListener? = null
    private class Entry(val id: String, val service: NsdServiceInfo)
    private val entries = mutableMapOf<String, Entry>()
    private val candidates = mutableMapOf<String, GatewayCandidate>()
    private val queue = ArrayDeque<Entry>()
    private var resolving: Entry? = null
    private var resolver: NsdManager.ResolveListener? = null
    private var resolutionTimeout: Runnable? = null
    var gateways by mutableStateOf<List<GatewayCandidate>>(emptyList()); private set
    var message by mutableStateOf("正在查找网关…"); private set
    var searching by mutableStateOf(false); private set

    fun start() {
        if (listener != null) return
        val nsd = manager ?: run { message = "此设备无法发现网关。"; return }
        val current = ++generation
        searching = true
        message = "正在查找网关…"
        val next = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) = Unit
            override fun onDiscoveryStopped(type: String) = post(current) { failed() }
            override fun onStartDiscoveryFailed(type: String, code: Int) = post(current) { failed() }
            override fun onStopDiscoveryFailed(type: String, code: Int) = post(current) { failed() }
            override fun onServiceFound(info: NsdServiceInfo) = post(current) {
                if (info.serviceType.trimEnd('.') != SERVICE_TYPE.trimEnd('.')) return@post
                val id = key(info)
                if (id !in entries && entries.size >= 32) return@post
                val entry = Entry(id, info)
                entries[id] = entry
                candidates.remove(id)
                queue.removeAll { it.id == id }
                queue.add(entry)
                publish()
                resolveNext(current)
            }
            override fun onServiceLost(info: NsdServiceInfo) = post(current) {
                val id = key(info)
                entries.remove(id)
                candidates.remove(id)
                queue.removeAll { it.id == id }
                publish()
            }
        }
        listener = next
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, next)
            handler.postDelayed({
                if (current == generation && listener != null) { searching = false; publish() }
            }, 5000)
        } catch (_: RuntimeException) { failed() }
    }

    fun restart() { stop(); start() }

    fun stop() {
        ++generation
        val previous = listener
        listener = null
        handler.removeCallbacksAndMessages(null)
        if (previous != null) runCatching { manager?.stopServiceDiscovery(previous) }
        stopResolution()
        resolving = null
        entries.clear(); candidates.clear(); queue.clear()
        gateways = emptyList(); searching = false
        message = "未查找网关。"
    }

    private fun failed() { stop(); message = "无法发现网关，请检查本地网络权限。" }
    private fun post(current: Int, work: () -> Unit) {
        handler.post { if (current == generation && listener != null) work() }
    }
    private fun key(info: NsdServiceInfo) = info.serviceType.trimEnd('.') + "|" + info.serviceName
    private fun publish() {
        gateways = candidates.values.groupBy { it.origin }.values.map { values -> values.minBy { it.name } }
            .sortedWith(compareBy({ it.name }, { it.origin }))
        if (gateways.isNotEmpty()) { searching = false; message = "附近的网关" }
        else if (!searching) message = "未发现网关，请确认已连接同一 Wi-Fi。"
    }
    private fun stopResolution() {
        resolutionTimeout?.let(handler::removeCallbacks)
        resolutionTimeout = null
        val previous = resolver
        resolver = null
        if (Build.VERSION.SDK_INT >= 34 && previous != null) runCatching { manager?.stopServiceResolution(previous) }
    }
    @Suppress("DEPRECATION")
    private fun resolveNext(current: Int) {
        if (current != generation || listener == null || resolving != null) return
        while (queue.isNotEmpty()) {
            val entry = queue.removeFirst()
            if (entries[entry.id] !== entry) continue
            resolving = entry
            val next = object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, code: Int) = post(current) { finish(current, entry, null) }
                override fun onServiceResolved(info: NsdServiceInfo) = post(current) {
                    val candidate = runCatching {
                        val attributes = info.attributes
                        if (attributes.entries.sumOf { it.key.toByteArray().size + it.value.size + 2 } > 1300) null
                        else GatewayCandidate.fromAttributes(entry.service.serviceName, attributes)
                    }.getOrNull()
                    finish(current, entry, candidate)
                }
            }
            resolver = next
            resolutionTimeout = Runnable { finish(current, entry, null) }.also { handler.postDelayed(it, 5000) }
            try { manager?.resolveService(entry.service, next) }
            catch (_: RuntimeException) { finish(current, entry, null) }
            return
        }
    }
    private fun finish(current: Int, entry: Entry, candidate: GatewayCandidate?) {
        if (current != generation || resolving !== entry) return
        stopResolution()
        resolving = null
        if (entries[entry.id] === entry) {
            if (candidate == null) candidates.remove(entry.id) else candidates[entry.id] = candidate
            publish()
        }
        resolveNext(current)
    }
    companion object { const val SERVICE_TYPE = "_limeiot._tcp." }
}
