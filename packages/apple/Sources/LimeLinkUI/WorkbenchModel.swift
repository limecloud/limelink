import SwiftUI
import Foundation
import CryptoKit
import LimeLinkCore
import LimeIoTKit
#if os(iOS)
import UIKit
#endif

@MainActor public final class WorkbenchModel: ObservableObject {
    @Published public var cloudMode = false {didSet{if cloudMode != oldValue{resetRoute()}}}
    @Published public var endpoint = "" {didSet{if endpoint != oldValue{token="";if client != nil{clearConnection()}}}}
    @Published public var cloudEndpoint = "" {didSet{if cloudEndpoint != oldValue{resetRoute()}}}
    @Published public private(set) var authorization: NativeLogin?
    @Published public private(set) var principal = ""
    @Published public private(set) var gateway = ""
    @Published public private(set) var cloudRecords: [ControlCommandRecord] = []
    @Published public var recordKey = ""
    @Published public var token = ""
    @Published public var space = "" {didSet{if space != oldValue{clearTargets();cloudSnapshot=nil;gateway=""}}}
    @Published public var spaces: [String] = []
    @Published public var devices: [Device] = []
    @Published public private(set) var gatewayDevices: [Device] = []
    @Published public var target = "" {didSet{if target != oldValue{clearAgent()}}}
    @Published public var text = ""
    @Published public var name = "我的手机"
    @Published public var result = "先连接网关，选择空间和电脑。"
    @Published public var fingerprint = ""
    @Published public var busy = false
    @Published public var hasPending = false
    @Published public var sessionID = ""
    @Published public var revision = 1
    @Published public var contentID = ""
    @Published public var cancelID = ""
    @Published public var modelNotice = ""
    @Published public private(set) var agentCapabilities: AgentCapabilities?
    @Published public private(set) var agentRecords: [AgentReference] = []
    @Published public private(set) var agentRun: AgentRun?
    @Published public private(set) var agentEvents: [AgentEvent] = []
    @Published public private(set) var agentToolEnabled=false
    @Published public private(set) var agentIoTDevices: [Device] = []
    @Published public var agentSelectedDevices=Set<String>()
    @Published public private(set) var agentToolRecords: [AgentToolRecord] = []
    @Published public var agentRunID = "" {didSet{if agentRunID != oldValue{agentRun=nil;agentEvents=[];agentContinue=false;agentToolRecords=[]}}}
    @Published public var agentWorkspace = ""
    @Published public var agentText = ""
    @Published public var agentWrite = false
    @Published public var agentContinue = false
    private var agent: AgentClient?
    private var agentIoT: AgentIoTClient?
    private var agentGeneration = 0
    private var client: LinkClient?
    private let secure: any SessionStore
    private let transport: any HTTPTransport
    private let development: Bool
    private var cloud: CloudLinkClient?
    private var cloudSnapshot: CloudLinkSnapshot?
    private var gatewayModels: [String:Model] = [:]
    private var task: Task<Void,Never>?
    private var generation = 0
    private var nextPoll = Date.distantPast
    private var ai: TextGenerationClient?
    private var aiKey: String?
    private func clearAgent(){agentGeneration += 1;agentCapabilities=nil;agentRecords=[];agentRunID="";agentRun=nil;agentEvents=[];agentWorkspace="";agentText="";agentWrite=false;agentContinue=false;agentToolEnabled=false;agentToolRecords=[];agentSelectedDevices=[]}
    private func clearTargetFields(){fingerprint="";sessionID="";revision=1;contentID="";cancelID="";aiKey=nil;modelNotice="";clearAgent()}
    private func clearTargets(){gatewayDevices=[];devices=[];agentIoTDevices=[];gatewayModels=[:];target="";clearTargetFields()}
    private func clearConnection(){client=nil;agent=nil;agentIoT=nil;ai=nil;spaces=[];space="";clearTargets();hasPending=false;result="网关地址已更改，请重新连接。原任务保留在原网关的安全存储记录中。"}
    private func resetRoute(){
        pause();client=nil;agent=nil;agentIoT=nil;cloud=nil;ai=nil;authorization=nil;principal="";gateway="";cloudSnapshot=nil
        spaces=[];space="";clearTargets();cloudRecords=[];recordKey="";token="";text="";hasPending=false
        result="连接入口已更改，请明确恢复会话或发起授权。原任务仍保存在原入口。"
    }
    /// 离开前台即取消当前等待；迟到响应只能更新 SDK 账本，不能恢复界面目标。
    public func pause(){generation += 1;task?.cancel();clearTargets();cloudSnapshot=nil;gateway="";authorization=nil}
    public init(store:any SessionStore = SecureStore(),transport:any HTTPTransport = URLSessionTransport(),development:Bool = ProcessInfo.processInfo.environment["LIMELINK_DEVELOPMENT"]=="1") {
        self.secure=store;self.transport=transport;self.development=development
        endpoint=ProcessInfo.processInfo.environment["LIMELINK_ENDPOINT"] ?? UserDefaults.standard.string(forKey:"limelink.endpoint") ?? ""
        cloudEndpoint=UserDefaults.standard.string(forKey:"limelink.cloud.endpoint") ?? ""
        #if os(iOS)
        name=UIDevice.current.name
        #else
        name=Host.current().localizedName ?? "我的客户端"
        #endif
    }
    public func run(_ work:@escaping @MainActor () async throws -> Void) {
        guard !busy else { return };busy=true
        let current=generation
        task=Task {
            defer{busy=false}
            do{try Task.checkCancellation();try await work()}catch{
                if current==generation && !Task.isCancelled{
                    if let control=error as? ControlError,control == .unauthenticated{spaces=[];space="";clearTargets();principal="";gateway="";cloudSnapshot=nil;cloudRecords=[];recordKey="";text=""}
                    result=(error as? GatewayError)?.message ?? (error as? ControlError)?.message ?? (error as? LinkError)?.code ?? error.localizedDescription
                }
            }
            guard current==generation && !Task.isCancelled else{return}
            if cloudMode,let cloud {
                do{let records=try await cloud.records();try Task.checkCancellation();cloudRecords=records;hasPending=records.contains{$0.isPrepared || !$0.canForget}}
                catch{if !Task.isCancelled{hasPending=true}}
            }else if let client{do{let pending=try await client.pending();try Task.checkCancellation();hasPending=pending != nil}catch{if !Task.isCancelled{hasPending=true}}}else{hasPending=false}
        }
    }
    public func connect() {
        run {
            self.clearConnection()
            let client=try LinkClient(endpoint:self.endpoint,store:self.secure,transport:self.transport,development:self.development)
            if self.token.isEmpty {try await client.restore()}else{try await client.login(token:self.token)}
            try Task.checkCancellation()
            self.token="";self.client=client
            let agent=AgentClient(link:client,store:self.secure);self.agent=agent
            self.agentIoT=AgentIoTClient(gateway:client.gateway,agent:agent,store:self.secure)
            self.ai=TextGenerationClient(gateway:client.gateway,store:self.secure)
            let spaces=try await client.spaces().map(\.spaceId);try Task.checkCancellation();self.spaces=spaces
            self.devices=[];self.target="";self.fingerprint=""
            let pending=try await client.pending();try Task.checkCancellation();self.hasPending=pending != nil
            UserDefaults.standard.set(self.endpoint,forKey:"limelink.endpoint")
            self.result="已连接，请明确选择空间并刷新电脑列表。"
        }
    }
    private func cloudClient() throws -> CloudLinkClient {
        if let cloud{return cloud}
        let value=try CloudLinkClient(endpoint:cloudEndpoint,store:secure,transport:transport,development:development);cloud=value;return value
    }
    private func loadCloud(_ client:CloudLinkClient) async throws {
        let session=try await client.control.restoreSession()
        let spaces=try await client.control.spaces(),records=try await client.records();try Task.checkCancellation()
        self.space="";clearTargets();cloudSnapshot=nil;gateway="";text=""
        principal=session.principal.name + "，" + session.principal.principalId;self.spaces=spaces.map(\.spaceId);cloudRecords=records
        authorization=nil;recordKey="";UserDefaults.standard.set(cloudEndpoint,forKey:"limelink.cloud.endpoint")
        result="云会话已恢复，请明确选择空间并刷新网关与电脑。原操作可在下方独立查询。"
    }
    public func restoreCloud(){run{try await self.loadCloud(self.cloudClient())}}
    public func beginCloud(){run{
        let client=try self.cloudClient()
        #if os(iOS)
        let platform="ios"
        #else
        let platform="macos"
        #endif
        let login=try await client.control.beginAuthorization(platform:platform);try Task.checkCancellation()
        self.authorization=login;self.nextPoll=Date().addingTimeInterval(Double(login.intervalSeconds))
        self.result="请在系统浏览器中核对授权码、平台和账号后批准；回到应用明确查询结果。"
    }}
    public func pollCloud(){run{
        guard Date()>=self.nextPoll,let login=self.authorization else{throw LinkError("请按授权间隔稍后查询，恢复请求需先点击发起 / 恢复授权。")}
        self.nextPoll=Date().addingTimeInterval(Double(login.intervalSeconds))
        let client=try self.cloudClient(),response=try await client.control.pollAuthorization();try Task.checkCancellation()
        if response.status == .approved{try await self.loadCloud(client)}else{self.result="授权状态："+response.status.rawValue}
    }}
    public func cancelCloud(){run{
        try await self.cloudClient().control.cancelAuthorization();try Task.checkCancellation()
        self.authorization=nil;self.result="原授权已取消。"
    }}
    public func refresh() {
        run {
            if self.cloudMode {
                guard !self.space.isEmpty else{throw LinkError("select_space_first")}
                let snapshot=try await self.cloudClient().snapshot(space:self.space);try Task.checkCancellation()
                self.target="";self.clearTargetFields();self.cloudSnapshot=snapshot
                self.gatewayDevices=snapshot.devices
                self.devices=snapshot.devices.filter{snapshot.models[$0.modelRevision]?.modelId=="urn:limelink:model:desktop:1"}
                self.gateway=snapshot.gateway.gatewayId+"，"+snapshot.gateway.localSpaceId+"，"+snapshot.gateway.revision
                self.result="已核对当前空间唯一有效网关；请选择电脑并核对指纹。";return
            }
            guard let client=self.client,!self.space.isEmpty else{throw LinkError("select_space_first")}
            let snapshot=try await client.snapshot(space:self.space)
            try Task.checkCancellation()
            self.target="";self.clearTargetFields()
            self.gatewayDevices=snapshot.devices
            self.devices=snapshot.devices.filter{snapshot.models[$0.modelRevision]?.modelId=="urn:limelink:model:desktop:1"}
            self.gatewayModels=snapshot.models
            self.agentIoTDevices=snapshot.devices.filter{device in snapshot.models[device.modelRevision].map{!$0.modelId.hasPrefix("urn:limelink:model:desktop:")} ?? false}
            self.result="发现 \(self.devices.count) 个 LimeLink 终端；离线端不可提交。"
        }
    }
    public func selectTarget() {
        clearTargetFields()
        run {
            guard !self.target.isEmpty else{return}
            let value:String
            if self.cloudMode{value=try await self.cloudClient().fingerprint(device:self.target)}
            else{guard let client=self.client else{return};value=try await client.fingerprint(space:self.space,device:self.target)}
            try Task.checkCancellation();self.fingerprint=value
        }
    }
    public func action(_ kind:String,reapply:Bool = false) {
        run {
            guard let device=self.devices.first(where:{$0.id==self.target}) else{throw LinkError("select_target_first")}
            let payload:JSONValue
            switch kind {
            case "pair":payload = .object(reapply ? ["name":.string(self.name),"reapply":.bool(true)] : ["name":.string(self.name)])
            case "card":payload = .object(["text":.string(self.text),"ttl":.integer(3600)])
            case "cancel":payload = .object(["id":.string(self.cancelID)])
            case "session_create":
                if self.sessionID.isEmpty{self.sessionID=UUID().uuidString.lowercased()}
                payload = .object(["id":.string(self.sessionID),"text":.string(self.text),"ttl":.integer(3600)])
            case "session_claim","session_release":payload = .object(["id":.string(self.sessionID),"revision":.integer(self.revision)])
            case "session_write":payload = .object(["id":.string(self.sessionID),"revision":.integer(self.revision),"text":.string(self.text)])
            case "content_put":
                if self.contentID.isEmpty{self.contentID=UUID().uuidString.lowercased()}
                let hash=SHA256.hash(data:Data(self.text.utf8)).map{String(format:"%02x",$0)}.joined()
                payload = .object(["id":.string(self.contentID),"text":.string(self.text),"ttl":.integer(3600),"sha256":.string(hash)])
            case "content_remove":payload = .object(["id":.string(self.contentID)])
            default:payload = .object([:])
            }
            self.hasPending=true
            if self.cloudMode {
                let record=try await self.cloudClient().perform(space:self.space,device:device,kind:kind,payload:payload);try Task.checkCancellation()
                self.recordKey=record.id;try self.showCloud(record,project:true);return
            }
            guard let client=self.client else{throw LinkError("connect_first")}
            var command=try await client.perform(space:self.space,device:device,kind:kind,payload:payload)
            for _ in 0..<20 where ["accepted","dispatched"].contains(command.status) {
                try await Task.sleep(for:.milliseconds(200));command=try await client.resolve()
            }
            try Task.checkCancellation();try self.show(command)
            if kind=="pair",case .object(let response)=try LinkClient.response(command),response["ok"] == .bool(true) {
                // 配对请求的处理回执与电脑上的批准分别核实；成功回执不阻塞后续能力读取。
                try await client.acknowledgeResolved();try Task.checkCancellation()
            }
        }
    }
    private func show(_ command:Command) throws {
        result=command.statusText + "\n" + command.commandId
        if let response=try LinkClient.response(command) {
            result += "\n" + response.jsonText
            if case .object(let object)=response,case .object(let value)=object["value"] {
                if case .integer(let revision)=value["revision"]{self.revision=revision}
                if case .string(let text)=value["text"]{self.text=text}
                if case .string(let id)=value["id"],command.request.operation.value.text.contains("card"){cancelID=id}
            }
        }
    }
    private func showCloud(_ record:ControlCommandRecord,project:Bool) throws {
        result="云原操作："+(record.isPrepared ? "尚未提交" : record.rejection ?? record.result?.status.rawValue ?? "结果未知")+"\n"+record.id
        guard let response=try CloudLinkClient.response(record) else{return}
        result += "\n"+response.jsonText
        // 原操作随时可查；旧空间/旧网关/旧目标的结果不覆盖当前编辑字段。
        guard project,let snapshot=cloudSnapshot,record.reference.principalId==snapshot.principal,
              record.reference.spaceId==space,record.reference.localSpaceId==snapshot.gateway.localSpaceId,
              record.reference.request.gatewayId==snapshot.gateway.gatewayId,record.reference.request.bindingRevision==snapshot.gateway.revision,
              record.reference.request.deviceId==target,devices.first(where:{$0.id==target})?.modelRevision==record.reference.request.modelRevision,
              case .object(let object)=response,case .object(let value)=object["value"] else{return}
        if case .integer(let revision)=value["revision"]{self.revision=revision}
        if case .string(let text)=value["text"]{self.text=text}
        if case .string(let id)=value["id"],case .object(let operation)=record.reference.request.operation.value,operation["kind"] == .string("card"){cancelID=id}
    }
    public func resolve(reconcile:Bool = false) {run{
        if self.cloudMode{
            guard !self.recordKey.isEmpty else{throw LinkError("select_original_record")}
            let record=try await self.cloudClient().resolve(key:self.recordKey,reconcile:reconcile);try Task.checkCancellation();try self.showCloud(record,project:true)
        }else if let client=self.client{let command=try await client.resolve();try Task.checkCancellation();try self.show(command)}
    }}
    public func finish() {run{
        if self.cloudMode{guard !self.recordKey.isEmpty else{throw LinkError("select_original_record")};try await self.cloudClient().forget(key:self.recordKey);try Task.checkCancellation();self.recordKey=""}
        else{guard let client=self.client else{return};try await client.acknowledgeResolved();try Task.checkCancellation()}
        self.result="所选记录已完成；尚未提交的准备记录可明确放弃，结果未知的记录会保留。"
    }}
    public func logout() {run{
        if self.cloudMode{try await self.cloudClient().logout()}else{try await self.client?.logout()};try Task.checkCancellation()
        self.client=nil;self.agent=nil;self.agentIoT=nil;self.cloud=nil;self.ai=nil;self.authorization=nil;self.principal="";self.gateway="";self.cloudSnapshot=nil
        self.space="";self.clearTargets();self.spaces=[];self.cloudRecords=[];self.recordKey="";self.text="";self.hasPending=false
        self.result="已退出。未核实记录和配对身份保留在系统安全存储。"
    }}
    public func generateDraft(resolve:Bool = false) {
        run {
            guard let ai=self.ai,!self.space.isEmpty else{throw LinkError("connect_first")}
            let capability=try await ai.capabilities(space:self.space)
            try Task.checkCancellation()
            guard capability.configured else{throw LinkError("gateway_text_model_not_configured")}
            self.modelNotice="文字内容由网关配置的模型服务处理；生成结果仅作为草稿。"
            let records=try await ai.records(space:self.space)
            let record:TextGenerationRecord
            if resolve {
                guard let key=self.aiKey ?? records.last?.id else{throw LinkError("no_original_model_task")}
                record=try await ai.resolve(space:self.space,key:key)
            } else {
                guard !records.contains(where:{$0.pending}) else{throw LinkError("resolve_original_model_task_first")}
                let input=try TextGenerationRequests.input(messages:[.init(role:"user",content:self.text)],instructions:"整理为简洁的纯文本草稿。不要声称已经控制设备或执行操作。")
                record=try await ai.submit(space:self.space,input:input)
            }
            try Task.checkCancellation();self.aiKey=record.id
            if let draft=record.text{self.text=draft}
            self.result=record.statusText + "；内容只进入草稿，发送需另行确认。"
        }
    }
    private func agentTarget(online:Bool = true) throws -> (AgentClient, Device) {
        guard !cloudMode,let agent,let device=devices.first(where:{$0.id==target}),!online || device.ready else {throw LinkError("请选择已连接网关中的在线电脑。")}
        return (agent,device)
    }
    private func loadAgentRecords(_ client:AgentClient) async throws {
        let version=agentGeneration,records=try await client.references();try Task.checkCancellation()
        guard version==agentGeneration else{throw CancellationError()}
        agentRecords=records.filter{$0.space==space && $0.device==target && $0.revision==devices.first(where:{$0.id==target})?.modelRevision}
    }
    public func discoverAgent(){run{
        let version=self.agentGeneration
        let (client,device)=try self.agentTarget()
        let capabilities=try await client.discover(space:self.space,device:device);try Task.checkCancellation()
        guard version==self.agentGeneration else{throw CancellationError()}
        self.agentCapabilities=capabilities
        let tools=try await client.discoverTools(space:self.space,device:device)
        try Task.checkCancellation();guard version==self.agentGeneration else{throw CancellationError()}
        self.agentToolEnabled=tools.enabled
        // 目录由用户明确选择；不按最近运行推定工作区或会话。
        self.agentWorkspace="";self.agentWrite=false
        try await self.loadAgentRecords(client);self.result="已读取电脑上的助手配置。"
    }}
    private func presentAgent(_ run:AgentRun){
        agentRunID=run.id;agentRun=run
        var events=Dictionary(uniqueKeysWithValues:agentEvents.map{($0.seq,$0)})
        for event in run.events{events[event.seq]=event}
        agentEvents=events.values.sorted{$0.seq<$1.seq}
        if run.expiresAt <= Int64(Date().timeIntervalSince1970){agentEvents=[]}
        result=run.stateText
    }
    public func submitAgent(){run{
        let version=self.agentGeneration
        let (client,device)=try self.agentTarget()
        guard let workspace=self.agentCapabilities?.workspaces.first(where:{$0.id==self.agentWorkspace}),!self.agentWrite || workspace.allowWrite else {throw LinkError("请选择允许的工作目录。")}
        let resume:AgentReference?
        if self.agentContinue{
            guard self.agentRun?.state=="succeeded",self.agentRun?.sessionId != nil,let record=self.agentRecords.first(where:{$0.id==self.agentRunID}) else{throw LinkError("请选择已完成的对话。")}
            resume=record
        }else{resume=nil}
        let selected=resume?.iotDevices ?? Array(self.agentSelectedDevices).sorted()
        guard selected.isEmpty || (self.agentToolEnabled && selected.allSatisfy({id in self.agentIoTDevices.contains{$0.id==id}})) else {throw LinkError("请选择当前网关中的设备。")}
        let run=try await client.submit(space:self.space,device:device,workspace:self.agentWorkspace,text:self.agentText,sandbox:self.agentWrite ? "workspace-write" : "read-only",resume:resume,iotDevices:selected)
        try Task.checkCancellation();guard version==self.agentGeneration else{throw CancellationError()}
        try await self.loadAgentRecords(client);self.presentAgent(run);self.agentText=""
    }}
    public func queryAgent(cancel:Bool = false){run{
        let version=self.agentGeneration
        let (client,device)=try self.agentTarget()
        guard let reference=self.agentRecords.first(where:{$0.id==self.agentRunID}) else{throw LinkError("请选择原任务。")}
        let after=cancel ? 0 : self.agentEvents.last?.seq ?? 0
        let run=try await client.query(reference,space:self.space,device:device,after:after,cancel:cancel)
        try Task.checkCancellation();guard version==self.agentGeneration else{throw CancellationError()};self.presentAgent(run)
        if let tools=self.agentIoT,!reference.iotDevices.isEmpty {
            do {if !cancel,run.state=="running"{_=try await tools.receive(reference,space:self.space,execution:device)}}
            catch{try await self.loadAgentTools(tools,reference:reference);throw error}
            try await self.loadAgentTools(tools,reference:reference)
        }
    }}
    public func restoreAgent(){run{
        let (client,_)=try self.agentTarget()
        try await self.loadAgentRecords(client);self.result="已恢复此电脑的任务引用，请选择原任务。"
    }}
    public func recoverAgent(){run{
        let version=self.agentGeneration
        let (client,_)=try self.agentTarget()
        let run=try await client.recover();try Task.checkCancellation();guard version==self.agentGeneration else{throw CancellationError()};try await self.loadAgentRecords(client)
        if let run,self.agentRecords.contains(where:{$0.id==run.id}){self.presentAgent(run)}else{self.result="原请求已核实，请重新读取助手配置或选择原任务。"}
    }}
    public var agentDeviceScope:[String] {agentContinue ? agentRecords.first{$0.id==agentRunID}?.iotDevices ?? [] : agentSelectedDevices.sorted()}
    public func agentPropertyName(_ record:AgentToolRecord)->String {
        guard record.call.isWrite else{return "设备状态"}
        let parts=record.call.path.split(separator:".").map(String.init)
        return gatewayModels[record.call.modelRevision]?.services.first{$0.id==parts.first}?.properties.first{$0.id==parts.last}?.displayName ?? record.call.path
    }
    private func loadAgentTools(_ tools:AgentIoTClient,reference:AgentReference) async throws {
        let version=agentGeneration
        try await tools.pruneExpired()
        let records=try await tools.records();try Task.checkCancellation()
        guard version==agentGeneration,agentRunID==reference.id else{throw CancellationError()}
        agentToolRecords=records.filter{$0.reference==reference}
    }
    public enum ToolAction {case confirm,reject,recover,report}
    public func performAgentTool(_ id:String,action:ToolAction){run{
        let version=self.agentGeneration,(_,device)=try self.agentTarget(online:action != .recover)
        guard let tools=self.agentIoT,let reference=self.agentRecords.first(where:{$0.id==self.agentRunID}) else{throw LinkError("请选择原任务。")}
        let record:AgentToolRecord
        do {
            switch action {
            case .confirm:record=try await tools.confirm(id,reference:reference,space:self.space,execution:device)
            case .reject:record=try await tools.reject(id,reference:reference,space:self.space,execution:device)
            case .recover:record=try await tools.recoverCommand(id,reference:reference,space:self.space,execution:device)
            case .report:record=try await tools.sendResult(id,reference:reference,space:self.space,execution:device)
            }
        }catch{try await self.loadAgentTools(tools,reference:reference);throw error}
        try Task.checkCancellation();guard version==self.agentGeneration else{throw CancellationError()}
        try await self.loadAgentTools(tools,reference:reference)
        self.result=record.needsRecovery ? "设备结果待核实，请查询原命令。" : record.delivered ? "设备操作结果已回传。" : "原设备命令已核实，请回传结果。"
    }}
    public func pollAgent(){
        guard !busy,!hasPending,!cloudMode,!agentToolRecords.contains(where:{$0.canConfirm}),let state=agentRun?.state,["awaiting_approval","approved","starting","running","cancelling"].contains(state) else{return}
        queryAgent()
    }
}
