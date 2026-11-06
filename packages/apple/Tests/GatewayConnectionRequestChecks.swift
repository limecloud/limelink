import Foundation
import LimeLinkCore

func gatewayConnectionRequestChecks()throws{
    struct Case:Decodable{let url:String;let origin:String?}
    let cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:"contracts/fixtures/gateway-connection-links.json")))
    for test in cases{
        let request:GatewayConnectionRequest?
        do{request=try GatewayConnectionRequest(url:URL(string:test.url)!)}catch{request=nil}
        guard request?.origin==test.origin else{throw LinkError("gateway_connection_vector_mismatch")}
        if let request{guard try GatewayConnectionRequest(url:request.url)==request else{throw LinkError("gateway_connection_roundtrip")}}
    }
    do{_=try GatewayConnectionRequest(origin:"https://"+String(repeating:"a",count:1100)+".example");throw LinkError("oversized_gateway_connection_accepted")}catch let error as LinkError{guard error.code=="invalid_gateway_connection_request" else{throw error}}
}
