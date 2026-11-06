import Foundation
import LimeIoTKit
import LimeLinkCore
import LimeLinkUI

private func check(_ value:Bool,_ code:String)throws{if !value{throw LinkError(code)}}
private actor MemoryStore:SessionStore {
    var records:[String:Data]=[:]
    var failReferences=false
    func load(origin:String)->Data?{records[origin]}
    func save(origin:String,data:Data?)throws{
        if failReferences && origin.contains("agent-runs"){throw LinkError("storage_unavailable")}
        records[origin]=data
    }
    func fail(){failReferences=true}
}
private actor AgentTransport:HTTPTransport {
    var creates=0,submits=0,queries=0
    var loseSubmit=false,malformed=false,missingAction=false
    var last:[String:Any]?
    var original:[String:Any]?
    let revision="sha256:"+String(repeating:"a",count:64)
    func lose(){loseSubmit=true}
    func corrupt(){malformed=true}
    func removeCapability(){missingAction=true}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse){
        let path=request.url!.path
        var status=200,body:[String:Any]=[:]
        if path.hasSuffix("/auth/session"){body=["authenticated":true,"csrf_token":"fixture","expires_at":"2030-01-01T00:00:00Z"]}
        else if path.hasSuffix("/capabilities"){
            var model=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"contracts/desktop.json"))) as! [String:Any]
            if missingAction{model["services"]=(model["services"] as! [[String:Any]]).filter{$0["id"] as? String != "agent"}}
            body=["models":[revision:model]]
        }else if path.hasSuffix("/devices"){
            body=["items":[["device_id":"desktop","model_revision":revision,"ready":true,"reported":[:]]],"next_cursor":NSNull()]
        }else if path.hasSuffix("/commands") && request.httpMethod=="POST"{
            creates+=1
            var input=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            input["space_id"]="chosen";input["idempotency_key"]=request.value(forHTTPHeaderField:"Idempotency-Key")!
            let operation=input["operation"] as! [String:Any],exchange=operation["value"] as! [String:Any]
            try check(operation["path"] as? String=="agent.exchange","agent_used_collaboration_path")
            let kind=exchange["kind"] as! String,payload=try JSONSerialization.jsonObject(with:Data((exchange["payload"] as! String).utf8)) as! [String:Any]
            let value:[String:Any]
            if kind=="agent.capabilities"{value=["adapter":"codex-app-server","configured":true,"authentication":"managed_by_codex","local_approval_required":true,"workspaces":[["id":"work","name":"测试目录","allow_write":true]]]}
            else{
                if kind=="agent.submit"{submits+=1}
                value=["id":malformed ? UUID().uuidString : payload["id"]!,"state":"awaiting_approval","workspace_id":"work","sandbox":"read-only","session_id":NSNull(),"error":NSNull(),"expires_at":Int(Date().timeIntervalSince1970)+3600,"events":[],"cursor":payload["after"] ?? 0]
            }
            let response=String(decoding:try JSONSerialization.data(withJSONObject:["ok":true,"value":value]),as:UTF8.self)
            body=["command_id":UUID().uuidString,"status":"confirmed","request_digest":"sha256:"+String(repeating:"b",count:64),"request":input,"error":NSNull(),"evidence":["type":"action_result","path":"agent.exchange","input_digest":"sha256:"+String(repeating:"c",count:64),"output":["response":response],"completion":"submitted","observed_at":ISO8601DateFormatter().string(from:Date())]]
            last=body
            if kind=="agent.submit"{original=body;if loseSubmit{loseSubmit=false;throw URLError(.timedOut)}}
        }else if path.contains("/commands/by-key/"){
            queries+=1
            if queries==1 && original != nil{status=404;body=["error":["code":"command_not_found"]]}
            else{body=last!}
        }else if path.hasSuffix("/spaces"){body=["items":[["space_id":"chosen","name":"测试空间"]],"next_cursor":NSNull()]}
        else if ["/commands","/rule-deployments","/runs"].contains(where:{path.hasSuffix($0)}){body=["items":[],"next_cursor":NSNull()]}
        else{throw LinkError("unexpected_agent_fixture_route")}
        return(try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Set-Cookie":"__Host-limeiot_session="+String(repeating:"a",count:64)+"; Secure; HttpOnly"])!)
    }
}
@main private enum AgentChecks {
    static func setup()async throws->(MemoryStore,AgentTransport,LinkClient,AgentClient,Device){
        let store=MemoryStore(),transport=AgentTransport(),link=try LinkClient(endpoint:"https://gateway.example",store:store,transport:transport)
        try await link.login(token:"fixture");let snapshot=try await link.snapshot(space:"chosen")
        return(store,transport,link,AgentClient(link:link,store:store),snapshot.devices[0])
    }
    @MainActor static func main()async throws{
        if let endpoint=ProcessInfo.processInfo.environment["LIMELINK_AGENT_IOT_ENDPOINT"]{try await AgentIoTLiveChecks.run(endpoint:endpoint);return}
        if let endpoint=ProcessInfo.processInfo.environment["LIMELINK_AGENT_CHECK_ENDPOINT"]{
            try await live(endpoint:endpoint);return
        }
        let vectors = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath:"contracts/fixtures/agent-responses.json")))
        guard case .object(let fixture) = vectors, case .array(let cases) = fixture["cases"] else { throw LinkError("invalid_vectors") }
        for item in cases {
            guard case .object(let fields) = item, let value=fields["value"], case .string(let name)=fields["name"], case .string(let kind)=fields["kind"], case .bool(let valid)=fields["valid"], case .string(let id)=fields["id"], case .integer(let after)=fields["after"] else { throw LinkError("invalid_vector") }
            var accepted=false
            do { if kind=="run" { _=try AgentClient.decodeRun(value,id:id,after:after) } else { _=try AgentClient.decodeCapabilities(value) };accepted=true } catch {}
            try check(accepted==valid,"shared_agent_vector:"+name)
        }
        let (_,transport,link,client,device)=try await setup()
        do{_=try await link.perform(space:"chosen",device:device,kind:"agent.submit",payload:.object([:]));throw LinkError("path_mismatch_accepted")}catch let error as LinkError{try check(error.code=="invalid_action_path","wrong_path_error")}
        let capabilities=try await client.discover(space:"chosen",device:device)
        try check(capabilities.localApprovalRequired,"missing_local_approval")
        let run=try await client.submit(space:"chosen",device:device,workspace:"work",text:"测试任务",sandbox:"read-only")
        try check(run.state=="awaiting_approval","platform_receipt_mistaken_for_agent_completion")
        let reference=try await client.references()[0]
        _=try await client.query(reference,space:"chosen",device:device)
        do{_=try await client.query(reference,space:"other",device:device);throw LinkError("target_change_accepted")}catch let error as LinkError{try check(error.code=="agent_target_changed","wrong_target_error")}
        try check(await transport.submits==1,"extra_submission")

        let (lostStore,lostTransport,lostLink,lostClient,lostDevice)=try await setup()
        await lostTransport.lose()
        do{_=try await lostClient.submit(space:"chosen",device:lostDevice,workspace:"work",text:"只提交一次",sandbox:"read-only");throw LinkError("expected_timeout")}catch is URLError{}
        try check(try await lostLink.pending() != nil,"lost_original_not_saved")
        let restored=AgentClient(link:lostLink,store:lostStore)
        do{_=try await restored.recover();throw LinkError("404_not_preserved")}catch GatewayError.server(_,404){}
        try check(try await lostLink.pending() != nil,"404_cleared_original")
        let recovered=try await restored.recover()
        try check(recovered?.state=="awaiting_approval","original_run_not_recovered")
        let submitCount=await lostTransport.submits,createCount=await lostTransport.creates
        try check(submitCount==1 && createCount==1,"lost_response_resubmitted")
        try check(try await lostLink.pending()==nil,"confirmed_original_not_archived")

        let (failedStore,failedTransport,_,failedClient,failedDevice)=try await setup();await failedStore.fail()
        do{_=try await failedClient.submit(space:"chosen",device:failedDevice,workspace:"work",text:"持久化先于发送",sandbox:"read-only");throw LinkError("expected_storage_failure")}catch let error as LinkError{try check(error.code=="storage_unavailable","wrong_storage_error")}
        try check(await failedTransport.creates==0,"post_before_durable_reference")

        let (_,badTransport,badLink,badClient,badDevice)=try await setup();await badTransport.corrupt()
        do{_=try await badClient.submit(space:"chosen",device:badDevice,workspace:"work",text:"校验原任务",sandbox:"read-only");throw LinkError("corrupt_result_accepted")}catch let error as LinkError{try check(error.code=="invalid_agent_response","wrong_decode_error")}
        try check(try await badLink.pending() != nil,"malformed_receipt_archived")

        let (_,missingTransport,_,missingClient,missingDevice)=try await setup();await missingTransport.removeCapability()
        do{_=try await missingClient.discover(space:"chosen",device:missingDevice);throw LinkError("missing_action_accepted")}catch let error as LinkError{try check(error.code=="target_capability_changed","wrong_capability_error")}
        try check(await missingTransport.creates==0,"post_without_current_action")
        _=try AgentToolVectorChecks.run()
        try await AgentIoTChecks.run()
        print("{\"passed\":true,\"groups\":7,\"independent_action\":true,\"durable_reference\":true,\"lost_response_get_only\":true,\"receipt_is_not_agent_completion\":true,\"malformed_preserves_original\":true,\"current_capability_required\":true,\"iot_tools\":true,\"real_model\":false,\"native_window\":false}")
    }
    @MainActor static func live(endpoint:String)async throws{
        func idle(_ model:WorkbenchModel)async throws{
            for _ in 0..<1000{if !model.busy{return};try await Task.sleep(for:.milliseconds(10))}
            throw LinkError("live_workbench_timeout")
        }
        let model=WorkbenchModel(store:MemoryStore(),development:true)
        model.endpoint=endpoint;model.token=ProcessInfo.processInfo.environment["LIMELINK_AGENT_CHECK_TOKEN"] ?? ""
        model.connect();try await idle(model)
        try check(model.spaces.contains("space-demo"),"live_space_missing")
        model.space="space-demo";model.refresh();try await idle(model)
        model.target="device-lamp";model.selectTarget();try await idle(model)
        try check(!model.fingerprint.isEmpty,"live_target_missing")
        model.action("pair");try await idle(model);model.finish();try await idle(model)
        try await Task.sleep(for:.milliseconds(300))
        model.discoverAgent();try await idle(model)
        try check(model.agentCapabilities?.localApprovalRequired==true,"live_agent_not_configured:"+model.result)
        model.agentWorkspace="work"
        let expected=ProcessInfo.processInfo.environment["LIMELINK_AGENT_CHECK_REAL"]=="1" ? "LIMELINK_AGENT_OK" : String(repeating:"真实协议夹具",count:100)
        let prompt=expected=="LIMELINK_AGENT_OK" ? "Reply with exactly LIMELINK_AGENT_OK. Do not use tools, read files, or access any external resource." : "normal"
        var originalSession:String?
        for index in 0..<2{
            model.agentText=prompt;model.agentContinue=index==1
            model.submitAgent();try await idle(model)
            try check(model.agentRun?.state=="awaiting_approval","live_submit_not_queued:"+model.result)
            let deadline=Date().addingTimeInterval(65)
            while Date()<deadline{
                try await Task.sleep(for:.milliseconds(250));model.queryAgent();try await idle(model)
                if let state=model.agentRun?.state,["succeeded","failed","unknown"].contains(state){break}
            }
            try check(model.agentRun?.state=="succeeded","live_agent_did_not_succeed:"+model.result)
            for _ in 0..<64 where model.agentRun?.events.count==4{model.queryAgent();try await idle(model)}
            let reply=model.agentEvents.filter{$0.kind=="message"}.map(\.text).joined()
            try check(reply.trimmingCharacters(in:.whitespacesAndNewlines)==expected,"live_reply_mismatch")
            if index==0{originalSession=model.agentRun?.sessionId}else{try check(model.agentRun?.sessionId==originalSession,"live_session_not_resumed")}
        }
        model.space="different-space"
        try check(model.agentRun==nil && model.agentEvents.isEmpty && model.agentCapabilities==nil && model.agentText.isEmpty,"live_space_leaked_projection")
        print("{\"passed\":true,\"workbench_model\":true,\"real_gateway\":true,\"submit_query_reply\":true,\"explicit_resume\":true,\"space_isolation\":true,\"native_window\":false}")
    }
}
