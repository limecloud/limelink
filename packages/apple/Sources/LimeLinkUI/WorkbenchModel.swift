import SwiftUI
import Foundation
import CryptoKit
import LimeLinkCore
import LimeIoTKit
#if os(iOS)
import UIKit
#endif

@MainActor public final class WorkbenchModel: ObservableObject {
    @Published public var endpoint = ""
    @Published public var token = ""
    @Published public var space = ""
    @Published public var spaces: [String] = []
    @Published public var devices: [Device] = []
    @Published public var target = ""
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
    private var client: LinkClient?
    private let secure = SecureStore()
    private var ai: TextGenerationClient?
    private var aiKey: String?
    public init() {
        endpoint=ProcessInfo.processInfo.environment["LIMELINK_ENDPOINT"] ?? UserDefaults.standard.string(forKey:"limelink.endpoint") ?? ""
        #if os(iOS)
        name=UIDevice.current.name
        #else
        name=Host.current().localizedName ?? "我的客户端"
        #endif
    }
    public func run(_ work:@escaping @MainActor () async throws -> Void) {
        guard !busy else { return };busy=true
        Task { defer{busy=false};do{try await work()}catch{result=(error as? GatewayError)?.message ?? error.localizedDescription} }
    }
    public func connect() {
        run {
            let client=try LinkClient(endpoint:self.endpoint,store:self.secure,development:ProcessInfo.processInfo.environment["LIMELINK_DEVELOPMENT"]=="1")
            if self.token.isEmpty {try await client.restore()}else{try await client.login(token:self.token)}
            self.token="";self.client=client
            self.ai=TextGenerationClient(gateway:client.gateway,store:self.secure)
            self.spaces=try await client.spaces().map(\.spaceId)
            self.devices=[];self.target="";self.fingerprint=""
            self.hasPending=try await client.pending() != nil
            UserDefaults.standard.set(self.endpoint,forKey:"limelink.endpoint")
            self.result="已连接，请明确选择空间并刷新电脑列表。"
        }
    }
    public func refresh() {
        run {
            guard let client=self.client,!self.space.isEmpty else{throw LinkError("select_space_first")}
            let snapshot=try await client.snapshot(space:self.space)
            self.devices=snapshot.devices.filter{snapshot.models[$0.modelRevision]?.modelId=="urn:limelink:model:desktop:1"}
            self.result="发现 \(self.devices.count) 个 LimeLink 终端；离线端不可提交。"
        }
    }
    public func selectTarget() {
        run {guard let client=self.client,!self.target.isEmpty else{return};self.fingerprint=try await client.fingerprint(space:self.space,device:self.target)}
    }
    public func action(_ kind:String) {
        run {
            guard let client=self.client,let device=self.devices.first(where:{$0.id==self.target}) else{throw LinkError("select_target_first")}
            let payload:JSONValue
            switch kind {
            case "pair":payload = .object(["name":.string(self.name)])
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
            var command=try await client.perform(space:self.space,device:device,kind:kind,payload:payload)
            for _ in 0..<20 where ["accepted","dispatched"].contains(command.status) {
                try await Task.sleep(for:.milliseconds(200));command=try await client.resolve()
            }
            try self.show(command)
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
    public func resolve() {run{guard let client=self.client else{return};try self.show(await client.resolve())}}
    public func finish() {run{guard let client=self.client else{return};try await client.acknowledgeResolved();self.hasPending=false;self.result="原结果已核实，可以发起下一项操作。"}}
    public func logout() {run{try await self.client?.logout();self.client=nil;self.ai=nil;self.devices=[];self.spaces=[];self.fingerprint="";self.result="已退出。未核实记录和配对身份保留在系统安全存储。"}}
    public func generateDraft(resolve:Bool = false) {
        run {
            guard let ai=self.ai,!self.space.isEmpty else{throw LinkError("connect_first")}
            let capability=try await ai.capabilities(space:self.space)
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
            self.aiKey=record.id
            if let draft=record.text{self.text=draft}
            self.result=record.statusText + "；内容只进入草稿，发送需另行确认。"
        }
    }
}
