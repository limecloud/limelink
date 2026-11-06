import Foundation
import LimeIoTKit

public struct AgentToolOutcome: Codable, Sendable { public let success: Bool; public let output: JSONValue }
public struct AgentToolRecord: Codable, Sendable, Identifiable {
    public let reference: AgentReference
    public let call: AgentToolCall
    public let runExpiresAt: Int64
    public var intent: CommandIntent?
    public var outcome: AgentToolOutcome?
    public var delivered: Bool
    public var commandID: String?
    public var commandStatus: String?
    public var replyIntent: CommandIntent?
    public var id: String {call.id}
    public var canConfirm: Bool {call.isWrite && intent == nil && outcome == nil && call.expiresAt>Int64(Date().timeIntervalSince1970)}
    public var needsRecovery: Bool {intent != nil && !["confirmed","failed","expired","rejected"].contains(commandStatus ?? "")}
    public var statusText: String {
        if let commandStatus{return ["confirmed":"设备已确认","unknown":"设备结果待核实","failed":"设备执行失败","expired":"设备命令已过期","rejected":"设备命令已拒绝","accepted":"设备命令已受理","dispatched":"设备命令已发送"][commandStatus] ?? "设备结果待核实"}
        if intent != nil{return "原设备命令待核实"}
        if let outcome {return outcome.success ? "已读取设备状态" : outcome.output == .object(["error":.string("user_rejected")]) ? "已拒绝操作" : "工具未完成"}
        return canConfirm ? "等待确认" : "提案已过期"
    }
}

