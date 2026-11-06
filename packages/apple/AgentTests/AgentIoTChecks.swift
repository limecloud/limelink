import Foundation
import LimeIoTKit
import LimeLinkCore

private func require(_ value: Bool, _ code: String) throws {if !value{throw LinkError(code)}}
private actor ToolStore: SessionStore {
    var data=[String:Data]()
    var failJournal=false
    var loseReadback=false,readbackPending=false,slowIntent=false
    func load(origin: String) -> Data? {
        if readbackPending && origin.contains("agent-iot"){readbackPending=false;return nil}
        return data[origin]
    }
    func save(origin: String, data value: Data?) async throws {
        if failJournal && origin.contains("agent-iot"){throw LinkError("storage_unavailable")}
        data[origin]=value
        if loseReadback && origin.contains("agent-iot"){loseReadback=false;readbackPending=true}
        if slowIntent,origin.contains("agent-iot"),let value,let records=try JSONSerialization.jsonObject(with:value) as? [[String:Any]],records.contains(where:{$0["intent"] != nil && !($0["intent"] is NSNull)}){slowIntent=false;try await Task.sleep(nanoseconds:1_200_000_000)}
    }
    func fail() {failJournal=true}
    func failReadback() {loseReadback=true}
    func slowSave() {slowIntent=true}
    func expireJournal() throws {
        for key in data.keys.filter({$0.contains("agent-iot")}) {
            var records=try JSONSerialization.jsonObject(with:data[key]!) as! [[String:Any]]
            for index in records.indices {
                records[index]["runExpiresAt"]=1
                var call=records[index]["call"] as! [String:Any];call["expiresAt"]=0;records[index]["call"]=call
            }
            data[key]=try JSONSerialization.data(withJSONObject:records)
        }
    }
}
private actor ToolTransport: HTTPTransport {
    let desktopRevision="sha256:"+String(repeating:"a",count:64)
    let lampRevision="sha256:"+String(repeating:"b",count:64)
    var devicePosts=0,resultPosts=0,submits=0,deviceLookups=0
    var run="",grant=[String](),proposal:[String:Any]?
    var commands=[String:[String:Any]](),deviceKeys=Set<String>()
    var loseDevice=false,loseResult=false,missingOnce=false,readOnly=false,changedRevision=false,unknownDevice=false,wrongReceipt=false
    func publish(_ tool: String, target: String="lamp", value: JSONValue = .bool(true), ttl: Int=120) {
        let arguments: [String:Any]
        if tool=="limeiot_read"{arguments=["device_id":target]}
        else{arguments=["device_id":target,"model_revision":lampRevision,"path":"light.power","value":try! JSONSerialization.jsonObject(with:Data(value.jsonText.utf8),options:.fragmentsAllowed)]}
        proposal=["id":UUID().uuidString.lowercased(),"tool":tool,"arguments":arguments,"expires_at":Int(Date().timeIntervalSince1970)+ttl]
    }
    func loseCommand() {loseDevice=true;missingOnce=true}
    func loseReply() {loseResult=true}
    func denyProperty() {readOnly=true}
    func changeModel() {changedRevision=true}
    func unknown() {unknownDevice=true}
    func corruptReceipt() {wrongReceipt=true}
    func postCounts() -> [Int] {[devicePosts,resultPosts]}
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        let path=request.url!.path
        var status=200,body=[String:Any]()
        if path.hasSuffix("/auth/session"){body=["authenticated":true,"csrf_token":"fixture","expires_at":"2030-01-01T00:00:00Z"]}
        else if path.hasSuffix("/capabilities") {
            let desktop=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"contracts/desktop.json")))
            let lamp:[String:Any]=["model_id":"urn:fixture:lamp:1","services":[["id":"light","properties":[["id":"power","schema":["type":"boolean"],"access":readOnly ? ["read"] : ["read","write"]]],"events":[],"actions":[]]]]
            body=["models":[desktopRevision:desktop,lampRevision:lamp,"sha256:"+String(repeating:"c",count:64):lamp]]
        }else if path.hasSuffix("/devices") {
            deviceLookups+=1
            body=["items":[["device_id":"desktop","model_revision":desktopRevision,"ready":true,"reported":[:]],["device_id":"lamp","model_revision":changedRevision ? "sha256:"+String(repeating:"c",count:64) : lampRevision,"ready":true,"reported":["light.power":["value":false,"observed_at":ISO8601DateFormatter().string(from:Date()),"quality":"good","source":"fixture"]]]],"next_cursor":NSNull()]
        }else if path.hasSuffix("/commands") && request.httpMethod=="POST" {
            var input=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            let key=request.value(forHTTPHeaderField:"Idempotency-Key")!,operation=input["operation"] as! [String:Any]
            input["space_id"]="chosen";input["idempotency_key"]=key
            let id=UUID().uuidString.lowercased()
            if operation["path"] as? String=="agent.exchange" {
                let exchange=operation["value"] as! [String:Any],kind=exchange["kind"] as! String
                let payload=try JSONSerialization.jsonObject(with:Data((exchange["payload"] as! String).utf8)) as! [String:Any]
                let value:[String:Any]
                switch kind {
                case "agent.submit":
                    submits+=1;run=payload["id"] as! String;grant=payload["iot_devices"] as? [String] ?? []
                    value=["id":run,"state":"awaiting_approval","workspace_id":"work","sandbox":"read-only","session_id":NSNull(),"error":NSNull(),"expires_at":Int(Date().timeIntervalSince1970)+3600,"events":[],"cursor":0]
                case "agent.tool_capabilities":value=["enabled":true,"tools":["limeiot_read","limeiot_command"],"approval_required":true,"max_devices":4]
                case "agent.tool_pending":value=["id":run,"devices":grant,"calls":proposal.map{[$0]} ?? [],"expires_at":Int(Date().timeIntervalSince1970)+3600]
                case "agent.tool_result":
                    resultPosts+=1;proposal=nil;value=["id":run,"call_id":payload["call_id"]!,"recorded":true]
                default:throw LinkError("unexpected_agent_tool_fixture_kind")
                }
                let response=String(decoding:try JSONSerialization.data(withJSONObject:["ok":true,"value":value]),as:UTF8.self)
                body=["command_id":id,"status":"confirmed","request_digest":"sha256:"+String(repeating:"d",count:64),"request":input,"error":NSNull(),"evidence":["type":"action_result","path":"agent.exchange","input_digest":"sha256:"+String(repeating:"e",count:64),"output":["response":response],"completion":"submitted","observed_at":ISO8601DateFormatter().string(from:Date())]]
                commands[key]=body
                if kind=="agent.tool_result" && loseResult{loseResult=false;throw URLError(.timedOut)}
            }else{
                devicePosts+=1;deviceKeys.insert(key)
                try require(operation["type"] as? String=="property.set" && operation["path"] as? String=="light.power","fixture_bad_device_operation")
                body=["command_id":id,"status":unknownDevice ? "unknown":"confirmed","request_digest":"sha256:"+String(repeating:"f",count:64),"request":input,"error":NSNull(),"evidence":unknownDevice ? NSNull() : ["type":"device_result","reported":["light.power":operation["value"]!]]]
                commands[key]=body
                if loseDevice{loseDevice=false;throw URLError(.timedOut)}
                if wrongReceipt{wrongReceipt=false;body["evidence"]=["type":"device_result","reported":["light.power":false]]}
            }
        }else if path.contains("/commands/by-key/") {
            let key=request.url!.lastPathComponent
            if missingOnce && deviceKeys.contains(key){missingOnce=false;status=404;body=["error":["code":"command_not_found"]]}
            else if let known=commands[key]{body=known}
            else{status=404;body=["error":["code":"command_not_found"]]}
        }else if path.hasSuffix("/spaces"){body=["items":[["space_id":"chosen"]],"next_cursor":NSNull()]}
        else if ["/commands","/rule-deployments","/runs"].contains(where:{path.hasSuffix($0)}){body=["items":[],"next_cursor":NSNull()]}
        else{throw LinkError("unexpected_agent_tool_fixture_route")}
        return(try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Set-Cookie":"__Host-limeiot_session="+String(repeating:"a",count:64)+"; Secure; HttpOnly"])!)
    }
}

