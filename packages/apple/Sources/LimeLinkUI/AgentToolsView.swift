import SwiftUI
import LimeLinkCore

public struct AgentDeviceSelection: View {
    @ObservedObject var model: WorkbenchModel
    public init(model: WorkbenchModel){self.model=model}
    public var body: some View {
        if model.agentToolEnabled {
            if model.agentContinue {
                if !model.agentDeviceScope.isEmpty {Text("对话中的设备："+model.agentDeviceScope.joined(separator:"、")).font(.system(size:12))}
            }else if !model.agentIoTDevices.isEmpty {
                DisclosureGroup("允许助手访问的设备") {
                    VStack(alignment:.leading,spacing:12) {
                        ForEach(model.agentIoTDevices) {device in
                            Toggle(device.id+(device.ready ? "" : "（离线）"),isOn:Binding(get:{model.agentSelectedDevices.contains(device.id)},set:{enabled in if enabled{model.agentSelectedDevices.insert(device.id)}else{model.agentSelectedDevices.remove(device.id)}}))
                                .disabled(!model.agentSelectedDevices.contains(device.id) && model.agentSelectedDevices.count>=4)
                        }
                    }.padding(.top,12)
                }
            }
        }
    }
}
public struct AgentToolResults: View {
    @ObservedObject var model: WorkbenchModel
    public init(model: WorkbenchModel){self.model=model}
    public var body: some View {
        if !model.agentToolRecords.isEmpty {
            VStack(alignment:.leading,spacing:16) {
                ForEach(model.agentToolRecords) {record in
                    VStack(alignment:.leading,spacing:12) {
                        HStack {Text(record.call.device).fontWeight(.medium);Spacer();Text(record.statusText).font(.system(size:12))}
                        if record.call.isWrite {Text(model.agentPropertyName(record)+"："+record.call.value.text).textSelection(.enabled)}
                        HStack {
                            if record.canConfirm {
                                Button("确认操作"){model.performAgentTool(record.id,action:.confirm)}.buttonStyle(.borderedProminent)
                                Button("拒绝"){model.performAgentTool(record.id,action:.reject)}
                            }
                            if record.needsRecovery {Button("核实原设备命令"){model.performAgentTool(record.id,action:.recover)}}
                            if record.outcome != nil && !record.delivered {Button(record.replyIntent == nil ? "回传结果" : "核实结果回传"){model.performAgentTool(record.id,action:.report)}}
                        }
                    }
                }
            }.font(.system(size:14)).privacySensitive()
        }
    }
}
