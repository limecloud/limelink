using System.Globalization;
using LimeLink.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace LimeLink.App;
public sealed partial class MainWindow {
    private LocalRuntimeConfigurationDocument? localAgentDocument;
    private readonly List<LocalAgentWorkspace> localAgentDirectories=new();
    private readonly CheckBox localAgentEnabled=new(){Content="启用 Codex"};
    private readonly TextBlock localRuntimeStatus=Text("尚未连接",12);
    private readonly TextBlock localConfigurationName=Text("尚未导入设备配置",12);
    private readonly TextBlock localExecutablePath=Text("尚未选择",12);
    private readonly TextBlock localConfigurationMessage=Text("",12);
    private readonly TextBox localTimeout=new(){Header="运行超时（秒）",Text="600",MaxWidth=160,HorizontalAlignment=HorizontalAlignment.Left};
    private readonly CheckBox localIoTTools=new(){Content="允许设备工具"};
    private readonly StackPanel localDirectoryRows=new(){Spacing=16};
    private ContentControl? localAgentForm;
    private Button localImport=null!,localDisconnect=null!,localReload=null!,localSave=null!,localAddDirectory=null!;
    private bool localAgentSettingsBusy,runtimeTransition;
    private string localExecutable="",localRuntimeState="尚未连接";
    private Task? runtimeCompletion;

