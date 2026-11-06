import Foundation
import Network
import LimeIoTKit

public struct RemoteGatewayProbeResult:Sendable,Identifiable {
    public let port:Int
    public let purpose:String
    public let reachable:Bool
    public let message:String
    public var id:Int{port}
}

public enum RemoteGatewayProbe {
    /// 只访问用户填写的 HTTPS 健康入口与设备 TCP 端口，不发送凭据或设备命令。
    public static func check(_ plan:RemoteGatewayPlan)async->[RemoteGatewayProbeResult] {
        async let https=checkHTTPS(plan)
        async let device=checkDevice(plan)
        return await [https,device]
    }
    private static func checkHTTPS(_ plan:RemoteGatewayPlan)async->RemoteGatewayProbeResult {
        let port=plan.ports[0],request=URLRequest(url:URL(string:plan.origin+"/healthz")!,timeoutInterval:10)
        let message:String,ok:Bool
        do{
            let(data,response)=try await URLSessionTransport().send(request)
            let health=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            ok=response.statusCode==200 && health?["status"] as? String=="ok" && health?["broker_connected"] as? Bool==true
            message=ok ? "连接正常" : "已响应，网关尚未就绪"
        }catch let error as URLError {
            ok=false
            switch error.code {
            case .serverCertificateUntrusted,.serverCertificateHasBadDate,.serverCertificateHasUnknownRoot,.serverCertificateNotYetValid,.secureConnectionFailed:message="证书或 TLS 校验失败"
            case .cannotFindHost,.dnsLookupFailed:message="域名尚未解析"
            case .cancelled:message="检查已取消"
            default:message="无法连接，请检查端口与防火墙"
            }
        }catch{ok=false;message="无法连接，请检查端口与防火墙"}
        return RemoteGatewayProbeResult(port:port.port,purpose:port.purpose,reachable:ok,message:message)
    }
    private static func checkDevice(_ plan:RemoteGatewayPlan)async->RemoteGatewayProbeResult {
        let port=plan.ports[1],ok=await TCPProbe(host:plan.host,port:port.port).run()
        return RemoteGatewayProbeResult(port:port.port,purpose:port.purpose,reachable:ok,message:ok ? "端口可达" : "无法连接，请检查监听与防火墙")
    }
}

/// 可取消、有超时的单端口连接，所有状态仅在私有串行队列读写。
private final class TCPProbe:@unchecked Sendable {
    private let queue=DispatchQueue(label:"run.limeai.link.remote-port")
    private let connection:NWConnection
    private var timer:DispatchSourceTimer?
    private var continuation:CheckedContinuation<Bool,Never>?
    private var cancelled=false
    init(host:String,port:Int){connection=NWConnection(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:UInt16(port))!,using:.tcp)}
    func run()async->Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation{continuation in
                queue.async{
                    guard !self.cancelled else{continuation.resume(returning:false);return}
                    self.continuation=continuation
                    self.connection.stateUpdateHandler={[weak self] state in
                        switch state{case .ready:self?.finish(true);case .failed,.cancelled:self?.finish(false);default:break}
                    }
                    let timer=DispatchSource.makeTimerSource(queue:self.queue)
                    timer.schedule(deadline:.now()+10);timer.setEventHandler{[weak self] in self?.finish(false)}
                    self.timer=timer;timer.resume();self.connection.start(queue:self.queue)
                }
            }
        } onCancel:{queue.async{self.cancelled=true;self.finish(false)}}
    }
    private func finish(_ reachable:Bool){
        guard let continuation else{return}
        self.continuation=nil;timer?.cancel();timer=nil;connection.stateUpdateHandler=nil;connection.cancel()
        continuation.resume(returning:reachable)
    }
}
