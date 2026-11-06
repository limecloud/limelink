import Foundation
import LimeIoTKit
import LimeLinkCore
import LimeLinkUI

private actor IoTLiveStore: SessionStore {
    var data=[String:Data]()
    func load(origin:String)->Data?{data[origin]}
    func save(origin:String,data value:Data?){data[origin]=value}
}
private actor IoTLossTransport: HTTPTransport {
    let underlying=URLSessionTransport()
    var deviceDropped=false,replyDropped=false
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        let result=try await underlying.send(request)
        if request.httpMethod=="POST",request.url?.path.hasSuffix("/commands")==true,let data=request.httpBody,let body=try JSONSerialization.jsonObject(with:data) as? [String:Any],let operation=body["operation"] as? [String:Any] {
            if operation["type"] as? String=="property.set",!deviceDropped {deviceDropped=true;throw URLError(.timedOut)}
            if let exchange=operation["value"] as? [String:Any],exchange["kind"] as? String=="agent.tool_result",let text=exchange["payload"] as? String,let payload=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],let output=payload["output"] as? [String:Any],output["status"] as? String=="confirmed",!replyDropped {replyDropped=true;throw URLError(.timedOut)}
        }
        return result
    }
    func losses()->[Bool]{[deviceDropped,replyDropped]}
}
@MainActor enum AgentIoTLiveChecks {
    private static func check(_ value:Bool,_ code:String)throws{if !value{throw LinkError(code)}}
    private static func idle(_ model:WorkbenchModel)async throws{
        for _ in 0..<1000{if !model.busy{return};try await Task.sleep(for:.milliseconds(10))}
        throw LinkError("iot_workbench_timeout")
    }
    static func run(endpoint:String)async throws{
        let transport=IoTLossTransport(),model=WorkbenchModel(store:IoTLiveStore(),transport:transport,development:true)
        model.endpoint=endpoint;model.token=ProcessInfo.processInfo.environment["LIMELINK_AGENT_CHECK_TOKEN"] ?? ""
        model.connect();try await idle(model);model.space="space-demo";model.refresh();try await idle(model)
        try check(model.agentIoTDevices.contains{$0.id=="device-button"},"iot_target_not_discovered")
        try check(!model.agentIoTDevices.contains{$0.id=="device-lamp"},"execution_device_in_iot_targets")
        model.target="device-lamp";model.selectTarget();try await idle(model)
        model.action("pair");try await idle(model);model.finish();try await idle(model)
        try await Task.sleep(for:.milliseconds(300));model.discoverAgent();try await idle(model)
        try check(model.agentToolEnabled,"iot_runtime_not_enabled:"+model.result)
        model.agentWorkspace="work";model.agentSelectedDevices=["device-button"]
        let real=ProcessInfo.processInfo.environment["LIMELINK_AGENT_CHECK_REAL"]=="1"
        model.agentText=real ? "Use limeiot_read for device-button exactly once. Then propose limeiot_command for light.power=true using its returned model_revision. Wait for client confirmation. Do not use other tools, files or external resources. After the device tool returns confirmed, reply exactly LIMELINK_IOT_DEVICE_OK." : "iot-live"
        model.submitAgent();try await idle(model)
        try check(model.agentRun?.state=="awaiting_approval","iot_submit_not_queued:"+model.result)
        let deadline=Date().addingTimeInterval(115)
        while Date()<deadline && !model.agentToolRecords.contains(where:{$0.canConfirm}) {
            try await Task.sleep(for:.milliseconds(250));model.queryAgent();try await idle(model)
            if ["failed","unknown","succeeded"].contains(model.agentRun?.state ?? ""){throw LinkError("iot_no_write_proposal:"+model.result)}
        }
        guard let proposal=model.agentToolRecords.first(where:{$0.canConfirm}) else{throw LinkError("iot_proposal_timeout")}
        try check(model.agentToolRecords.contains{!$0.call.isWrite && $0.delivered && $0.outcome?.success==true},"iot_read_not_verified")
        try check(proposal.intent == nil,"iot_write_before_confirmation")
        guard let file=ProcessInfo.processInfo.environment["LIMELINK_AGENT_IOT_APPROVAL_FILE"] else{throw LinkError("iot_approval_probe_missing")}
        try Data("awaiting-client-confirmation".utf8).write(to:URL(fileURLWithPath:file),options:.atomic)
        for _ in 0..<200 {
            if (try? String(contentsOfFile:file,encoding:.utf8))=="confirm"{break}
            try await Task.sleep(for:.milliseconds(50))
        }
        try check((try? String(contentsOfFile:file,encoding:.utf8))=="confirm","iot_no_driver_confirmation")
        model.pollAgent();try check(!model.busy,"poll_blocked_device_confirmation")
        model.performAgentTool(proposal.id,action:.confirm);try await idle(model)
        try check(model.agentToolRecords.first{$0.id==proposal.id}?.intent != nil,"iot_original_intent_missing")
        try check(await transport.losses()==[true,false],"iot_device_loss_not_injected")
        model.performAgentTool(proposal.id,action:.recover);try await idle(model)
        try check(await transport.losses()==[true,true],"iot_reply_loss_not_injected")
        try check(model.hasPending,"iot_original_reply_not_retained")
        model.performAgentTool(proposal.id,action:.report);try await idle(model)
        guard let completed=model.agentToolRecords.first(where:{$0.id==proposal.id}) else{throw LinkError("iot_verified_record_missing")}
        try check(completed.delivered && completed.commandStatus=="confirmed" && completed.outcome?.success==true,"iot_original_result_not_recovered:"+model.result)
        let finish=Date().addingTimeInterval(65)
        while Date()<finish {
            model.queryAgent();try await idle(model)
            if ["succeeded","failed","unknown"].contains(model.agentRun?.state ?? ""){break}
            try await Task.sleep(for:.milliseconds(250))
        }
        try check(model.agentRun?.state=="succeeded","iot_agent_not_completed:"+model.result)
        for _ in 0..<64 where model.agentRun?.events.count==4{model.queryAgent();try await idle(model)}
        try check(model.agentEvents.last(where:{$0.kind=="message"})?.text.trimmingCharacters(in:.whitespacesAndNewlines)=="LIMELINK_IOT_DEVICE_OK","iot_final_reply_mismatch")
        model.space="another-space"
        try check(model.agentToolRecords.isEmpty && model.agentSelectedDevices.isEmpty && !model.agentToolEnabled,"iot_projection_leaked_space")
        print("{\"passed\":true,\"product_client\":\"apple\",\"workbench_model\":true,\"real_gateway\":true,\"read\":true,\"explicit_write_confirmation\":true,\"lost_device_response\":true,\"lost_reply_response\":true,\"original_recovery\":true,\"scope_isolation\":true,\"native_window\":false,\"physical_device\":false}")
    }
}
