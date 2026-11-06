import Foundation

public struct LocalAgentWorkspace:Codable,Equatable,Identifiable,Sendable {
    public var id:String
    public var name:String
    public var path:String
    public var allowWrite:Bool
    enum CodingKeys:String,CodingKey{case id,name,path;case allowWrite="allow_write"}
    public init(id:String=UUID().uuidString.lowercased(),name:String="",path:String="",allowWrite:Bool=false){self.id=id;self.name=name;self.path=path;self.allowWrite=allowWrite}
    public init(from decoder:Decoder)throws{
        let fields=try decoder.container(keyedBy:CodingKeys.self)
        id=try fields.decode(String.self,forKey:.id);name=try fields.decode(String.self,forKey:.name);path=try fields.decode(String.self,forKey:.path);allowWrite=try fields.decodeIfPresent(Bool.self,forKey:.allowWrite) ?? false
    }
}
public struct LocalAgentConfiguration:Codable,Equatable,Sendable {
    public var executable:String
    public var workspaces:[LocalAgentWorkspace]
    public var timeoutSeconds:Int
    public var allowIoTTools:Bool
    enum CodingKeys:String,CodingKey{case executable,workspaces;case timeoutSeconds="timeout_seconds";case allowIoTTools="allow_iot_tools"}
    public init(executable:String="",workspaces:[LocalAgentWorkspace]=[],timeoutSeconds:Int=600,allowIoTTools:Bool=false){self.executable=executable;self.workspaces=workspaces;self.timeoutSeconds=timeoutSeconds;self.allowIoTTools=allowIoTTools}
    public init(from decoder:Decoder)throws{
        let fields=try decoder.container(keyedBy:CodingKeys.self)
        executable=try fields.decode(String.self,forKey:.executable);workspaces=try fields.decode([LocalAgentWorkspace].self,forKey:.workspaces);timeoutSeconds=try fields.decodeIfPresent(Int.self,forKey:.timeoutSeconds) ?? 600;allowIoTTools=try fields.decodeIfPresent(Bool.self,forKey:.allowIoTTools) ?? false
    }
    public func validated()throws->Self{
        let files=FileManager.default
        func absolute(_ path:String)->Bool{path.hasPrefix("/") && !path.contains("\0")}
        guard absolute(executable),files.isExecutableFile(atPath:executable),
              (30...1800).contains(timeoutSeconds),(1...8).contains(workspaces.count) else{throw LinkError("invalid_local_agent_configuration")}
        var result=self
        result.executable=URL(fileURLWithPath:executable).resolvingSymlinksInPath().path
        let executableType=try files.attributesOfItem(atPath:result.executable)[.type] as? FileAttributeType
        guard executableType == .typeRegular else{throw LinkError("agent_executable_unavailable")}
        var ids=Set<String>()
        for index in result.workspaces.indices{
            let item=result.workspaces[index]
            guard (1...64).contains(item.id.utf8.count),item.id.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==45 || $0==95}),ids.insert(item.id).inserted,
                  !item.name.isEmpty,item.name.utf8.count<=64,!item.name.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}),absolute(item.path) else{throw LinkError("invalid_local_agent_workspace")}
            let path=URL(fileURLWithPath:item.path).resolvingSymlinksInPath().path
            var directory:ObjCBool=false
            guard files.fileExists(atPath:path,isDirectory:&directory),directory.boolValue else{throw LinkError("agent_workspace_unavailable")}
            result.workspaces[index].path=path
        }
        return result
    }
}

#if os(macOS)
import Darwin

/// 仅修改当前设备配置的 Agent 字段；设备身份和连接参数保持原值。
public struct LocalRuntimeConfigurationDocument {
    public let url:URL
    public let agent:LocalAgentConfiguration?
    private let original:Data
    private let fields:[String:Any]
    public init(contentsOf url:URL)throws{
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value==geteuid(),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max)<=65536 else{throw LinkError("runtime_configuration_not_editable")}
        let bytes=try Data(contentsOf:url)
        guard bytes.count<=65536,let fields=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              fields["mqtt_host"] is String,fields["mqtt_port"] is NSNumber,fields["space"] is String,fields["device"] is String,fields["model_revision"] is String,fields["database"] is String else{throw LinkError("invalid_runtime_configuration")}
        self.url=url;original=bytes;self.fields=fields
        if let value=fields["agent"],!(value is NSNull){
            guard let object=value as? [String:Any],Set(object.keys).isSubset(of:["executable","workspaces","timeout_seconds","allow_iot_tools"]),
                  let workspaces=object["workspaces"] as? [[String:Any]],workspaces.allSatisfy({Set($0.keys).isSubset(of:["id","name","path","allow_write"])}) else{throw LinkError("runtime_configuration_not_editable")}
            agent=try JSONDecoder().decode(LocalAgentConfiguration.self,from:JSONSerialization.data(withJSONObject:value))
        }else{agent=nil}
    }
    public func save(agent configuration:LocalAgentConfiguration?)throws{
        let validated=try configuration?.validated()
        var result=fields
        if let validated{result["agent"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(validated))}else{result.removeValue(forKey:"agent")}
        let output=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        guard output.count<=65536 else{throw LinkError("runtime_configuration_too_large")}
        try unchanged()
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".limelink-config-\(UUID().uuidString).tmp")
        let descriptor=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard descriptor>=0 else{throw LinkError("runtime_configuration_save_failed")}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer{try? handle.close();try? FileManager.default.removeItem(at:temporary)}
        try handle.write(contentsOf:output);try handle.synchronize();try handle.close()
        try unchanged()
        guard Darwin.rename(temporary.path,url.path)==0 else{throw LinkError("runtime_configuration_save_failed")}
    }
    private func unchanged()throws{
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value==geteuid(),
              try Data(contentsOf:url)==original else{throw LinkError("runtime_configuration_changed")}
    }
}
#endif