    private Button AgentSettingButton(string label,Func<Task> action){var button=new Button{Content=label};button.Click+=async(_,_)=>await AgentSettingsAction(action);return button;}
    private async Task AgentSettingsAction(Func<Task> action){
        if(localAgentSettingsBusy)return;localAgentSettingsBusy=true;RefreshLocalAgentSettings();
        try{await action();}catch(Exception error)when(error is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or System.Text.Json.JsonException or System.ComponentModel.Win32Exception){localConfigurationMessage.Text=AgentConfigurationError(error);}
        finally{localAgentSettingsBusy=false;RefreshLocalAgentSettings();}
    }
    private FrameworkElement BuildLocalAgentSettings(){
        localImport=AgentSettingButton("导入设备配置",ChooseLocalAgentConfiguration);localDisconnect=AgentSettingButton("断开执行端",StopRuntime);
        localReload=AgentSettingButton("重新读取",()=>{EnsureRuntimeStopped();if(configuration is null)throw new InvalidOperationException("invalid_runtime_configuration");LoadLocalAgentSettings(configuration);return Task.CompletedTask;});
        localSave=Primary(AgentSettingButton("保存并连接",SaveLocalAgentSettings));
        localAddDirectory=AgentSettingButton("添加目录",()=>{localAgentDirectories.Add(new(Guid.NewGuid().ToString(),"",""));RenderLocalAgentDirectories();return Task.CompletedTask;});
        localAgentEnabled.Checked+=(_,_)=>RefreshLocalAgentSettings();localAgentEnabled.Unchecked+=(_,_)=>RefreshLocalAgentSettings();
        localAgentForm=new ContentControl{HorizontalContentAlignment=HorizontalAlignment.Stretch,Content=Column(Row(Text("Codex 程序"),AgentSettingButton("自动查找",FindLocalCodex),AgentSettingButton("选择程序",ChooseLocalCodex)),localExecutablePath,
            Row(Text("工作目录"),localAddDirectory),localDirectoryRows,localTimeout,localIoTTools,Text("任务需在本机批准，设备写入另需逐次确认。",12))};
        var body=Column(Row(Text("本机助手"),localRuntimeStatus),Row(localConfigurationName,localImport,localDisconnect),localAgentEnabled,localAgentForm,Row(localReload,localSave),localConfigurationMessage);
        RefreshLocalAgentSettings();return body;
    }
    private void RefreshLocalAgentSettings(){
        if(localAgentForm is null)return;
        var stopped=runtime is null&&!runtimeTransition;var editable=localAgentDocument is not null&&!localAgentSettingsBusy&&stopped;
        localRuntimeStatus.Text=localRuntimeState;localImport.IsEnabled=!localAgentSettingsBusy&&stopped;
        localImport.Content=localAgentDocument is null?"导入设备配置":"更换配置";
        localDisconnect.IsEnabled=runtime is not null&&!localAgentSettingsBusy&&!runtimeTransition;
        localDisconnect.Visibility=runtime is null?Visibility.Collapsed:Visibility.Visible;
        localAgentEnabled.IsEnabled=editable;localAgentForm.IsEnabled=editable&&localAgentEnabled.IsChecked==true;
        localAgentForm.Visibility=localAgentEnabled.IsChecked==true?Visibility.Visible:Visibility.Collapsed;
        localReload.IsEnabled=!localAgentSettingsBusy&&stopped&&configuration is not null;localSave.IsEnabled=editable;
        localAddDirectory.IsEnabled=localAgentDirectories.Count<8;
    }
    private void EnsureRuntimeStopped(){if(runtime is not null||runtimeTransition)throw new InvalidOperationException("runtime_already_running");}
    private static string AgentConfigurationError(Exception error)=>error.Message switch{
        "runtime_already_running"=>"请先断开本机执行端，等待当前任务中断结果。",
        "runtime_configuration_changed"=>"配置已被修改，请重新读取后保存。",
        "runtime_configuration_not_editable"=>"请选择当前用户拥有的设备配置文件。",
        "invalid_local_agent_configuration"=>"请选择 Codex 程序，配置 1 至 8 个目录，超时须为 30 至 1800 秒。",
        "agent_executable_unavailable"=>"请选择 Codex 原生可执行程序（.exe）。",
        "invalid_local_agent_workspace" or "agent_workspace_unavailable" or "agent_path_unavailable"=>"请检查目录名称和路径，名称最多 64 字节。",
        _=>"操作未完成，请检查配置内容和文件权限。"
    };
    private void LoadLocalAgentSettings(string path){
        var document=LocalRuntimeConfigurationDocument.Load(path);var settings=document.Agent;
        localAgentDocument=document;configuration=document.Path;localConfigurationName.Text=Path.GetFileName(path);localConfigurationMessage.Text="";
        localExecutable=settings?.Executable??"";localExecutablePath.Text=localExecutable.Length==0?"尚未选择":localExecutable;
        localAgentDirectories.Clear();localAgentDirectories.AddRange(settings?.Workspaces??[]);RenderLocalAgentDirectories();
        localTimeout.Text=(settings?.TimeoutSeconds??600).ToString(CultureInfo.InvariantCulture);localIoTTools.IsChecked=settings?.AllowIoTTools??false;
        localAgentEnabled.IsChecked=settings is not null;RefreshLocalAgentSettings();
    }
    private async Task ChooseLocalAgentConfiguration(){
        EnsureRuntimeStopped();var picker=new FileOpenPicker();picker.FileTypeFilter.Add(".json");WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));
        if(await picker.PickSingleFileAsync() is { } file)LoadLocalAgentSettings(file.Path);
    }
    private async Task ChooseLocalCodex(){
        var picker=new FileOpenPicker();picker.FileTypeFilter.Add(".exe");WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));
        if(await picker.PickSingleFileAsync() is { } file){localExecutable=file.Path;localExecutablePath.Text=file.Path;localConfigurationMessage.Text="";}
    }
    private async Task FindLocalCodex(){
        localConfigurationMessage.Text="正在查找 Codex…";
        var found=await Task.Run(()=>CodexExecutableDiscovery.FindAsync(CodexExecutableDiscovery.Candidates()));
        if(found is null){localConfigurationMessage.Text="未找到支持 App Server 的 Codex，请选择程序或更新 Codex。";return;}
        localExecutable=found.Path;localExecutablePath.Text=found.Path;localConfigurationMessage.Text="Codex "+found.Version;
    }
    private void RenderLocalAgentDirectories(){
        localDirectoryRows.Children.Clear();
        foreach(var workspace in localAgentDirectories.ToArray()){
            var id=workspace.Id;var name=new TextBox{Header="目录名称",Text=workspace.Name,MinWidth=180};var write=new CheckBox{Content="允许修改此目录的文件",IsChecked=workspace.AllowWrite};
            void Change(Func<LocalAgentWorkspace,LocalAgentWorkspace> update){var index=localAgentDirectories.FindIndex(item=>item.Id==id);if(index>=0)localAgentDirectories[index]=update(localAgentDirectories[index]);}
            name.TextChanged+=(_,_)=>Change(item=>item with{Name=name.Text});write.Checked+=(_,_)=>Change(item=>item with{AllowWrite=true});write.Unchecked+=(_,_)=>Change(item=>item with{AllowWrite=false});
            var choose=AgentSettingButton("选择文件夹",async()=>{
                var picker=new FolderPicker();picker.FileTypeFilter.Add("*");WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));
                if(await picker.PickSingleFolderAsync() is not { } folder)return;
                Change(item=>item with{Path=folder.Path,Name=item.Name.Length==0?folder.Name:item.Name});RenderLocalAgentDirectories();
            });
            var remove=AgentSettingButton("移除",()=>{localAgentDirectories.RemoveAll(item=>item.Id==id);RenderLocalAgentDirectories();return Task.CompletedTask;});
            localDirectoryRows.Children.Add(Column(Row(name,choose,remove),Text(workspace.Path,12),write));
        }
        RefreshLocalAgentSettings();
    }
    private async Task SaveLocalAgentSettings(){
        EnsureRuntimeStopped();var document=localAgentDocument??throw new InvalidOperationException("invalid_runtime_configuration");
        LocalAgentConfiguration? settings=null;
        if(localAgentEnabled.IsChecked==true){
            if(!int.TryParse(localTimeout.Text,NumberStyles.None,CultureInfo.InvariantCulture,out var timeout))throw new InvalidOperationException("invalid_local_agent_configuration");
            settings=new(localExecutable,localAgentDirectories.ToArray(),timeout,localIoTTools.IsChecked==true);
        }
        await Task.Run(()=>document.Save(settings));LoadLocalAgentSettings(document.Path);StartConfiguredRuntime(document.Path);
    }
}
