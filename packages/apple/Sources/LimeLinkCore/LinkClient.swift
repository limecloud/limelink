import Foundation
import LimeIoTKit

public struct PendingAction: Codable, Sendable {
    public let origin: String
    public let space: String
    public let intent: CommandIntent
}

public actor LinkClient {
    public nonisolated let gateway: GatewayClient
    private let store: any SessionStore
    private var busy=false
    private var selectedSpace: String?
    private var scope: String { gateway.origin + "#limelink.pending" }
    public init(endpoint:String,store:any SessionStore = SecureStore(),transport:any HTTPTransport = URLSessionTransport(),development:Bool = false) throws {
        self.store=store
        gateway=try GatewayClient(endpoint:endpoint,transport:transport,store:store,allowLoopbackHTTP:development)
    }
    public func login(token:String) async throws { try await gateway.login(token:token) }
    public func restore() async throws { try await gateway.restore() }
    public func spaces() async throws -> [Space] { try await gateway.spaces() }
    public func snapshot(space:String) async throws -> Snapshot {
        let snapshot=try await gateway.snapshot(space:space)
        selectedSpace=space
        return snapshot
    }
    public func pending() async throws -> PendingAction? {
        guard let data=try await store.load(origin:scope) else { return nil }
        let pending=try JSONDecoder().decode(PendingAction.self,from:data)
        guard pending.origin==gateway.origin else { throw LinkError("pending_origin_mismatch") }
        return pending
    }
    private func identity(space:String,device:String) async throws -> LinkIdentity {
        let key=gateway.origin + "#limelink.identity:" + space + ":" + device
        if let data=try await store.load(origin:key) { return try JSONDecoder().decode(LinkIdentity.self,from:data) }
        let identity=LinkIdentity(),data=try JSONEncoder().encode(identity)
        try await store.save(origin:key,data:data)
        guard try await store.load(origin:key)==data else { throw LinkError("identity_not_durable") }
        return identity
    }
    public func fingerprint(space:String,device:String) async throws -> String { try await identity(space:space,device:device).fingerprint }
    public func perform(space:String,device:Device,kind:String,payload:JSONValue) async throws -> Command {
        guard !busy else { throw LinkError("request_in_progress") };busy=true;defer{busy=false}
        guard selectedSpace==space,device.ready else { throw LinkError("refresh_target_required") }
        guard try await pending()==nil else { throw LinkError("resolve_original_request_first") }
        let snapshot=try await gateway.snapshot(space:space)
        guard let current=snapshot.devices.first(where:{$0.id==device.id}),current.ready,current.modelRevision==device.modelRevision,
              snapshot.models[current.modelRevision]?.modelId=="urn:limelink:model:desktop:1" else { throw LinkError("target_capability_changed") }
        let identity=try await identity(space:space,device:device.id)
        let input=try identity.exchange(space:space,device:device.id,revision:device.modelRevision,kind:kind,payload:payload.jsonText)
        let intent=CommandIntent(device:current,path:"link.exchange",value:input,type:"action.invoke")
        let pending=PendingAction(origin:gateway.origin,space:space,intent:intent)
        let data=try JSONEncoder().encode(pending)
        try await store.save(origin:scope,data:data)
        guard try await store.load(origin:scope)==data else { throw LinkError("intent_not_durable") }
        // 网络失败后保留原意图；下次只允许查询，不能重建另一个 POST。
        return try await gateway.create(space:space,intent:intent)
    }
    public func resolve() async throws -> Command {
        guard !busy else { throw LinkError("request_in_progress") };busy=true;defer{busy=false}
        guard let pending=try await pending() else { throw LinkError("no_pending_request") }
        return try await gateway.resolve(space:pending.space,intent:pending.intent)
    }
    public func acknowledgeResolved() async throws {
        guard let pending=try await pending() else { return }
        let result=try await gateway.resolve(space:pending.space,intent:pending.intent)
        guard ["confirmed","failed","expired","rejected"].contains(result.status) else { throw LinkError("original_request_unresolved") }
        try await store.save(origin:scope,data:nil)
    }
    public func logout() async throws {
        guard !busy else { throw LinkError("request_in_progress") }
        try await gateway.logout();selectedSpace=nil
        // 退出登录保留未核实任务及配对私钥，重新登录后查询原请求。
    }
    public static func response(_ command:Command) throws -> JSONValue? {
        guard command.status=="confirmed",case .object(let evidence)=command.evidence,case .object(let output)=evidence["output"],case .string(let text)=output["response"] else { return nil }
        return try JSONDecoder().decode(JSONValue.self,from:Data(text.utf8))
    }
}