enum AgentIoTChecks {
    private static func setup() async throws -> (ToolStore,ToolTransport,LinkClient,AgentClient,AgentIoTClient,Device,AgentReference) {
        let store=ToolStore(),transport=ToolTransport(),link=try LinkClient(endpoint:"https://gateway.example",store:store,transport:transport)
        try await link.login(token:"fixture");let snapshot=try await link.snapshot(space:"chosen")
        let device=snapshot.devices.first{$0.id=="desktop"}!,agent=AgentClient(link:link,store:store)
        _=try await agent.submit(space:"chosen",device:device,workspace:"work",text:"控制已选择的灯",sandbox:"read-only",iotDevices:["lamp"])
        let reference=try await agent.references()[0]
        return(store,transport,link,agent,AgentIoTClient(gateway:link.gateway,agent:agent,store:store),device,reference)
    }
    static func run() async throws {
        let (_,readTransport,_,readAgent,readClient,execution,reference)=try await setup()
        try require(reference.iotDevices==["lamp"],"grant_not_durable")
        try require(try await readAgent.discoverTools(space:"chosen",device:execution).enabled,"missing_tool_capability")
        await readTransport.publish("limeiot_read")
        let read=try await readClient.receive(reference,space:"chosen",execution:execution)
        try require(read?.delivered==true && read?.outcome?.success==true,"read_not_reported")
        try require(await readTransport.devicePosts==0,"read_created_device_command")

        let (_,transport,_,_,client,device,ref)=try await setup();await transport.publish("limeiot_command")
        let proposal=try await client.receive(ref,space:"chosen",execution:device)!
        try require(proposal.canConfirm && proposal.intent == nil,"proposal_bypassed_confirmation")
        try require(await transport.devicePosts==0,"write_before_confirmation")
        let done=try await client.confirm(proposal.id,reference:ref,space:"chosen",execution:device)
        try require(done.delivered && done.outcome?.success==true && done.replyIntent != nil,"write_or_reply_not_durable")
        do{_=try await client.confirm(proposal.id,reference:ref,space:"chosen",execution:device);throw LinkError("duplicate_confirmation_accepted")}catch let error as LinkError{try require(error.code=="resolve_original_iot_command_first","wrong_duplicate_error")}
        try require(await transport.postCounts()==[1,1],"duplicate_device_write")

        let (store,lostTransport,lostLink,lostAgent,lostClient,lostDevice,lostRef)=try await setup();await lostTransport.publish("limeiot_command")
        let lost=try await lostClient.receive(lostRef,space:"chosen",execution:lostDevice)!
        await lostTransport.loseCommand()
        do{_=try await lostClient.confirm(lost.id,reference:lostRef,space:"chosen",execution:lostDevice);throw LinkError("missing_command_timeout")}catch is URLError{}
        let restarted=AgentIoTClient(gateway:lostLink.gateway,agent:lostAgent,store:store)
        do{_=try await restarted.recoverCommand(lost.id,reference:lostRef,space:"chosen",execution:lostDevice);throw LinkError("404_original_discarded")}catch GatewayError.server(_,404){}
        try require(try await restarted.records().first?.intent != nil,"lost_intent_not_preserved")
        let recovered=try await restarted.recoverCommand(lost.id,reference:lostRef,space:"chosen",execution:lostDevice)
        try require(recovered.delivered && recovered.commandStatus=="confirmed","original_command_not_recovered")
        try require(await lostTransport.devicePosts==1,"recovery_posted_second_device_command")

        let (replyStore,replyTransport,replyLink,replyAgent,replyClient,replyDevice,replyRef)=try await setup();await replyTransport.publish("limeiot_command")
        let reply=try await replyClient.receive(replyRef,space:"chosen",execution:replyDevice)!
        await replyTransport.loseReply()
        do{_=try await replyClient.confirm(reply.id,reference:replyRef,space:"chosen",execution:replyDevice);throw LinkError("missing_reply_timeout")}catch is URLError{}
        try await replyStore.expireJournal()
        try require(try await replyClient.pruneExpired()==0,"unresolved_reply_intent_pruned")
        _=try await replyAgent.recover()
        let restored=AgentIoTClient(gateway:replyLink.gateway,agent:replyAgent,store:replyStore)
        let delivered=try await restored.sendResult(reply.id,reference:replyRef,space:"chosen",execution:replyDevice)
        try require(delivered.delivered,"original_reply_not_recovered")
        try require(await replyTransport.postCounts()==[1,1],"reply_recovery_reposted")

        let (failedStore,failedTransport,_,_,failedClient,failedDevice,failedRef)=try await setup();await failedTransport.publish("limeiot_command")
        let failed=try await failedClient.receive(failedRef,space:"chosen",execution:failedDevice)!
        await failedStore.fail()
        do{_=try await failedClient.confirm(failed.id,reference:failedRef,space:"chosen",execution:failedDevice);throw LinkError("missing_intent_storage_failure")}catch let error as LinkError{try require(error.code=="storage_unavailable","wrong_intent_failure")}
        try require(await failedTransport.devicePosts==0,"device_post_before_durable_intent")

        let (readbackStore,readbackTransport,_,_,readbackClient,readbackDevice,readbackRef)=try await setup()
        await readbackTransport.publish("limeiot_command")
        let readback=try await readbackClient.receive(readbackRef,space:"chosen",execution:readbackDevice)!
        await readbackStore.failReadback()
        do{_=try await readbackClient.confirm(readback.id,reference:readbackRef,space:"chosen",execution:readbackDevice);throw LinkError("readback_failure_ignored")}catch let error as LinkError{try require(error.code=="agent_tool_record_not_durable","wrong_readback_error")}
        try require(await readbackTransport.devicePosts==0,"device_post_before_intent_readback")
        try require(try await readbackClient.records().first?.intent != nil,"readback_failure_lost_original")

        let (slowStore,slowTransport,_,_,slowClient,slowDevice,slowRef)=try await setup()
        await slowTransport.publish("limeiot_command",ttl:1)
        let slow=try await slowClient.receive(slowRef,space:"chosen",execution:slowDevice)!
        await slowStore.slowSave()
        do{_=try await slowClient.confirm(slow.id,reference:slowRef,space:"chosen",execution:slowDevice);throw LinkError("slow_expired_confirmation_accepted")}catch let error as LinkError{try require(error.code=="agent_tool_call_expired","wrong_slow_expired_error")}
        try require(await slowTransport.devicePosts==0,"slow_expired_device_post")
        try require(try await slowClient.records().first?.intent != nil,"slow_expiry_did_not_cross_storage_boundary")
        let (expiredStore,expiredTransport,_,_,expiredClient,expiredDevice,expiredRef)=try await setup()
        await expiredTransport.publish("limeiot_command")
        let expired=try await expiredClient.receive(expiredRef,space:"chosen",execution:expiredDevice)!
        try await expiredStore.expireJournal()
        do{_=try await expiredClient.confirm(expired.id,reference:expiredRef,space:"chosen",execution:expiredDevice);throw LinkError("expired_confirmation_accepted")}catch let error as LinkError{try require(error.code=="resolve_original_iot_command_first","wrong_expired_error")}
        try require(await expiredTransport.devicePosts==0,"expired_device_post")
        try require(try await expiredClient.pruneExpired()==1,"expired_unused_proposal_not_pruned")
        try await store.expireJournal()
        try require(try await restarted.pruneExpired()==1,"expired_delivered_record_not_pruned")
        try await readbackStore.expireJournal()
        try require(try await readbackClient.pruneExpired()==0,"unresolved_device_intent_pruned")
        try require(try await readbackClient.records().first?.intent != nil,"unresolved_reference_lost_at_ttl")

        for mode in ["read-only","revision","bad-value","scope","reject","unknown","bad-receipt"] {
            let (_,t,_,_,c,d,r)=try await setup()
            await t.publish("limeiot_command",target:mode=="scope" ? "outside" : "lamp",value:mode=="bad-value" ? .integer(5):.bool(true))
            if mode=="scope" {
                do{_=try await c.receive(r,space:"chosen",execution:d);throw LinkError("outside_scope_accepted")}catch let error as LinkError{try require(error.code=="invalid_agent_tool_call","wrong_scope_error")}
            }else{
                let record=try await c.receive(r,space:"chosen",execution:d)!
                if mode=="read-only"{await t.denyProperty()};if mode=="revision"{await t.changeModel()};if mode=="unknown"{await t.unknown()};if mode=="bad-receipt"{await t.corruptReceipt()}
                if mode=="reject"{let rejected=try await c.reject(record.id,reference:r,space:"chosen",execution:d);try require(rejected.delivered && rejected.outcome?.success==false,"rejection_not_reported")}
                else if mode=="unknown"{let result=try await c.confirm(record.id,reference:r,space:"chosen",execution:d);try require(result.needsRecovery && result.outcome?.success==false,"unknown_reported_as_success")}
                else if mode=="bad-receipt"{
                    do{_=try await c.confirm(record.id,reference:r,space:"chosen",execution:d);throw LinkError("bad_receipt_accepted")}catch GatewayError.invalidResponse{}
                    let result=try await c.recoverCommand(record.id,reference:r,space:"chosen",execution:d);try require(result.delivered,"bad_receipt_original_not_retained")
                }else{
                    do{_=try await c.confirm(record.id,reference:r,space:"chosen",execution:d);throw LinkError("unsafe_property_accepted")}catch let error as LinkError{try require(["agent_tool_property_not_allowed","agent_tool_model_or_availability_changed"].contains(error.code),"wrong_property_error:"+error.code)}
                }
            }
            try require(await t.devicePosts == (["unknown","bad-receipt"].contains(mode) ? 1:0),"unexpected_device_post:"+mode)
        }
        do{_=try await client.receive(ref,space:"other",execution:device);throw LinkError("cross_space_tool_accepted")}catch let error as LinkError{try require(error.code=="agent_target_changed","wrong_tool_space_error")}
    }
}
