using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace LimeLink.Core;

public sealed record LocalAgentWorkspace(
    [property:JsonPropertyName("id")] string Id,
    [property:JsonPropertyName("name")] string Name,
    [property:JsonPropertyName("path")] string Path,
    [property:JsonPropertyName("allow_write")] bool AllowWrite=false);

public sealed record LocalAgentConfiguration(
    [property:JsonPropertyName("executable")] string Executable,
    [property:JsonPropertyName("workspaces")] IReadOnlyList<LocalAgentWorkspace> Workspaces,
    [property:JsonPropertyName("timeout_seconds")] int TimeoutSeconds=600,
    [property:JsonPropertyName("allow_iot_tools")] bool AllowIoTTools=false) {
    public LocalAgentConfiguration Validated(){
        if(TimeoutSeconds is <30 or >1800||Workspaces is null||Workspaces.Count is <1 or >8)throw new InvalidOperationException("invalid_local_agent_configuration");
        var executable=CanonicalPath(Executable,false);
        if(OperatingSystem.IsWindows()){
            // 运行时直接启动原生程序，不通过 cmd/PowerShell 执行 npm 包装脚本。
            if(!executable.EndsWith(".exe",StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("agent_executable_unavailable");
        }else if((File.GetUnixFileMode(executable)&(UnixFileMode.UserExecute|UnixFileMode.GroupExecute|UnixFileMode.OtherExecute))==0)throw new InvalidOperationException("agent_executable_unavailable");
        var ids=new HashSet<string>(StringComparer.Ordinal);var workspaces=new List<LocalAgentWorkspace>();
        foreach(var item in Workspaces){
            if(item is null||string.IsNullOrEmpty(item.Id)||item.Id.Length>64||!item.Id.All(c=>char.IsAsciiLetterOrDigit(c)||c is '-' or '_')||!ids.Add(item.Id)||
               string.IsNullOrEmpty(item.Name)||Encoding.UTF8.GetByteCount(item.Name)>64||item.Name.Any(c=>c<32||c==127))throw new InvalidOperationException("invalid_local_agent_workspace");
            workspaces.Add(item with{Path=CanonicalPath(item.Path,true)});
        }
        return this with{Executable=executable,Workspaces=workspaces};
    }
    internal static string CanonicalPath(string path,bool directory){
        if(string.IsNullOrEmpty(path)||path.Contains('\0')||!System.IO.Path.IsPathFullyQualified(path))throw new InvalidOperationException(directory?"agent_workspace_unavailable":"agent_executable_unavailable");
        var full=System.IO.Path.GetFullPath(path);
        FileSystemInfo info=directory?new DirectoryInfo(full):new FileInfo(full);
        if(!info.Exists)throw new InvalidOperationException(directory?"agent_workspace_unavailable":"agent_executable_unavailable");
        var parent=System.IO.Path.GetDirectoryName(full);
        if(parent is not null&&parent!=full){full=System.IO.Path.Combine(CanonicalDirectory(parent,0),System.IO.Path.GetFileName(full));info=directory?new DirectoryInfo(full):new FileInfo(full);}
        if((info.Attributes&FileAttributes.ReparsePoint)!=0){var target=info.ResolveLinkTarget(true)??throw new InvalidOperationException("agent_path_unavailable");return CanonicalPath(target.FullName,directory);}
        if(((info.Attributes&FileAttributes.Directory)!=0)!=directory)throw new InvalidOperationException(directory?"agent_workspace_unavailable":"agent_executable_unavailable");
        return info.FullName;
    }
    private static string CanonicalDirectory(string path,int depth){
        if(depth>128)throw new InvalidOperationException("agent_path_unavailable");
        var info=new DirectoryInfo(path);if(!info.Exists)throw new InvalidOperationException("agent_workspace_unavailable");
        if(info.Parent is not null)info=new DirectoryInfo(System.IO.Path.Combine(CanonicalDirectory(info.Parent.FullName,depth+1),info.Name));
        if((info.Attributes&FileAttributes.ReparsePoint)!=0){var target=(info.ResolveLinkTarget(true) as DirectoryInfo)??throw new InvalidOperationException("agent_workspace_unavailable");return CanonicalDirectory(target.FullName,depth+1);}
        return info.FullName;
    }
}

/// 只编辑 Agent 字段；保留原始设备身份与连接资料，拒绝覆盖外部修改。
public sealed class LocalRuntimeConfigurationDocument {
    public string Path{get;}
    public LocalAgentConfiguration? Agent{get;}
    private readonly byte[] original;
    private readonly JsonObject fields;
    private const int MaximumBytes=65536;
    private LocalRuntimeConfigurationDocument(string path,byte[] bytes,JsonObject value,LocalAgentConfiguration? agent){Path=path;original=bytes;fields=value;Agent=agent;}
    public static LocalRuntimeConfigurationDocument Load(string path){
        if(!System.IO.Path.IsPathFullyQualified(path))throw new InvalidOperationException("runtime_configuration_not_editable");
        var bytes=Read(path);var fields=JsonNode.Parse(bytes)?.AsObject()??throw new InvalidOperationException("invalid_runtime_configuration");
        foreach(var key in new[]{"mqtt_host","space","device","model_revision","database"})if(fields[key] is not JsonValue scalar||!scalar.TryGetValue<string>(out _))throw new InvalidOperationException("invalid_runtime_configuration");
        if(fields["mqtt_port"] is not JsonValue port||!port.TryGetValue<int>(out var number)||number is <1 or >65535)throw new InvalidOperationException("invalid_runtime_configuration");
        LocalAgentConfiguration? agent=null;
        if(fields["agent"] is JsonNode node){
            if(node is not JsonObject value||value.Any(pair=>!new[]{"executable","workspaces","timeout_seconds","allow_iot_tools"}.Contains(pair.Key))||
               value["workspaces"] is not JsonArray workspaces||workspaces.Any(item=>item is not JsonObject workspace||workspace.Any(pair=>!new[]{"id","name","path","allow_write"}.Contains(pair.Key))))throw new InvalidOperationException("runtime_configuration_not_editable");
            agent=node.Deserialize<LocalAgentConfiguration>()??throw new InvalidOperationException("invalid_local_agent_configuration");
        }
        return new(System.IO.Path.GetFullPath(path),bytes,fields,agent);
    }
    public void Save(LocalAgentConfiguration? configuration){
        var agent=configuration?.Validated();var value=(JsonObject)fields.DeepClone();
        if(agent is null)value.Remove("agent");else value["agent"]=JsonSerializer.SerializeToNode(agent);
        var bytes=JsonSerializer.SerializeToUtf8Bytes(value,new JsonSerializerOptions{WriteIndented=true});
        if(bytes.Length>MaximumBytes)throw new InvalidOperationException("runtime_configuration_too_large");
        Unchanged();var temporary=System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Path)!,".limelink-config-"+Guid.NewGuid()+".tmp");
        try{
            using(var output=CreatePrivate(temporary)){output.Write(bytes);output.Flush(true);}
            Unchanged();File.Move(temporary,Path,true);
        }finally{if(File.Exists(temporary))File.Delete(temporary);}
    }
    private void Unchanged(){if(!Read(Path).AsSpan().SequenceEqual(original))throw new InvalidOperationException("runtime_configuration_changed");}
    private static byte[] Read(string path){
        var file=new FileInfo(path);
        if(!file.Exists||(file.Attributes&(FileAttributes.Directory|FileAttributes.ReparsePoint))!=0||file.Length>MaximumBytes)throw new InvalidOperationException("runtime_configuration_not_editable");
        if(OperatingSystem.IsWindows()){
            using var identity=WindowsIdentity.GetCurrent();
            if(identity.User is null||!identity.User.Equals(file.GetAccessControl(AccessControlSections.Owner).GetOwner(typeof(SecurityIdentifier))))throw new InvalidOperationException("runtime_configuration_not_editable");
        }
        using var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);
        if(input.Length>MaximumBytes)throw new InvalidOperationException("runtime_configuration_too_large");
        var bytes=new byte[input.Length];input.ReadExactly(bytes);return bytes;
    }
    private static FileStream CreatePrivate(string path){
        if(OperatingSystem.IsWindows()){
            using var identity=WindowsIdentity.GetCurrent();var user=identity.User??throw new InvalidOperationException("runtime_configuration_not_editable");
            var security=new FileSecurity();security.SetOwner(user);security.SetAccessRuleProtection(true,false);security.AddAccessRule(new FileSystemAccessRule(user,FileSystemRights.FullControl,AccessControlType.Allow));
            return new FileInfo(path).Create(FileMode.CreateNew,FileSystemRights.Read|FileSystemRights.Write,FileShare.None,4096,FileOptions.WriteThrough,security);
        }
        return new FileStream(path,new FileStreamOptions{Mode=FileMode.CreateNew,Access=FileAccess.Write,Share=FileShare.None,Options=FileOptions.WriteThrough,UnixCreateMode=UnixFileMode.UserRead|UnixFileMode.UserWrite});
    }
}
