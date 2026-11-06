#if os(macOS)
import Foundation
import Darwin

public struct LocalGatewayTools:Equatable,Sendable {
    public let docker:String
    public let compose:String?
    public init(docker:String,compose:String?=nil){self.docker=docker;self.compose=compose}
    public static func discover(environment:[String:String]=ProcessInfo.processInfo.environment)->Self? {
        let directories=(environment["PATH"] ?? "").split(separator:":").map(String.init)+["/opt/homebrew/bin","/usr/local/bin","/Applications/Docker.app/Contents/Resources/bin"]
        var seen=Set<String>()
        for directory in directories where directory.hasPrefix("/") && seen.insert(directory).inserted {
            let docker=URL(fileURLWithPath:directory).appendingPathComponent("docker").path
            guard let version=try? GatewayProcess.run(docker,["--version"],timeout:2),version.status==0,
                  String(decoding:version.data,as:UTF8.self).hasPrefix("Docker version ") else{continue}
            if let plugin=try? GatewayProcess.run(docker,["compose","version"],timeout:2),plugin.status==0{return Self(docker:docker)}
            for composeDirectory in directories where composeDirectory.hasPrefix("/") {
                let compose=URL(fileURLWithPath:composeDirectory).appendingPathComponent("docker-compose").path
                if let probe=try? GatewayProcess.run(compose,["version"],timeout:2),probe.status==0,
                   String(decoding:probe.data,as:UTF8.self).contains("Docker Compose version "){return Self(docker:docker,compose:compose)}
            }
        }
        return nil
    }
}

public struct LocalGatewayService:Decodable,Sendable,Identifiable {
    public let service:String
    public let state:String
    public let health:String?
    public var id:String{service}
}
public struct LocalGatewayReply:Decodable,Sendable {
    public let ok:Bool
    public let state:String?
    public let origin:String?
    public let platform:String?
    public let revision:String?
    public let distribution:String?
    public let runtimeConfiguration:String?
    public let services:[LocalGatewayService]?
    public let started:Bool?
    public let agentEnabled:Bool?
    public let systemTrustChanged:Bool?
}
public struct LocalGatewayFailure:Error,Sendable {
    public let code:String
    /// 命令可能已有副作用；调用方必须核实原目录，不得自动换目录重试。
    public let outcomeUnknown:Bool
    public init(_ code:String,outcomeUnknown:Bool=false){self.code=code;self.outcomeUnknown=outcomeUnknown}
}
public enum LocalGatewayCommand:Sendable {
    case inspect(bundle:URL)
    case initialize(bundle:URL,directory:URL,host:String,httpsPort:Int,mqttPort:Int)
    case status(directory:URL),start(directory:URL),stop(directory:URL)
    fileprivate var mutating:Bool {
        switch self{case .initialize,.start,.stop:return true;default:return false}
    }
}

