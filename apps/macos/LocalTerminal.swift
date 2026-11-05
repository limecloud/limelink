import SwiftUI
import AppKit

private struct Peer:Decodable,Identifiable{let id:String;let name:String;let fingerprint:String;let state:String}
private struct Card:Decodable,Identifiable{let id:String;let text:String;let state:String}
private struct Content:Decodable,Identifiable{let id:String;let text:String;let stale:Bool}
private struct SharedSession:Decodable,Identifiable{let id:String;let revision:Int64;let text:String;let writer:String?;let lease_until:Int64;let expired:Bool}
@MainActor private final class RuntimeBridge:ObservableObject {
    @Published var peers:[Peer]=[]
    @Published var cards:[Card]=[]
    @Published var contents:[Content]=[]
    @Published var sessions:[SharedSession]=[]
    @Published var status="选择本机设备配置后启动。执行端只使用设备证书，不使用用户凭据。"
    @Published var running=false
    private var process:Process?
    private var input:FileHandle?
    private var buffer=""
    private var configuration:URL?
    private var executable:URL?
    func choose(){
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.canChooseDirectories=false
        guard panel.runModal() == .OK,let path=panel.url else{return};start(path)
    }
    func start(_ configuration:URL){
        guard process==nil else{return}
        let executable=ProcessInfo.processInfo.environment["LIMELINK_RUNTIME_BINARY"].map(URL.init(fileURLWithPath:)) ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/limelink-runtime")
        let child=Process(),stdin=Pipe(),stdout=Pipe()
        child.executableURL=executable;child.arguments=[configuration.path];child.standardInput=stdin;child.standardOutput=stdout;child.standardError=FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler={[weak self] handle in let data=handle.availableData;guard !data.isEmpty else{return};Task{@MainActor in self?.receive(data)}}
        child.terminationHandler={[weak self] _ in Task{@MainActor in self?.status="本机执行端已停止";self?.running=false;self?.process=nil;self?.input=nil}}
        do{try child.run();process=child;input=stdin.fileHandleForWriting;self.configuration=configuration;self.executable=executable;running=true;status="正在连接网关设备通道…"}catch{status="无法启动执行端，请检查配置与内置程序。"}
    }
    func receive(_ data:Data){
        buffer+=String(decoding:data,as:UTF8.self)
        guard buffer.utf8.count<1_000_000 else{stop();return}
        while let newline=buffer.firstIndex(of:"\n"){
            let line=String(buffer[..<newline]);buffer.removeSubrange(...newline)
            guard let data=line.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{continue}
            if object["type"] as? String=="view"{
                func decode<T:Decodable>(_ key:String)->T?{guard let value=object[key],let bytes=try? JSONSerialization.data(withJSONObject:value) else{return nil};return try? JSONDecoder().decode(T.self,from:bytes)}
                peers=decode("peers") ?? [];cards=decode("cards") ?? [];contents=decode("contents") ?? [];sessions=decode("sessions") ?? []
            }else if object["type"] as? String=="connection"{status=object["state"] as? String=="ready" ? "设备通道在线" : "设备通道离线，等待重新握手"}
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
    func stop(){process?.terminate();input=nil;process=nil;running=false;peers=[];cards=[];contents=[];sessions=[];status="执行端已停止"}
}
private struct SharedSessionRow:View {
    let session:SharedSession
    let send:(String,String,Int64,String?)->Void
    @State private var draft=""
    var body:some View {
        VStack(alignment:.leading,spacing:8){
            Text(session.id+" · 修订 \(session.revision)").font(.caption.monospaced())
            if session.expired{Text("会话已过期")}
            else{
                Text("输入方："+(session.writer ?? "空闲")+"；资格最长 30 秒")
                Text(session.text).textSelection(.enabled).privacySensitive()
                TextEditor(text:$draft).frame(minHeight:80).accessibilityLabel("本机会话草稿")
                HStack{
                    Button("取得本机输入资格"){send("session_claim",session.id,session.revision,nil)}
                    Button("提交本机草稿"){send("session_write",session.id,session.revision,draft)}.disabled(session.writer != "local-desktop")
                    Button("释放资格"){send("session_release",session.id,session.revision,nil)}.disabled(session.writer != "local-desktop")
                }
            }
        }.onAppear{draft=session.text}
    }
}
private struct ReceivedCardRow:View {
    let card:Card
    let presented:()->Void
    @State private var visible=false
    private func acknowledge(){
        guard visible,card.state=="queued",NSApplication.shared.isActive,NSApplication.shared.windows.contains(where:{$0.isVisible && $0.occlusionState.contains(.visible)}) else{return}
        presented()
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8){Text(card.text).textSelection(.enabled).privacySensitive();Text(card.id+" · "+card.state).font(.caption).foregroundStyle(.secondary)}
            .onAppear{visible=true;Task{@MainActor in try? await Task.sleep(for:.milliseconds(150));acknowledge()}}
            .onDisappear{visible=false}
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)){_ in acknowledge()}
    }
}
struct LocalTerminalView:View {
    @StateObject private var runtime=RuntimeBridge()
    var body:some View {
        Form {
            Section("本机执行端") {
                Text(runtime.status)
                HStack{Button("选择设备配置并启动",action:runtime.choose).disabled(runtime.running);Button("停止执行端",action:runtime.stop).disabled(!runtime.running)}
                Button("导出脱敏诊断",action:runtime.exportDiagnostics).disabled(!runtime.running)
                Text("配置由设备管理员提供，包含设备 ID、模型修订、Broker CA 与本机证书路径。不会复制手机的所有者会话。").font(.footnote)
            }
            Section("协同批准") {
                if runtime.peers.isEmpty{Text("暂无配对请求")}
                ForEach(runtime.peers){peer in
                    VStack(alignment:.leading){Text(peer.name+" · "+peer.state);Text(peer.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        if peer.state=="pending"{HStack{Button("核对后批准"){runtime.send("approve",peer.id)};Button("拒绝"){runtime.send("reject",peer.id)}}}
                        if peer.state=="approved"{Button("撤销协同",role:.destructive){runtime.send("revoke",peer.id)}}
                    }
                }
            }
            Section("收到的文本卡片") {
                if runtime.cards.isEmpty{Text("手机发送的文本卡片会出现在这里")}
                ForEach(runtime.cards){card in
                    if ["queued","presented"].contains(card.state){ReceivedCardRow(card:card){runtime.send("presented",card.id)}}
                }
            }
            Section("纯文本内容") {ForEach(runtime.contents){item in VStack(alignment:.leading){Text(item.stale ? "内容已过期" : item.text);Text(item.id).font(.caption)}}}
            Section("手机与本机会话接续") {
                if runtime.sessions.isEmpty{Text("手机建立的会话会出现在这里。编辑前需取得输入资格，修订冲突会明确拒绝。")}
                ForEach(runtime.sessions){session in SharedSessionRow(session:session){type,id,revision,text in runtime.send(type,id,revision:revision,text:text)}}
            }
        }.formStyle(.grouped)
        .task{if let path=ProcessInfo.processInfo.environment["LIMELINK_RUNTIME_CONFIG"]{runtime.start(URL(fileURLWithPath:path))}}
        .onDisappear{ /* 切换到工作台时保留显式启动的执行端；退出应用会关闭 stdin。 */ }
        .padding()
    }
}
