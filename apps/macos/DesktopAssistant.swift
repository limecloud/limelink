import SwiftUI
import LimeLinkCore
import LimeLinkUI

struct DesktopAssistant: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var runtime: RuntimeBridge
    let connect: () -> Void
    @State private var pairing = false
    @Environment(\.colorScheme) private var scheme
    private var p: DesktopPalette { DesktopPalette(scheme: scheme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DesktopHeading(title: "助手")
            if !runtime.agentRuns.isEmpty {
                LocalAgentApprovalView(runtime: runtime)
            }
            if !model.spaces.isEmpty || runtime.agentRuns.isEmpty {
            Group {
            if model.cloudMode || model.spaces.isEmpty {
                Text(model.cloudMode ? "助手任务需要直接连接执行电脑所在的网关。" : "连接网关后，选择执行任务的电脑。").foregroundStyle(p("slate11"))
                Button("连接网关", action: connect).buttonStyle(DesktopButtonStyle(primary: true))
            } else {
                HStack(spacing: 16) {
                    Picker("工作空间", selection: $model.space) { Text("选择工作空间").tag(""); ForEach(Array(model.spaces.enumerated()), id: \.element) { index, space in Text("工作空间 \(index + 1)").tag(space) } }.frame(maxWidth: 260)
                    Button("刷新电脑", action: model.refresh).disabled(model.space.isEmpty)
                    Picker("执行电脑", selection: $model.target) { Text("选择电脑").tag(""); ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in Text("电脑 \(index + 1)" + (device.ready ? "" : "（离线）")).tag(device.id) } }.frame(maxWidth: 260)
                    Button("配对") { pairing = true }.disabled(model.target.isEmpty).popover(isPresented: $pairing) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("与电脑配对").fontWeight(.semibold)
                            Text(model.fingerprint.prefix(8).uppercased().prefix(4) + " " + model.fingerprint.prefix(8).uppercased().suffix(4)).font(.system(size: 22, design: .monospaced)).textSelection(.enabled)
                            Button("连接电脑") { model.action("pair") }
                            Button("检查连接") { model.action("status") }
                        }.padding(24).frame(width: 380)
                    }
                }
                HStack {
                    Button("读取助手配置", action: model.discoverAgent).disabled(model.target.isEmpty || model.hasPending)
                    Button("恢复任务记录", action: model.restoreAgent).disabled(model.target.isEmpty)
                    if model.hasPending { Button("核实原请求", action: model.recoverAgent) }
                }
                if let capabilities = model.agentCapabilities {
                    DesktopRule()
                    HStack(spacing: 20) {
                        Text("Codex").fontWeight(.semibold)
                        Picker("工作目录", selection: $model.agentWorkspace) {
                            Text("选择工作目录").tag("")
                            ForEach(capabilities.workspaces) { Text($0.name).tag($0.id) }
                        }.frame(maxWidth: 340)
                        if capabilities.workspaces.first(where: { $0.id == model.agentWorkspace })?.allowWrite == true {
                            Toggle("允许修改文件", isOn: $model.agentWrite).toggleStyle(.checkbox)
                        }
                        Spacer()
                    }
                    AgentDeviceSelection(model:model)
                    TextEditor(text: $model.agentText).font(.system(size: 14)).scrollContentBackground(.hidden).padding(16).frame(minHeight: 160)
                        .background(p("slate1"), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p("slate7"), lineWidth: 0.5))
                        .privacySensitive().accessibilityLabel("助手任务")
                    HStack {
                        if model.agentRun?.state == "succeeded", model.agentRun?.sessionId != nil {
                            Toggle("继续所选对话", isOn: $model.agentContinue).toggleStyle(.checkbox)
                        }
                        Spacer()
                        Text("\(model.agentText.utf8.count) / 2048 字节").font(.system(size: 12)).foregroundStyle(p("slate11"))
                        Button("提交任务", systemImage: "arrow.up", action: model.submitAgent).buttonStyle(DesktopButtonStyle(primary: true))
                            .disabled(model.agentWorkspace.isEmpty || model.agentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.agentText.utf8.count > 2048 || model.hasPending)
                    }
                }
                if !model.agentRecords.isEmpty {
                    DesktopRule()
                    HStack(spacing: 16) {
                        Picker("原任务", selection: $model.agentRunID) {
                            Text("选择任务").tag("")
                            ForEach(Array(model.agentRecords.enumerated().reversed()), id: \.element.id) { index, record in Text("任务 \(index + 1)").tag(record.id) }
                        }.frame(maxWidth: 300)
                        Button("查询进度") { model.queryAgent() }.disabled(model.agentRunID.isEmpty || model.hasPending)
                        if model.agentRun?.canCancel == true { Button("中断任务") { model.queryAgent(cancel: true) }.disabled(model.hasPending) }
                        Spacer()
                        if let run = model.agentRun { Text(run.stateText).foregroundStyle(p("teal11")) }
                    }
                    if let run = model.agentRun, let error = run.error {
                        Text(error == "agent_login_required" ? "请在执行电脑上登录 Codex，再发起新任务。" : "任务未正常结束，请先核实原任务。").foregroundStyle(p("slate11"))
                        DisclosureGroup("错误详情") { Text(error).font(.system(size: 12, design: .monospaced)) }
                    }
                    ForEach(model.agentEvents) { event in
                        if event.kind == "message" { Text(event.text).textSelection(.enabled).privacySensitive() }
                        else { Label(event.text, systemImage: event.kind == "tool_completed" ? "checkmark" : "gearshape").font(.system(size: 12)).foregroundStyle(p("slate11")) }
                    }
                    AgentToolResults(model:model)
                    if model.agentRun?.events.count == 4 { Button("继续读取回复") { model.queryAgent() }.disabled(model.hasPending) }
                }
            }
            }.disabled(model.busy)
            }
            if runtime.agentRuns.isEmpty {
                DesktopRule()
                DisclosureGroup("本机执行端") { LocalAgentApprovalView(runtime: runtime).padding(.top, 16) }
            }
        }
            .onChange(of: model.agentWorkspace) { _, _ in model.agentWrite = false; model.agentContinue = false }
            .task(id:model.agentRunID){
                guard !model.agentRunID.isEmpty else{return}
                while !Task.isCancelled {
                    do{try await Task.sleep(for:.seconds(2))}catch{return}
                    model.pollAgent()
                }
            }
    }
}
