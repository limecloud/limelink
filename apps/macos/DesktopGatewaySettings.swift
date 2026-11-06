import SwiftUI
import AppKit
import LimeLinkCore

@MainActor final class LocalGatewayController:ObservableObject {
    @Published private(set) var tools:LocalGatewayTools?
    @Published private(set) var bundle:URL?
    @Published private(set) var inspection:LocalGatewayReply?
    @Published private(set) var directory:URL?
    @Published private(set) var reply:LocalGatewayReply?
    @Published private(set) var busy=false
    @Published private(set) var message=""
    @Published var host="127.0.0.1"
    @Published var httpsPort=18443
    @Published var mqttPort=18883
    let addresses:[String]
    private let client:LocalGatewayDeployment
    private let selectionFile:URL?
    private var prepared=false
    var installed:Bool{directory.map{FileManager.default.fileExists(atPath:$0.appendingPathComponent("deployment.json").path)} ?? false}
    var canInstall:Bool{!busy && tools != nil && inspection != nil && directory == nil && (1024...65535).contains(httpsPort) && (1024...65535).contains(mqttPort) && httpsPort != mqttPort}
    var stateText:String {
        if busy{return "正在处理…"}
        switch reply?.state{case "running":return "服务运行中";case "installed":return "已安装，尚未启动";case "stopped_or_unhealthy":return "已停止或服务未就绪";default:return directory == nil ? "尚未安装" : "状态待核实"}
    }
    init(){
        let env=ProcessInfo.processInfo.environment
        client=LocalGatewayDeployment(helper:env["LIMELINK_GATEWAY_BINARY"].map(URL.init(fileURLWithPath:)) ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/limelink-gateway"))
        selectionFile=env["LIMELINK_GATEWAY_SELECTION"].map(URL.init(fileURLWithPath:))
        addresses=LocalGatewayDeployment.privateAddresses();host=addresses.first ?? "127.0.0.1"
        let selected:String?
        if let selectionFile{selected=(try? Data(contentsOf:selectionFile)).flatMap{try? JSONDecoder().decode(String.self,from:$0)}}
        else{selected=UserDefaults.standard.string(forKey:"limelink.localGatewayDirectory")}
        if let selected,selected.hasPrefix("/"){directory=URL(fileURLWithPath:selected)}
    }
    func prepare(){guard !prepared else{return};prepared=true;findTools()}
    func findTools(){
        guard !busy else{return};busy=true;message="正在查找 Docker 和 Compose…"
        Task{
            tools=await Task.detached(priority:.userInitiated){LocalGatewayTools.discover()}.value
            busy=false;message=tools == nil ? "未找到 Docker 和 Compose。请安装并启动容器环境后重新检查。" : ""
            if tools != nil,directory != nil{refresh()}
            else if directory == nil,bundle == nil,let packaged=Bundle.main.url(forResource:"GatewayBundle",withExtension:nil){inspect(packaged)}
        }
    }
    func chooseBundle(){
        guard !busy else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.message="选择包含 bundle.json 的 LimeLink 网关离线包"
        guard panel.runModal() == .OK,let selected=panel.url else{return}
        inspect(selected)
    }
    private func inspect(_ selected:URL){
        bundle=nil;inspection=nil
        perform(.inspect(bundle:selected),progress:"正在校验部署包…"){[weak self] value in
            self?.bundle=selected;self?.inspection=value;self?.message="开发部署包，尚未正式签名。"
        }
    }
    func chooseExisting(){
        guard !busy else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.message="选择已有 LimeLink 网关安装目录"
        guard panel.runModal() == .OK,let selected=panel.url else{return}
        do{try remember(selected);reply=nil;refresh()}catch{message="无法保存安装位置，请检查写入权限。"}
    }
    func install(){
        guard canInstall,let bundle else{return}
        let panel=NSSavePanel();panel.title="选择网关安装位置";panel.nameFieldStringValue="LimeLink Gateway";panel.canCreateDirectories=true
        guard panel.runModal() == .OK,let selected=panel.url else{return}
        guard !FileManager.default.fileExists(atPath:selected.path) else{message="请选择尚不存在的新目录，已有安装可通过“打开已有安装”管理。";return}
        // 先记住原目录；失败或退出后继续核实这个安装，不自动新建另一套身份。
        do{try remember(selected)}catch{message="无法保存安装位置，安装尚未开始。";return}
        perform(.initialize(bundle:bundle,directory:selected,host:host,httpsPort:httpsPort,mqttPort:mqttPort),progress:"正在安装网关，请保持此窗口打开…"){[weak self] value in
            self?.reply=value;self?.message="安装完成。启动网关后可连接当前电脑的执行端。"
        }
    }
    func refresh(){guard let directory,tools != nil else{return};perform(.status(directory:directory),progress:"正在查询服务…"){[weak self] value in self?.reply=value;self?.message=""}}
    func start(){guard installed,let directory else{return};perform(.start(directory:directory),progress:"正在启动网关…"){[weak self] value in self?.reply=value;self?.message=""}}
    func stop(){guard installed,let directory else{return};perform(.stop(directory:directory),progress:"正在停止网关…"){[weak self] value in self?.reply=value;self?.message="服务已停止，安装数据和设备身份已保留。"}}
    func locate(_ relative:String?=nil){
        guard let directory else{return}
        let target=relative.map{directory.appendingPathComponent($0)} ?? directory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
    var runtimeConfiguration:URL?{installed ? directory?.appendingPathComponent("desktop-runtime.json") : nil}
    private func remember(_ url:URL)throws{
        if let selectionFile{try JSONEncoder().encode(url.path).write(to:selectionFile,options:.atomic)}
        else{UserDefaults.standard.set(url.path,forKey:"limelink.localGatewayDirectory")}
        directory=url
    }
    private func perform(_ command:LocalGatewayCommand,progress:String,completion:@escaping @MainActor(LocalGatewayReply)->Void){
        guard !busy else{return};busy=true;message=progress
        let client=client,tools=tools
        Task{
            let result=await Task.detached(priority:.userInitiated){Result{try client.execute(command,tools:tools)}}.value
            busy=false
            switch result {
            case .success(let value):completion(value)
            case .failure(let error):
                reply=nil
                let failure=error as? LocalGatewayFailure
                switch failure?.code {
                case "deployment_executable_unavailable":message="缺少部署辅助程序，请使用包含网关组件的 LimeLink 应用。"
                case "docker_compose_unavailable":message="请先检查 Docker 和 Compose。"
                case "local_docker_socket_required":message="本机安装需要本机 Docker 引擎，请检查当前 Docker 连接。"
                case "bundle_checksum_mismatch","desktop_contract_mismatch","package_symlink_refused":message="部署包校验失败，请重新获取完整部署包。"
                case "deployment_tool_failed","deployment_tool_unavailable":message="Docker 未完成操作，请确认容器引擎已启动，并检查原安装目录。"
                case "installed_image_mismatch","gateway_image_revision_mismatch":message="本机镜像与安装记录不一致，请保留原目录并核对部署包。"
                case "deployment_timeout","deployment_timeout_query_original":message="等待操作超时。"
                default:message="未能完成操作，请检查部署包、Docker 和原安装目录。"
                }
                if failure?.outcomeUnknown==true{message += " 请保留原目录并刷新状态，不要重复安装。"}
            }
        }
    }
}

struct DesktopLocalGatewaySettings:View {
    @ObservedObject var gateway:LocalGatewayController
    @ObservedObject var runtime:RuntimeBridge
    @Environment(\.colorScheme) private var scheme
    private var p:DesktopPalette{DesktopPalette(scheme:scheme)}
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            HStack{Text("本机网关").fontWeight(.semibold);Spacer();Text(gateway.stateText).font(.system(size:12)).foregroundStyle(p("slate11"))}
            HStack{Text(gateway.tools == nil ? "容器环境未就绪" : "已找到 Docker 和 Compose");Spacer();Button("检查环境",action:gateway.findTools)}
            if let tools=gateway.tools{Text(tools.docker).font(.system(size:12,design:.monospaced)).foregroundStyle(p("slate11")).textSelection(.enabled)}
            DesktopRule()
            if let directory=gateway.directory {
                Text(directory.path).font(.system(size:12,design:.monospaced)).foregroundStyle(p("slate11")).textSelection(.enabled)
                if let origin=gateway.reply?.origin{Text(origin).textSelection(.enabled)}
                if let services=gateway.reply?.services,!services.isEmpty{
                    ForEach(services){service in HStack{Text(service.service == "gateway" ? "网关" : "安全入口");Spacer();Text(service.state == "running" ? (service.health == "unhealthy" ? "健康检查未通过" : "运行中") : "已停止").foregroundStyle(p("slate11"))}}
                }
                HStack{Button("刷新状态",action:gateway.refresh);Button("启动",action:gateway.start).buttonStyle(DesktopButtonStyle(primary:true)).disabled(!gateway.installed || gateway.tools == nil || gateway.reply?.state == "running");Button("停止",action:gateway.stop).disabled(!gateway.installed || gateway.tools == nil);Spacer();Button("安装目录"){gateway.locate()}}
                if gateway.installed{
                    DesktopRule()
                    HStack{Text("当前电脑");Spacer();Button("连接执行端"){
                        if let configuration=gateway.runtimeConfiguration{runtime.start(configuration)}
                    }.disabled(runtime.running || gateway.reply?.state != "running")}
                    Text("Agent 在“本机助手”中单独启用并设置工作目录。").font(.system(size:12)).foregroundStyle(p("slate11"))
                    HStack{Button("查看网关证书"){gateway.locate("state/authority/ca.crt")};Button("查看登录凭据"){gateway.locate("state/secrets")}}
                    Text("手机连接前需信任网关证书。退出 LimeLink 后，网关由 Docker 继续运行。").font(.system(size:12)).foregroundStyle(p("slate11"))
                }
                Button("打开其他安装",action:gateway.chooseExisting)
            }else{
                HStack{Text(gateway.bundle?.lastPathComponent ?? "尚未选择部署包").lineLimit(1);Spacer();Button("选择部署包",action:gateway.chooseBundle)}
                if let inspection=gateway.inspection {
                    Text((inspection.platform ?? "")+"  "+String((inspection.revision ?? "").prefix(12))).font(.system(size:12,design:.monospaced)).foregroundStyle(p("slate11"))
                    Picker("访问地址",selection:$gateway.host){ForEach(gateway.addresses,id:\.self){address in Text(address == "127.0.0.1" ? "仅本机（127.0.0.1）" : address).tag(address)}}
                    HStack(spacing:16){Text("HTTPS");DesktopInput{TextField("HTTPS 端口",value:$gateway.httpsPort,format:.number.grouping(.never)).accessibilityLabel("HTTPS 端口")};Text("MQTT");DesktopInput{TextField("MQTT 端口",value:$gateway.mqttPort,format:.number.grouping(.never)).accessibilityLabel("MQTT 端口")}}
                }
                HStack{Button("打开已有安装",action:gateway.chooseExisting);Spacer();Button("安装网关",action:gateway.install).buttonStyle(DesktopButtonStyle(primary:true)).disabled(!gateway.canInstall)}
            }
            if !gateway.message.isEmpty{Text(gateway.message).font(.system(size:12)).foregroundStyle(p("slate11")).accessibilityLabel("网关状态："+gateway.message)}
        }.buttonStyle(DesktopButtonStyle()).disabled(gateway.busy).task{gateway.prepare()}
    }
}

