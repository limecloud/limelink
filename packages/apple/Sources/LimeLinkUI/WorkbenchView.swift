import SwiftUI
import LimeLinkCore

public struct WorkbenchView:View {
    @StateObject private var model=WorkbenchModel()
    @StateObject private var voice=VoiceDraft()
    @Environment(\.scenePhase) private var scenePhase
    public init(){}
    public var body:some View {
        NavigationStack {
            Form {
                Section {
                    HStack{Image(systemName:"leaf.fill").foregroundStyle(.green);VStack(alignment:.leading){Text("LimeLink 柠联").font(.title2.bold());Text("手机的灵感，电脑接着做。").foregroundStyle(.secondary)}}
                }
                Section("1 · 连接你的 LimeIoT 网关") {
                    TextField("网关 HTTPS 地址",text:$model.endpoint).textContentType(.URL).autocorrectionDisabled()
                    SecureField("所有者凭据（留空恢复会话）",text:$model.token)
                    HStack{Button("连接",action:model.connect);Button("退出",action:model.logout)}
                    Picker("明确选择空间",selection:$model.space){Text("请选择").tag("");ForEach(model.spaces,id:\.self){Text($0).tag($0)}}
                    Button("刷新电脑与真实能力",action:model.refresh)
                }
                Section("2 · 核对电脑并配对") {
                    Picker("目标电脑",selection:$model.target){Text("请选择").tag("");ForEach(model.devices){device in Text(device.deviceId + (device.ready ? " · 在线" : " · 离线")).tag(device.id)}}
                        .onChange(of:model.target){_,_ in model.selectTarget()}
                    TextField("本客户端名称",text:$model.name)
                    if !model.fingerprint.isEmpty{Text("本客户端指纹\n" + model.fingerprint).font(.caption.monospaced()).textSelection(.enabled)}
                    HStack{Button("请求配对"){model.action("pair")};Button("检查配对和展示状态"){model.action("status")}}
                    Text("在电脑本机核对名称、指纹和目标后批准。配对请求 120 秒有效。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("3 · 草稿与明确发送") {
                    TextEditor(text:$model.text).frame(minHeight:120).privacySensitive().accessibilityLabel("纯文本草稿")
                    Text("\(model.text.utf8.count) / 2048 字节；仅按纯文本展示，不执行其中的指令。").font(.caption)
                    HStack{Button("确认发送到所选电脑"){voice.stop();model.action("card")};Button(voice.recording ? "停止录音" : "语音草稿"){if voice.recording{voice.stop()}else{voice.start{model.text=$0}}}}
                    Text(voice.message).font(.footnote).foregroundStyle(.secondary)
                    HStack{Button("通过网关生成草稿"){model.generateDraft()};Button("查询原模型任务"){model.generateDraft(resolve:true)}}
                    Text("模型调用会把当前草稿发送到网关已配置的提供方；生成不会触发设备操作。" + model.modelNotice).font(.footnote)
                }
                Section("原任务与恢复") {
                    Text(model.result).font(.callout.monospaced()).textSelection(.enabled).privacySensitive()
                    if model.hasPending {
                        HStack{Button("查询原请求",action:model.resolve);Button("完成已核实记录",action:model.finish)}
                        Text("响应丢失后只查询原请求；结果未知时不自动重发。").font(.footnote)
                    }
                    TextField("需要取消的原卡片 ID",text:$model.cancelID)
                    Button("请求取消尚未展示的卡片"){model.action("cancel")}
                }
                Section("会话修订与输入资格") {
                    TextField("会话 ID（新建可留空）",text:$model.sessionID)
                    Stepper("当前修订：\(model.revision)",value:$model.revision,in:1...1_000_000)
                    HStack{Button("从当前草稿建立会话"){model.action("session_create")};Button("取得 30 秒输入资格"){model.action("session_claim")}}
                    HStack{Button("提交当前草稿修订"){model.action("session_write")};Button("释放输入资格"){model.action("session_release")}}
                }
                Section("有界内容与撤销") {
                    TextField("内容 ID（新建可留空）",text:$model.contentID)
                    HStack{Button("安装纯文本内容（1小时）"){model.action("content_put")};Button("移除所选内容"){model.action("content_remove")}}
                    Button("撤销此客户端与目标的协同",role:.destructive){model.action("revoke")}
                    Text("应用退出和电脑休眠会影响在线状态；手机后台不承担网关职责。当前录音使用系统语音识别，网关模型凭据留在网关。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(model.busy)
            .navigationTitle("柠联工作台")
            .overlay(alignment:.topTrailing){if model.busy{ProgressView().padding()}}
        }
        .tint(Color(red:0.28,green:0.44,blue:0.15))
        .onChange(of:scenePhase){_,phase in if phase != .active{voice.stop()}}
        .onDisappear{voice.stop()}
    }
}