/// 只负责有界的本机进程调用；包、身份、Docker Socket 与部署合同由 Rust 辅助程序校验。
public struct LocalGatewayDeployment:Sendable {
    public let helper:URL
    public init(helper:URL){self.helper=helper}
    public func execute(_ command:LocalGatewayCommand,tools:LocalGatewayTools?=nil,timeout:TimeInterval?=nil)throws->LocalGatewayReply {
        var arguments:[String]
        let budget:TimeInterval
        switch command {
        case .inspect(let bundle):arguments=["inspect","--bundle",try path(bundle)];budget=120
        case .initialize(let bundle,let directory,let host,let https,let mqtt):
            guard (1024...65535).contains(https),(1024...65535).contains(mqtt),https != mqtt else{throw LocalGatewayFailure("invalid_ports")}
            arguments=["initialize","--bundle",try path(bundle),"--directory",try path(directory),"--host",host,"--https-port",String(https),"--mqtt-port",String(mqtt)];budget=600
        case .status(let directory):arguments=["status","--directory",try path(directory)];budget=45
        case .start(let directory):arguments=["start","--directory",try path(directory)];budget=150
        case .stop(let directory):arguments=["stop","--directory",try path(directory)];budget=90
        }
        if case .inspect=command{}else{
            guard let tools else{throw LocalGatewayFailure("docker_compose_unavailable")}
            arguments += ["--docker",try path(URL(fileURLWithPath:tools.docker))]
            if let compose=tools.compose{arguments += ["--compose",try path(URL(fileURLWithPath:compose))]}
        }
        let result:GatewayProcess.Result
        do{result=try GatewayProcess.run(try path(helper),arguments,timeout:timeout ?? budget)}
        catch let failure as LocalGatewayFailure{throw LocalGatewayFailure(failure.code,outcomeUnknown:command.mutating && failure.outcomeUnknown)}
        if result.status != 0 {
            struct Failure:Decodable{let code:String}
            let code=(try? JSONDecoder().decode(Failure.self,from:result.data).code) ?? "deployment_failed"
            throw LocalGatewayFailure(code,outcomeUnknown:command.mutating)
        }
        let decoder=JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply=try? decoder.decode(LocalGatewayReply.self,from:result.data),reply.ok else{throw LocalGatewayFailure("invalid_helper_response",outcomeUnknown:command.mutating)}
        return reply
    }
    private func path(_ url:URL)throws->String {
        guard url.isFileURL,url.path.hasPrefix("/"),!url.path.contains("\0") else{throw LocalGatewayFailure("invalid_local_path")}
        return url.path
    }
    public static func privateAddresses()->[String] {
        var head:UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head)==0 else{return ["127.0.0.1"]}
        defer{freeifaddrs(head)}
        var addresses=Set<String>(),item=head
        while let current=item {
            defer{item=current.pointee.ifa_next}
            let interface=current.pointee
            guard (interface.ifa_flags & UInt32(IFF_UP)) != 0,let address=interface.ifa_addr,address.pointee.sa_family==UInt8(AF_INET) else{continue}
            var value=UnsafeRawPointer(address).assumingMemoryBound(to:sockaddr_in.self).pointee.sin_addr
            var buffer=[CChar](repeating:0,count:Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET,&value,&buffer,socklen_t(buffer.count)) != nil else{continue}
            let text=String(decoding:buffer.prefix{ $0 != 0 }.map{UInt8(bitPattern:$0)},as:UTF8.self),parts=text.split(separator:".").compactMap{Int($0)}
            if parts.count==4 && (parts[0]==10 || (parts[0]==172 && (16...31).contains(parts[1])) || (parts[0]==192 && parts[1]==168)){addresses.insert(text)}
        }
        return addresses.sorted()+["127.0.0.1"]
    }
}

enum GatewayProcess {
    struct Result{let status:Int32;let data:Data}
    static func run(_ path:String,_ arguments:[String],timeout:TimeInterval)throws->Result {
        let resolved=URL(fileURLWithPath:path).resolvingSymlinksInPath()
        guard path.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:resolved.path),
              (try? FileManager.default.attributesOfItem(atPath:resolved.path)[.type] as? FileAttributeType) == .typeRegular else{throw LocalGatewayFailure("deployment_executable_unavailable")}
        let process=Process(),output=Pipe()
        process.executableURL=resolved;process.arguments=arguments
        process.standardInput=FileHandle.nullDevice;process.standardOutput=output;process.standardError=output
        let descriptor=output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor,F_SETFL,O_NONBLOCK)==0 else{throw LocalGatewayFailure("deployment_pipe_unavailable")}
        defer{try? output.fileHandleForReading.close();try? output.fileHandleForWriting.close()}
        do{try process.run()}catch{throw LocalGatewayFailure("deployment_executable_unavailable")}
        let deadline=ProcessInfo.processInfo.systemUptime+max(0.05,timeout)
        var data=Data(),buffer=[UInt8](repeating:0,count:8192)
        func stop(){if process.isRunning{Darwin.kill(process.processIdentifier,SIGKILL)};process.waitUntilExit()}
        while true {
            let running=process.isRunning,count=Darwin.read(descriptor,&buffer,buffer.count)
            if count>0 {
                guard data.count+count<=65536 else{stop();throw LocalGatewayFailure("deployment_output_budget",outcomeUnknown:true)}
                data.append(contentsOf:buffer.prefix(count))
            }else if count<0 && errno != EAGAIN && errno != EINTR{stop();throw LocalGatewayFailure("deployment_read_failed",outcomeUnknown:true)}
            if count<=0 && !running{break}
            guard ProcessInfo.processInfo.systemUptime<deadline else{stop();throw LocalGatewayFailure("deployment_timeout",outcomeUnknown:true)}
            if count<=0{Thread.sleep(forTimeInterval:0.01)}
        }
        process.waitUntilExit();return Result(status:process.terminationStatus,data:data)
    }
}
#endif
