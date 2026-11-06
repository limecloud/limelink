import SwiftUI
import LimeLinkCore
import LimeIoTKit

public struct WorkbenchView:View {
    @StateObject private var model=WorkbenchModel()
    @StateObject private var voice=VoiceDraft()
    @StateObject private var discovery=GatewayDiscovery()
    @State private var confirmingReapply=false
    @State private var connectionRequest:GatewayConnectionRequest?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    public init(){}
    public var body:some View {
        NavigationStack {
            Form {
                Section {
                    HStack{Image(systemName:"leaf.fill").foregroundStyle(.green);VStack(alignment:.leading){Text("LimeLink 柠联").font(.title2.bold());Text("手机的灵感，电脑接着做。").foregroundStyle(.secondary)}}
                }
                connectionSection
                targetSection
                agentSection
                draftSection
                recoverySection
                sessionSection
                contentSection
            }
            .disabled(model.busy)
            .navigationTitle("柠联工作台")
            .overlay(alignment:.topTrailing){if model.busy{ProgressView().padding()}}
        }
        .tint(Color(red:0.28,green:0.44,blue:0.15))
        .task{discovery.start()}
        .task(id:model.agentRunID){
            guard !model.agentRunID.isEmpty else{return}
            while !Task.isCancelled {do{try await Task.sleep(for:.seconds(2))}catch{return};model.pollAgent()}
        }
        .onChange(of:scenePhase){_,phase in if phase == .background{voice.stop();model.pause();discovery.stop()}else if phase == .active{discovery.start()}else{voice.stop()}}
        .onDisappear{voice.stop();model.pause();discovery.stop()}
        .onOpenURL{url in
            do{connectionRequest=try GatewayConnectionRequest(url:url)}catch{model.result="无法识别网关连接地址。"}
        }
        .alert("连接网关",isPresented:Binding(get:{connectionRequest != nil},set:{if !$0{connectionRequest=nil}})){
            Button("使用此地址"){
                guard !model.busy,let request=connectionRequest else{return}
                model.cloudMode=false;model.endpoint=request.origin;model.result="网关地址已填入，请登录或恢复连接。";connectionRequest=nil
            }.disabled(model.busy)
            Button("取消",role:.cancel){connectionRequest=nil}
        }message:{Text(connectionRequest?.origin ?? "")}
    }
    private var connectionSection:some View {
                Section("1，选择连接入口") {
                    Toggle("通过 LimeIoT 云控制面连接",isOn:$model.cloudMode)
                    if model.cloudMode {
                        TextField("控制面 HTTPS 地址",text:$model.cloudEndpoint).textContentType(.URL).autocorrectionDisabled()
                        HStack{Button("恢复云会话",action:model.restoreCloud);Button("发起 / 恢复授权",action:model.beginCloud)}
                        if let authorization=model.authorization {
                            Text("授权码："+authorization.userCode).font(.title3.monospaced()).privacySensitive()
                            Text("到期："+authorization.expiresAt).font(.caption)
                            Button("打开系统浏览器核对并批准") {if let url=URL(string:authorization.verificationUri){openURL(url)}}
                            HStack{Button("查询授权结果",action:model.pollCloud);Button("取消原授权",action:model.cancelCloud)}
                        }
                        if !model.principal.isEmpty{Text("当前账号："+model.principal).privacySensitive()}
                        if !model.gateway.isEmpty{Text("有效网关："+model.gateway).font(.caption.monospaced())}
                        Button("退出云会话",action:model.logout)
                        Text("授权由系统浏览器明确批准。云入口仅提供已授权的设备命令；模型草稿使用本地网关入口。").font(.footnote)
                    }else{
                    HStack{if discovery.searching{ProgressView()};Text(discovery.message).foregroundStyle(.secondary)}
                    ForEach(discovery.gateways){gateway in
                        Button{model.endpoint=gateway.origin;model.connect()}label:{VStack(alignment:.leading,spacing:4){Text(gateway.name);Text(gateway.origin).font(.caption).foregroundStyle(.secondary)}}
                    }
                    Button("重新查找",action:discovery.restart)
                    if !model.endpoint.isEmpty{
                        Text(model.endpoint).font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("首次连接"){SecureField("访问密钥",text:$model.token);Button("连接",action:model.connect)}
                        HStack{Button("恢复连接",action:model.connect);Button("退出",action:model.logout)}
                    }
                    DisclosureGroup("手动输入地址"){TextField("https://",text:$model.endpoint).textContentType(.URL).autocorrectionDisabled();Button("连接",action:model.connect)}
                    }
                    Picker("明确选择空间",selection:$model.space){Text("请选择").tag("");ForEach(model.spaces,id:\.self){Text($0).tag($0)}}
                    Button("刷新电脑与真实能力",action:model.refresh)
                }
    }

