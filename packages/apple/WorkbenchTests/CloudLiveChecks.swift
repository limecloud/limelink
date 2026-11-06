import Foundation
import CryptoKit
import Security
import LimeIoTKit
import LimeLinkCore
import LimeLinkUI

// 仅测试使用独立 CA，保留证书期限与精确主机名校验，不更改系统信任。
private final class LiveTrust:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    let certificate:SecCertificate
    let host:String
    init(certificate:SecCertificate,host:String){self.certificate=certificate;self.host=host}
    func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping @Sendable (URLSession.AuthChallengeDisposition,URLCredential?)->Void){
        guard challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host==host,let trust=challenge.protectionSpace.serverTrust,
              SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,host as CFString))==errSecSuccess,
              SecTrustSetAnchorCertificates(trust,[certificate] as CFArray)==errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust,true)==errSecSuccess,SecTrustEvaluateWithError(trust,nil) else{completionHandler(.cancelAuthenticationChallenge,nil);return}
        completionHandler(.useCredential,URLCredential(trust:trust))
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping @Sendable (URLRequest?)->Void){completionHandler(nil)}
}
private struct LiveTransport:HTTPTransport {
    let session:URLSession
    init(origin:String,caFile:String)throws {
        let pem=try String(contentsOfFile:caFile,encoding:.utf8).components(separatedBy:.newlines).filter{!$0.hasPrefix("-----")}.joined()
        guard let der=Data(base64Encoded:pem),let certificate=SecCertificateCreateWithData(nil,der as CFData),let host=URLComponents(string:origin)?.host else{throw LinkError("live_fixture_certificate_invalid")}
        let config=URLSessionConfiguration.ephemeral;config.httpShouldSetCookies=false;config.httpCookieStorage=nil;config.urlCache=nil;config.timeoutIntervalForRequest=12
        session=URLSession(configuration:config,delegate:LiveTrust(certificate:certificate,host:host),delegateQueue:nil)
    }
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse){let(data,response)=try await session.data(for:request);guard let response=response as? HTTPURLResponse else{throw ControlError.invalidResponse};return(data,response)}
}
private actor LiveStore:SessionStore {
    let directory:URL
    init(_ directory:URL){self.directory=directory}
    func path(_ origin:String)->URL {directory.appendingPathComponent(SHA256.hash(data:Data(origin.utf8)).map{String(format:"%02x",$0)}.joined()+".json")}
    func load(origin:String)throws->Data?{let file=path(origin);return FileManager.default.fileExists(atPath:file.path) ? try Data(contentsOf:file) : nil}
    func save(origin:String,data:Data?)throws{
        guard let data else{throw LinkError("unexpected_live_store_delete")}
        let file=path(origin);try data.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let handle=try FileHandle(forWritingTo:file);defer{try? handle.close()};try handle.synchronize()
    }
}

