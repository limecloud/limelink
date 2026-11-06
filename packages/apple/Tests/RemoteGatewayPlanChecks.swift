import Foundation
import LimeLinkCore

func remoteGatewayPlanChecks()throws{
    func check(_ condition:Bool,_ code:String)throws{if !condition{throw LinkError(code)}}
    let source=try JSONDecoder().decode(RemoteGatewaySource.self,from:Data(contentsOf:URL(fileURLWithPath:"contracts/iot-sdk.lock.json")))
    var input=RemoteGatewayInput();input.host="192.168.1.20"
    let privatePlan=try RemoteGatewayPlan(input:input,source:source)
    try check(privatePlan.origin=="https://192.168.1.20:8443" && privatePlan.sshCommand=="ssh -p 22 'ubuntu@192.168.1.20'","private_gateway_origin_or_ssh")
    try check(privatePlan.ports.map(\.port)==[8443,18883] && privatePlan.host==input.host,"private_gateway_required_ports")
    let privateCommands=privatePlan.steps.map(\.commands).joined(separator:"\n")
    try check(privateCommands.contains("--mqtt-bind '192.168.1.20'") && privateCommands.contains(source.head) && privateCommands.contains("systemctl enable --now") && !privateCommands.contains("docker"),"private_gateway_boundaries")
    try check(privateCommands.contains("set -C;") && privateCommands.contains("ca.crt") && !privateCommands.contains("ca.key") && !privateCommands.contains("--insecure"),"remote_certificate_boundaries")
    input.network = .publicNetwork;input.host="gateway.example.com";input.httpsPort=443;input.sshHost="203.0.113.20"
    let publicPlan=try RemoteGatewayPlan(input:input,source:source),publicCommands=publicPlan.steps.map(\.commands).joined(separator:"\n")
    try check(publicPlan.origin=="https://gateway.example.com" && publicPlan.sshCommand.contains("ubuntu@203.0.113.20"),"public_gateway_address_split")
    try check(publicPlan.ports.map(\.port)==[443,18883] && publicPlan.markdown.contains("TCP 443") && publicPlan.markdown.contains("TCP 18883") && publicPlan.markdown.contains("云安全组与宝塔/系统防火墙"),"public_gateway_port_reminder")
    try check(publicCommands.contains("ufw allow 443/tcp") && publicCommands.contains("ufw allow 18883/tcp") && !publicCommands.contains("ufw disable") && !publicCommands.contains("ufw allow 17880"),"remote_firewall_scope")
    try check(publicCommands.contains("proxy_pass http://127.0.0.1:17880;") && publicCommands.contains("ssl_certificate") && publicCommands.contains("proxy_set_header Host $http_host;") && publicCommands.contains("--mqtt-bind '0.0.0.0'") && !publicCommands.contains("docker") && !publicCommands.contains("--insecure"),"public_gateway_tls_or_exposure")
    func rejects(_ input:RemoteGatewayInput,_ code:String)throws{
        do{_=try RemoteGatewayPlan(input:input,source:source)}catch let error as LinkError{try check(error.code==code,"remote_plan_wrong_failure");return}
        throw LinkError("unsafe_remote_plan_accepted")
    }
    for host in ["https://gateway.example.com","gateway.example.com:443","good.example/path","user@good.example","-evil.example","a..example","example.com\ncommand","$(echo bad).example","999.2.3.4","192.168.001.1","[::1]"]{
        var invalid=input;invalid.host=host;try rejects(invalid,"invalid_gateway_host")
    }
    for host in ["192.168.1.1","10.0.0.1","172.16.0.1","127.0.0.1","169.254.1.2","0.0.0.0","224.0.0.1"]{var invalid=input;invalid.host=host;try rejects(invalid,"public_gateway_host_required")}
    var invalid=input;invalid.network = .privateNetwork;try rejects(invalid,"private_gateway_ip_required")
    invalid=input;invalid.sshUser="root";_=try RemoteGatewayPlan(input:invalid,source:source)
    invalid=input;invalid.sshUser="user;id";try rejects(invalid,"invalid_gateway_user")
    invalid=input;invalid.sshPort=443;try rejects(invalid,"invalid_gateway_ports")
    for path in ["relative","/","/home/../tmp","/home/ubuntu\ncommand"]{invalid=input;invalid.directory=path;try rejects(invalid,"invalid_gateway_directory")}
    // 本机包路径保留字面量，不把路径字符当作Shell语法。
    input.packagePath="/local/a 'quoted' $(echo invalid).tar.gz"
    let quoted=try RemoteGatewayPlan(input:input,source:source)
    try check(quoted.markdown.contains("'\"'\"'") && quoted.markdown.contains("$(echo invalid).tar.gz'"),"native_package_path_not_quoted")
}

func remoteGatewayProbeChecks()async throws->Int{
    struct Case:Decodable{let host:String;let privateNetwork:Bool;let https:Int;let mqtt:Int;let httpsReady:Bool;let deviceReady:Bool;let certificateError:Bool}
    guard let path=ProcessInfo.processInfo.environment["LIMELINK_REMOTE_PROBE_CASES"] else{return 0}
    let cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
    let source=try JSONDecoder().decode(RemoteGatewaySource.self,from:Data(contentsOf:URL(fileURLWithPath:"contracts/iot-sdk.lock.json")))
    for test in cases{
        var input=RemoteGatewayInput();input.network = test.privateNetwork ? .privateNetwork : .publicNetwork;input.host=test.host;input.httpsPort=test.https;input.mqttPort=test.mqtt
        let plan=try RemoteGatewayPlan(input:input,source:source)
        let result=await RemoteGatewayProbe.check(plan)
        guard result.count==2,result[0].reachable==test.httpsReady,result[1].reachable==test.deviceReady,
              !test.certificateError || result[0].message=="证书或 TLS 校验失败" else{throw LinkError("remote_gateway_probe_result_mismatch")}
    }
    return cases.count
}
