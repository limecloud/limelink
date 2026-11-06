import Foundation
import LimeIoTKit

public struct AgentWorkspace: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let allowWrite: Bool
}
public struct AgentCapabilities: Decodable, Sendable {
    public let adapter: String
    public let configured: Bool
    public let authentication: String
    public let localApprovalRequired: Bool
    public let workspaces: [AgentWorkspace]
}
public struct AgentReference: Codable, Sendable, Identifiable, Equatable {
    public let origin: String
    public let space: String
    public let device: String
    public let revision: String
    public let id: String
    public let iotDevices: [String]
    private enum CodingKeys: String, CodingKey { case origin, space, device, revision, id, iotDevices }
    init(origin: String, space: String, device: String, revision: String, id: String, iotDevices: [String] = []) {
        self.origin=origin;self.space=space;self.device=device;self.revision=revision;self.id=id;self.iotDevices=iotDevices
    }
    public init(from decoder: any Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        origin=try c.decode(String.self,forKey:.origin);space=try c.decode(String.self,forKey:.space);device=try c.decode(String.self,forKey:.device);revision=try c.decode(String.self,forKey:.revision);id=try c.decode(String.self,forKey:.id)
        iotDevices=try c.decodeIfPresent([String].self,forKey:.iotDevices) ?? []
    }
}
public struct AgentEvent: Decodable, Sendable, Identifiable, Equatable {
    public let seq: Int
    public let kind: String
    public let text: String
    public var id: Int { seq }
}
public struct AgentRun: Decodable, Sendable {
    public let id: String
    public let state: String
    public let workspaceId: String
    public let sandbox: String
    public let sessionId: String?
    public let error: String?
    public let expiresAt: Int64
    public let events: [AgentEvent]
    public let cursor: Int
    public var canCancel: Bool { ["awaiting_approval", "approved", "starting", "running"].contains(state) }
    public var stateText: String { Self.stateText(state) }
    public static func stateText(_ state: String) -> String {
        ["awaiting_approval":"等待电脑批准", "approved":"已批准，等待执行", "starting":"正在启动", "running":"正在执行", "cancelling":"正在中断", "succeeded":"已完成", "failed":"执行失败", "cancelled":"已停止", "unknown":"结果待核实", "rejected":"已拒绝", "expired":"批准已过期"][state] ?? "结果待核实"
    }
}

