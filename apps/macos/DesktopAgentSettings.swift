import SwiftUI
import AppKit
import LimeLinkCore

struct DesktopAgentSettings:View {
    @ObservedObject var runtime:RuntimeBridge
    @Environment(\.colorScheme) private var scheme
    @State private var executableMessage=""
    @State private var findingCodex=false
    private var p:DesktopPalette{DesktopPalette(scheme:scheme)}
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            HStack{Text("本机助手").fontWeight(.semibold);Spacer();Text(runtime.status).font(.system(size:12)).foregroundStyle(p("slate11"))}
            HStack{Text(runtime.configurationName.isEmpty ? "尚未导入设备配置" : runtime.configurationName).lineLimit(1);Spacer();Button(runtime.configurationName.isEmpty ? "导入设备配置" : "更换配置",action:runtime.chooseAgentConfiguration).disabled(runtime.running || findingCodex)}
            if runtime.configurationEditable{
                if runtime.running{
                    HStack{Text("断开后可修改设置，进行中的任务会请求中断。").font(.system(size:12)).foregroundStyle(p("slate11"));Spacer();Button("断开执行端",action:runtime.stop)}
                }
                VStack(alignment:.leading,spacing:20){
                    Toggle("启用 Codex",isOn:$runtime.agentEnabled).toggleStyle(.checkbox)
                    if runtime.agentEnabled{
                        VStack(alignment:.leading,spacing:8){
                            HStack{Text("Codex 程序");Spacer();Button(findingCodex ? "正在查找…" : "自动查找",action:findCodex);Button("选择程序",action:chooseExecutable)}
                            Text(runtime.agentSettings.executable.isEmpty ? "尚未选择" : runtime.agentSettings.executable).font(.system(size:12,design:.monospaced)).lineLimit(2).textSelection(.enabled).foregroundStyle(p("slate11"))
                            if !executableMessage.isEmpty{Text(executableMessage).font(.system(size:12)).foregroundStyle(p("slate11"))}
                        }
                        VStack(alignment:.leading,spacing:16){
                            HStack{Text("工作目录");Spacer();Button("添加目录"){runtime.agentSettings.workspaces.append(LocalAgentWorkspace())}.disabled(runtime.agentSettings.workspaces.count>=8)}
                            ForEach($runtime.agentSettings.workspaces){$workspace in
                                VStack(alignment:.leading,spacing:10){
                                    HStack{DesktopInput{TextField("目录名称",text:$workspace.name).accessibilityLabel("目录名称")};Button("选择文件夹"){chooseDirectory(id:workspace.id)};Button("移除"){runtime.agentSettings.workspaces.removeAll{$0.id==workspace.id}}}
                                    if !workspace.path.isEmpty{Text(workspace.path).font(.system(size:12,design:.monospaced)).lineLimit(2).textSelection(.enabled).foregroundStyle(p("slate11"))}
                                    Toggle("允许修改此目录的文件",isOn:$workspace.allowWrite).toggleStyle(.checkbox)
                                    DesktopRule()
                                }
                            }
                        }
                        HStack{Text("运行超时（秒）");Spacer();DesktopInput{TextField("秒数",value:$runtime.agentSettings.timeoutSeconds,format:.number.grouping(.never)).accessibilityLabel("运行超时（秒）")}.frame(width:100)}
                        Toggle("允许设备工具",isOn:$runtime.agentSettings.allowIoTTools).toggleStyle(.checkbox)
                        Text("任务需在本机批准，设备写入另需逐次确认。").font(.system(size:12)).foregroundStyle(p("slate11"))
                    }
                }.disabled(runtime.running || findingCodex)
                HStack{Button("重新读取",action:runtime.reloadAgentConfiguration).disabled(runtime.running || findingCodex);Spacer();Button("保存并连接",action:runtime.saveAgentConfiguration).buttonStyle(DesktopButtonStyle(primary:true)).disabled(runtime.running || findingCodex)}
            }
            if !runtime.configurationMessage.isEmpty{Text(runtime.configurationMessage).font(.system(size:12)).foregroundStyle(p("slate11")).accessibilityLabel("配置状态："+runtime.configurationMessage)}
        }.buttonStyle(DesktopButtonStyle())
    }
    private func chooseExecutable(){
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.canChooseFiles=true
        guard panel.runModal() == .OK,let url=panel.url else{return}
        runtime.agentSettings.executable=url.path;executableMessage=""
    }
    private func findCodex(){
        let files=FileManager.default
        let paths=(ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator:":").map{String($0)+"/codex"}+[files.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/codex").path,"/opt/homebrew/bin/codex","/usr/local/bin/codex"]
        findingCodex=true;executableMessage=""
        Task{
            let found=await Task.detached(priority:.userInitiated){CodexExecutableDiscovery.find(candidates:paths)}.value
            findingCodex=false
            guard !runtime.running,runtime.agentEnabled else{return}
            if let found{runtime.agentSettings.executable=found.path;executableMessage="Codex "+found.version}
            else{executableMessage="未找到支持 App Server 的 Codex，请选择程序或更新 Codex。"}
        }
    }
    private func chooseDirectory(id:String){
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true
        guard panel.runModal() == .OK,let url=panel.url,let index=runtime.agentSettings.workspaces.firstIndex(where:{$0.id==id}) else{return}
        runtime.agentSettings.workspaces[index].path=url.path
        if runtime.agentSettings.workspaces[index].name.isEmpty{runtime.agentSettings.workspaces[index].name=url.lastPathComponent}
    }
}
