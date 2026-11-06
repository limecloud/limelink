package run.limeai.link.core

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

@ConsistentCopyVisibility
data class GatewayConnectionRequest private constructor(val origin:String) {
    val url:String get()="limelink://connect?gateway="+URLEncoder.encode(origin,Charsets.UTF_8)
    companion object {
        fun fromOrigin(origin:String):GatewayConnectionRequest {
            val uri=URI(origin)
            require(origin.toByteArray(Charsets.UTF_8).size<=1024&&uri.scheme=="https"&&!uri.host.isNullOrEmpty()&&uri.rawUserInfo==null&&uri.rawPath.isNullOrEmpty()&&uri.rawQuery==null&&uri.rawFragment==null&&(uri.port==-1||uri.port in 1..65535)&&origin.none{it.isWhitespace()}){"invalid_gateway_connection_request"}
            return GatewayConnectionRequest(origin)
        }
        fun fromUrl(url:String):GatewayConnectionRequest {
            val uri=URI(url)
            require(url.toByteArray(Charsets.UTF_8).size<=2048&&uri.scheme=="limelink"&&uri.rawAuthority=="connect"&&uri.rawPath.isNullOrEmpty()&&uri.rawFragment==null){"invalid_gateway_connection_request"}
            val query=requireNotNull(uri.rawQuery).split('&')
            require(query.size==1){"invalid_gateway_connection_request"}
            val field=query[0].split('=',limit=2)
            require(field.size==2&&field[0]=="gateway"){"invalid_gateway_connection_request"}
            return fromOrigin(URLDecoder.decode(field[1],Charsets.UTF_8))
        }
    }
}
