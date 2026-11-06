import Foundation

/// 安装后的跨端交接只携带地址，不携带登录凭据或设备私钥。
public struct GatewayConnectionRequest:Sendable,Equatable {
    public let origin:String
    public init(origin:String)throws {
        guard origin.utf8.count<=1024,let parts=URLComponents(string:origin),parts.scheme=="https",
              let host=parts.host,!host.isEmpty,parts.user==nil,parts.password==nil,parts.path.isEmpty,
              parts.query==nil,parts.fragment==nil,parts.url?.absoluteString==origin,
              parts.port.map({(1...65535).contains($0)}) ?? true,
              !origin.contains(where:{$0.isWhitespace || $0.isNewline}) else{throw LinkError("invalid_gateway_connection_request")}
        self.origin=origin
    }
    public init(url:URL)throws {
        guard url.absoluteString.utf8.count<=2048,let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),
              parts.scheme=="limelink",parts.host=="connect",parts.user==nil,parts.password==nil,
              parts.port==nil,parts.path.isEmpty,parts.fragment==nil,
              parts.percentEncodedQuery?.hasPrefix("gateway=")==true,
              let items=parts.queryItems,items.count==1,items[0].name=="gateway",let value=items[0].value else{throw LinkError("invalid_gateway_connection_request")}
        try self.init(origin:value)
    }
    public var url:URL {
        var parts=URLComponents();parts.scheme="limelink";parts.host="connect"
        parts.queryItems=[URLQueryItem(name:"gateway",value:origin)]
        return parts.url!
    }
}
