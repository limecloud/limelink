import Foundation

public enum RemoteGatewayNetwork:String,Sendable {case privateNetwork,publicNetwork}
public struct RemoteGatewaySource:Decodable,Sendable {
    public let repository:String
    public let head:String
    public let worktreeOverlay:Bool
    enum CodingKeys:String,CodingKey{case repository,head,worktreeOverlay="worktree_overlay"}
}
public struct RemoteGatewayInput:Sendable,Equatable {
    public var network:RemoteGatewayNetwork = .privateNetwork
    public var host=""
    public var httpsPort=8443
    public var mqttPort=18883
    public var sshHost=""
    public var sshPort=22
    public var sshUser="ubuntu"
    public var directory="/home/ubuntu/limelink-gateway"
    public var packagePath="./limelink-native-linux-amd64.tar.gz"
    public init(){}
}
public struct RemoteGatewayStep:Sendable,Identifiable {
    public let title:String
    public let detail:String
    public let commands:String
    public var id:String{title}
}
public struct RemoteGatewayPort:Sendable,Identifiable {
    public let port:Int
    public let purpose:String
    public var id:Int{port}
}
public struct RemoteGatewayPlan:Sendable {
    public let origin:String
    public let host:String
    public let ports:[RemoteGatewayPort]
    public let sshCommand:String
    public let steps:[RemoteGatewayStep]
    public let markdown:String
    public init(input:RemoteGatewayInput,source:RemoteGatewaySource)throws {
        func require(_ condition:Bool,_ code:String)throws{if !condition{throw LinkError(code)}}
        try require(source.repository=="https://github.com/limecloud/iot" && !source.worktreeOverlay && source.head.count==40 && source.head.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)},"invalid_gateway_source")
        let host=input.host.lowercased(),sshHost=(input.sshHost.isEmpty ? host : input.sshHost).lowercased()
        try require(Self.validHost(host) && Self.validHost(sshHost),"invalid_gateway_host")
        try require((1...65535).contains(input.httpsPort) && (1024...65535).contains(input.mqttPort) && (1...65535).contains(input.sshPort) && input.httpsPort != input.mqttPort && input.sshPort != input.httpsPort && input.sshPort != input.mqttPort,"invalid_gateway_ports")
        try require(input.sshUser.range(of:"^[a-z_][a-z0-9_-]{0,31}$",options:.regularExpression) != nil,"invalid_gateway_user")
        try require(input.directory.hasPrefix("/") && input.directory != "/" && input.directory.utf8.count<=1024 && input.directory.utf8.allSatisfy{(65...90).contains($0)||(97...122).contains($0)||(48...57).contains($0)||[47,45,46,95].contains($0)} && !input.directory.split(separator:"/").contains(where:{$0=="." || $0==".."}),"invalid_gateway_directory")
        try require(!input.packagePath.isEmpty && input.packagePath.utf8.count<=2048 && !input.packagePath.contains(where:{$0.isNewline || $0=="\0"}),"invalid_gateway_package_path")
        let parts=Self.ipv4(host)
        let privateIP=parts.map(Self.privateIP) ?? false
        if input.network == .privateNetwork{try require(privateIP,"private_gateway_ip_required")}
        else{try require(parts == nil || (!privateIP && parts![0] != 127 && parts![0] != 0 && parts![0]<224 && !(parts![0]==169 && parts![1]==254)),"public_gateway_host_required")}
        origin="https://"+host+(input.httpsPort==443 ? "" : ":\(input.httpsPort)")
        self.host=host
        ports=[RemoteGatewayPort(port:input.httpsPort,purpose:"HTTPS"),RemoteGatewayPort(port:input.mqttPort,purpose:"设备连接")]
        sshCommand="ssh -p \(input.sshPort) "+Self.quote(input.sshUser+"@"+sshHost)
        let root=input.directory,src=root+"/limelink-native",state="/var/lib/limelink"
        let q=Self.quote
        let admin=input.sshUser=="root" ? "" : "sudo "
        let bind=input.network == .privateNetwork ? host : "0.0.0.0"
        let archive=root+"/gateway.tar.gz"
        var steps=[RemoteGatewayStep(title:"检查远程主机",detail:"普通 Linux 安装，需要 Python 3、OpenSSL、Mosquitto、Nginx 和 systemd。SSH 可用管理员账号，网关由独立非 root 账号运行。",commands:sshCommand+"\n# 以下在远程主机执行\npython3 --version\nopenssl version\nmosquitto -h\nnginx -v\nsystemctl --version"),
            RemoteGatewayStep(title:"上传原生安装包",detail:"以下在当前电脑执行。使用对应 CPU 架构的原生包，并核对发布方摘要；远程准备目录必须不存在。",commands:"shasum -a 256 "+q(input.packagePath)+"\n"+sshCommand+" "+q("umask 077; mkdir -m 700 "+q(root))+"\nscp -P \(input.sshPort) "+q(input.packagePath)+" "+q(input.sshUser+"@"+sshHost+":"+archive)),
            RemoteGatewayStep(title:"安装网关",detail:"以下在远程主机执行。先核对上传摘要与固定源码版本，再安装。数据位于 /var/lib/limelink，安装器拒绝覆盖已有服务和身份。",commands:"set -eu\nsha256sum "+q(archive)+"\ntar -xzf "+q(archive)+" --directory "+q(root)+" --no-same-owner --no-same-permissions\npython3 -B "+q(src+"/install.py")+" inspect\n# 核对上游修订："+source.head+"\n"+admin+"python3 -B "+q(src+"/install.py")+" install --origin "+q(origin)+" --mqtt-port \(input.mqttPort) --mqtt-bind "+q(bind))]
        let certificate=input.network == .publicNetwork ? "/path/to/fullchain.pem" : state+"/tls/server.crt"
        let key=input.network == .publicNetwork ? "/path/to/privkey.pem" : state+"/tls/server.key"
        let listen=input.network == .publicNetwork ? "\(input.httpsPort)" : host+":\(input.httpsPort)"
        let nginx="server {\n    listen \(listen) ssl;\n    server_name \(host);\n    ssl_certificate \(Self.nginxQuote(certificate));\n    ssl_certificate_key \(Self.nginxQuote(key));\n    location / {\n        proxy_pass http://127.0.0.1:17880;\n        proxy_set_header Host $http_host;\n    }\n}"
        steps.append(RemoteGatewayStep(title:"配置 HTTPS 入口",detail:input.network == .publicNetwork ? "将域名解析到主机并使用受信证书。以下 Nginx 示例须由管理员替换证书路径、校验后加载。放行 HTTPS 与设备 mTLS 端口，内部 HTTP 和明文 MQTT 保留回环监听。" : "在已有 Nginx 中添加独立站点，校验后加载。仅监听填写的内网 IP；客户端首次连接需信任网关证书。",commands:nginx))
        steps.append(RemoteGatewayStep(title:"放行访问端口",detail:"云服务器需同时检查云平台安全组和主机防火墙。宝塔用户在“安全 → 防火墙”放行下列 TCP 入站端口，来源限定为实际客户端网络。SSH 端口 \(input.sshPort) 仅供管理。使用 HTTP 验证签发或续期证书时还需开放 TCP 80；内部 HTTP 17880 和明文 MQTT 18884 保留回环监听。",commands:"# 云安全组与宝塔均需放行\n# HTTPS：TCP \(input.httpsPort)\n# 设备 mTLS：TCP \(input.mqttPort)\n# 已使用 UFW 的主机可执行以下规则；不要另行启用其他防火墙\n"+admin+"ufw status\n"+admin+"ufw allow \(input.httpsPort)/tcp comment 'LimeLink HTTPS'\n"+admin+"ufw allow \(input.mqttPort)/tcp comment 'LimeLink device mTLS'\n# 不要关闭防火墙，也不要把内部端口映射到公网"))
        if input.network == .privateNetwork{
            steps.append(RemoteGatewayStep(title:"信任证书",detail:"通过已核验的 SSH 通道取得 CA 公钥，核对指纹后在电脑和手机信任。不要传输 CA 私钥。",commands:"openssl x509 -in "+q(state+"/authority/ca.crt")+" -noout -fingerprint -sha256\n# 在当前电脑终端执行，保留已有同名证书\n(set -C; "+sshCommand+" "+q("cat -- "+q(state+"/authority/ca.crt"))+" > ./limelink-gateway-ca.crt)"))
        }
        steps.append(RemoteGatewayStep(title:"启动与连接",detail:"以下服务命令在远程主机执行。用 /var/lib/limelink/secrets/owner-token 登录网关；设备必须另持 mTLS 证书。Agent 单独启用，停止服务保留数据。",commands:admin+"systemctl enable --now limelink-broker.service limelink-gateway.service\n"+admin+"systemctl status limelink-broker.service limelink-gateway.service --no-pager\n# 在当前电脑核对HTTPS，不跳过证书校验\ncurl --fail --show-error "+q(origin+"/healthz")+"\n# 需要停止时在远程主机执行\n"+admin+"systemctl stop limelink-gateway.service limelink-broker.service"))
        self.steps=steps
        let portList=ports.map{"TCP \($0.port)（\($0.purpose)）"}.joined(separator:"，")
        let instructions=steps.map{"## \($0.title)\n\n\($0.detail)\n\n```\n\($0.commands)\n```\n"}.joined(separator:"\n")
        markdown="""
        # LimeLink 远程网关安装引导

        访问地址：\(origin)

        需放行的入站端口：\(portList)。云安全组与宝塔/系统防火墙须分别配置。

        源码：\(source.repository) @ \(source.head)

        此文件是安装步骤，不表示远程主机已经部署成功。执行端入网与正式升级仍需单独完成。

        \(instructions)
        """
    }
    private static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    private static func nginxQuote(_ value:String)->String{"\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"$",with:"\\$")+"\""}
    private static func privateIP(_ parts:[Int])->Bool{parts[0]==10 || (parts[0]==172 && (16...31).contains(parts[1])) || (parts[0]==192 && parts[1]==168)}
    private static func ipv4(_ value:String)->[Int]? {
        let fields=value.split(separator:".",omittingEmptySubsequences:false)
        guard fields.count==4,fields.allSatisfy({!$0.isEmpty && $0.count<=3 && $0.utf8.allSatisfy{(48...57).contains($0)} && ($0.count==1 || $0.first != "0")}),fields.allSatisfy({Int($0).map{(0...255).contains($0)} ?? false}) else{return nil}
        return fields.compactMap{Int($0)}
    }
    private static func validHost(_ value:String)->Bool {
        if ipv4(value) != nil{return true}
        guard value.utf8.count<=253,value.contains("."),!value.utf8.allSatisfy({(48...57).contains($0)||$0==46}) else{return false}
        return value.split(separator:".",omittingEmptySubsequences:false).allSatisfy{label in !label.isEmpty && label.utf8.count<=63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy{(97...122).contains($0)||(48...57).contains($0)||$0==45}}
    }
}
