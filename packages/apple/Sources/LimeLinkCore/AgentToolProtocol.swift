import Foundation
import LimeIoTKit

public struct AgentToolCapabilities: Sendable { public let enabled: Bool }
public struct AgentToolCall: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let tool: String
    public let arguments: JSONValue
    public let expiresAt: Int64
    public var isWrite: Bool { tool == "limeiot_command" }
    public var device: String { (try? AgentToolProtocol.object(arguments)["device_id"]?.text) ?? "" }
    public var path: String { (try? AgentToolProtocol.object(arguments)["path"]?.text) ?? "" }
    public var modelRevision: String { (try? AgentToolProtocol.object(arguments)["model_revision"]?.text) ?? "" }
    public var value: JSONValue { (try? AgentToolProtocol.object(arguments)["value"]) ?? .null }
}
public struct AgentToolBatch: Sendable { public let id: String; public let calls: [AgentToolCall]; public let expiresAt: Int64 }

/// 只接受与原任务范围一致的有界数据；模型输出不授予设备权限。
public enum AgentToolProtocol {
    static func object(_ value: JSONValue) throws -> [String:JSONValue] {
        guard case .object(let object)=value else {throw LinkError("invalid_agent_tool_response")};return object
    }
    static func string(_ object: [String:JSONValue], _ key: String) throws -> String {
        guard case .string(let value)=object[key] else {throw LinkError("invalid_agent_tool_response")};return value
    }
    static func identifier(_ value: String) -> Bool {value.range(of:"^[A-Za-z0-9_.:-]{1,128}\\z",options:.regularExpression) != nil}
    static func revision(_ value: String) -> Bool {value.range(of:"^sha256:[a-f0-9]{64}\\z",options:.regularExpression) != nil}
    static func path(_ value: String) -> Bool {value.range(of:"^[A-Za-z0-9_]{1,64}\\.[A-Za-z0-9_]{1,64}\\z",options:.regularExpression) != nil}
    static func scalar(_ value: JSONValue) -> Bool {
        guard value.jsonText.utf8.count<=512 else{return false}
        switch value {case .bool,.integer,.string:return true;case .number(let number):return number.isFinite;default:return false}
    }
    static func date(_ value: String) -> Date? {
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        if let result=formatter.date(from:value){return result};formatter.formatOptions=[.withInternetDateTime];return formatter.date(from:value)
    }
    private static func timestamp(_ value: JSONValue) -> Bool {
        if value == .null{return true};if case .string(let text)=value{return date(text) != nil};return false
    }
    private static func numeric(_ value: JSONValue) -> Bool {switch value {case .integer:return true;case .number(let number):return number.isFinite;default:return false}}
    private static func validSchema(_ fields: [String:JSONValue]) -> Bool {
        guard Set(fields.keys).isSubset(of:Set(["type","minimum","maximum","minLength","maxLength","enum"])),case .string(let type)=fields["type"],["boolean","integer","number","string"].contains(type) else{return false}
        for key in ["minimum","maximum"] {if let value=fields[key],!numeric(value){return false}}
        for key in ["minLength","maxLength"] {if let value=fields[key] {guard case .integer(let count)=value,count>=0 else{return false}}}
        if let value=fields["enum"] {guard case .array(let choices)=value,!choices.isEmpty,choices.count<=16,choices.allSatisfy(scalar) else{return false}}
        return true
    }
    public static func validGrant(_ devices: [String]) -> Bool {devices.count<=4 && Set(devices).count==devices.count && devices.allSatisfy(identifier)}
    public static func capabilities(_ value: JSONValue) throws -> AgentToolCapabilities {
        let fields=try object(value)
        guard Set(fields.keys)==Set(["enabled","tools","approval_required","max_devices"]),case .bool(let enabled)=fields["enabled"],fields["approval_required"] == .bool(true),fields["max_devices"] == .integer(4),fields["tools"] == .array([.string("limeiot_read"),.string("limeiot_command")]) else {throw LinkError("invalid_agent_tool_capabilities")}
        return AgentToolCapabilities(enabled:enabled)
    }
    public static func validate(_ call: AgentToolCall, devices: [String]) throws {
        let fields=try object(call.arguments)
        guard UUID(uuidString:call.id) != nil,call.expiresAt>=0,call.arguments.jsonText.utf8.count<=1024,devices.contains(try string(fields,"device_id")) else {throw LinkError("invalid_agent_tool_call")}
        if call.tool=="limeiot_read",Set(fields.keys)==Set(["device_id"]){return}
        guard call.isWrite,Set(fields.keys)==Set(["device_id","model_revision","path","value"]),revision(try string(fields,"model_revision")),path(try string(fields,"path")),let value=fields["value"],scalar(value) else {throw LinkError("invalid_agent_tool_call")}
    }
    public static func pending(_ value: JSONValue, reference: AgentReference) throws -> AgentToolBatch {
        let fields=try object(value),required=Set(["id","devices","calls","expires_at"])
        guard Set(fields.keys).isSuperset(of:required),Set(fields.keys).isSubset(of:required.union(["content_expired"])),fields["id"] == .string(reference.id),case .array(let devices)=fields["devices"],case .array(let calls)=fields["calls"],case .integer(let expires)=fields["expires_at"],expires>=0,calls.count<=1 else {throw LinkError("invalid_agent_tool_response")}
        if let expired=fields["content_expired"] {
            guard case .bool(true)=expired,devices.isEmpty,calls.isEmpty else {throw LinkError("invalid_agent_tool_response")}
            return AgentToolBatch(id:reference.id,calls:[],expiresAt:Int64(expires))
        }
        // TTL 后运行时清空范围；只能接受没有提案的过期响应。
        let same=devices == reference.iotDevices.map(JSONValue.string)
        guard same || (expires<=Int(Date().timeIntervalSince1970) && devices.isEmpty && calls.isEmpty) else {throw LinkError("agent_tool_scope_changed")}
        var result=[AgentToolCall]()
        for raw in calls {
            let f=try object(raw)
            guard Set(f.keys)==Set(["id","tool","arguments","expires_at"]),case .integer(let deadline)=f["expires_at"],deadline<=expires,let arguments=f["arguments"] else {throw LinkError("invalid_agent_tool_response")}
            let call=AgentToolCall(id:try string(f,"id"),tool:try string(f,"tool"),arguments:arguments,expiresAt:Int64(deadline))
            try validate(call,devices:reference.iotDevices);result.append(call)
        }
        return AgentToolBatch(id:reference.id,calls:result,expiresAt:Int64(expires))
    }
    public static func completion(_ value: JSONValue, id: String, call: String) throws {
        let fields=try object(value)
        guard Set(fields.keys)==Set(["id","call_id","recorded"]),fields["id"] == .string(id),fields["call_id"] == .string(call),fields["recorded"] == .bool(true) else {throw LinkError("invalid_agent_tool_result")}
    }
    public static func validateResult(_ call: AgentToolCall, success: Bool, output: JSONValue) throws {
        let fields=try object(output)
        guard output.jsonText.utf8.count<=1600 else {throw LinkError("agent_tool_response_budget")}
        if !success,Set(fields.keys)==Set(["error"]),case .string(let error)=fields["error"],error.range(of:"^[a-z0-9_]{1,96}\\z",options:.regularExpression) != nil{return}
        guard fields["device_id"] == .string(call.device) else {throw LinkError("agent_tool_result_target_mismatch")}
        if !call.isWrite {
            guard success,Set(fields.keys)==Set(["device_id","model_revision","ready","properties"]),revision(try string(fields,"model_revision")),case .bool=fields["ready"],case .array(let properties)=fields["properties"],properties.count<=8 else {throw LinkError("invalid_agent_tool_result")}
            var paths=Set<String>()
            for raw in properties {
                let f=try object(raw),p=try string(f,"path"),schema=try object(f["schema"] ?? .null)
                guard Set(f.keys)==Set(["path","schema","writable","value","observed_at","quality"]),path(p),paths.insert(p).inserted,case .bool=f["writable"],let value=f["value"],value == .null || scalar(value),let observed=f["observed_at"],timestamp(observed),(try string(f,"quality")).utf8.count<=32,validSchema(schema) else {throw LinkError("invalid_agent_tool_result")}
            }
        } else {
            let args=try object(call.arguments)
            guard Set(fields.keys)==Set(["device_id","model_revision","path","value","command_id","status","observed_at"]),fields["model_revision"]==args["model_revision"],fields["path"]==args["path"],fields["value"]==args["value"],identifier(try string(fields,"command_id")),["confirmed","failed","expired","rejected","unknown"].contains(try string(fields,"status")),success == (fields["status"] == .string("confirmed")),let observed=fields["observed_at"],timestamp(observed) else {throw LinkError("invalid_agent_tool_result")}
        }
    }
}