@MainActor func cloudLiveWorkbenchChecks()async throws {
    let env=ProcessInfo.processInfo.environment
    guard let origin=env["LIMEIOT_TEST_CONTROL_ORIGIN"],origin.hasPrefix("https://"),let ca=env["LIMEIOT_TEST_CONTROL_CA_FILE"],let path=env["LIMELINK_CLOUD_WORKBENCH_DIRECTORY"],let space=env["LIMELINK_CLOUD_WORKBENCH_SPACE"] else{throw LinkError("live_fixture_missing")}
    let directory=URL(fileURLWithPath:path),store=LiveStore(directory),transport=try LiveTransport(origin:origin,caFile:ca)
    func check(_ condition:Bool,_ code:String)throws{if !condition{throw LinkError(code)}}
    func idle(_ model:WorkbenchModel)async throws {for _ in 0..<2000{if !model.busy{return};try await Task.sleep(for:.milliseconds(10))};throw LinkError("live_workbench_busy_timeout")}
    func marker(_ name:String)throws{try Data(name.utf8).write(to:directory.appendingPathComponent(name),options:.atomic)}
    func wait(_ name:String)async throws {for _ in 0..<900{if FileManager.default.fileExists(atPath:directory.appendingPathComponent(name).path){return};try await Task.sleep(for:.milliseconds(100))};throw LinkError("live_workbench_marker_timeout_"+name)}
    func model()->WorkbenchModel {let value=WorkbenchModel(store:store,transport:transport);value.cloudMode=true;value.cloudEndpoint=origin;return value}
    func terminal(_ value:WorkbenchModel)async throws->ControlCommandRecord {
        for _ in 0..<30{
            if let record=value.cloudRecords.first(where:{$0.id==value.recordKey}),record.result?.status.terminal==true{return record}
            value.resolve(reconcile:true);try await idle(value);try await Task.sleep(for:.milliseconds(200))
        }
        throw LinkError("live_workbench_terminal_timeout_"+value.result)
    }
    let untrusted=try ControlClient(endpoint:origin,store:store)
    do{_=try await untrusted.beginAuthorization(platform:"macos");throw LinkError("untrusted_fixture_ca_accepted")}catch is URLError{}
    let current=model();current.beginCloud();try await idle(current)
    guard let login=current.authorization else{throw LinkError("live_authorization_missing_"+current.result)}
    let encoder=JSONEncoder();encoder.keyEncodingStrategy = .convertToSnakeCase
    let loginFile=directory.appendingPathComponent("login.json");try encoder.encode(login).write(to:loginFile,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:loginFile.path)
    try await wait("approved");try await Task.sleep(for:.seconds(3));current.pollCloud();try await idle(current)
    try check(!current.principal.isEmpty && current.spaces.contains(space),"real_authorization_not_restored_"+current.result)
    current.space=space;current.refresh();try await idle(current);current.target="device-lamp";current.selectTarget();try await idle(current)
    try check(!current.fingerprint.isEmpty && !current.gateway.isEmpty,"real_gateway_target_missing_"+current.result)
    try Data(current.fingerprint.utf8).write(to:directory.appendingPathComponent("fingerprint.txt"),options:.atomic)
    current.name="真实云工作台模型夹具";current.action("pair");try await idle(current)
    let paired=try await terminal(current)
    guard case .object(let pairResponse)=try CloudLinkClient.response(paired),case .object(let peer)=pairResponse["value"],peer["state"] == .string("pending") else{throw LinkError("real_product_pair_not_pending")}
    try marker("pair-waiting");try await wait("paired")
    current.action("status");try await idle(current);let status=try await terminal(current)
    guard case .object(let statusResponse)=try CloudLinkClient.response(status),case .object(let statusValue)=statusResponse["value"],statusValue["state"] == .string("approved") else{throw LinkError("real_product_approval_missing")}
    current.text="工作台 HTTPS → WSS → MQTT/mTLS：响应丢失后保留原卡片。";try marker("ready-to-send");try await wait("send")
    current.action("card");try await idle(current)
    guard let original=current.cloudRecords.last(where:{$0.reference.request.operation.value.objectKind=="card"}) else{throw LinkError("real_unknown_record_missing")}
    try check(original.attempted && original.result==nil && current.hasPending,"real_lost_response_not_unknown")
    try marker("unknown");try await wait("recover")
    let recovered=model();recovered.restoreCloud();try await idle(recovered)
    try check(recovered.devices.isEmpty && recovered.target.isEmpty,"restore_silently_selected_target")
    recovered.recordKey=original.id;let result=try await terminal(recovered)
    try check(result.reference==original.reference && result.result?.status == .confirmed,"real_original_record_changed")
    guard case .object(let cardResponse)=try CloudLinkClient.response(result),cardResponse["ok"] == .bool(true) else{throw LinkError("real_card_not_confirmed")}
    try check(recovered.text.isEmpty && recovered.sessionID.isEmpty,"old_result_overwrote_unselected_projection")
    recovered.finish();try await idle(recovered);try check(!recovered.cloudRecords.contains(where:{$0.id==original.id}),"real_terminal_forget_failed")
    recovered.logout();try await idle(recovered);let signedOut=model();signedOut.restoreCloud();try await idle(signedOut)
    try check(signedOut.principal.isEmpty && signedOut.cloudRecords.isEmpty,"real_logged_out_records_exposed")
    try marker("finished")
    print("{\"passed\":true,\"real_https\":true,\"real_workbench_model\":true,\"browser_approval\":true,\"untrusted_ca_rejected\":true,\"original_recovery_after_restart\":true,\"native_window\":false,\"physical_phone\":false}")
}
private extension JSONValue {
    var objectKind:String?{guard case .object(let fields)=self,case .string(let kind)=fields["kind"] else{return nil};return kind}
}
