import Foundation
import CryptoKit
import LimeIoTKit
import LimeLinkCore
import LimeLinkUI

private actor MemoryStore:SessionStore {
    var values:[String:Data]=[:]
    func load(origin:String)->Data?{values[origin]}
    func save(origin:String,data:Data?){values[origin]=data}
}
private actor WorkbenchTransport:HTTPTransport {
    let origin="https://control.example"
    let token=String(repeating:"c",count:64),authorization="na-"+String(repeating:"b",count:64),revision="sha256:"+String(repeating:"a",count:64)
    let expiry=ISO8601DateFormatter().string(from:Date().addingTimeInterval(240))
    let sessionExpiry=ISO8601DateFormatter().string(from:Date().addingTimeInterval(3500))
    var creates=0,queries=0,polls=0
    var original:[String:Any]?
    var pauseSpaces=false,waiting=false
    var spacesContinuation:CheckedContinuation<Void,Never>?
    func holdSpaces(){pauseSpaces=true}
    func releaseSpaces(){pauseSpaces=false;spacesContinuation?.resume();spacesContinuation=nil}
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse) {
        let route=request.url!.path
        var status=200,body:[String:Any]=[:]
        if route=="/api/native/v1/authorizations" {
            body=["authorization_id":authorization,"user_code":"ABCDEF12","verification_uri":origin+"/console/?native="+authorization,"expires_at":expiry,"interval_seconds":3,"status":"pending"]
        }else if route.hasSuffix("/authorizations/poll") {
            polls += 1
            body=["status":"approved","expires_at":expiry,"material":["version":1,"origin":origin,"audience":"console","session":token,"principal_id":"owner","expires_at":sessionExpiry]]
        }else if route.hasSuffix("/authorizations/cancel"){body=["status":"cancelled"]}
        else if route.hasSuffix("/auth/session") {
            let hash=SHA256.hash(data:Data(("limeiot-csrf:console:"+token).utf8)).map{String(format:"%02x",$0)}.joined()
            body=["audience":"console","principal":["principal_id":"owner","name":"测试账号"],"csrf_token":hash,"expires_at":sessionExpiry]
        }else if route.hasSuffix("/spaces") {
            if pauseSpaces{waiting=true;await withCheckedContinuation{spacesContinuation=$0};waiting=false}
            body=["spaces":[["space_id":"cloud-space","name":"空间一"],["space_id":"other-space","name":"空间二"]]]
        }else if route.hasSuffix("/gateways") {
            body=["gateways":[["gateway_id":"gateway-a","space_id":route.components(separatedBy:"/")[5],"local_space_id":"local-space","principal_id":"owner","scopes":["devices.read","commands.write"],"revision":"binding-a","active":true]]]
        }else if route.hasSuffix("/devices") {
            body=["items":[["device_id":"desktop","model_revision":revision,"ready":true,"reported":[:]]],"next":NSNull(),"binding_revision":"binding-a"]
        }else if route.contains("/model-releases/"){body=["revision":revision,"model":["model_id":"urn:limelink:model:desktop:1","services":[]]]}
        else if route.hasSuffix("/remote-commands")&&request.httpMethod=="POST" {
            creates += 1;original=try JSONSerialization.jsonObject(with:request.httpBody!) as? [String:Any];throw URLError(.timedOut)
        }else if route.contains("/remote-commands/by-key/") {
            queries += 1
            if queries==1{status=404;body=["error":["code":"not_found"]]}
            else{body=["remote_id":"remote-"+String(repeating:"d",count:64),"space_id":"cloud-space","principal_id":"owner","local_space_id":"local-space","request_digest":String(repeating:"e",count:64),"request":original!,"status":"unknown","local_result":NSNull()]}
        }else{throw LinkError("unexpected_workbench_fixture_route")}
        return(try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
    }
}
@main private enum WorkbenchChecks {
    @MainActor static func main()async throws {
        func check(_ value:Bool,_ message:String)throws{if !value{throw LinkError(message)}}
        func idle(_ model:WorkbenchModel)async throws {
            for _ in 0..<500{if !model.busy{return};try await Task.sleep(for:.milliseconds(10))}
            throw LinkError("workbench_timeout")
        }
        let authStore=MemoryStore(),authTransport=WorkbenchTransport()
        let auth=WorkbenchModel(store:authStore,transport:authTransport);auth.cloudMode=true;auth.cloudEndpoint="https://control.example"
        auth.beginCloud();try await idle(auth);try check(auth.authorization?.userCode=="ABCDEF12","authorization_not_presented")
        auth.pollCloud();try await idle(auth);try check(await authTransport.polls==0,"authorization_interval_bypassed")
        auth.pause();try check(auth.authorization==nil,"authorization_survived_pause")
        auth.beginCloud();try await idle(auth);try check(auth.authorization != nil,"original_proof_not_resumed")
        auth.cancelCloud();try await idle(auth);try check(auth.authorization==nil,"authorization_cancel_not_cleared")

        let store=MemoryStore(),transport=WorkbenchTransport()
        let seed=try CloudLinkClient(endpoint:"https://control.example",store:store,transport:transport)
        _=try await seed.control.beginAuthorization(platform:"macos");_=try await seed.control.pollAuthorization()
        let model=WorkbenchModel(store:store,transport:transport);model.cloudMode=true;model.cloudEndpoint="https://control.example"
        model.restoreCloud();try await idle(model);try check(model.spaces.count==2 && !model.principal.isEmpty,"restore_failed")
        model.space="cloud-space";model.refresh();try await idle(model);model.target="desktop";model.selectTarget();try await idle(model)
        try check(!model.fingerprint.isEmpty && !model.gateway.isEmpty,"target_not_bound")
        model.action("pair");try await idle(model);try check(model.hasPending && model.cloudRecords.count==1,"lost_response_record_missing")
        let key=model.cloudRecords[0].id;model.space="other-space";model.recordKey=key
        try check(model.target.isEmpty && model.gateway.isEmpty && model.sessionID.isEmpty,"space_changed_old_projection")
        model.resolve();try await idle(model);model.resolve();try await idle(model)
        try check(await transport.queries==2,"original_record_not_queried")
        model.finish();try await idle(model);try check(model.cloudRecords.count==1,"unknown_record_forgotten")
        model.refresh();try await idle(model);model.target="desktop";model.selectTarget();try await idle(model);model.action("pair");try await idle(model)
        try check(await transport.creates==1,"new_post_after_unknown")
        model.cloudMode=false;try check(model.cloudRecords.isEmpty && model.target.isEmpty && model.principal.isEmpty,"route_changed_old_identity")

        let late=WorkbenchModel(store:store,transport:transport);late.cloudMode=true;late.cloudEndpoint="https://control.example"
        await transport.holdSpaces();late.restoreCloud()
        for _ in 0..<500{if await transport.waiting{break};try await Task.sleep(for:.milliseconds(10))}
        try check(await transport.waiting,"delayed_fixture_not_reached")
        late.pause();await transport.releaseSpaces();try await idle(late)
        try check(late.spaces.isEmpty && late.principal.isEmpty && late.devices.isEmpty,"late_result_restored_view")
        print("{\"passed\":true,\"groups\":7,\"authorization_interval\":true,\"proof_resume_cancel\":true,\"cloud_selection\":true,\"original_recovery\":true,\"unknown_blocks_submit\":true,\"route_isolation\":true,\"late_response_cancel\":true,\"native_window\":false}")
    }
}
