import SwiftUI
import AppKit
import LimeLinkCore

struct Peer:Decodable,Identifiable{let id:String;let name:String;let fingerprint:String;let state:String}
struct Card:Decodable,Identifiable{let id:String;let text:String;let state:String}
struct Content:Decodable,Identifiable{let id:String;let text:String;let stale:Bool}
struct SharedSession:Decodable,Identifiable{let id:String;let revision:Int64;let text:String;let writer:String?;let lease_until:Int64;let expired:Bool}
struct LocalAgentRun:Decodable,Identifiable {
    let id:String;let client:String;let workspace_id:String;let workspace_path:String?;let sandbox:String;let text:String;let state:String;let error:String?;let reply:String;let reply_truncated:Bool
    let iot_devices:[String]?
}
private struct LocalAgentView:Decodable{let runs:[LocalAgentRun]}
@MainActor final class RuntimeBridge:ObservableObject {
    @Published var peers:[Peer]=[]
    @Published var cards:[Card]=[]
    @Published var contents:[Content]=[]
    @Published var sessions:[SharedSession]=[]
    @Published var agentRuns:[LocalAgentRun]=[]
    @Published var status="尚未连接"
    @Published var running=false
    @Published var agentEnabled=false
    @Published var agentSettings=LocalAgentConfiguration()
    @Published private(set) var configurationName=""
    @Published private(set) var configurationMessage=""
    @Published private(set) var configurationEditable=false
    private var configurationDocument:LocalRuntimeConfigurationDocument?
    private var process:Process?
    private var input:FileHandle?
    private var buffer=Data()
    private var configuration:URL?
    private var executable:URL?
    private func readAgentSettings(_ url:URL)throws{
        let document=try LocalRuntimeConfigurationDocument(contentsOf:url)
        configurationDocument=document;configuration=url;configurationName=url.lastPathComponent
        agentEnabled=document.agent != nil;agentSettings=document.agent ?? LocalAgentConfiguration()
        configurationEditable=true;configurationMessage=""
    }
    func chooseAgentConfiguration(){
        guard process==nil else{configurationMessage="请先断开本机执行端。";return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.canChooseDirectories=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do{try readAgentSettings(url)}catch{configurationMessage=configurationError(error)}
    }
    func reloadAgentConfiguration(){
        guard process==nil,let configuration else{return}
        do{try readAgentSettings(configuration)}catch{configurationEditable=false;configurationMessage=configurationError(error)}
    }
    func saveAgentConfiguration(){
        guard process==nil,!running else{configurationMessage="请先断开本机执行端。";return}
        guard let document=configurationDocument,configurationEditable else{configurationMessage="请先导入设备配置。";return}
        do{
            try document.save(agent:agentEnabled ? agentSettings : nil)
            try readAgentSettings(document.url)
            start(document.url)
        }catch{configurationMessage=configurationError(error)}
    }
    private func configurationError(_ error:Error)->String{
        switch (error as? LinkError)?.code{
        case "runtime_configuration_changed":return "配置已被修改，请重新读取后保存。"
        case "runtime_configuration_not_editable":return "请选择当前用户拥有的设备配置文件。"
        case "invalid_local_agent_configuration","agent_executable_unavailable":return "请选择可执行的 Codex 程序，配置 1 至 8 个目录，超时须为 30 至 1800 秒。"
        case "invalid_local_agent_workspace","agent_workspace_unavailable":return "请检查目录名称和路径，名称最多 64 字节。"
        default:return "配置未保存，请检查文件内容和写入权限。"
        }
    }
    func choose(){
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.canChooseDirectories=false
        guard panel.runModal() == .OK,let path=panel.url else{return};start(path)
    }
    func start(_ configuration:URL){
        guard process==nil else{return}
        do{try readAgentSettings(configuration)}catch{configurationDocument=nil;configurationEditable=false;configurationName=configuration.lastPathComponent;configurationMessage=configurationError(error)}
        buffer.removeAll();peers=[];cards=[];contents=[];sessions=[];agentRuns=[]
        let executable=ProcessInfo.processInfo.environment["LIMELINK_RUNTIME_BINARY"].map(URL.init(fileURLWithPath:)) ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/limelink-runtime")
        let child=Process(),stdin=Pipe(),stdout=Pipe()
        child.executableURL=executable;child.arguments=[configuration.path];child.standardInput=stdin;child.standardOutput=stdout;child.standardError=FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler={[weak self,weak child] handle in let data=handle.availableData;guard !data.isEmpty else{return};Task{@MainActor in guard let self,let child,self.process===child else{return};self.receive(data)}}
        child.terminationHandler={[weak self] child in Task{@MainActor in guard let self,self.process===child else{return};self.status="已断开";self.running=false;self.process=nil;self.input=nil}}
        do{try child.run();process=child;input=stdin.fileHandleForWriting;self.configuration=configuration;self.executable=executable;running=true;status="正在连接…"}catch{status="连接失败，请检查设备配置。"}
    }
    func receive(_ data:Data){
        buffer.append(data)
        guard buffer.count<1_000_000 else{stop();return}
        while let newline=buffer.firstIndex(of:10){
            let data=Data(buffer[..<newline]);buffer.removeSubrange(...newline)
            guard let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{continue}
            if object["type"] as? String=="view"{
                func decode<T:Decodable>(_ key:String)->T?{guard let value=object[key],let bytes=try? JSONSerialization.data(withJSONObject:value) else{return nil};return try? JSONDecoder().decode(T.self,from:bytes)}
                peers=decode("peers") ?? [];cards=decode("cards") ?? [];contents=decode("contents") ?? [];sessions=decode("sessions") ?? []
                let agent:LocalAgentView?=decode("agent");agentRuns=agent?.runs ?? []
            }else if object["type"] as? String=="connection"{status=object["state"] as? String=="ready" ? "已连接" : "连接中断，正在重连"}
            else if object["type"] as? String=="error"{status="操作未完成："+(object["code"] as? String ?? "unknown")}
        }
    }
    func send(_ type:String,_ id:String,revision:Int64?=nil,text:String?=nil){
        var frame:[String:Any]=["type":type,"id":id]
        if let revision{frame["revision"]=revision};if let text{frame["text"]=text}
        guard let data=try? JSONSerialization.data(withJSONObject:frame) else{return}
        do{try input?.write(contentsOf:data+Data([10]))}catch{status="本机通道写入失败"}
    }
    func exportDiagnostics(){
        guard let configuration,let executable else{return}
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="LimeLink-diagnostics.json"
        guard panel.runModal() == .OK,let destination=panel.url else{return}
        Task{
            do{
                let data=try await Task.detached{
                    let process=Process(),output=Pipe();process.executableURL=executable;process.arguments=["--diagnostics",configuration.path];process.standardOutput=output;process.standardError=FileHandle.nullDevice
                    try process.run();let bytes=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
                    guard process.terminationStatus==0,bytes.count<100_000 else{throw CocoaError(.fileReadUnknown)};return bytes
                }.value
                try data.write(to:destination,options:.atomic);status="已导出计数与版本；不含正文、身份或凭据。"
            }catch{status="诊断导出未完成。"}
        }
    }
    func stop(){
        // EOF 让运行时先请求中断并记录确认；关掉 UI 通道不代表 Agent 已停止。
        try? input?.close();input=nil;status="正在断开，等待任务中断结果"
    }
}
struct LocalAgentApprovalView:View {
    @ObservedObject var runtime:RuntimeBridge
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        let p=DesktopPalette(scheme:scheme)
        VStack(alignment:.leading,spacing:16){
            HStack{Text("这台电脑的任务").fontWeight(.semibold);Spacer();if !runtime.running{Button("导入执行端配置",action:runtime.choose)}}
            if runtime.agentRuns.isEmpty{Text(runtime.running ? "暂无助手任务" : "执行端尚未连接").foregroundStyle(p("slate11"))}
            ForEach(runtime.agentRuns){run in
                VStack(alignment:.leading,spacing:12){
                    Text(AgentRun.stateText(run.state)).fontWeight(.medium)
                    if !run.text.isEmpty{Text(run.text).textSelection(.enabled).privacySensitive()}
                    if !run.reply.isEmpty{Text(run.reply).textSelection(.enabled).privacySensitive()}
                    if run.reply_truncated{Text("仅显示最近回复，完整内容可在原任务中查询。").font(.system(size:12)).foregroundStyle(p("slate11"))}
                    if run.state=="awaiting_approval"{
                        Text(runtime.peers.first(where:{$0.id==run.client})?.name ?? "已配对客户端").font(.system(size:12)).foregroundStyle(p("slate11"))
                        Text(run.workspace_path ?? run.workspace_id).font(.system(size:12,design:.monospaced)).textSelection(.enabled)
                        Text(run.sandbox=="workspace-write" ? "允许修改此工作目录。Agent 可读取主机上的其他可读文件，工具网络访问关闭。" : "只读执行。Agent 可读取主机上的其他可读文件，工具网络访问关闭。").font(.system(size:12)).foregroundStyle(p("slate11"))
                        if let devices=run.iot_devices,!devices.isEmpty{
                            Text("可访问设备："+devices.joined(separator:"、")).font(.system(size:12,design:.monospaced)).textSelection(.enabled)
                            Text("设备写入由任务发起端逐次确认。").font(.system(size:12)).foregroundStyle(p("slate11"))
                        }
                        HStack{Button("允许执行"){runtime.send("agent_approve",run.id)}.buttonStyle(DesktopButtonStyle(primary:true));Button("拒绝"){runtime.send("agent_reject",run.id)}}
                    }else if ["approved","starting","running"].contains(run.state){Button("中断任务"){runtime.send("agent_cancel",run.id)}}
                }
                DesktopRule()
            }
        }
    }
}
private struct SharedSessionRow:View {
    let session:SharedSession
    let send:(String,String,Int64,String?)->Void
    @State private var draft=""
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        let p=DesktopPalette(scheme:scheme)
        VStack(alignment:.leading,spacing:16){
            HStack{Text("共同编辑").fontWeight(.semibold);Spacer();Text("版本 \(session.revision)").font(.system(size:12)).foregroundStyle(p("slate11"))}
            if session.expired{Text("会话已过期").foregroundStyle(p("slate11"))}
            else{
                Text(session.text).textSelection(.enabled).privacySensitive()
                if session.writer=="local-desktop"{DesktopInput{TextEditor(text:$draft).scrollContentBackground(.hidden).frame(minHeight:100).accessibilityLabel("修改内容")};HStack{Button("保存修改"){send("session_write",session.id,session.revision,draft)}.buttonStyle(DesktopButtonStyle(primary:true));Button("结束编辑"){send("session_release",session.id,session.revision,nil)}}}
                else{Button("开始编辑"){send("session_claim",session.id,session.revision,nil)}}
            }
        }.onAppear{draft=session.text}
    }
}
private struct ReceivedCardRow:View {
    let card:Card
    let presented:()->Void
    @State private var visible=false
    @State private var bounds=CGRect.zero
    @Environment(\.terminalViewport) private var viewport
    @Environment(\.colorScheme) private var scheme
    private func acknowledge(){
        guard visible,bounds.intersects(viewport),card.state=="queued",NSApplication.shared.isActive,NSApplication.shared.windows.contains(where:{$0.isVisible && $0.occlusionState.contains(.visible)}) else{return}
        presented()
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8){Text(card.text).textSelection(.enabled).privacySensitive();Text(DesktopCopy.state(card.state)).font(.system(size:12)).foregroundStyle(DesktopPalette(scheme:scheme)("slate11"))}
            .background(GeometryReader{proxy in Color.clear.onChange(of:proxy.frame(in:.global),initial:true){_,frame in bounds=frame;acknowledge()}})
            .onChange(of:viewport){_,_ in acknowledge()}
            .onAppear{visible=true;Task{@MainActor in try? await Task.sleep(for:.milliseconds(150));acknowledge()}}
            .onDisappear{visible=false}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in acknowledge()}
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didChangeOcclusionStateNotification)){_ in acknowledge()}
    }
}
struct LocalTerminalView:View {
    @ObservedObject var runtime:RuntimeBridge
    let discover:()->Void
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        let p=DesktopPalette(scheme:scheme)
        VStack(alignment:.leading,spacing:24){
            if !runtime.running{
                HStack(spacing:40){VStack(alignment:.leading,spacing:20){DesktopHeading(title:"连接这台电脑");Button("查找网关",action:discover).buttonStyle(DesktopButtonStyle(primary:true));DisclosureGroup("管理员配置"){Button("导入设备配置",action:runtime.choose).padding(.top,12)};if runtime.status != "尚未连接"{Text(runtime.status).font(.system(size:12)).foregroundStyle(p("slate11"))}};Spacer();DesktopArtwork(name:"devices").frame(width:300,height:260)}.frame(minHeight:360)
            }else{
                HStack{DesktopHeading(title:"收到的内容");Text(runtime.status).font(.system(size:12)).foregroundStyle(p("slate11"));Menu("管理"){Button("导出诊断",action:runtime.exportDiagnostics);Button("断开连接",action:runtime.stop)}}
                ForEach(runtime.peers){peer in
                    VStack(alignment:.leading,spacing:12){
                        HStack{Text(peer.name).fontWeight(.semibold);Spacer();Text(DesktopCopy.state(peer.state)).font(.system(size:12)).foregroundStyle(p("slate11"))}
                        if peer.state=="pending"{Text("核对码").font(.system(size:12)).foregroundStyle(p("slate11"));Text(String(peer.fingerprint.prefix(4)).uppercased()+" "+String(peer.fingerprint.dropFirst(4).prefix(4)).uppercased()).font(.system(size:22,design:.monospaced)).textSelection(.enabled);HStack{Button("允许连接"){runtime.send("approve",peer.id)}.buttonStyle(DesktopButtonStyle(primary:true));Button("拒绝"){runtime.send("reject",peer.id)}}}
                        if peer.state=="approved"{DisclosureGroup("设备详情"){VStack(alignment:.leading,spacing:12){Text(peer.fingerprint).font(.system(size:12,design:.monospaced)).textSelection(.enabled);Button("取消配对",role:.destructive){runtime.send("revoke",peer.id)}}.padding(.top,12)}}
                    }
                    DesktopRule()
                }
                if runtime.cards.filter({["queued","presented"].contains($0.state)}).isEmpty && runtime.sessions.isEmpty && runtime.contents.isEmpty{Text("暂无收到的内容").foregroundStyle(p("slate11"))}
                ForEach(runtime.cards){card in if ["queued","presented"].contains(card.state){ReceivedCardRow(card:card){runtime.send("presented",card.id)};DesktopRule()}}
                ForEach(runtime.sessions){session in SharedSessionRow(session:session){type,id,revision,text in runtime.send(type,id,revision:revision,text:text)};DesktopRule()}
                ForEach(runtime.contents){item in Text(item.stale ? "内容已过期" : item.text).textSelection(.enabled).privacySensitive();DesktopRule()}
            }
        }
    }
}
