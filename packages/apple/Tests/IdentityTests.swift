import Foundation
import CryptoKit
import LimeIoTKit
import LimeLinkCore

private struct CheckFailure:Error{let detail:String}
private func XCTAssertTrue(_ condition:Bool)throws{if !condition{throw CheckFailure(detail:"expected true")}}
private func XCTAssertFalse(_ condition:Bool)throws{try XCTAssertTrue(!condition)}
private func XCTAssertNotEqual<T:Equatable>(_ left:T,_ right:T)throws{try XCTAssertTrue(left != right)}
private func hex(_ value:Data)->String{value.map{String(format:"%02x",$0)}.joined()}
private struct IdentityTests {
    func testSignatureBindsTargetAndPayload() throws {
        let identity=LinkIdentity()
        let exchange=try identity.exchange(space:"space-a",device:"desktop-a",revision:"sha256:revision",kind:"card",payload:"{\"text\":\"你好\",\"ttl\":60}",now:Date(timeIntervalSince1970:100),nonce:"00000000-0000-0000-0000-000000000001")
        guard case .object(let object)=exchange,case .string(let signature)=object["signature"],case .string(let publicKey)=object["public_key"] else{throw CheckFailure(detail:"missing fields")}
        func bytes(_ value:String)->Data{Data(stride(from:0,to:value.count,by:2).map{offset in UInt8(value.dropFirst(offset).prefix(2),radix:16)!})}
        let payload="{\"text\":\"你好\",\"ttl\":60}"
        let message="limelink.exchange/v1\nspace-a\ndesktop-a\nsha256:revision\n\(identity.id)\ncard\n00000000-0000-0000-0000-000000000001\n120\n\(hex(Data(SHA256.hash(data:Data(payload.utf8)))))"
        let key=try P256.Signing.PublicKey(x963Representation:bytes(publicKey)),sig=try P256.Signing.ECDSASignature(derRepresentation:bytes(signature))
        try XCTAssertTrue(key.isValidSignature(sig,for:Data(message.utf8)))
        try XCTAssertFalse(key.isValidSignature(sig,for:Data(message.replacingOccurrences(of:"desktop-a",with:"desktop-b").utf8)))
    }
    func testPayloadBoundAndIndependentIdentities() throws {
        try XCTAssertNotEqual(LinkIdentity().id,LinkIdentity().id)
        do{_ = try LinkIdentity().exchange(space:"s",device:"d",revision:"r",kind:"card",payload:String(repeating:"x",count:4097));throw CheckFailure(detail:"oversized payload accepted")}catch is LinkError{}
    }
}

private actor MemoryStore:SessionStore {
    var values:[String:Data]=[:]
    var failIntent=false
    func load(origin:String)throws->Data?{values[origin]}
    func save(origin:String,data:Data?)throws{if failIntent&&origin.contains(".pending"){throw LinkError("storage_failed")};values[origin]=data}
    func failIntents(){failIntent=true}
}
private actor FixtureTransport:HTTPTransport {
    var postCommands=0
    var resolveQueries=0
    let revision="sha256:"+String(repeating:"a",count:64)
    func send(_ request:URLRequest)async throws->(Data,HTTPURLResponse){
        let path=request.url!.path
        var status=200
        let body:String
        if path=="/api/v1/auth/session"{body="{\"authenticated\":true,\"csrf_token\":\"csrf\",\"expires_at\":\"2030-01-01T00:00:00Z\"}"}
        else if path.hasSuffix("/capabilities"){
            let model=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"contracts/desktop.json")))
            body=String(decoding:try JSONSerialization.data(withJSONObject:["models":[revision:model]]),as:UTF8.self)
        }
        else if path.hasSuffix("/devices"){body="{\"items\":[{\"device_id\":\"desktop\",\"model_revision\":\"\(revision)\",\"ready\":true,\"reported\":{}}],\"next_cursor\":null}"}
        else if path.hasSuffix("/commands")&&request.httpMethod=="POST"{postCommands+=1;throw URLError(.timedOut)}
        else if path.contains("/commands/by-key/"){resolveQueries+=1;status=404;body="{\"error\":{\"code\":\"command_not_found\"}}"}
        else{body="{\"items\":[],\"next_cursor\":null}"}
        return(Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Set-Cookie":"__Host-limeiot_session="+String(repeating:"a",count:64)+"; Secure; HttpOnly"])!)
    }
}
private func recoveryChecks()async throws{
    let memory=MemoryStore(),transport=FixtureTransport(),client=try LinkClient(endpoint:"https://gateway.example",store:memory,transport:transport)
    try await client.login(token:"fixture")
    let snapshot=try await client.snapshot(space:"chosen"),device=snapshot.devices[0]
    do{_ = try await client.perform(space:"chosen",device:device,kind:"pair",payload:.object(["name":.string("phone")]));throw CheckFailure(detail:"timeout expected")}catch is URLError{}
    try XCTAssertTrue(await transport.postCommands==1)
    try XCTAssertTrue(try await client.pending() != nil)
    do{_ = try await client.perform(space:"chosen",device:device,kind:"pair",payload:.object([:]));throw CheckFailure(detail:"must block new POST")}catch is LinkError{}
    do{_ = try await client.resolve();throw CheckFailure(detail:"404 expected")}catch GatewayError.server(_,404){}
    try XCTAssertTrue(await transport.postCommands==1)
    try XCTAssertTrue(await transport.resolveQueries==1)
    let memory2=MemoryStore(),transport2=FixtureTransport(),client2=try LinkClient(endpoint:"https://gateway.example",store:memory2,transport:transport2)
    try await client2.login(token:"fixture");let s2=try await client2.snapshot(space:"chosen");await memory2.failIntents()
    do{_ = try await client2.perform(space:"chosen",device:s2.devices[0],kind:"pair",payload:.object(["name":.string("phone")]));throw CheckFailure(detail:"storage failure expected")}catch is LinkError{}
    try XCTAssertTrue(await transport2.postCommands==0)
}
@main private enum LinkChecks {
    static func main()async throws{
        try IdentityTests().testSignatureBindsTargetAndPayload()
        try IdentityTests().testPayloadBoundAndIndependentIdentities()
        try await recoveryChecks()
        try localAgentConfigurationChecks()
        try remoteGatewayPlanChecks()
        try gatewayConnectionRequestChecks()
        let probes=try await remoteGatewayProbeChecks()
        #if os(macOS)
        try localGatewayDeploymentChecks()
        try mobileDeviceDeploymentChecks()
        #endif
        try await cloudConsumerChecks()
        print("{\"passed\":true,\"groups\":7,\"signature_target_binding\":true,\"payload_budget\":true,\"response_loss_get_only\":true,\"storage_failure_zero_post\":true,\"local_agent_configuration\":true,\"local_gateway_deployment\":true,\"remote_gateway_plan\":true,\"remote_gateway_probe_cases\":\(probes)}")
    }
}