/// 用户网关会话只留在客户端。设备命令与 Agent 回传分别保存，任何恢复都不重建设备 POST。
public actor AgentIoTClient {
    private let gateway: GatewayClient
    private let agent: AgentClient
    private let store: any SessionStore
    private var busy=false
    private var scope: String {gateway.origin+"#limelink.agent-iot"}
    public init(gateway: GatewayClient, agent: AgentClient, store: any SessionStore = SecureStore()) {self.gateway=gateway;self.agent=agent;self.store=store}

    public func records() async throws -> [AgentToolRecord] {
        guard let data=try await store.load(origin:scope) else{return []}
        let records=try JSONDecoder().decode([AgentToolRecord].self,from:data),references=try await agent.references()
        guard records.count<=128,Set(records.map(\.id)).count==records.count else {throw LinkError("invalid_agent_tool_records")}
        for record in records {
            guard record.reference.origin==gateway.origin,references.contains(record.reference),record.runExpiresAt>=record.call.expiresAt,!record.delivered || record.outcome != nil else {throw LinkError("invalid_agent_tool_records")}
            try AgentToolProtocol.validate(record.call,devices:record.reference.iotDevices)
            if let intent=record.intent {
                let fields=try AgentToolProtocol.object(record.call.arguments)
                guard record.call.isWrite,UUID(uuidString:intent.key) != nil,intent.input.deviceId==record.call.device,fields["model_revision"] == .string(intent.input.modelRevision),intent.input.operation.type=="property.set",intent.input.operation.path==record.call.path,intent.input.operation.value==record.call.value else {throw LinkError("agent_tool_intent_mismatch")}
            }
            if let outcome=record.outcome {
                try AgentToolProtocol.validateResult(record.call,success:outcome.success,output:outcome.output)
                if record.call.isWrite,outcome.success,record.intent == nil {throw LinkError("agent_tool_intent_missing")}
            }
        }
        return records
    }
    private func canDiscard(_ record: AgentToolRecord, now: Int64) -> Bool {
        guard record.runExpiresAt<=now else{return false}
        // 任何尚待核实的设备命令或回传都继续保留原意图。
        let deviceResolved=record.intent == nil || ["confirmed","failed","expired","rejected"].contains(record.commandStatus ?? "")
        let replyResolved=record.replyIntent == nil || record.delivered
        return deviceResolved && replyResolved
    }
    private func persist(_ records: [AgentToolRecord]) async throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let data=try encoder.encode(records)
        try await store.save(origin:scope,data:data)
        guard try await store.load(origin:scope)==data else {throw LinkError("agent_tool_record_not_durable")}
    }
    /// 运行保留期届满后回收已解决记录；未知结果不能因 TTL 被遗忘。
    @discardableResult public func pruneExpired() async throws -> Int {
        guard !busy else{throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        let previous=try await records(),now=Int64(Date().timeIntervalSince1970)
        let retained=previous.filter{!canDiscard($0,now:now)}
        if retained.count != previous.count{try await persist(retained)}
        return previous.count-retained.count
    }
    private func save(_ record: AgentToolRecord) async throws {
        let now=Int64(Date().timeIntervalSince1970)
        var records=try await records().filter{$0.id==record.id || !canDiscard($0,now:now)}
        if let index=records.firstIndex(where:{$0.id==record.id}) {
            let previous=records[index]
            guard previous.reference==record.reference,previous.call==record.call else {throw LinkError("agent_tool_record_conflict")}
            records[index]=record
        } else {guard records.count<128 else{throw LinkError("agent_tool_record_capacity")};records.append(record)}
        try await persist(records)
    }
    private func check(_ reference: AgentReference, space: String, execution: Device) async throws {
        guard reference.origin==gateway.origin,reference.space==space,reference.device==execution.id,reference.revision==execution.modelRevision,try await agent.references().contains(reference) else {throw LinkError("agent_target_changed")}
    }
    private func current(_ id: String, reference: AgentReference) async throws -> AgentToolRecord {
        guard let record=try await records().first(where:{$0.id==id}),record.reference==reference else {throw LinkError("agent_tool_record_missing")};return record
    }
    private func stillPending(_ record: AgentToolRecord, execution: Device) async throws {
        guard record.call.expiresAt>Int64(Date().timeIntervalSince1970) else {throw LinkError("agent_tool_call_expired")}
        let batch=try await agent.pendingTools(record.reference,space:record.reference.space,device:execution)
        guard batch.calls.contains(record.call) else {throw LinkError("agent_tool_proposal_changed")}
    }
    private func target(_ record: AgentToolRecord, snapshot: Snapshot) throws -> (Device,Model) {
        guard snapshot.space==record.reference.space,let device=snapshot.devices.first(where:{$0.id==record.call.device}),let model=snapshot.models[device.modelRevision],!model.modelId.hasPrefix("urn:limelink:model:desktop:") else {throw LinkError("agent_tool_device_unavailable")}
        return(device,model)
    }
    private func report(_ original: AgentToolRecord, execution: Device) async throws -> AgentToolRecord {
        var record=original
        guard !record.delivered,let outcome=record.outcome else{return record}
        if let intent=record.replyIntent {
            try await agent.resolveToolResult(record.reference,space:record.reference.space,device:execution,call:record.call,outcome:outcome,intent:intent)
        } else {
            let reference=record.reference,id=record.id
            try await agent.completeTool(reference,space:reference.space,device:execution,call:record.call,success:outcome.success,output:outcome.output,onPrepared:{pending in try await self.saveReply(id,reference:reference,pending:pending)})
        }
        record=try await current(record.id,reference:record.reference)
        record.delivered=true;try await save(record);return record
    }
    private func saveReply(_ id: String, reference: AgentReference, pending: PendingAction) async throws {
        var record=try await current(id,reference:reference)
        guard record.replyIntent == nil,pending.origin==reference.origin,pending.space==reference.space else{throw LinkError("agent_tool_reply_intent_mismatch")}
        record.replyIntent=pending.intent;try await save(record)
    }
    private func outcome(_ original: AgentToolRecord, success: Bool, output: JSONValue, execution: Device) async throws -> AgentToolRecord {
        var record=original
        try AgentToolProtocol.validateResult(record.call,success:success,output:output)
        record.outcome=AgentToolOutcome(success:success,output:output);try await save(record)
        return try await report(record,execution:execution)
    }
    private func read(_ record: AgentToolRecord, execution: Device) async throws -> AgentToolRecord {
        guard record.call.expiresAt>Int64(Date().timeIntervalSince1970) else{throw LinkError("agent_tool_call_expired")}
        let snapshot=try await gateway.snapshot(space:record.reference.space)
        let selected:(Device,Model)
        do{selected=try target(record,snapshot:snapshot)}catch let error as LinkError where error.code=="agent_tool_device_unavailable" {
            return try await outcome(record,success:false,output:.object(["error":.string(error.code)]),execution:execution)
        }
        let(device,model)=selected
        var properties=[JSONValue]()
        for service in model.services {
            for property in service.properties where ["boolean","integer","number","string"].contains(property.schema.type) && property.access.contains(where:{["read","write"].contains($0)}) {
                let path=service.id+"."+property.id,observation=property.access.contains("read") ? device.reported[path] : nil
                let schema=try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(property.schema))
                properties.append(.object(["path":.string(path),"schema":schema,"writable":.bool(property.access.contains("write")),"value":observation?.value ?? .null,"observed_at":observation.map{.string($0.observedAt)} ?? .null,"quality":.string(observation?.quality ?? "unknown")]))
            }
        }
        let output:JSONValue = .object(["device_id":.string(device.id),"model_revision":.string(device.modelRevision),"ready":.bool(device.ready),"properties":.array(properties)])
        guard properties.count<=8,output.jsonText.utf8.count<=1600 else {return try await outcome(record,success:false,output:.object(["error":.string("agent_tool_response_budget")]),execution:execution)}
        do{try AgentToolProtocol.validateResult(record.call,success:true,output:output)}catch{
            return try await outcome(record,success:false,output:.object(["error":.string("agent_tool_invalid_observation")]),execution:execution)
        }
        return try await outcome(record,success:true,output:output,execution:execution)
    }
    /// 读取在用户已选择的范围内自动处理；写入只保存并返回提案。
    public func receive(_ reference: AgentReference, space: String, execution: Device) async throws -> AgentToolRecord? {
        guard !busy else{throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        try await check(reference,space:space,execution:execution)
        let batch=try await agent.pendingTools(reference,space:space,device:execution)
        guard let call=batch.calls.first else{return nil}
        if let previous=try await records().first(where:{$0.id==call.id}) {
            guard previous.reference==reference,previous.call==call else{throw LinkError("agent_tool_record_conflict")}
            if previous.outcome != nil{return try await report(previous,execution:execution)}
            if previous.call.isWrite{return previous}
            return try await read(previous,execution:execution)
        }
        let record=AgentToolRecord(reference:reference,call:call,runExpiresAt:batch.expiresAt,intent:nil,outcome:nil,delivered:false,commandID:nil,commandStatus:nil,replyIntent:nil)
        try await save(record)
        return call.isWrite ? record : try await read(record,execution:execution)
    }
    private func validValue(_ value: JSONValue, schema: ValueSchema) -> Bool {
        guard AgentToolProtocol.scalar(value),schema.enumValues?.contains(value) ?? true else{return false}
        switch (schema.type,value) {
        case ("boolean",.bool):return true
        case ("string",.string(let text)):return text.unicodeScalars.count >= (schema.minLength ?? 0) && text.unicodeScalars.count <= (schema.maxLength ?? Int.max)
        case ("integer",.integer(let value)),("number",.integer(let value)):return Double(value)>=(schema.minimum ?? -Double.greatestFiniteMagnitude) && Double(value)<=(schema.maximum ?? Double.greatestFiniteMagnitude)
        case ("number",.number(let value)):return value.isFinite && value>=(schema.minimum ?? -Double.greatestFiniteMagnitude) && value<=(schema.maximum ?? Double.greatestFiniteMagnitude)
        default:return false
        }
    }
    /// 只由用户明确确认触发。意图保存后即进入不确定区，恢复绝不再次 POST。
    public func confirm(_ id: String, reference: AgentReference, space: String, execution: Device) async throws -> AgentToolRecord {
        guard !busy else{throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        try await check(reference,space:space,execution:execution)
        var record=try await current(id,reference:reference)
        guard record.canConfirm else {throw LinkError("resolve_original_iot_command_first")}
        try await stillPending(record,execution:execution)
        let snapshot=try await gateway.snapshot(space:space), (device,model)=try target(record,snapshot:snapshot)
        let fields=try AgentToolProtocol.object(record.call.arguments)
        guard device.ready,fields["model_revision"] == .string(device.modelRevision) else {throw LinkError("agent_tool_model_or_availability_changed")}
        let properties=model.services.flatMap{service in service.properties.filter{service.id+"."+$0.id==record.call.path}}
        guard properties.count==1,let property=properties.first,property.access.contains("write"),validValue(record.call.value,schema:property.schema) else {throw LinkError("agent_tool_property_not_allowed")}
        try Task.checkCancellation()
        guard record.canConfirm else{throw LinkError("agent_tool_call_expired")}
        let intent=CommandIntent(device:device,path:record.call.path,value:record.call.value)
        record.intent=intent;try await save(record)
        try Task.checkCancellation()
        guard record.call.expiresAt>Int64(Date().timeIntervalSince1970) else{throw LinkError("agent_tool_call_expired")}
        return try await finish(record,command:gateway.create(space:space,intent:intent),execution:execution)
    }
    private func finish(_ original: AgentToolRecord, command initial: Command, execution: Device) async throws -> AgentToolRecord {
        var record=original,command=initial
        guard let intent=record.intent else{throw LinkError("agent_tool_intent_missing")}
        record.commandID=command.id;record.commandStatus=command.status;try await save(record)
        for _ in 0..<20 where ["accepted","dispatched"].contains(command.status) {
            try await Task.sleep(for:.milliseconds(200))
            command=try await gateway.resolve(space:record.reference.space,intent:intent)
        }
        record.commandID=command.id;record.commandStatus=command.status;try await save(record)
        guard ["confirmed","failed","expired","rejected","unknown"].contains(command.status) else {throw LinkError("resolve_original_iot_command_first")}
        // 已回传的未知结果保持原文；后续查询只更新本机原命令状态。
        if record.outcome != nil{return record}
        var fields=try AgentToolProtocol.object(record.call.arguments)
        fields["command_id"] = .string(command.id);fields["status"] = .string(command.status)
        if case .object(let evidence)=command.evidence,case .string(let observed)=evidence["observed_at"],AgentToolProtocol.date(observed) != nil {fields["observed_at"] = .string(observed)}else{fields["observed_at"] = .null}
        return try await outcome(record,success:command.status=="confirmed",output:.object(fields),execution:execution)
    }
    public func recoverCommand(_ id: String, reference: AgentReference, space: String, execution: Device) async throws -> AgentToolRecord {
        guard !busy else{throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        try await check(reference,space:space,execution:execution)
        let record=try await current(id,reference:reference)
        guard let intent=record.intent else{throw LinkError("agent_tool_intent_missing")}
        // 404、离线与超时均保留原意图。
        return try await finish(record,command:gateway.resolve(space:space,intent:intent),execution:execution)
    }
    public func sendResult(_ id: String, reference: AgentReference, space: String, execution: Device) async throws -> AgentToolRecord {
        guard !busy else{throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        try await check(reference,space:space,execution:execution)
        return try await report(current(id,reference:reference),execution:execution)
    }
    public func reject(_ id: String, reference: AgentReference, space: String, execution: Device) async throws -> AgentToolRecord {
        guard !busy else{throw LinkError("request_in_progress")};busy=true;defer{busy=false}
        try await check(reference,space:space,execution:execution)
        let record=try await current(id,reference:reference)
        guard record.canConfirm else{throw LinkError("resolve_original_iot_command_first")}
        try await stillPending(record,execution:execution)
        return try await outcome(record,success:false,output:.object(["error":.string("user_rejected")]),execution:execution)
    }
}
