package run.limeai.link.core

import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** 局域网公告只提供候选入口，认证与 TLS 校验仍由网关客户端完成。 */
@ConsistentCopyVisibility
data class GatewayCandidate private constructor(val name: String, val origin: String) {
    companion object {
        fun fromAttributes(name: String, attributes: Map<String, ByteArray>): GatewayCandidate? {
            if (attributes["version"]?.contentEquals(byteArrayOf(49)) != true) return null
            val bytes = attributes["origin"] ?: return null
            if (bytes.size !in 1..248) return null
            val value = runCatching {
                Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            }.getOrNull() ?: return null
            if ('%' in value || value.endsWith(':')) return null
            val url = runCatching { URI(value) }.getOrNull() ?: return null
            if (url.scheme != "https" || url.host.isNullOrEmpty() || url.rawUserInfo != null ||
                !url.rawPath.isNullOrEmpty() || url.rawQuery != null || url.rawFragment != null ||
                url.port != -1 && url.port !in 1..65535 || url.toASCIIString() != value ||
                url.host.any { !it.isLetterOrDigit() && it !in ".-:[]" }) return null
            val label = StringBuilder()
            name.codePoints().filter { !Character.isISOControl(it) && Character.getType(it) != Character.FORMAT.toInt() }
                .limit(80).forEach { label.appendCodePoint(it) }
            return GatewayCandidate(label.toString().ifEmpty { "LimeIoT 网关" }, value)
        }
    }
}
