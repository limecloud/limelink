#if os(macOS)
import Foundation
import LimeLinkCore

func localGatewayDeploymentChecks()throws{
    func check(_ condition:Bool,_ code:String)throws{if !condition{throw LinkError(code)}}
    func failure(_ code:String,unknown:Bool,_ action:()throws->Void)throws{
        do{try action()}catch let error as LocalGatewayFailure{
            try check(error.code==code && error.outcomeUnknown==unknown,"unexpected_gateway_failure");return
        }
        throw LinkError("gateway_failure_not_reported")
    }
    let files=FileManager.default,root=files.temporaryDirectory.appendingPathComponent("limelink-gateway-checks-\(UUID().uuidString)")
    try files.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? files.removeItem(at:root)}
    func executable(_ name:String,_ body:String)throws->URL{
        let path=root.appendingPathComponent(name)
        try Data(("#!/bin/sh\n"+body+"\n").utf8).write(to:path)
        try files.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path)
        return path
    }
    let recorded=root.appendingPathComponent("arguments.txt")
    let good=try executable("helper","printf '%s\\n' \"$@\" > '"+recorded.path+"'\nprintf '%s' '{\"ok\":true,\"state\":\"running\",\"origin\":\"https://127.0.0.1:18443\",\"services\":[{\"service\":\"gateway\",\"state\":\"running\",\"health\":\"healthy\"}],\"agent_enabled\":false,\"system_trust_changed\":false,\"runtime_configuration\":\"/private/device.json\"}'")
    let tools=LocalGatewayTools(docker:"/path with spaces/docker",compose:"/compose path/standalone")
    let client=LocalGatewayDeployment(helper:good),bundle=root.appendingPathComponent("package ; $(echo injected)")
    let reply=try client.execute(.inspect(bundle:bundle))
    try check(reply.state=="running" && reply.services?.first?.health=="healthy" && reply.agentEnabled==false && reply.systemTrustChanged==false && reply.runtimeConfiguration=="/private/device.json","gateway_json_contract")
    try check(try String(contentsOf:recorded,encoding:.utf8)=="inspect\n--bundle\n"+bundle.path+"\n","gateway_arguments_not_literal")
    let directory=root.appendingPathComponent("installation")
    _=try client.execute(.start(directory:directory),tools:tools)
    try check(try String(contentsOf:recorded,encoding:.utf8)=="start\n--directory\n"+directory.path+"\n--docker\n/path with spaces/docker\n--compose\n/compose path/standalone\n","gateway_tools_arguments_changed")
    try failure("docker_compose_unavailable",unknown:false){_=try client.execute(.stop(directory:directory))}
    try failure("invalid_ports",unknown:false){_=try client.execute(.initialize(bundle:bundle,directory:directory,host:"127.0.0.1",httpsPort:443,mqttPort:443),tools:tools)}
    let failed=try executable("failed","printf '%s' '{\"ok\":false,\"code\":\"remote_docker_not_allowed\"}' >&2; exit 1")
    try failure("remote_docker_not_allowed",unknown:true){_=try LocalGatewayDeployment(helper:failed).execute(.start(directory:directory),tools:tools)}
    let malformed=try executable("malformed","printf '%s' '{\"ok\":false}'")
    try failure("invalid_helper_response",unknown:false){_=try LocalGatewayDeployment(helper:malformed).execute(.inspect(bundle:bundle))}
    try failure("invalid_helper_response",unknown:true){_=try LocalGatewayDeployment(helper:malformed).execute(.stop(directory:directory),tools:tools)}
    let hanging=try executable("hanging","exec /bin/sleep 10"),started=ProcessInfo.processInfo.systemUptime
    try failure("deployment_timeout",unknown:true){_=try LocalGatewayDeployment(helper:hanging).execute(.start(directory:directory),tools:tools,timeout:0.1)}
    try check(ProcessInfo.processInfo.systemUptime-started<2,"gateway_timeout_not_bounded")
    let oversized=try executable("oversized","/usr/bin/head -c 65537 /dev/zero")
    try failure("deployment_output_budget",unknown:false){_=try LocalGatewayDeployment(helper:oversized).execute(.inspect(bundle:bundle))}
    let alias=root.appendingPathComponent("helper-alias");try files.createSymbolicLink(at:alias,withDestinationURL:good)
    _=try LocalGatewayDeployment(helper:alias).execute(.inspect(bundle:bundle))
    _=try executable("docker","if [ \"$1\" = '--version' ]; then printf 'Docker version 29.0.0\\n'; elif [ \"$1\" = 'compose' ]; then exit 1; else exit 3; fi")
    _=try executable("docker-compose","printf 'Docker Compose version v5.5.1\\n'")
    let discovered=LocalGatewayTools.discover(environment:["PATH":root.path])
    try check(discovered?.docker==root.appendingPathComponent("docker").path && discovered?.compose==root.appendingPathComponent("docker-compose").path,"standalone_compose_not_discovered")
    try check(LocalGatewayDeployment.privateAddresses().contains("127.0.0.1"),"loopback_choice_missing")
}
#endif