/// Agent 运行引用与平台命令各自持久化。丢失响应后先核对原平台命令，不再次提交任务。
public actor AgentClient {
    private let link: LinkClient
    private let store: any SessionStore
    private var busy = false
    private var scope: String { link.gateway.origin + "#limelink.agent-runs" }
    public init(link: LinkClient, store: any SessionStore = SecureStore()) { self.link = link; self.store = store }

    public func references() async throws -> [AgentReference] {
        guard let data = try await store.load(origin: scope) else { return [] }
        let records = try JSONDecoder().decode([AgentReference].self, from: data)
        guard records.count <= 128, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ $0.origin == link.gateway.origin && UUID(uuidString: $0.id) != nil && AgentToolProtocol.validGrant($0.iotDevices) && !$0.iotDevices.contains($0.device) }) else { throw LinkError("invalid_agent_records") }
        return records
    }
    private func save(_ record: AgentReference) async throws {
        var records = try await references()
        if let old = records.first(where: { $0.id == record.id }) {
            guard old == record else { throw LinkError("agent_reference_conflict") }; return
        }
        guard records.count < 128 else { throw LinkError("agent_record_capacity") }
        records.append(record)
        let data = try JSONEncoder().encode(records)
        try await store.save(origin: scope, data: data)
        guard try await store.load(origin: scope) == data else { throw LinkError("agent_reference_not_durable") }
    }
    private static func decode<T: Decodable>(_ value: JSONValue) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(value.jsonText.utf8))
    }
    private func finish(_ initial: Command, original: PendingAction? = nil) async throws -> JSONValue {
        var command = initial
        for _ in 0..<20 where ["accepted", "dispatched"].contains(command.status) {
            try await Task.sleep(for: .milliseconds(200))
            if let original{command=try await link.gateway.resolve(space:original.space,intent:original.intent)}else{command=try await link.resolve()}
        }
        guard command.request.operation.path == "agent.exchange" else { throw LinkError("agent_original_path_mismatch") }
        if ["failed", "expired", "rejected"].contains(command.status) {
            try await link.acknowledgeResolved(); throw LinkError("agent_command_" + command.status)
        }
        guard let response = try LinkClient.response(command), case .object(let object) = response, case .bool(let ok) = object["ok"] else { throw LinkError("resolve_original_agent_request_first") }
        if !ok {
            guard Set(object.keys) == Set(["ok", "error"]), case .string(let error) = object["error"], error.range(of: "^[a-z0-9_]{1,96}$", options: .regularExpression) != nil else { throw LinkError("invalid_agent_response") }
            try await link.acknowledgeResolved(); throw LinkError(error)
        }
        guard Set(object.keys) == Set(["ok", "value"]), let value = object["value"] else { throw LinkError("invalid_agent_response") }
        // 调用方校验并保存引用后才归档；解码失败仍保留原请求。
        return value
    }
    private func request(space: String, device: Device, kind: String, payload: JSONValue, onPrepared:(@Sendable (PendingAction) async throws -> Void)? = nil) async throws -> JSONValue {
        try await finish(link.perform(space: space, device: device, kind: kind, payload: payload, path: "agent.exchange",onPrepared:onPrepared))
    }
    public static func decodeCapabilities(_ value: JSONValue) throws -> AgentCapabilities {
        guard case .object(let fields) = value, Set(fields.keys) == Set(["adapter", "configured", "authentication", "local_approval_required", "workspaces"]) else { throw LinkError("invalid_agent_capabilities") }
        guard case .array(let workspaces) = fields["workspaces"], workspaces.allSatisfy({ if case .object(let workspace) = $0 { return Set(workspace.keys) == Set(["id", "name", "allow_write"]) }; return false }) else { throw LinkError("invalid_agent_capabilities") }
        let result: AgentCapabilities = try Self.decode(value)
        guard result.adapter == "codex-app-server", result.configured, result.localApprovalRequired,
              result.authentication == "managed_by_codex", (1...8).contains(result.workspaces.count),
              Set(result.workspaces.map(\.id)).count == result.workspaces.count,
              result.workspaces.allSatisfy({ $0.id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil && !$0.name.isEmpty && $0.name.utf8.count <= 64 }) else { throw LinkError("invalid_agent_capabilities") }
        return result
    }
    public static func decodeRun(_ value: JSONValue, id: String, after: Int) throws -> AgentRun {
        guard case .object(let fields) = value,
              Set(fields.keys).isSuperset(of: Set(["id", "state", "workspace_id", "sandbox", "session_id", "error", "expires_at", "events", "cursor"])),
              Set(fields.keys).isSubset(of: Set(["id", "state", "workspace_id", "sandbox", "session_id", "error", "expires_at", "events", "cursor", "content_expired"])) else { throw LinkError("invalid_agent_response") }
        if let expired = fields["content_expired"], case .bool = expired {} else if fields["content_expired"] != nil { throw LinkError("invalid_agent_response") }
        guard case .array(let events) = fields["events"], events.allSatisfy({ if case .object(let event) = $0 { return Set(event.keys) == Set(["seq", "kind", "text"]) }; return false }), (0...256).contains(after) else { throw LinkError("invalid_agent_response") }
        let result: AgentRun = try Self.decode(value)
        let states = ["awaiting_approval", "approved", "starting", "running", "cancelling", "succeeded", "failed", "cancelled", "unknown", "rejected", "expired"]
        guard result.id == id, states.contains(result.state), ["read-only", "workspace-write"].contains(result.sandbox),
              result.events.count <= 4, (after...256).contains(result.cursor),
              result.cursor == (result.events.last?.seq ?? after),
              result.events.allSatisfy({ $0.seq > after && $0.seq <= 256 && ["message", "tool_started", "tool_completed", "working"].contains($0.kind) && $0.text.utf8.count <= 400 }),
              zip(result.events, result.events.dropFirst()).allSatisfy({ $0.seq < $1.seq }) else { throw LinkError("invalid_agent_response") }
        return result
    }
    public func discover(space: String, device: Device) async throws -> AgentCapabilities {
        guard !busy else { throw LinkError("request_in_progress") }; busy = true; defer { busy = false }
        let result = try Self.decodeCapabilities(await request(space: space, device: device, kind: "agent.capabilities", payload: .object([:])))
        try await link.acknowledgeResolved(); return result
    }
    public func submit(space: String, device: Device, workspace: String, text: String, sandbox: String, resume: AgentReference? = nil, iotDevices: [String] = []) async throws -> AgentRun {
        guard !busy else { throw LinkError("request_in_progress") }; busy = true; defer { busy = false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2048,
              ["read-only", "workspace-write"].contains(sandbox) else { throw LinkError("invalid_agent_input") }
        let selected=iotDevices.sorted()
        guard AgentToolProtocol.validGrant(selected),!selected.contains(device.id) else {throw LinkError("invalid_agent_devices")}
        if let resume { try check(resume, space: space, device: device);guard resume.iotDevices==selected else {throw LinkError("agent_tool_scope_changed")} }
        guard try await link.pending() == nil else { throw LinkError("resolve_original_request_first") }
        let reference = AgentReference(origin: link.gateway.origin, space: space, device: device.id, revision: device.modelRevision, id: UUID().uuidString.lowercased(),iotDevices:selected)
        try await save(reference)
        var payload: [String: JSONValue] = ["id": .string(reference.id), "workspace_id": .string(workspace), "text": .string(text), "sandbox": .string(sandbox)]
        if let resume { payload["resume_from"] = .string(resume.id) }
        if !selected.isEmpty {payload["iot_devices"] = .array(selected.map(JSONValue.string))}
        let result = try Self.decodeRun(await request(space: space, device: device, kind: "agent.submit", payload: .object(payload)), id: reference.id, after: 0)
        try await link.acknowledgeResolved(); return result
    }
    private func check(_ reference: AgentReference, space: String, device: Device) throws {
        guard reference.origin == link.gateway.origin, reference.space == space, reference.device == device.id, reference.revision == device.modelRevision else { throw LinkError("agent_target_changed") }
    }
    private func checkSaved(_ reference: AgentReference, space: String, device: Device) async throws {
        try check(reference,space:space,device:device)
        guard try await references().contains(reference) else {throw LinkError("agent_reference_missing")}
    }
    public func discoverTools(space: String, device: Device) async throws -> AgentToolCapabilities {
        guard !busy else {throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        let result=try AgentToolProtocol.capabilities(await request(space:space,device:device,kind:"agent.tool_capabilities",payload:.object([:])))
        try await link.acknowledgeResolved();return result
    }
    public func pendingTools(_ reference: AgentReference, space: String, device: Device) async throws -> AgentToolBatch {
        guard !busy else {throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        try await checkSaved(reference,space:space,device:device)
        let result=try AgentToolProtocol.pending(await request(space:space,device:device,kind:"agent.tool_pending",payload:.object(["id":.string(reference.id)])),reference:reference)
        try await link.acknowledgeResolved();return result
    }
    public func completeTool(_ reference: AgentReference, space: String, device: Device, call: AgentToolCall, success: Bool, output: JSONValue, onPrepared:(@Sendable (PendingAction) async throws -> Void)? = nil) async throws {
        guard !busy else {throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        try await checkSaved(reference,space:space,device:device)
        try AgentToolProtocol.validate(call,devices:reference.iotDevices)
        try AgentToolProtocol.validateResult(call,success:success,output:output)
        let result=try await request(space:space,device:device,kind:"agent.tool_result",payload:.object(["id":.string(reference.id),"call_id":.string(call.id),"success":.bool(success),"output":output]),onPrepared:onPrepared)
        try AgentToolProtocol.completion(result,id:reference.id,call:call.id)
        try await link.acknowledgeResolved()
    }
    public func resolveToolResult(_ reference: AgentReference, space: String, device: Device, call: AgentToolCall, outcome: AgentToolOutcome, intent: CommandIntent) async throws {
        guard !busy else{throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        try await checkSaved(reference,space:space,device:device)
        let exchange=try AgentToolProtocol.object(intent.input.operation.value)
        let payload=try JSONDecoder().decode(JSONValue.self,from:Data(try AgentToolProtocol.string(exchange,"payload").utf8))
        guard intent.input.deviceId==device.id,intent.input.modelRevision==device.modelRevision,intent.input.operation.path=="agent.exchange",intent.input.operation.type=="action.invoke",exchange["kind"] == .string("agent.tool_result"),payload == .object(["id":.string(reference.id),"call_id":.string(call.id),"success":.bool(outcome.success),"output":outcome.output]) else{throw LinkError("agent_tool_reply_intent_mismatch")}
        if let pending=try await link.pending(),pending.intent.key != intent.key{throw LinkError("resolve_original_request_first")}
        let original=PendingAction(origin:link.gateway.origin,space:space,intent:intent)
        let result=try await finish(link.gateway.resolve(space:space,intent:intent),original:original)
        try AgentToolProtocol.completion(result,id:reference.id,call:call.id)
        try await link.acknowledgeResolved()
    }
    public func query(_ reference: AgentReference, space: String, device: Device, after: Int = 0, cancel: Bool = false) async throws -> AgentRun {
        guard !busy else { throw LinkError("request_in_progress") }; busy = true; defer { busy = false }
        try check(reference, space: space, device: device)
        guard (0...256).contains(after), !cancel || after == 0 else { throw LinkError("invalid_agent_cursor") }
        let payload: JSONValue = cancel ? .object(["id": .string(reference.id)]) : .object(["id": .string(reference.id), "after": .integer(after)])
        let result = try Self.decodeRun(await request(space: space, device: device, kind: cancel ? "agent.cancel" : "agent.status", payload: payload), id: reference.id, after: after)
        try await link.acknowledgeResolved(); return result
    }
    /// 恢复的是已持久化平台命令，既不选择“最近会话”，也不构造第二次提交。
    public func recover() async throws -> AgentRun? {
        guard !busy else { throw LinkError("request_in_progress") }; busy = true; defer { busy = false }
        guard let original = try await link.pending(), original.intent.input.operation.path == "agent.exchange",
              case .object(let exchange) = original.intent.input.operation.value, case .string(let kind) = exchange["kind"],
              case .string(let text) = exchange["payload"], let data = text.data(using: .utf8),
              case .object(let payload) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw LinkError("no_original_agent_request") }
        let value = try await finish(link.resolve())
        if kind == "agent.capabilities" { _ = try Self.decodeCapabilities(value); try await link.acknowledgeResolved(); return nil }
        if kind == "agent.tool_capabilities" {_ = try AgentToolProtocol.capabilities(value);try await link.acknowledgeResolved();return nil}
        guard ["agent.submit", "agent.status", "agent.cancel","agent.tool_pending","agent.tool_result"].contains(kind), case .string(let id) = payload["id"],
              let reference = try await references().first(where: { $0.id == id }),
              reference.space == original.space, reference.device == original.intent.input.deviceId,
              reference.revision == original.intent.input.modelRevision else { throw LinkError("agent_reference_missing") }
        if kind == "agent.tool_pending" {_ = try AgentToolProtocol.pending(value,reference:reference);try await link.acknowledgeResolved();return nil}
        if kind == "agent.tool_result" {
            guard case .string(let call)=payload["call_id"] else {throw LinkError("invalid_agent_tool_result")}
            try AgentToolProtocol.completion(value,id:id,call:call);try await link.acknowledgeResolved();return nil
        }
        let after: Int; if case .integer(let cursor) = payload["after"] { after = cursor } else { after = 0 }
        let result = try Self.decodeRun(value, id: id, after: after)
        try await link.acknowledgeResolved(); return result
    }
}
