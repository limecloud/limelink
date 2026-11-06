import Foundation
import LimeIoTKit
import LimeLinkCore
import LimeLinkUI

private actor PairingStore:SessionStore {
    private var values:[String:Data]=[:]
    func load(origin:String)->Data?{values[origin]}
    func save(origin:String,data:Data?){values[origin]=data}
}
private actor PairingTransport:HTTPTransport {
    enum Outcome:CaseIterable {case confirmed,delayed,rejected,unknown,failed,lost,notFound}
    let outcome:Outcome
    let revision="sha256:"+String(repeating:"a",count:64)
    private(set) var creates=0
    private(set) var queries=0
    private var original:[String:Any]?
    init(_ outcome:Outcome){self.outcome=outcome}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse){
        let path=request.url!.path
        var status=200,body:[String:Any]=[:]
        if path.hasSuffix("/auth/session") {body=["authenticated":true,"csrf_token":"fixture","expires_at":"2030-01-01T00:00:00Z"]}
        else if path.hasSuffix("/spaces"){body=["items":[["space_id":"chosen","name":"测试空间"]],"next_cursor":NSNull()]}
        else if path.hasSuffix("/capabilities"){
            let model=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"contracts/desktop.json")))
            body=["models":[revision:model]]
        }else if path.hasSuffix("/devices"){
            body=["items":[["device_id":"desktop","model_revision":revision,"ready":true,"reported":[:]]],"next_cursor":NSNull()]
        }else if path.hasSuffix("/commands"),request.httpMethod=="POST" {
            creates+=1
            var input=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
            input["space_id"]="chosen";input["idempotency_key"]=request.value(forHTTPHeaderField:"Idempotency-Key")!
            original=input
            if outcome == .lost{throw URLError(.timedOut)}
            body=try command(queried:false)
        }else if path.contains("/commands/by-key/"){
            queries+=1
            if outcome == .notFound{status=404;body=["error":["code":"command_not_found"]]}
            else{body=try command(queried:true)}
        }else if ["/commands","/rule-deployments","/runs"].contains(where:{path.hasSuffix($0)}){body=["items":[],"next_cursor":NSNull()]}
        else{throw LinkError("unexpected_pairing_fixture_route")}
        return(try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Set-Cookie":"__Host-limeiot_session="+String(repeating:"a",count:64)+"; Secure; HttpOnly"])!)
    }
    private func command(queried:Bool)throws->[String:Any]{
        let pending = !queried && (outcome == .delayed || outcome == .notFound)
        let state=pending ? "accepted" : outcome == .unknown ? "unknown" : outcome == .failed ? "failed" : "confirmed"
        let response=String(decoding:try JSONSerialization.data(withJSONObject:["ok":outcome != .rejected,"value":["state":"pending"]]),as:UTF8.self)
        let evidence:Any=state=="confirmed" ? ["type":"action_result","path":"link.exchange","input_digest":"sha256:"+String(repeating:"c",count:64),"output":["response":response],"completion":"submitted","observed_at":ISO8601DateFormatter().string(from:Date())] : NSNull()
        return ["command_id":"pairing-fixture","status":state,"request_digest":"sha256:"+String(repeating:"b",count:64),"request":original!,"error":NSNull(),"evidence":evidence]
    }
}

@MainActor func localPairingWorkbenchChecks()async throws {
    func check(_ condition:Bool,_ code:String)throws{if !condition{throw LinkError(code)}}
    func idle(_ model:WorkbenchModel)async throws {
        for _ in 0..<600{if !model.busy{return};try await Task.sleep(for:.milliseconds(10))}
        throw LinkError("pairing_workbench_timeout")
    }
    for outcome in PairingTransport.Outcome.allCases {
        let transport=PairingTransport(outcome),model=WorkbenchModel(store:PairingStore(),transport:transport)
        model.endpoint="https://gateway.example";model.token="fixture";model.connect();try await idle(model)
        model.space="chosen";model.refresh();try await idle(model)
        model.target="desktop";model.selectTarget();try await idle(model)
        model.action("pair");try await idle(model)
        let successful=outcome == .confirmed || outcome == .delayed
        try check(model.hasPending != successful,"pairing_receipt_retention:\(outcome)")
        try check(await transport.creates==1,"pairing_submitted_twice:\(outcome)")
        if !successful{
            model.action("card");try await idle(model)
            try check(await transport.creates==1 && model.hasPending,"unresolved_pair_did_not_block:\(outcome)")
        }else{
            model.action("card");try await idle(model)
            try check(await transport.creates==2 && model.hasPending,"unrelated_card_automatically_archived")
        }
    }
}
