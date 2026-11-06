import SwiftUI
import AppKit
import LimeLinkCore

struct DesktopRemoteGatewayGuide:View {
    var useAddress:((String)->Void)?
    @State private var input=RemoteGatewayInput()
    @State private var plan:RemoteGatewayPlan?
    @State private var message=""
    @State private var checking=false
    @State private var checks:[RemoteGatewayProbeResult]=[]
    @Environment(\.colorScheme) private var scheme
    private var p:DesktopPalette{DesktopPalette(scheme:scheme)}
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            Text("远程网关").fontWeight(.semibold)
            Picker("访问网络",selection:$input.network){Text("内网").tag(RemoteGatewayNetwork.privateNetwork);Text("公网").tag(RemoteGatewayNetwork.publicNetwork)}.pickerStyle(.segmented)
            if let plan {
                HStack{Text(plan.origin).textSelection(.enabled);Spacer();Button("修改主机"){self.plan=nil;message="";checks=[]}.disabled(checking)}
                VStack(alignment:.leading,spacing:12){
                    Text("需要放行的端口").fontWeight(.medium)
                    ForEach(plan.ports){port in
                        HStack{Text(port.purpose);Spacer();Text("TCP \(port.port)").monospacedDigit()}
                    }
                    Text("请在云平台安全组和宝塔“安全 → 防火墙”分别放行。").font(.system(size:12)).foregroundStyle(p("slate11"))
                    HStack{Button(checking ? "正在检查…" : "检查连接"){probe(plan)}.disabled(checking);Spacer()}
                    ForEach(checks){result in
                        HStack(alignment:.top){Text(result.purpose);Spacer();Text(result.message).foregroundStyle(p(result.reachable ? "green11" : "slate11"))}
                    }
                    if !checks.isEmpty{Text("设备证书将在执行端连接时验证。").font(.system(size:12)).foregroundStyle(p("slate11"))}
                }
                DesktopRule()
                ForEach(plan.steps){step in
                    DisclosureGroup(step.title){VStack(alignment:.leading,spacing:12){Text(step.detail).foregroundStyle(p("slate11"));Text(step.commands).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.padding(.top,12)}
                    DesktopRule()
                }
                HStack{Button("导出安装引导"){export(plan)};Spacer();if let useAddress{Button("使用此地址"){useAddress(plan.origin)}.buttonStyle(DesktopButtonStyle(primary:true))}}
                Text("按引导在远程主机安装，完成后用网关凭据登录。").font(.system(size:12)).foregroundStyle(p("slate11"))
            }else{
                field("网关地址"){TextField(input.network == .privateNetwork ? "192.168.1.20" : "gateway.example.com",text:$input.host).accessibilityLabel("远程网关地址")}
                HStack(spacing:16){Text("HTTPS 端口");DesktopInput{TextField("HTTPS 端口",value:$input.httpsPort,format:.number.grouping(.never)).accessibilityLabel("远程 HTTPS 端口")};Text("设备端口");DesktopInput{TextField("设备端口",value:$input.mqttPort,format:.number.grouping(.never)).accessibilityLabel("远程 MQTT 端口")}}
                field("SSH 地址"){TextField("留空则使用网关地址",text:$input.sshHost).accessibilityLabel("SSH 主机地址")}
                HStack(spacing:16){Text("SSH 用户");DesktopInput{TextField("普通用户",text:$input.sshUser).accessibilityLabel("SSH 用户")};Text("SSH 端口");DesktopInput{TextField("SSH 端口",value:$input.sshPort,format:.number.grouping(.never)).accessibilityLabel("SSH 端口")}}
                field("安装目录"){TextField("远程主机上的新目录",text:$input.directory).accessibilityLabel("远程安装目录")}
                HStack{Text("原生安装包");Spacer();Button("选择安装包",action:choosePackage)}
                Text(input.packagePath).font(.system(size:12,design:.monospaced)).foregroundStyle(p("slate11")).lineLimit(2).textSelection(.enabled)
                Text(input.network == .privateNetwork ? "电脑与手机需能访问此内网 IP，首次连接需信任网关证书。" : "公网 HTTPS 使用受信证书，设备连接需持有独立 mTLS 证书。").font(.system(size:12)).foregroundStyle(p("slate11"))
                HStack{Spacer();Button("生成安装引导",action:generate).buttonStyle(DesktopButtonStyle(primary:true))}
            }
            if !message.isEmpty{Text(message).font(.system(size:12)).foregroundStyle(p("slate11")).accessibilityLabel("远程部署状态："+message)}
        }.buttonStyle(DesktopButtonStyle()).onChange(of:input.network){_,network in plan=nil;message="";checks=[];input.httpsPort=network == .publicNetwork ? 443 : 8443}
    }
    private func probe(_ plan:RemoteGatewayPlan){
        checking=true;checks=[]
        Task{
            let result=await RemoteGatewayProbe.check(plan)
            if self.plan?.origin==plan.origin && self.plan?.ports.map(\.port)==plan.ports.map(\.port){checks=result}
            checking=false
        }
    }
    private func field<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View{VStack(alignment:.leading,spacing:8){Text(title);DesktopInput{content()}}}
    private func generate(){
        do{
            guard let url=Bundle.main.url(forResource:"IoTDeploymentSource",withExtension:"json") else{throw LinkError("invalid_gateway_source")}
            let source=try JSONDecoder().decode(RemoteGatewaySource.self,from:Data(contentsOf:url))
            plan=try RemoteGatewayPlan(input:input,source:source);message=""
        }catch{
            switch (error as? LinkError)?.code {
            case "invalid_gateway_host":message="请填写主机名或 IPv4 地址，不含协议、端口或路径。"
            case "private_gateway_ip_required":message="内网部署请填写 10、172.16 至 172.31 或 192.168 网段的 IPv4 地址。"
            case "public_gateway_host_required":message="公网部署请填写公网域名或公网 IPv4 地址。"
            case "invalid_gateway_ports":message="请检查端口范围，HTTPS、SSH 和设备端口不能重复；设备端口至少为 1024。"
            case "invalid_gateway_user":message="请填写有效的 SSH 用户名。"
            case "invalid_gateway_directory":message="请填写远程主机上的新绝对目录，使用字母、数字、斜线、下划线、短横线或点，不含上级路径。"
            case "invalid_gateway_package_path":message="请选择对应主机架构的原生安装包。"
            default:message="缺少已固定的网关源码信息，请使用完整的 LimeLink 应用。"
            }
        }
    }
    private func choosePackage(){
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.canChooseFiles=true
        guard panel.runModal() == .OK,let url=panel.url else{return}
        input.packagePath=url.path;message=""
    }
    private func export(_ plan:RemoteGatewayPlan){
        let panel=NSSavePanel();panel.nameFieldStringValue="LimeLink-远程网关.md"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{try Data(plan.markdown.utf8).write(to:url,options:.atomic);message="安装引导已导出。"}catch{message="导出失败，请检查文件位置和写入权限。"}
    }
}