    private var targetSection:some View {
                Section("2，核对电脑并配对") {
                    Picker("目标电脑",selection:$model.target){Text("请选择").tag("");ForEach(model.devices){device in Text(device.deviceId + (device.ready ? "，在线" : "，离线")).tag(device.id)}}
                        .onChange(of:model.target){_,_ in model.selectTarget()}
                    TextField("本客户端名称",text:$model.name)
                    if !model.fingerprint.isEmpty{Text("本客户端指纹\n" + model.fingerprint).font(.caption.monospaced()).textSelection(.enabled)}
                    HStack{Button("请求配对"){model.action("pair")};Button("检查配对和展示状态"){model.action("status")}}
                    Button("重新申请已失效的配对"){confirmingReapply=true}
                        .confirmationDialog("重新申请所选电脑的协同？",isPresented:$confirmingReapply,titleVisibility:.visible){
                            Button("清除旧会话与内容并重新申请",role:.destructive){model.action("pair",reapply:true)}
                        }message:{Text("仅对过期、拒绝或撤销的关系生效；旧会话与内容将清除，电脑必须再次批准。先核实所有未完成请求。")}
                    Text("在电脑本机核对名称、指纹和目标后批准。配对请求 120 秒有效。").font(.footnote).foregroundStyle(.secondary)
                }
    }

    private var draftSection:some View {
                Section("3，草稿与明确发送") {
                    TextEditor(text:$model.text).frame(minHeight:120).privacySensitive().accessibilityLabel("纯文本草稿")
                    Text("\(model.text.utf8.count) / 2048 字节；仅按纯文本展示，不执行其中的指令。").font(.caption)
                    HStack{Button("确认发送到所选电脑"){voice.stop();model.action("card")};Button(voice.recording || voice.starting ? "停止录音" : "语音草稿"){if voice.recording || voice.starting{voice.stop()}else{voice.start{model.text=$0}}}}
                    Text(voice.message).font(.footnote).foregroundStyle(.secondary)
                    if !model.cloudMode{HStack{Button("通过网关生成草稿"){model.generateDraft()};Button("查询原模型任务"){model.generateDraft(resolve:true)}}}
                    Text("模型调用会把当前草稿发送到网关已配置的提供方；生成不会触发设备操作。" + model.modelNotice).font(.footnote)
                }
    }
    private var agentSection:some View {
        Section("助手") {
            if model.cloudMode{Text("助手任务需要直接连接网关。").foregroundStyle(.secondary)}
            else{
                HStack{Button("读取助手配置",action:model.discoverAgent).disabled(model.hasPending);Button("恢复任务记录",action:model.restoreAgent)}
                if model.hasPending{Button("核实原助手请求",action:model.recoverAgent)}
                if let capabilities=model.agentCapabilities{
                    Picker("工作目录",selection:$model.agentWorkspace){Text("请选择").tag("");ForEach(capabilities.workspaces){Text($0.name).tag($0.id)}}
                        .onChange(of:model.agentWorkspace){_,_ in model.agentWrite=false;model.agentContinue=false}
                    if capabilities.workspaces.first(where:{$0.id==model.agentWorkspace})?.allowWrite==true{Toggle("允许修改文件",isOn:$model.agentWrite)}
                    AgentDeviceSelection(model:model)
                    TextEditor(text:$model.agentText).frame(minHeight:120).privacySensitive().accessibilityLabel("助手任务")
                    if model.agentRun?.state=="succeeded",model.agentRun?.sessionId != nil{Toggle("继续所选对话",isOn:$model.agentContinue)}
                    Button("提交助手任务",action:model.submitAgent).disabled(model.agentWorkspace.isEmpty || model.agentText.isEmpty || model.hasPending)
                }
                if !model.agentRecords.isEmpty{
                    Picker("原任务",selection:$model.agentRunID){Text("选择任务").tag("");ForEach(model.agentRecords.reversed()){Text("任务 "+String($0.id.prefix(8))).tag($0.id)}}
                    HStack{Button("查询进度"){model.queryAgent()};if model.agentRun?.canCancel==true{Button("中断任务"){model.queryAgent(cancel:true)}}}.disabled(model.agentRunID.isEmpty || model.hasPending)
                    if let run=model.agentRun{Text(run.stateText);if let error=run.error{DisclosureGroup("错误详情"){Text(error).font(.system(size:12,design:.monospaced))}}}
                    ForEach(model.agentEvents){event in Text(event.text).textSelection(.enabled).privacySensitive()}
                    AgentToolResults(model:model)
                }
            }
        }
    }

