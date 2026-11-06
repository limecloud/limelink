import Foundation
import LimeLinkCore

func localAgentConfigurationChecks()throws{
    func check(_ condition:Bool,_ code:String)throws{if !condition{throw LinkError(code)}}
    func rejects(_ action:()throws->Void)throws{
        do{try action()}catch{return}
        throw LinkError("invalid_local_configuration_accepted")
    }
    let files=FileManager.default,root=files.temporaryDirectory.appendingPathComponent("limelink-agent-config-\(UUID().uuidString)")
    try files.createDirectory(at:root,withIntermediateDirectories:true)
    defer{try? files.removeItem(at:root)}
    let workspace=root.appendingPathComponent("工作目录"),alias=root.appendingPathComponent("目录快捷方式")
    try files.createDirectory(at:workspace,withIntermediateDirectories:false)
    try files.createSymbolicLink(at:alias,withDestinationURL:workspace)
    var configuration=LocalAgentConfiguration(executable:"/bin/echo",workspaces:[LocalAgentWorkspace(id:"work",name:"笔记",path:alias.path)])
    let valid=try configuration.validated()
    try check(valid.workspaces[0].path==workspace.resolvingSymlinksInPath().path,"workspace_not_canonical")
    try check(!valid.workspaces[0].allowWrite && !valid.allowIoTTools && valid.timeoutSeconds==600,"unsafe_configuration_defaults")
    configuration.timeoutSeconds=29;try rejects{_=try configuration.validated()};configuration.timeoutSeconds=1801;try rejects{_=try configuration.validated()};configuration.timeoutSeconds=600
    configuration.executable="bin/codex";try rejects{_=try configuration.validated()};configuration.executable=workspace.path;try rejects{_=try configuration.validated()};configuration.executable="/bin/echo"
    configuration.workspaces[0].path="relative/path";try rejects{_=try configuration.validated()};configuration.workspaces[0].path=root.appendingPathComponent("missing").path;try rejects{_=try configuration.validated()};configuration.workspaces[0].path=workspace.path
    configuration.workspaces[0].name=String(repeating:"字",count:22);try rejects{_=try configuration.validated()};configuration.workspaces[0].name="笔记"
    configuration.workspaces.append(configuration.workspaces[0]);try rejects{_=try configuration.validated()};configuration.workspaces.removeLast()
    configuration.workspaces[0].id="bad id";try rejects{_=try configuration.validated()};configuration.workspaces[0].id="work"
    let defaults=try JSONDecoder().decode(LocalAgentConfiguration.self,from:Data("{\"executable\":\"/bin/echo\",\"workspaces\":[{\"id\":\"work\",\"name\":\"笔记\",\"path\":\"/tmp\"}]}".utf8))
    try check(defaults.timeoutSeconds==600 && !defaults.allowIoTTools && !defaults.workspaces[0].allowWrite,"configuration_defaults_not_decoded")
    #if os(macOS)
    func executable(_ name:String,_ body:String)throws->String{
        let path=root.appendingPathComponent(name)
        try Data(("#!/bin/sh\n"+body+"\n").utf8).write(to:path)
        try files.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path)
        return path.path
    }
    let old=try executable("old-codex","printf 'codex-cli 0.1.2505191453\\n'")
    let supported=try executable("current-codex","if [ \"$1\" = '--version' ]; then printf 'codex-cli 0.166.0\\n'; else printf 'Usage: codex app-server [OPTIONS] [COMMAND]\\n  generate-json-schema\\n'; fi")
    let wrongHelp=try executable("unsupported-codex","if [ \"$1\" = '--version' ]; then printf 'codex-cli 0.166.0\\n'; else printf 'unrecognized subcommand app-server\\n'; fi")
    let failed=try executable("failed-codex","printf 'codex-cli 0.166.0\\n'; exit 1")
    let oversized=try executable("verbose-codex","i=0; while [ \"$i\" -lt 1024 ]; do printf 'codex-cli 0.166.0 codex-cli 0.166.0\\n'; i=$((i+1)); done")
    let hanging=try executable("hanging-codex","exec /bin/sleep 10")
    let aliasExecutable=root.appendingPathComponent("codex-alias");try files.createSymbolicLink(at:aliasExecutable,withDestinationURL:URL(fileURLWithPath:supported))
    let discovered=CodexExecutableDiscovery.find(candidates:["relative/codex",workspace.path,old,wrongHelp,failed,oversized,aliasExecutable.path])
    try check(discovered?.path==URL(fileURLWithPath:supported).resolvingSymlinksInPath().path && discovered?.version=="0.166.0","compatible_codex_not_selected")
    for _ in 0..<12{try check(CodexExecutableDiscovery.find(candidates:[supported])?.version=="0.166.0","fast_codex_output_lost")}
    try check(CodexExecutableDiscovery.find(candidates:[old,wrongHelp,failed])==nil,"unsupported_codex_selected")
    let probeStart=ProcessInfo.processInfo.systemUptime
    try check(CodexExecutableDiscovery.find(candidates:[hanging],probeTimeout:0.1)==nil && ProcessInfo.processInfo.systemUptime-probeStart<2,"codex_probe_timeout_not_bounded")
    let path=root.appendingPathComponent("device.json")
    let base:[String:Any]=["mqtt_host":"gateway.example","mqtt_port":8883,"space":"chosen","device":"desktop","model_revision":"sha256:"+String(repeating:"a",count:64),"database":root.appendingPathComponent("device.sqlite").path,"ca":"/private/ca.crt","certificate":"/private/device.crt","private_key":"/private/device.key"]
    let data=try JSONSerialization.data(withJSONObject:base,options:.sortedKeys)
    try data.write(to:path)
    let document=try LocalRuntimeConfigurationDocument(contentsOf:path)
    try check(document.agent==nil,"missing_agent_not_optional")
    configuration.allowIoTTools=true;configuration.workspaces[0].allowWrite=true
    try document.save(agent:configuration)
    let saved=try Data(contentsOf:path),object=try JSONSerialization.jsonObject(with:saved) as! [String:Any]
    var untouched=object;untouched.removeValue(forKey:"agent")
    try check(NSDictionary(dictionary:untouched)==NSDictionary(dictionary:base),"device_identity_changed_by_agent_settings")
    let permissions=try files.attributesOfItem(atPath:path.path)[.posixPermissions] as! NSNumber
    try check(permissions.intValue & 0o777==0o600,"configuration_permissions_too_broad")
    let updated=try LocalRuntimeConfigurationDocument(contentsOf:path)
    try check(updated.agent?.allowIoTTools==true && updated.agent?.workspaces[0].allowWrite==true,"saved_agent_not_restored")
    try rejects{try document.save(agent:nil)}
    try check(try Data(contentsOf:path)==saved,"stale_document_overwrote_new_configuration")
    try updated.save(agent:nil)
    try check(try LocalRuntimeConfigurationDocument(contentsOf:path).agent==nil,"agent_not_disabled")
    let link=root.appendingPathComponent("device-link.json");try files.createSymbolicLink(at:link,withDestinationURL:path)
    try rejects{_=try LocalRuntimeConfigurationDocument(contentsOf:link)}
    let current=try LocalRuntimeConfigurationDocument(contentsOf:path)
    var changed=base;changed["device"]="different";let changedData=try JSONSerialization.data(withJSONObject:changed)
    try changedData.write(to:path);try rejects{try current.save(agent:configuration)}
    try check(try Data(contentsOf:path)==changedData,"external_configuration_change_overwritten")
    let invalid=root.appendingPathComponent("invalid.json");try Data("{}".utf8).write(to:invalid);try rejects{_=try LocalRuntimeConfigurationDocument(contentsOf:invalid)}
    var future=base;var agent=try JSONSerialization.jsonObject(with:JSONEncoder().encode(configuration)) as! [String:Any];agent["future_setting"]=true;future["agent"]=agent
    try JSONSerialization.data(withJSONObject:future).write(to:invalid);try rejects{_=try LocalRuntimeConfigurationDocument(contentsOf:invalid)}
    try Data(repeating:32,count:65537).write(to:invalid);try rejects{_=try LocalRuntimeConfigurationDocument(contentsOf:invalid)}
    #endif
}
