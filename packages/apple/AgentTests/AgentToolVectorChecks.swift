import Foundation
import LimeIoTKit
import LimeLinkCore

enum AgentToolVectorChecks {
    static func run() throws -> Int {
        let data=try Data(contentsOf:URL(fileURLWithPath:"contracts/fixtures/agent-tools.json"))
        let root=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let decoder=JSONDecoder()
        let reference=try decoder.decode(AgentReference.self,from:JSONSerialization.data(withJSONObject:root["reference"]!))
        let cases=root["cases"] as! [[String:Any]]
        for item in cases {
            let value=try decoder.decode(JSONValue.self,from:JSONSerialization.data(withJSONObject:item["value"]!))
            var accepted=false
            do {
                switch item["kind"] as! String {
                case "capabilities":_ = try AgentToolProtocol.capabilities(value)
                case "call":
                    let call=try decodeCall(value)
                    try AgentToolProtocol.validate(call,devices:reference.iotDevices)
                case "result":
                    let raw=try decoder.decode(JSONValue.self,from:JSONSerialization.data(withJSONObject:item["call"]!))
                    try AgentToolProtocol.validateResult(decodeCall(raw),success:item["success"] as! Bool,output:value)
                case "pending":_ = try AgentToolProtocol.pending(value,reference:reference)
                case "completion":try AgentToolProtocol.completion(value,id:reference.id,call:root["call_id"] as! String)
                default:throw LinkError("unknown_tool_vector")
                }
                accepted=true
            }catch{}
            guard accepted == item["valid"] as! Bool else {throw LinkError("shared_tool_vector:"+(item["name"] as! String))}
        }
        return cases.count
    }
    private static func decodeCall(_ value:JSONValue) throws -> AgentToolCall {
        // 使用正式 pending 解码边界构建协议调用，避免测试专用初始化器。
        let decoder=JSONDecoder()
        let reference=try decoder.decode(AgentReference.self,from:Data("{\"origin\":\"https://gateway.example\",\"space\":\"chosen\",\"device\":\"desktop\",\"revision\":\"sha256:fixture\",\"id\":\"11111111-1111-4111-8111-111111111111\",\"iotDevices\":[\"lamp\"]}".utf8))
        let batch:JSONValue = .object(["id":.string(reference.id),"devices":.array([.string("lamp")]),"calls":.array([value]),"expires_at":.integer(2000003600)])
        guard let call=try AgentToolProtocol.pending(batch,reference:reference).calls.first else{throw LinkError("missing_tool_vector_call")}
        return call
    }
}
