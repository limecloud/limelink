#if os(macOS)
import Foundation
import Darwin

public struct DiscoveredCodex:Equatable,Sendable {
    public let path:String
    public let version:String
}

/// 只运行本机程序的版本和帮助命令；不启动模型或读取认证资料。
public enum CodexExecutableDiscovery {
    public static func find(candidates:[String],probeTimeout:TimeInterval=2)->DiscoveredCodex? {
        var seen=Set<String>(),probed=0
        for candidate in candidates where candidate.hasPrefix("/") && !candidate.contains("\0") {
            let path=URL(fileURLWithPath:candidate).resolvingSymlinksInPath().path
            guard seen.insert(path).inserted,FileManager.default.isExecutableFile(atPath:path),
                  (try? FileManager.default.attributesOfItem(atPath:path)[.type] as? FileAttributeType) == .typeRegular else{continue}
            guard probed<8 else{break};probed += 1
            guard let output=probe(path,arguments:["--version"],timeout:probeTimeout),
                  let version=compatibleVersion(output),
                  let help=probe(path,arguments:["app-server","--help"],timeout:probeTimeout),
                  help.contains("codex app-server"),help.contains("generate-json-schema") else{continue}
            return DiscoveredCodex(path:path,version:version)
        }
        return nil
    }
    private static func compatibleVersion(_ output:String)->String? {
        let fields=output.split(whereSeparator:{$0.isWhitespace})
        guard fields.count==2,fields[0]=="codex-cli" else{return nil}
        let parts=fields[1].split(separator:".",omittingEmptySubsequences:false)
        guard parts.count==3,parts.allSatisfy({!$0.isEmpty && $0.utf8.allSatisfy({(48...57).contains($0)})}),
              let major=Int(parts[0]),let minor=Int(parts[1]),Int(parts[2]) != nil,
              major>0 || minor>=166 else{return nil}
        return String(fields[1])
    }
    private static func probe(_ path:String,arguments:[String],timeout:TimeInterval)->String? {
        let process=Process(),output=Pipe()
        process.executableURL=URL(fileURLWithPath:path);process.arguments=arguments
        process.standardInput=FileHandle.nullDevice;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        let descriptor=output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor,F_SETFL,O_NONBLOCK)==0 else{return nil}
        defer{try? output.fileHandleForReading.close();try? output.fileHandleForWriting.close()}
        do{try process.run()}catch{return nil}
        let deadline=ProcessInfo.processInfo.systemUptime+max(0.05,min(timeout,5))
        var bytes=Data(),buffer=[UInt8](repeating:0,count:4096)
        while true {
            // 先观察退出状态，再排空管道，避免命令在读取后退出导致遗漏最后一段输出。
            let running=process.isRunning
            let count=Darwin.read(descriptor,&buffer,buffer.count)
            if count>0 {
                guard bytes.count+count<=16384 else{stop(process);return nil}
                bytes.append(contentsOf:buffer.prefix(count))
            }else if count<0 && errno != EAGAIN && errno != EINTR{stop(process);return nil}
            if count<=0 && !running{break}
            guard ProcessInfo.processInfo.systemUptime<deadline else{stop(process);return nil}
            if count<=0{Thread.sleep(forTimeInterval:0.01)}
        }
        process.waitUntilExit()
        guard process.terminationStatus==0 else{return nil}
        return String(data:bytes,encoding:.utf8)
    }
    private static func stop(_ process:Process){
        if process.isRunning{Darwin.kill(process.processIdentifier,SIGKILL)}
        process.waitUntilExit()
    }
}
#endif