    private var recoverySection:some View {
                Section("原任务与恢复") {
                    Text(model.result).font(.callout.monospaced()).textSelection(.enabled).privacySensitive()
                    if model.cloudMode {
                        Picker("当前账号全部空间的原操作",selection:$model.recordKey){
                            Text("请选择").tag("")
                            ForEach(model.cloudRecords){record in Text(recordLabel(record)).tag(record.id)}
                        }
                        HStack{Button("查询原请求"){model.resolve()};Button("核对原网关回执"){model.resolve(reconcile:true)}}
                        Button("完成已结束记录 / 放弃未提交准备",action:model.finish)
                        Text("未知结果保留并阻止新提交。核对只查询原 remote_id；切换空间或电脑不会重建请求。").font(.footnote)
                    }else if model.hasPending {
                        HStack{Button("查询原请求"){model.resolve()};Button("完成已核实记录",action:model.finish)}
                        Text("响应丢失后只查询原请求；结果未知时不自动重发。").font(.footnote)
                    }
                    TextField("需要取消的原卡片 ID",text:$model.cancelID)
                    Button("请求取消尚未展示的卡片"){model.action("cancel")}
                }
    }
    private func recordLabel(_ record:ControlCommandRecord)->String {
        let status=record.isPrepared ? "尚未提交" : (record.result?.status.rawValue ?? record.rejection ?? "未知")
        return [record.reference.spaceId,record.reference.request.deviceId,status,String(record.id.prefix(8))].joined(separator:"，")
    }

    private var sessionSection:some View {
                Section("会话修订与输入资格") {
                    TextField("会话 ID（新建可留空）",text:$model.sessionID)
                    Stepper("当前修订：\(model.revision)",value:$model.revision,in:1...1_000_000)
                    HStack{Button("从当前草稿建立会话"){model.action("session_create")};Button("取得 30 秒输入资格"){model.action("session_claim")}}
                    HStack{Button("提交当前草稿修订"){model.action("session_write")};Button("释放输入资格"){model.action("session_release")}}
                }
    }

    private var contentSection:some View {
                Section("有界内容与撤销") {
                    TextField("内容 ID（新建可留空）",text:$model.contentID)
                    HStack{Button("安装纯文本内容（1小时）"){model.action("content_put")};Button("移除所选内容"){model.action("content_remove")}}
                    Button("撤销此客户端与目标的协同",role:.destructive){model.action("revoke")}
                    Text("应用退出和电脑休眠会影响在线状态；手机后台不承担网关职责。当前录音使用系统语音识别，网关模型凭据留在网关。").font(.footnote).foregroundStyle(.secondary)
                }
    }

}
