import SwiftUI
import AppKit
import LimeLinkUI
import LimeLinkDesktopAssets

private struct TerminalViewportKey:EnvironmentKey {static let defaultValue=CGRect.zero}
extension EnvironmentValues {
    var terminalViewport:CGRect {get{self[TerminalViewportKey.self]} set{self[TerminalViewportKey.self]=newValue}}
}
struct DesktopPalette {
    let scheme:ColorScheme
    func callAsFunction(_ name:String)->Color{DesktopColors.color(name,dark:scheme == .dark)}
}
struct DesktopBackdrop:View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    var body:some View {
        let p=DesktopPalette(scheme:scheme)
        GeometryReader{geometry in
            let span=max(geometry.size.width,geometry.size.height)
            ZStack{
                LinearGradient(colors:[p("teal2"),p("slate2"),p("blue2")],startPoint:.topLeading,endPoint:.bottomTrailing)
                if contrast != .increased{
                    RadialGradient(colors:[DesktopColors.color("mint6",dark:false).opacity(scheme == .dark ? 0.13 : 0.32),.clear],center:.topLeading,startRadius:0,endRadius:span*0.75)
                    RadialGradient(colors:[DesktopColors.color("blue6",dark:false).opacity(scheme == .dark ? 0.1 : 0.32),.clear],center:.topTrailing,startRadius:0,endRadius:span*0.6)
                    RadialGradient(colors:[DesktopColors.color("violet6",dark:false).opacity(scheme == .dark ? 0.07 : 0.16),.clear],center:.bottomTrailing,startRadius:0,endRadius:span*0.7)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct DesktopButtonStyle:ButtonStyle {
    var primary=false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration:Configuration)->some View {
        let p=DesktopPalette(scheme:scheme)
        let fill=primary && enabled
            ? AnyShapeStyle(LinearGradient(colors:[DesktopColors.color("teal11",dark:false),DesktopColors.color("teal12",dark:false)],startPoint:.topLeading,endPoint:.bottomTrailing))
            : AnyShapeStyle(p(!enabled ? "slate3" : configuration.isPressed ? "slate5" : "slate3"))
        configuration.label.font(.system(size:14,weight:primary ? .semibold : .regular))
            .padding(.horizontal,14).padding(.vertical,9)
            .foregroundStyle(primary && enabled ? DesktopColors.color("white",dark:false) : p(enabled ? "slate12" : "slate11"))
            .background(fill,in:RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(p(contrast == .increased ? "slate11" : "slate7"),lineWidth:0.5))
    }
}
struct DesktopRule:View {
    @Environment(\.colorScheme) private var scheme
    var body:some View{Rectangle().fill(DesktopPalette(scheme:scheme)("slate7")).frame(height:0.5).accessibilityHidden(true)}
}
struct DesktopInput<Content:View>:View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content:Content
    var body:some View {
        let p=DesktopPalette(scheme:scheme)
        content.textFieldStyle(.plain).padding(10).background(p("slate1"),in:RoundedRectangle(cornerRadius:6)).overlay(RoundedRectangle(cornerRadius:6).strokeBorder(p("slate7"),lineWidth:0.5))
    }
}
struct DesktopArtwork:View {
    let name:String
    var body:some View {
        if let url=DesktopAssets.image(name),let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFit().accessibilityHidden(true)}
    }
}
struct DesktopHeading:View {
    let title:String
    var body:some View{Text(title).font(.system(size:22,weight:.semibold)).frame(maxWidth:.infinity,alignment:.leading)}
}
enum DesktopCopy {
    static func state(_ value:String)->String {
        ["pending":"等待批准","approved":"已配对","rejected":"已拒绝","revoked":"已取消配对","expired":"已过期","queued":"等待显示","presented":"已显示","cancelled":"已取消","accepted":"已接收","dispatched":"已发送","confirmed":"已完成","failed":"未完成","unknown":"结果待确认" ][value] ?? value
    }
    static func status(_ raw:String)->String {
        let first=String(raw.split(separator:"\n").first ?? "")
        let mappings=["select_target_first":"请选择电脑","connect_first":"请先连接网关","select_space_first":"请选择工作空间","pairing_required":"请先与电脑配对","pairing_not_approved":"等待电脑批准配对","gateway_text_model_not_configured":"网关尚未配置 AI 服务","resolve_original_model_task_first":"请先查询上次 AI 任务","select_original_record":"请选择一条记录","no_original_model_task":"暂无 AI 任务","unauthenticated":"登录已失效，请重新连接","HTTPS":"请输入 HTTPS 地址"]
        for (code,message) in mappings where first.contains(code){return message}
        if first.contains("结果未知") || first.contains("unknown"){return "结果待确认，请查看历史"}
        if first.contains("先连接网关"){return "尚未连接"}
        if first.hasPrefix("云原操作："){return state(String(first.dropFirst(5)))}
        if first.hasPrefix("授权状态："){return state(String(first.dropFirst(5)))}
        if first.hasPrefix("请在系统浏览器"){return "等待浏览器批准登录"}
        if first.hasPrefix("连接入口已更改") || first.hasPrefix("网关地址已更改"){return "请重新连接"}
        if first.hasPrefix("已核对当前空间"){return "请选择电脑"}
        if ["accepted","dispatched","confirmed","failed"].contains(first){return state(first)}
        if first.contains("已连接") || first.contains("云会话已恢复"){return "已连接"}
        if first.contains("已退出"){return "已退出"}
        if first.contains("所选记录已完成"){return "记录已归档"}
        return first.count>36 ? "请查看操作详情" : first.replacingOccurrences(of:" · ",with:"，")
    }
}
private enum Destination:String {
    case home="概览",assistant="助手",devices="设备",send="协同",receive="接收",history="任务记录",connection="网关"
    var symbol:String{switch self{case .home:return "house";case .assistant:return "bubble.left.and.text.bubble.right";case .devices:return "square.grid.2x2";case .send:return "paperplane";case .receive:return "tray";case .history:return "clock";case .connection:return "network"}}
}
struct DesktopWorkspace:View {
    @StateObject private var model=WorkbenchModel()
    @StateObject private var voice=VoiceDraft()
    @ObservedObject var runtime:RuntimeBridge
    @ObservedObject var gateway:LocalGatewayController
    @ObservedObject var mobile:MobileDeviceController
    @StateObject private var discovery=GatewayDiscovery()
    @State private var destination=Destination.home
    @State private var pairing=false
    @State private var advancedMode="会话"
    @State private var confirmingReapply=false
    @State private var installingGateway=false
    @State private var connectingPhone=false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings
    private var p:DesktopPalette{DesktopPalette(scheme:scheme)}
    private var connected:Bool{!model.spaces.isEmpty}
    var body:some View {
        VStack(spacing:0){
            navigation
            GeometryReader{geometry in ScrollView{
                Group{switch destination{case .home:home;case .assistant:DesktopAssistant(model:model,runtime:runtime,connect:{destination = .connection});case .devices:devices;case .send:VStack(alignment:.leading,spacing:24){collaborationNavigation;send};case .receive:VStack(alignment:.leading,spacing:24){collaborationNavigation;LocalTerminalView(runtime:runtime,discover:{destination = .connection}).environment(\.terminalViewport,geometry.frame(in:.global))};case .history:history;case .connection:connection}}
                    .padding(28).frame(maxWidth:1180,alignment:.leading).frame(maxWidth:.infinity,minHeight:destination == .home ? geometry.size.height : nil,alignment:destination == .home ? .center : .top)
            }}
            if model.busy || model.result != "先连接网关，选择空间和电脑。"{
                DesktopRule()
                HStack(spacing:12){if model.busy{ProgressView().controlSize(.small)};Text(model.busy ? "正在处理…" : DesktopCopy.status(model.result)).font(.system(size:12)).lineLimit(1);Spacer();Button("详情"){destination = .history}.buttonStyle(.plain).foregroundStyle(p("teal11"))}.padding(.horizontal,32).padding(.vertical,12)
            }
        }.background{DesktopBackdrop().ignoresSafeArea()}.foregroundStyle(p("slate12")).font(.system(size:14)).tint(p("teal11")).buttonStyle(DesktopButtonStyle())
            .onChange(of:model.target){_,_ in model.selectTarget()}
            .onChange(of:destination){_,_ in stopVoice()}
            .onChange(of:phase){_,next in if next != .active{stopVoice()};if next == .background{model.pause();discovery.stop()}else if next == .active{discovery.start()}}
            .onDisappear{stopVoice();model.pause();discovery.stop()}
            .task{discovery.start();if let path=ProcessInfo.processInfo.environment["LIMELINK_RUNTIME_CONFIG"]{runtime.start(URL(fileURLWithPath:path))}}
            .confirmationDialog("重新配对？",isPresented:$confirmingReapply,titleVisibility:.visible){Button("清除旧会话并重新配对",role:.destructive){model.action("pair",reapply:true)}}message:{Text("旧会话与保存内容将被清除，需要在电脑上再次批准。")}
            .sheet(isPresented:$installingGateway){DesktopGatewaySetup(runtime:runtime,gateway:gateway){origin in model.cloudMode=false;model.endpoint=origin}}
            .sheet(isPresented:$connectingPhone){DesktopMobileSetup(mobile:mobile,origin:model.endpoint)}
    }
    private func stopVoice(){if voice.recording || voice.starting{voice.stop()}}
    private var navigation:some View {
        VStack(spacing:0){
            HStack(spacing:24){HStack(spacing:6){ForEach([Destination.home,.assistant,.devices,.send],id:\.self){nav($0)}};Spacer(minLength:8);nav(.connection);Button{destination = .history}label:{Image(systemName:"clock.arrow.circlepath").frame(width:28,height:28)}.buttonStyle(.plain).help("历史").accessibilityLabel("历史");Button{openSettings()}label:{Image(systemName:"gearshape").frame(width:28,height:28)}.buttonStyle(.plain).help("设置").accessibilityLabel("设置")}.padding(.horizontal,28).frame(height:72)
            DesktopRule()
        }
    }
    private func nav(_ item:Destination)->some View {
        let selected=destination == item || (item == .send && destination == .receive)
        return Button{destination=item}label:{Label(item.rawValue,systemImage:item.symbol).padding(.horizontal,14).padding(.vertical,8).foregroundStyle(p(selected ? "teal11" : "slate11")).background(selected ? p("teal4") : .clear,in:Capsule()).contentShape(Rectangle())}.buttonStyle(.plain).fontWeight(.medium).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var home:some View {
        VStack(spacing:28){
            HStack(spacing:0){
                VStack(alignment:.leading,spacing:24){VStack(alignment:.leading,spacing:3){Text("管理网关，");Text("连接你的设备。").foregroundStyle(LinearGradient(colors:[p("teal11"),p("teal9")],startPoint:.leading,endPoint:.trailing))}.font(.system(size:36,weight:.semibold)).fixedSize(horizontal:false,vertical:true);HStack(spacing:12){Button(connected ? "管理设备" : "查找网关",systemImage:"network"){destination = connected ? .devices : .connection}.buttonStyle(DesktopButtonStyle(primary:true));Button("发送内容"){destination = .send}}}.frame(maxWidth:.infinity,alignment:.leading)
                DesktopArtwork(name:"welcome").frame(width:360,height:290)
            }.padding(.horizontal,28).frame(minHeight:310)
            HStack(spacing:16){homeLink("助手",symbol:"bubble.left.and.text.bubble.right",target:.assistant);homeLink("设备",symbol:"square.grid.2x2",target:.devices);homeLink("任务记录",symbol:"clock.arrow.circlepath",target:.history)}
        }
    }
    private func homeLink(_ title:String,symbol:String,target:Destination)->some View {
        Button{destination=target}label:{HStack(spacing:16){Image(systemName:symbol).font(.system(size:22)).foregroundStyle(p("teal11"));Text(title).fontWeight(.semibold);Spacer();Image(systemName:"arrow.up.right").foregroundStyle(p("slate11"))}.padding(20).frame(maxWidth:.infinity,minHeight:88).background(p("slate1"),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(p("slate7"),lineWidth:0.5))}.buttonStyle(.plain)
    }
    private var collaborationNavigation:some View {
        Picker("协同",selection:$destination){Text("发送").tag(Destination.send);Text("接收").tag(Destination.receive)}.pickerStyle(.segmented).frame(width:200)
    }
    private var devices:some View {
        VStack(alignment:.leading,spacing:24){
            HStack{DesktopHeading(title:"设备");if connected{Button("刷新设备",action:model.refresh).disabled(model.space.isEmpty || model.busy)}else{Button("查找网关"){destination = .connection}.buttonStyle(DesktopButtonStyle(primary:true))}}
            if connected{
                Picker("工作空间",selection:$model.space){Text("选择工作空间").tag("");ForEach(model.spaces,id:\.self){Text($0).tag($0)}}.frame(maxWidth:360)
                if model.gatewayDevices.isEmpty{Text(model.space.isEmpty ? "选择工作空间后查看设备。" : "点击刷新设备，读取网关中的设备。").foregroundStyle(p("slate11"))}
                ForEach(model.gatewayDevices){device in
                    HStack(spacing:16){Image(systemName:"square.grid.2x2").foregroundStyle(p("teal11"));Text(device.deviceId).fontWeight(.medium);Spacer();Text(device.ready ? "在线" : "离线").font(.system(size:12)).foregroundStyle(p(device.ready ? "green11" : "slate11"))}
                    DesktopRule()
                }
            }else{nearbyGateways}
        }
    }
    @ViewBuilder private var send:some View {
        if !connected{
            HStack(spacing:40){VStack(alignment:.leading,spacing:20){DesktopHeading(title:"发送内容");nearbyGateways};DesktopArtwork(name:"devices").frame(width:280,height:240)}.frame(minHeight:360)
        }else{
            VStack(alignment:.leading,spacing:20){
                HStack(spacing:16){DesktopHeading(title:"发送内容");Picker("发送到",selection:$model.target){Text("选择电脑").tag("");ForEach(model.devices){Text($0.deviceId+($0.ready ? "" : "（离线）")).tag($0.id)}}.frame(maxWidth:340);Button("配对"){pairing=true}.disabled(model.target.isEmpty).popover(isPresented:$pairing){pairingPanel.padding(24).frame(width:380)}}
                TextEditor(text:$model.text).font(.system(size:14)).scrollContentBackground(.hidden).padding(16).frame(minHeight:260).background(p("slate1"),in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).strokeBorder(p("slate7"),lineWidth:0.5)).privacySensitive().accessibilityLabel("要发送的内容")
                HStack(spacing:12){Button(voice.recording || voice.starting ? "停止录音" : "语音输入",systemImage:"mic"){if voice.recording || voice.starting{voice.stop()}else{voice.start{model.text=$0}}};if !model.cloudMode{Menu("AI 整理"){Button("发送草稿到 AI 服务并整理"){model.generateDraft()};Button("查询上次结果"){model.generateDraft(resolve:true)}}};Spacer();Text("\(model.text.utf8.count) / 2048 字节").font(.system(size:12)).foregroundStyle(p("slate11"));Button("发送",systemImage:"arrow.up"){stopVoice();model.action("card")}.buttonStyle(DesktopButtonStyle(primary:true)).disabled(model.target.isEmpty || model.text.isEmpty)}
                if voice.recording || voice.starting || (voice.message != "语音仅生成草稿，发送仍需点击确认。" && voice.message != "录音已停止，请检查草稿后确认发送。"){Text(voice.message).font(.system(size:12)).foregroundStyle(p("slate11"))}
                DesktopRule()
                DisclosureGroup("会话与保存"){
                    VStack(alignment:.leading,spacing:16){Picker("操作",selection:$advancedMode){Text("共同编辑").tag("会话");Text("保存内容").tag("内容")}.pickerStyle(.segmented)
                        if advancedMode == "会话"{DesktopInput{TextField("会话编号（新建时留空）",text:$model.sessionID)};Stepper("版本 \(model.revision)",value:$model.revision,in:1...1_000_000);HStack{Button("新建会话"){model.action("session_create")};Button("开始编辑"){model.action("session_claim")};Button("保存修改"){model.action("session_write")};Button("结束编辑"){model.action("session_release")}}}
                        else{DesktopInput{TextField("内容编号（新建时留空）",text:$model.contentID)};HStack{Button("保存到电脑（1 小时）"){model.action("content_put")};Button("删除保存内容"){model.action("content_remove")}}}
                    }.padding(.top,16)
                }
            }.disabled(model.busy)
        }
    }
    private var pairingPanel:some View {
        VStack(alignment:.leading,spacing:16){DesktopHeading(title:"与电脑配对");DesktopInput{TextField("此设备名称",text:$model.name)};Text("核对码").font(.system(size:12)).foregroundStyle(p("slate11"));Text(model.fingerprint.isEmpty ? "正在读取…" : model.fingerprint).font(.system(size:12,design:.monospaced)).textSelection(.enabled);HStack{Button("请求配对"){model.action("pair")}.buttonStyle(DesktopButtonStyle(primary:true));Button("查询状态"){model.action("status")}};DisclosureGroup("管理配对"){VStack(alignment:.leading,spacing:12){Button("重新配对"){confirmingReapply=true};Button("取消配对",role:.destructive){model.action("revoke")}}.padding(.top,12)}}.disabled(model.busy)
    }
    private var connection:some View {
        VStack(alignment:.leading,spacing:24){
            HStack{DesktopHeading(title:"网关");Button("安装与管理",systemImage:"server.rack"){installingGateway=true};Button("连接手机",systemImage:"iphone"){connectingPhone=true}}
            Picker("连接方式",selection:$model.cloudMode){Text("网关连接").tag(false);Text("账号登录").tag(true)}.pickerStyle(.segmented).frame(width:320)
            VStack(alignment:.leading,spacing:16){
                if model.cloudMode{
                    Text("服务地址").fontWeight(.medium)
                    DesktopInput{TextField("https://",text:$model.cloudEndpoint)}
                    HStack{Button("登录",action:model.beginCloud).buttonStyle(DesktopButtonStyle(primary:true));Button("恢复登录",action:model.restoreCloud)}
                    if let authorization=model.authorization{Text("授权码："+authorization.userCode).font(.system(size:14,weight:.semibold,design:.monospaced)).privacySensitive();Text("有效期至 "+authorization.expiresAt).font(.system(size:12)).foregroundStyle(p("slate11"));Button("在浏览器中批准"){if let url=URL(string:authorization.verificationUri){openURL(url)}};HStack{Button("检查登录结果",action:model.pollCloud);Button("取消",action:model.cancelCloud)}}
                    if !model.principal.isEmpty{Text(model.principal).privacySensitive()}
                }else{
                    nearbyGateways
                    if !model.endpoint.isEmpty{
                        DesktopRule()
                        Text("当前网关").fontWeight(.medium)
                        Text(model.endpoint).font(.system(size:12)).foregroundStyle(p("slate11")).textSelection(.enabled)
                        DisclosureGroup("首次连接"){
                            VStack(alignment:.leading,spacing:12){DesktopInput{SecureField("访问密钥",text:$model.token)};Button("连接",action:model.connect).buttonStyle(DesktopButtonStyle(primary:true))}.padding(.top,12)
                        }
                        Button("恢复连接",action:model.connect)
                    }
                    DisclosureGroup("手动输入地址"){
                        VStack(alignment:.leading,spacing:12){DesktopInput{TextField("https://",text:$model.endpoint)};Button("连接",action:model.connect)}.padding(.top,12)
                    }
                }
                if connected{DesktopRule();Picker("工作空间",selection:$model.space){Text("选择工作空间").tag("");ForEach(model.spaces,id:\.self){Text($0).tag($0)}};HStack{Button("查找电脑",action:model.refresh).disabled(model.space.isEmpty);Button("断开连接",action:model.logout)}
                    ForEach(model.devices){device in HStack{Image(systemName:"desktopcomputer");Text(device.deviceId);Spacer();Text(device.ready ? "在线" : "离线").font(.system(size:12)).foregroundStyle(p(device.ready ? "green11" : "slate11"))};DesktopRule()}
                    if !model.devices.isEmpty{Button("发送内容"){destination = .send}}
                }
                if !model.gateway.isEmpty{DisclosureGroup("连接详情"){Text(model.gateway).font(.system(size:12,design:.monospaced)).textSelection(.enabled).padding(.top,12)}}
            }.frame(maxWidth:620,alignment:.leading).disabled(model.busy)
        }
    }
    private var nearbyGateways:some View {
        VStack(alignment:.leading,spacing:16){
            HStack(spacing:10){if discovery.searching{ProgressView().controlSize(.small)};Text(discovery.message).foregroundStyle(p("slate11"));Spacer();Button("重新查找",action:discovery.restart).buttonStyle(.plain).foregroundStyle(p("teal11"))}
            ForEach(discovery.gateways){gateway in
                HStack(spacing:16){Image(systemName:"network").font(.system(size:22)).foregroundStyle(p("teal11"));VStack(alignment:.leading,spacing:4){Text(gateway.name).fontWeight(.medium);Text(gateway.origin).font(.system(size:12)).foregroundStyle(p("slate11"))};Spacer();Button(model.endpoint == gateway.origin && connected ? "已连接" : "连接"){model.cloudMode=false;model.endpoint=gateway.origin;model.connect()}.disabled(model.endpoint == gateway.origin && connected)}
                DesktopRule()
            }
        }
    }
    private var history:some View {
        VStack(alignment:.leading,spacing:24){
            DesktopHeading(title:"历史")
            if model.result == "先连接网关，选择空间和电脑。" && model.cloudRecords.isEmpty{Text("暂无操作记录").foregroundStyle(p("slate11"))}
            else{
                if model.cloudMode{Picker("记录",selection:$model.recordKey){Text("选择记录").tag("");ForEach(model.cloudRecords){record in Text(record.reference.request.deviceId+"，"+DesktopCopy.state(record.isPrepared ? "未发送" : record.result?.status.rawValue ?? record.rejection ?? "unknown")).tag(record.id)}}}
                Text(DesktopCopy.status(model.result)).fontWeight(.medium)
                HStack{Button("查询结果"){model.resolve()};if model.cloudMode{Button("向网关核实"){model.resolve(reconcile:true)}};Button("归档记录",action:model.finish)}
                DisclosureGroup("操作详情"){Text(model.result).font(.system(size:12,design:.monospaced)).textSelection(.enabled).privacySensitive().padding(.top,12)}
                DisclosureGroup("取消发送"){HStack{DesktopInput{TextField("消息编号",text:$model.cancelID)};Button("取消尚未显示的内容"){model.action("cancel")}}.padding(.top,12)}
            }
        }.disabled(model.busy)
    }
}
