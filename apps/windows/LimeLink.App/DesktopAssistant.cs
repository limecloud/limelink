using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using LimeIoT.Client;
using LimeLink.Core;
using System.Text.Json.Nodes;

namespace LimeLink.App;
public sealed partial class MainWindow {
    private AgentClient? agentClient;
    private AgentIoTClient? agentIoTClient;
    private long agentGeneration;
    private AgentRun? agentRun;
    private readonly List<AgentEvent> agentEvents=new();
    private readonly ComboBox agentWorkspaces=new(){Header="工作目录",DisplayMemberPath="Name",HorizontalAlignment=HorizontalAlignment.Stretch};
    private readonly ComboBox agentRecords=new(){Header="任务",DisplayMemberPath="Id",HorizontalAlignment=HorizontalAlignment.Stretch};
    private readonly TextBox agentPrompt=new(){Header="交给助手的任务",AcceptsReturn=true,MinHeight=160,TextWrapping=TextWrapping.Wrap};
    private readonly CheckBox agentWrite=new(){Content="允许修改所选目录",IsEnabled=false};
    private readonly CheckBox agentContinue=new(){Content="继续所选任务的会话"};
    private readonly TextBlock agentStatus=new(){TextWrapping=TextWrapping.Wrap};
    private readonly TextBlock agentReply=new(){TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true};
    private readonly StackPanel localAgents=new(){Spacing=16};
    private readonly StackPanel agentDeviceChoices=new(){Spacing=8,Visibility=Visibility.Collapsed};
    private readonly StackPanel agentTools=new(){Spacing=16};
    private readonly HashSet<string> agentSelectedDevices=new();
    private readonly DispatcherTimer agentPoll=new(){Interval=TimeSpan.FromSeconds(2)};
    private bool agentAwaitingConfirmation;
    private StackPanel? agentRemoteControls;
    private readonly TextBlock agentUnavailable=new(){Text="助手需要连接执行电脑所在的网关。",TextWrapping=TextWrapping.Wrap,Visibility=Visibility.Collapsed};
    private void UpdateAssistantRoute(){if(agentRemoteControls is null)return;agentRemoteControls.Visibility=cloudMode?Visibility.Collapsed:Visibility.Visible;agentUnavailable.Visibility=cloudMode?Visibility.Visible:Visibility.Collapsed;}
    private void ClearAgentProjection(){agentGeneration++;agentRun=null;agentEvents.Clear();agentStatus.Text="";agentReply.Text="";agentTools.Children.Clear();agentAwaitingConfirmation=false;}
    private void ClearAgent(){ClearAgentProjection();agentWorkspaces.ItemsSource=null;agentRecords.ItemsSource=null;agentPrompt.Text="";agentWrite.IsChecked=false;agentWrite.IsEnabled=false;agentContinue.IsChecked=false;agentDeviceChoices.Children.Clear();agentDeviceChoices.Visibility=Visibility.Collapsed;agentSelectedDevices.Clear();}
    private static ComboBox MirrorSelection(ComboBox source,string header){
        var picker=new ComboBox{Header=header,DisplayMemberPath=source.DisplayMemberPath,HorizontalAlignment=HorizontalAlignment.Stretch};
        picker.SetBinding(ItemsControl.ItemsSourceProperty,new Binding{Source=source,Path=new PropertyPath("ItemsSource"),Mode=BindingMode.OneWay});
        picker.SetBinding(ComboBox.SelectedItemProperty,new Binding{Source=source,Path=new PropertyPath("SelectedItem"),Mode=BindingMode.TwoWay});return picker;
    }
    private FrameworkElement BuildAssistant(){
        agentWorkspaces.SelectionChanged+=(_,_)=>{agentWrite.IsChecked=false;agentWrite.IsEnabled=(agentWorkspaces.SelectedItem as AgentWorkspace)?.AllowWrite==true;};
        agentRecords.SelectionChanged+=(_,_)=>{ClearAgentProjection();agentContinue.IsChecked=false;};
        void SetDeviceChoiceEnabled(){foreach(var checkbox in agentDeviceChoices.Children.OfType<CheckBox>())checkbox.IsEnabled=agentContinue.IsChecked!=true;}
        agentContinue.Checked+=(_,_)=>SetDeviceChoiceEnabled();agentContinue.Unchecked+=(_,_)=>SetDeviceChoiceEnabled();
        agentPoll.Tick+=async(_,_)=>{if(active&&!busy&&!agentAwaitingConfirmation&&desktopPage=="assistant"&&agentRecords.SelectedItem is AgentReference&&!cloudMode)await Run(()=>QueryAgent(false));};agentPoll.Start();
        agentRemoteControls=Column(MirrorSelection(spaces,"工作空间"),MirrorSelection(targets,"执行电脑"),
            Row(Button("读取工作目录",DiscoverAgent),Button("恢复原请求",RecoverAgent)),agentWorkspaces,agentPrompt,agentWrite,agentDeviceChoices,agentRecords,agentContinue,
            Row(Primary(Button("提交任务",SubmitAgent)),Button("查询状态与回复",()=>QueryAgent(false)),Button("请求停止",()=>QueryAgent(true))),agentStatus,agentTools,agentReply);
        return Column(Text("助手",22),agentUnavailable,agentRemoteControls,Details("本机执行",Column(Row(Button("导入执行端配置",StartRuntime),Button("断开执行端",StopRuntime)),localAgents)));
    }
    private (AgentClient Client,string Space,Device Device,long Generation) AgentTarget(){
        if(cloudMode)throw new InvalidOperationException("Agent 暂时通过网关连接，请在网关中切换连接方式。");
        if(agentClient is null||spaces.SelectedItem is not string space||targets.SelectedItem is not Device device)throw new InvalidOperationException("请先连接网关并选择执行电脑");
        return(agentClient,space,device,agentGeneration);
    }
    private async Task LoadAgentRecords(AgentClient c,string space,Device device,string? selected=null){
        var references=await c.ReferencesAsync(Cancellation);Cancellation.ThrowIfCancellationRequested();
        agentRecords.ItemsSource=references.Where(r=>r.Space==space&&r.Device==device.Id&&r.Revision==device.ModelRevision).ToArray();
        if(selected is not null)agentRecords.SelectedItem=((AgentReference[])agentRecords.ItemsSource).SingleOrDefault(r=>r.Id==selected);
    }
    private async Task DiscoverAgent(){
        var target=AgentTarget();var caps=await target.Client.DiscoverAsync(target.Space,target.Device,Cancellation);
        if(target.Generation!=agentGeneration)return;
        agentWorkspaces.ItemsSource=caps.Workspaces;await LoadAgentRecords(target.Client,target.Space,target.Device);
        var generation=agentGeneration;var tools=await target.Client.DiscoverToolsAsync(target.Space,target.Device,Cancellation);var snapshot=await client!.SnapshotAsync(target.Space,Cancellation);if(generation!=agentGeneration)return;
        agentDeviceChoices.Children.Clear();agentSelectedDevices.Clear();agentDeviceChoices.Visibility=tools.Enabled?Visibility.Visible:Visibility.Collapsed;
        if(tools.Enabled){agentDeviceChoices.Children.Add(Text("允许助手使用的设备"));foreach(var device in snapshot.Devices.Where(d=>d.Id!=target.Device.Id&&d.Ready&&!(snapshot.Models[d.ModelRevision]?["model_id"]?.GetValue<string>()??"").StartsWith("urn:limelink:model:desktop:",StringComparison.Ordinal))){
            var checkbox=new CheckBox{Content=device.Id};checkbox.Checked+=(_,_)=>{if(agentSelectedDevices.Count>=4){checkbox.IsChecked=false;return;}agentSelectedDevices.Add(device.Id);};checkbox.Unchecked+=(_,_)=>agentSelectedDevices.Remove(device.Id);agentDeviceChoices.Children.Add(checkbox);
        }}
        agentStatus.Text="请选择工作目录。每次任务由执行电脑批准。";
    }
    private void ShowAgent(AgentRun run){
        if(agentRun?.Id!=run.Id)agentEvents.Clear();
        foreach(var e in run.Events)if(agentEvents.All(old=>old.Seq!=e.Seq))agentEvents.Add(e);
        if(run.ExpiresAt<=DateTimeOffset.UtcNow.ToUnixTimeSeconds())agentEvents.Clear();
        agentRun=run;agentStatus.Text=run.StateText+(run.Error is null?"":"\n"+run.Error);
        agentReply.Text=string.Concat(agentEvents.Where(e=>e.Kind=="message").OrderBy(e=>e.Seq).Select(e=>e.Text));
    }
    private async Task SubmitAgent(){
        var target=AgentTarget();var workspace=agentWorkspaces.SelectedItem as AgentWorkspace??throw new InvalidOperationException("请选择工作目录");
        if(agentContinue.IsChecked==true&&(agentRun?.State!="succeeded"||agentRun.SessionId is null))throw new InvalidOperationException("请先查询已完成的任务");
        var resume=agentContinue.IsChecked==true?agentRecords.SelectedItem as AgentReference??throw new InvalidOperationException("请选择要继续的任务"):null;
        try{
            var selected=resume?.Devices??agentSelectedDevices.Order(StringComparer.Ordinal).ToArray();
            var run=await target.Client.SubmitAsync(target.Space,target.Device,workspace.Id,agentPrompt.Text,agentWrite.IsChecked==true?"workspace-write":"read-only",resume,Cancellation,selected);
            if(target.Generation!=agentGeneration)return;
            await LoadAgentRecords(target.Client,target.Space,target.Device,run.Id);ShowAgent(run);
        }catch{if(target.Generation==agentGeneration)await LoadAgentRecords(target.Client,target.Space,target.Device);throw;}
    }
    private async Task QueryAgent(bool cancel){
        var target=AgentTarget();var reference=agentRecords.SelectedItem as AgentReference??throw new InvalidOperationException("请选择任务");
        var after=cancel?0:agentRun?.Id==reference.Id?agentRun.Cursor:0;
        var run=await target.Client.QueryAsync(reference,target.Space,target.Device,after,cancel,Cancellation);
        if(target.Generation==agentGeneration){ShowAgent(run);await LoadAgentTools(reference,target.Space,target.Device,agentGeneration);}
    }
    private async Task LoadAgentTools(AgentReference reference,string space,Device device,long generation){
        var tools=agentIoTClient;if(tools is null)return;await tools.PruneExpiredAsync(Cancellation);
        if(agentRun?.State=="running")await tools.ReceiveAsync(reference,space,device,Cancellation);
        var records=await tools.RecordsAsync(Cancellation);if(generation!=agentGeneration||!active)return;agentTools.Children.Clear();agentAwaitingConfirmation=records.Any(r=>r.Reference.Matches(reference)&&r.CanConfirm);
        foreach(var record in records.Where(r=>r.Reference.Matches(reference))){
            var call=record.Call;var label=call.IsWrite?(call.Path switch{"light.power"=>"电源","light.brightness"=>"亮度",_=>call.Path})+"："+(call.Value is JsonValue v&&v.TryGetValue<bool>(out var flag)?flag?"开启":"关闭":call.Value?.ToJsonString()):"读取设备状态";
            var panel=Column(Text(call.Device+"  "+label),Text(record.StatusText,12));
            if(record.CanConfirm)panel.Children.Add(Row(Primary(Button("确认操作",async()=>{await tools.ConfirmAsync(record.Id,reference,space,device,Cancellation);await LoadAgentTools(reference,space,device,generation);})),Button("拒绝",async()=>{await tools.RejectAsync(record.Id,reference,space,device,Cancellation);await LoadAgentTools(reference,space,device,generation);})));
            else if(record.NeedsRecovery)panel.Children.Add(Button("查询原设备命令",async()=>{await tools.RecoverCommandAsync(record.Id,reference,space,device,Cancellation);await LoadAgentTools(reference,space,device,generation);}));
            if(record.Outcome is not null&&!record.Delivered)panel.Children.Add(Button("恢复结果回传",async()=>{await tools.SendResultAsync(record.Id,reference,space,device,Cancellation);await LoadAgentTools(reference,space,device,generation);}));
            agentTools.Children.Add(panel);
        }
    }
    private async Task RecoverAgent(){
        var target=AgentTarget();var run=await target.Client.RecoverAsync(Cancellation);
        if(target.Generation!=agentGeneration)return;
        // 原请求可能属于其他空间；仅在当前目标匹配时投影回复。
        var reference=run is null?null:(await target.Client.ReferencesAsync(Cancellation)).SingleOrDefault(r=>r.Id==run.Id);
        if(reference is not null&&reference.Space==target.Space&&reference.Device==target.Device.Id&&reference.Revision==target.Device.ModelRevision){await LoadAgentRecords(target.Client,target.Space,target.Device,run!.Id);ShowAgent(run);}
        else agentStatus.Text="原请求已核实。请选择对应空间和电脑查看任务。";
    }
    private void RenderLocalAgents(JsonObject frame){
        localAgents.Children.Clear();
        if(frame["agent"]?["runs"] is not JsonArray runs)return;
        foreach(var item in runs){
            var run=item!.AsObject();var id=run["id"]!.GetValue<string>();var state=run["state"]!.GetValue<string>();
            var status=new AgentRun(id,state,"",run["sandbox"]!.GetValue<string>(),null,null,0,[],0).StateText;
            var peer=(frame["peers"] as JsonArray)?.FirstOrDefault(p=>p?["id"]?.GetValue<string>()==run["client"]?.GetValue<string>());
            var body=Column(Text(status,22),Text("来自 "+(peer?["name"]?.GetValue<string>()??run["client"]?.GetValue<string>()??"")),Text(peer?["fingerprint"]?.GetValue<string>()??"",12),Text(run["text"]?.GetValue<string>()??""),Text(run["workspace_path"]?.GetValue<string>()??""),Text(run["sandbox"]?.GetValue<string>()=="workspace-write"?"允许修改所选目录；仍可读取本机其他可读文件":"只读执行；仍可读取本机其他可读文件",12));
            if(run["iot_devices"] is JsonArray devices&&devices.Count>0){body.Children.Add(Text("可访问设备："+string.Join("、",devices.Select(value=>value!.GetValue<string>())),12));body.Children.Add(Text("设备写入由任务发起端逐次确认。",12));}
            if(state=="awaiting_approval")body.Children.Add(Row(LocalAgentButton("批准本次执行","agent_approve",id),LocalAgentButton("拒绝","agent_reject",id)));
            if(state is "approved" or "starting" or "running")body.Children.Add(LocalAgentButton("请求停止","agent_cancel",id));
            if(run["reply"] is JsonValue reply)body.Children.Add(new TextBlock{Text=reply.GetValue<string>(),TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true});
            if(run["reply_truncated"]?.GetValue<bool>()==true)body.Children.Add(Text("仅显示最近回复",12));
            if(run["error"] is JsonValue error)body.Children.Add(Text(error.GetValue<string>(),12));
            localAgents.Children.Add(body);
        }
    }
    // 本机通道不依赖网关请求的忙碌状态，批准与中断始终可以响应。
    private Button LocalAgentButton(string label,string kind,string id){var button=new Button{Content=label};button.Click+=(_,_)=>{try{SendLocal(kind,id);}catch(Exception e)when(e is IOException or InvalidOperationException){result.Text="本机操作未完成，请核实执行端。";}};return button;}
}