struct DesktopGatewaySettings:View {
    @ObservedObject var gateway:LocalGatewayController
    @ObservedObject var runtime:RuntimeBridge
    var useAddress:((String)->Void)?
    @State private var mode="local"
    var body:some View {
        VStack(alignment:.leading,spacing:24){
            Picker("部署位置",selection:$mode){Text("本机").tag("local");Text("远程").tag("remote")}.pickerStyle(.segmented)
            if mode == "local"{DesktopLocalGatewaySettings(gateway:gateway,runtime:runtime)}
            else{DesktopRemoteGatewayGuide(useAddress:useAddress)}
        }
    }
}

struct DesktopGatewaySetup:View {
    @ObservedObject var runtime:RuntimeBridge
    @ObservedObject var gateway:LocalGatewayController
    var useAddress:(String)->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:0){
            HStack{Text("安装与管理网关").font(.system(size:22,weight:.semibold));Spacer();Button("完成"){dismiss()}.buttonStyle(DesktopButtonStyle())}.padding(28)
            DesktopRule()
            ScrollView{DesktopGatewaySettings(gateway:gateway,runtime:runtime,useAddress:{origin in useAddress(origin);dismiss()}).padding(28)}
        }.font(.system(size:14)).frame(width:680,height:740).background{DesktopBackdrop()}
    }
}
