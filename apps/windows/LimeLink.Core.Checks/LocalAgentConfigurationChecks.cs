using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json.Nodes;
using LimeLink.Core;

internal static class LocalAgentConfigurationChecks {
    public static async Task Run(){
        static void Check(bool value,string code){if(!value)throw new InvalidOperationException(code);}
        static void Reject(Action action){try{action();}catch(Exception error)when(error is InvalidOperationException or IOException or ArgumentException or System.Text.Json.JsonException){return;}throw new InvalidOperationException("invalid_local_configuration_accepted");}
        var root=Path.Combine(Path.GetTempPath(),"limelink-agent-config-"+Guid.NewGuid());Directory.CreateDirectory(root);
        try{
            var workspace=Path.Combine(root,"工作目录");Directory.CreateDirectory(workspace);var executable=Environment.ProcessPath!;
            var settings=new LocalAgentConfiguration(executable,[new("work","笔记",workspace)]);var valid=settings.Validated();
            Check(valid.TimeoutSeconds==600&&!valid.AllowIoTTools&&!valid.Workspaces[0].AllowWrite,"unsafe_configuration_defaults");
            Reject(()=> (settings with{TimeoutSeconds=29}).Validated());Reject(()=> (settings with{TimeoutSeconds=1801}).Validated());
            Reject(()=> (settings with{Executable="relative/codex"}).Validated());Reject(()=> (settings with{Executable=workspace}).Validated());
            Reject(()=> (settings with{Workspaces=[]}).Validated());Reject(()=> (settings with{Workspaces=[settings.Workspaces[0],settings.Workspaces[0]]}).Validated());
            foreach(var item in new[]{new LocalAgentWorkspace("bad id","名称",workspace),new("work",new string('字',22),workspace),new("work","bad\nname",workspace),new("work","名称","relative/path"),new("work","名称",Path.Combine(root,"missing"))})Reject(()=> (settings with{Workspaces=[item]}).Validated());
            var path=Path.Combine(root,"device.json");var original=new JsonObject{{"mqtt_host","gateway.example"},{"mqtt_port",8883},{"space","chosen"},{"device","desktop"},{"model_revision","sha256:"+new string('a',64)},{"database",Path.Combine(root,"device.sqlite")},{"ca","private/ca.crt"},{"certificate","private/device.crt"},{"private_key","private/device.key"}};
            File.WriteAllText(path,original.ToJsonString());var document=LocalRuntimeConfigurationDocument.Load(path);Check(document.Agent is null,"missing_agent_not_optional");
            settings=settings with{AllowIoTTools=true,Workspaces=[settings.Workspaces[0] with{AllowWrite=true}]};document.Save(settings);
            var saved=File.ReadAllBytes(path);var objectValue=JsonNode.Parse(saved)!.AsObject();objectValue.Remove("agent");Check(JsonNode.DeepEquals(objectValue,original),"device_identity_changed_by_agent_settings");
            if(OperatingSystem.IsWindows()){
                var security=new FileInfo(path).GetAccessControl();using var identity=WindowsIdentity.GetCurrent();
                Check(security.AreAccessRulesProtected&&identity.User!.Equals(security.GetOwner(typeof(SecurityIdentifier))),"configuration_acl_not_private");
                foreach(FileSystemAccessRule rule in security.GetAccessRules(true,true,typeof(SecurityIdentifier)))Check(rule.IdentityReference.Equals(identity.User)&&rule.AccessControlType==AccessControlType.Allow,"configuration_acl_grants_other_identity");
            }else Check((File.GetUnixFileMode(path)&(UnixFileMode)0x1ff)==(UnixFileMode.UserRead|UnixFileMode.UserWrite),"configuration_permissions_too_broad");
            var updated=LocalRuntimeConfigurationDocument.Load(path);Check(updated.Agent?.AllowIoTTools==true&&updated.Agent.Workspaces[0].AllowWrite,"saved_agent_not_restored");
            Reject(()=>document.Save(null));Check(File.ReadAllBytes(path).AsSpan().SequenceEqual(saved),"stale_document_overwrote_new_configuration");
            updated.Save(null);Check(LocalRuntimeConfigurationDocument.Load(path).Agent is null,"agent_not_disabled");
            var current=LocalRuntimeConfigurationDocument.Load(path);var changed=(JsonObject)original.DeepClone();changed["device"]="different";File.WriteAllText(path,changed.ToJsonString());Reject(()=>current.Save(settings));Check(JsonNode.DeepEquals(JsonNode.Parse(File.ReadAllBytes(path)),changed),"external_configuration_change_overwritten");
            var future=(JsonObject)original.DeepClone();future["agent"]=System.Text.Json.JsonSerializer.SerializeToNode(settings);future["agent"]!["future_setting"]=true;File.WriteAllText(path,future.ToJsonString());Reject(()=>LocalRuntimeConfigurationDocument.Load(path));
            future["agent"]!.AsObject().Remove("future_setting");future["agent"]!["workspaces"]![0]!["future_setting"]=true;File.WriteAllText(path,future.ToJsonString());Reject(()=>LocalRuntimeConfigurationDocument.Load(path));
            File.WriteAllText(path,"{}");Reject(()=>LocalRuntimeConfigurationDocument.Load(path));File.WriteAllBytes(path,new byte[65537]);Reject(()=>LocalRuntimeConfigurationDocument.Load(path));
            var defaults=(JsonObject)original.DeepClone();defaults["agent"]=new JsonObject{{"executable",executable},{"workspaces",new JsonArray(new JsonObject{{"id","work"},{"name","笔记"},{"path",workspace}})}};File.WriteAllText(path,defaults.ToJsonString());var restored=LocalRuntimeConfigurationDocument.Load(path).Agent!;Check(restored.TimeoutSeconds==600&&!restored.AllowIoTTools&&!restored.Workspaces[0].AllowWrite,"configuration_defaults_not_decoded");
            if(!OperatingSystem.IsWindows()){
                var alias=Path.Combine(root,"alias");Directory.CreateSymbolicLink(alias,workspace);
                Check((settings with{Workspaces=[settings.Workspaces[0] with{Path=alias}]}).Validated().Workspaces[0].Path==valid.Workspaces[0].Path,"workspace_not_canonical");
                var configLink=Path.Combine(root,"device-link.json");File.CreateSymbolicLink(configLink,path);Reject(()=>LocalRuntimeConfigurationDocument.Load(configLink));
                var ancestor=Path.Combine(root,"ancestor");Directory.CreateSymbolicLink(ancestor,root);
                Check((settings with{Workspaces=[settings.Workspaces[0] with{Path=Path.Combine(ancestor,"工作目录")}]}).Validated().Workspaces[0].Path==valid.Workspaces[0].Path,"workspace_ancestor_not_canonical");
            }
            var discovered=await CodexExecutableDiscovery.FindAsync([Path.Combine(root,"missing"),executable]);Check(discovered?.Version=="0.166.0","compatible_codex_not_selected");
            for(var i=0;i<8;i++)Check((await CodexExecutableDiscovery.FindAsync([executable]))?.Version=="0.166.0","fast_codex_output_lost");
            using(var cancelled=new CancellationTokenSource()){cancelled.Cancel();try{await CodexExecutableDiscovery.FindAsync([executable],cancelled.Token);throw new InvalidOperationException("cancelled_codex_probe_started");}catch(OperationCanceledException){}}
            if(!OperatingSystem.IsWindows()){
                string Script(string name,string body){var file=Path.Combine(root,name);File.WriteAllText(file,"#!/bin/sh\n"+body+"\n");File.SetUnixFileMode(file,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);return file;}
                var old=Script("old-codex","printf 'codex-cli 0.1.2505191453\\n'");var wrong=Script("wrong-codex","if [ \"$1\" = '--version' ]; then printf 'codex-cli 0.166.0\\n'; else printf 'no app server\\n'; fi");
                Check((await CodexExecutableDiscovery.FindAsync([old,wrong,executable]))?.Version=="0.166.0","unsupported_codex_not_skipped");
                var hanging=Script("hanging-codex","exec /bin/sleep 10");var start=Environment.TickCount64;
                Check(await CodexExecutableDiscovery.FindAsync([hanging],probeTimeout:TimeSpan.FromMilliseconds(100)) is null&&Environment.TickCount64-start<2000,"codex_probe_timeout_not_bounded");
                var verbose=Script("verbose-codex","while :; do printf 'codex-cli 0.166.0 codex-cli 0.166.0\\n'; done");start=Environment.TickCount64;
                Check(await CodexExecutableDiscovery.FindAsync([verbose],probeTimeout:TimeSpan.FromMilliseconds(100)) is null&&Environment.TickCount64-start<2000,"codex_probe_output_not_bounded");
            }
            Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new{local_agent_configuration=true,identity_preserved=true,external_change_refused=true,codex_probe=true,windows_acl_exercised=OperatingSystem.IsWindows(),windows_ui=false}));
        }finally{Directory.Delete(root,true);}
    }
}
