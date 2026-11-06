using System.Diagnostics;
using System.ComponentModel;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using Windows.Media.SpeechRecognition;
using LimeIoT.Client;
using LimeLink.Core;

namespace LimeLink.App;
public sealed partial class MainWindow:Window {
    private readonly ComboBox route=new(){Header="连接入口",ItemsSource=new[]{"本地 LimeIoT 网关","LimeIoT 云控制面"},SelectedIndex=0,HorizontalAlignment=HorizontalAlignment.Stretch};
    private readonly StackPanel cloudControls=new(){Spacing=8,Visibility=Visibility.Collapsed};
    private readonly TextBlock authorizationView=new(){TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true};
    private readonly TextBlock cloudIdentity=new(){TextWrapping=TextWrapping.Wrap};
    private readonly ComboBox records=new(){Header="当前账号全部空间的原操作",DisplayMemberPath="Label",HorizontalAlignment=HorizontalAlignment.Stretch,Visibility=Visibility.Collapsed};
    private sealed record RecordItem(ControlCommandRecord Record,string Label);
    private readonly TextBox endpoint=new(){Header="LimeIoT 网关 HTTPS 地址"};
    private readonly PasswordBox token=new(){Header="所有者凭据（留空恢复会话）"};
    private readonly ComboBox spaces=new(){Header="明确选择空间",HorizontalAlignment=HorizontalAlignment.Stretch};
    private readonly ComboBox targets=new(){Header="目标电脑",HorizontalAlignment=HorizontalAlignment.Stretch,DisplayMemberPath="Id"};
    private readonly TextBox name=new(){Header="本客户端名称",Text=Environment.MachineName};
    private readonly TextBox draft=new(){Header="纯文本草稿",AcceptsReturn=true,MinHeight=130,TextWrapping=TextWrapping.Wrap};
    private readonly TextBox session=new(){Header="会话 ID"};
    private readonly TextBox revision=new(){Header="当前修订",Text="1"};
    private readonly TextBox contentId=new(){Header="内容 ID"};
    private readonly TextBox cancelId=new(){Header="需要取消的原卡片 ID"};
    private readonly TextBlock result=new(){Text="连接网关后，请选择空间并刷新电脑。",TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true};
    private readonly TextBlock fingerprint=new(){TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true};
    private readonly ContentControl controls=new();
    private readonly ScrollViewer scroll=new();
    private readonly StackPanel local=new(){Spacing=12};
    private readonly SecretStore secure=new();
    private LinkClient? client;
    private CloudLinkClient? cloud;
    private CloudLinkSnapshot? cloudSnapshot;
    private NativeLogin? authorization;
    private long nextPoll;
    private bool cloudMode;
    private CancellationTokenSource? work;
    private CancellationToken Cancellation=>work?.Token??CancellationToken.None;
    private TextGenerationClient? ai;
    private string? aiKey,configuration,lastView;
    private readonly Dictionary<string,string> sessionDrafts=new();
    private readonly Dictionary<string,FrameworkElement> visibleCards=new();
    private Process? runtime;
    private bool runtimeInputClosed;
    private bool busy,active=true;
    private sealed class CommandAvailability:INotifyPropertyChanged {
        private bool enabled=true;
        public bool Enabled{get=>enabled;set{if(enabled==value)return;enabled=value;PropertyChanged?.Invoke(this,new(nameof(Enabled)));}}
        public event PropertyChangedEventHandler? PropertyChanged;
    }
    private readonly CommandAvailability commandAvailability=new();
    public MainWindow(){
        Title="LimeLink 柠联";
        BuildWorkspace(out var modelCommands,out var reconcile);
        endpoint.TextChanged+=(_,_)=>ResetRoute();
        route.SelectionChanged+=(_,_)=>{cloudMode=route.SelectedIndex==1;ResetRoute();endpoint.Text="";endpoint.Header=cloudMode?"服务地址":"网关地址";token.Visibility=modelCommands.Visibility=cloudMode?Visibility.Collapsed:Visibility.Visible;cloudControls.Visibility=records.Visibility=reconcile.Visibility=cloudMode?Visibility.Visible:Visibility.Collapsed;};
        spaces.SelectionChanged+=(_,_)=>{ClearTargets();cloudSnapshot=null;cloudIdentity.Text="";};
        targets.SelectionChanged+=async(_,_)=>{ClearTargetFields();await Run(async()=>{if(targets.SelectedItem is not Device d||spaces.SelectedItem is not string s)return;var value=cloudMode?await Cloud().FingerprintAsync(d.Id,Cancellation):client is not null?await client.FingerprintAsync(s,d.Id):"";Cancellation.ThrowIfCancellationRequested();fingerprint.Text="本客户端指纹\n"+value;});};
        scroll.ViewChanged+=(_,_)=>ReportVisibleCards();Activated+=(_,args)=>{active=args.WindowActivationState!=WindowActivationState.Deactivated;if(active)ReportVisibleCards();else if(cloudMode)PauseCloud();else if(desktopPage=="assistant"){work?.Cancel();ClearAgentProjection();}};
        Closed+=async(_,_)=>{agentPoll.Stop();work?.Cancel();await StopRuntime();client?.Dispose();cloud?.Dispose();};
    }
    private Button Button(string label,Func<Task> action){var button=new Button{Content=label};button.SetBinding(Microsoft.UI.Xaml.Controls.Control.IsEnabledProperty,new Microsoft.UI.Xaml.Data.Binding{Source=commandAvailability,Path=new PropertyPath(nameof(CommandAvailability.Enabled)),Mode=Microsoft.UI.Xaml.Data.BindingMode.OneWay});button.Click+=async(_,_)=>await Run(action);return button;}
    private void ClearTargetFields(){fingerprint.Text="";session.Text="";revision.Text="1";contentId.Text="";cancelId.Text="";aiKey=null;ClearAgent();}
    private void ClearTargets(){targets.ItemsSource=null;ClearTargetFields();}
    private void PauseCloud(){work?.Cancel();ClearTargets();cloudSnapshot=null;authorization=null;authorizationView.Text="";cloudIdentity.Text="";}
    private void ResetRoute(){work?.Cancel();token.Password="";client?.Dispose();cloud?.Dispose();client=null;agentClient=null;agentIoTClient=null;cloud=null;ai=null;spaces.ItemsSource=null;ClearTargets();cloudSnapshot=null;records.ItemsSource=null;authorization=null;authorizationView.Text="";cloudIdentity.Text="";draft.Text="";result.Text="连接入口已更改，请恢复会话或明确发起授权；原操作保留在原入口。";UpdateWorkspaceState();}
    private CloudLinkClient Cloud()=>cloud??=new(endpoint.Text,secure);
    private async Task Run(Func<Task> action){
        if(busy)return;busy=true;commandAvailability.Enabled=false;work=new();
        try{await action();Cancellation.ThrowIfCancellationRequested();}
        catch(OperationCanceledException){ }
        catch(Exception error){if(!Cancellation.IsCancellationRequested){if(error is GatewayException{Code:"unauthenticated"}){spaces.ItemsSource=null;ClearTargets();cloudSnapshot=null;records.ItemsSource=null;cloudIdentity.Text="";draft.Text="";}result.Text=error is GatewayException gateway?gateway.Code:error.Message;}}
        finally{
            if(cloudMode&&cloud is not null&&!Cancellation.IsCancellationRequested){try{var saved=await cloud.RecordsAsync(Cancellation);Cancellation.ThrowIfCancellationRequested();var key=(records.SelectedItem as RecordItem)?.Record.Id;records.ItemsSource=saved.Select(r=>new RecordItem(r,string.Join("，",r.Reference.SpaceId,r.Reference.Request.DeviceId,r.IsPrepared?"尚未提交":r.Result?.Status??r.Rejection??"未知",r.Id[..8]))).ToArray();records.SelectedItem=(records.ItemsSource as RecordItem[])?.FirstOrDefault(r=>r.Record.Id==key);}catch(OperationCanceledException){}catch(Exception error){result.Text+="\n原记录读取未完成："+error.Message;}}
            work.Dispose();work=null;commandAvailability.Enabled=true;busy=false;UpdateWorkspaceState();
        }
    }
    private async Task LoadCloud(){var c=Cloud();var current=await c.Control.RestoreSessionAsync(Cancellation);var available=await c.Control.SpacesAsync(Cancellation);Cancellation.ThrowIfCancellationRequested();spaces.ItemsSource=null;ClearTargets();cloudSnapshot=null;spaces.ItemsSource=available.Select(s=>s.SpaceId).ToArray();authorization=null;authorizationView.Text="";cloudIdentity.Text="当前账号："+current.Principal.Name+"，"+current.Principal.PrincipalId;draft.Text="";result.Text="云会话已恢复，请明确选择空间并刷新；原操作可独立查询。";}
    private async Task BeginCloud(){var login=await Cloud().Control.BeginAuthorizationAsync("windows",Cancellation);Cancellation.ThrowIfCancellationRequested();authorization=login;nextPoll=Environment.TickCount64+login.IntervalSeconds*1000L;authorizationView.Text="授权码："+login.UserCode+"\n到期："+login.ExpiresAt;result.Text="在系统浏览器核对授权码、平台和账号后批准。回到应用后明确恢复原授权并查询。";}
    private async Task OpenAuthorization(){if(authorization is null)throw new InvalidOperationException("begin_or_resume_authorization_first");await Windows.System.Launcher.LaunchUriAsync(new Uri(authorization.VerificationUri));}
    private async Task PollCloud(){if(authorization is null||Environment.TickCount64<nextPoll)throw new InvalidOperationException("resume_authorization_and_wait_interval");nextPoll=Environment.TickCount64+authorization.IntervalSeconds*1000L;var response=await Cloud().Control.PollAuthorizationAsync(Cancellation);Cancellation.ThrowIfCancellationRequested();if(response.Status=="approved")await LoadCloud();else result.Text="授权状态："+response.Status;}
    private async Task CancelCloud(){await Cloud().Control.CancelAuthorizationAsync(Cancellation);Cancellation.ThrowIfCancellationRequested();authorization=null;authorizationView.Text="";result.Text="原授权已取消。";}
    private async Task Connect(){if(cloudMode){await LoadCloud();return;}client?.Dispose();client=null;agentClient=null;agentIoTClient=null;ai=null;spaces.ItemsSource=null;ClearTargets();var next=new LinkClient(endpoint.Text,secure);try{if(token.Password.Length==0)await next.Gateway.RestoreAsync();else await next.Gateway.LoginAsync(token.Password);}catch{next.Dispose();throw;}token.Password="";client=next;agentClient=new(next,secure);agentIoTClient=new(next.Gateway,agentClient,secure);ai=new(next.Gateway,secure);aiKey=null;spaces.ItemsSource=await next.Gateway.SpacesAsync();result.Text="已连接，请明确选择空间并刷新。";}
    private async Task Refresh(){
        if(spaces.SelectedItem is not string space)throw new InvalidOperationException("select_space_first");ClearTargets();
        if(cloudMode){var snapshot=await Cloud().SnapshotAsync(space,Cancellation);Cancellation.ThrowIfCancellationRequested();cloudSnapshot=snapshot;targets.ItemsSource=snapshot.Devices.Where(d=>snapshot.Models[d.ModelRevision]?["model_id"]?.GetValue<string>()=="urn:limelink:model:desktop:1").ToArray();cloudIdentity.Text=string.Join("，",snapshot.Principal,snapshot.Gateway.GatewayId,snapshot.Gateway.LocalSpaceId,snapshot.Gateway.Revision);}
        else{if(client is null)throw new InvalidOperationException("connect_first");var snapshot=await client.SnapshotAsync(space);targets.ItemsSource=snapshot.Devices.Where(d=>snapshot.Models[d.ModelRevision]?["model_id"]?.GetValue<string>()=="urn:limelink:model:desktop:1").ToArray();}
        result.Text="已读取真实终端能力，请核对目标与指纹。";
    }
    private void Show(CommandReceipt receipt){var response=LinkClient.Response(receipt);result.Text=receipt.Status+"\n"+receipt.Id+"\n"+response?.ToJsonString();var value=response?["value"];if(value?["revision"] is JsonValue number)revision.Text=number.GetValue<long>().ToString();if(value?["text"] is JsonValue text)draft.Text=text.GetValue<string>();if(receipt.Document["request"]?["operation"]?["value"]?["kind"]?.GetValue<string>()=="card")cancelId.Text=value?["id"]?.GetValue<string>()??"";}
    private async Task Reapply(){
        var dialog=new ContentDialog{XamlRoot=Content.XamlRoot,Title="重新申请所选电脑的协同？",Content="仅对过期、拒绝或撤销的关系生效；清除旧会话与内容后，电脑必须再次批准。先核实所有未完成请求。",PrimaryButtonText="清除并重新申请",CloseButtonText="取消",DefaultButton=ContentDialogButton.Close};
        if(await dialog.ShowAsync()==ContentDialogResult.Primary)await Action("pair",true);
    }
    private async Task Action(string kind,bool reapply=false){
        if(spaces.SelectedItem is not string space||targets.SelectedItem is not Device device)throw new InvalidOperationException("select_target_first");
        JsonObject payload=kind switch{
            "pair"=>new(){{"name",name.Text}},"card"=>new(){{"text",draft.Text},{"ttl",3600}},"cancel"=>new(){{"id",cancelId.Text}},
            "session_create"=>new(){{"id",session.Text.Length==0?(session.Text=Guid.NewGuid().ToString()):session.Text},{"text",draft.Text},{"ttl",3600}},
            "session_claim" or "session_release"=>new(){{"id",session.Text},{"revision",long.Parse(revision.Text)}},
            "session_write"=>new(){{"id",session.Text},{"revision",long.Parse(revision.Text)},{"text",draft.Text}},
            "content_put"=>new(){{"id",contentId.Text.Length==0?(contentId.Text=Guid.NewGuid().ToString()):contentId.Text},{"text",draft.Text},{"ttl",3600},{"sha256",LinkIdentity.Hash(draft.Text)}},
            "content_remove"=>new(){{"id",contentId.Text}},_=>new()
        };
        if(kind=="pair"&&reapply)payload["reapply"]=true;
        if(cloudMode){var record=await Cloud().PerformAsync(space,device,kind,payload,Cancellation);Cancellation.ThrowIfCancellationRequested();ShowCloud(record);return;}
        if(client is null)throw new InvalidOperationException("connect_first");
        var command=await client.PerformAsync(space,device,kind,payload,Cancellation);
        for(var i=0;i<20&&command.Status is "accepted" or "dispatched";i++){await Task.Delay(200,Cancellation);command=await client.ResolveAsync(Cancellation);}Cancellation.ThrowIfCancellationRequested();Show(command);
        if(kind=="pair"&&LinkClient.Response(command)?["ok"] is JsonValue ok&&ok.TryGetValue<bool>(out var success)&&success){if(!await client.FinishSuccessfulPairingAsync(Cancellation))throw new InvalidOperationException("original_request_unresolved");Cancellation.ThrowIfCancellationRequested();}
    }
    private void ShowCloud(ControlCommandRecord record){
        var response=CloudLinkClient.Response(record);result.Text=string.Join("\n","云原操作："+(record.IsPrepared?"尚未提交":record.Rejection??record.Result?.Status??"未知"),record.Id,response?.ToJsonString());
        var reference=record.Reference;var selected=cloudSnapshot;
        if(selected is null||reference.PrincipalId!=selected.Principal||reference.SpaceId!=(spaces.SelectedItem as string)||reference.LocalSpaceId!=selected.Gateway.LocalSpaceId||reference.Request.GatewayId!=selected.Gateway.GatewayId||reference.Request.BindingRevision!=selected.Gateway.Revision||reference.Request.DeviceId!=(targets.SelectedItem as Device)?.Id||reference.Request.ModelRevision!=(targets.SelectedItem as Device)?.ModelRevision)return;
        var value=response?["value"];if(value?["revision"] is JsonValue number)revision.Text=number.GetValue<long>().ToString();if(value?["text"] is JsonValue text)draft.Text=text.GetValue<string>();if(reference.Request.Operation["value"]?["kind"]?.ToString()=="card")cancelId.Text=value?["id"]?.GetValue<string>()??"";
    }
    private async Task Resolve()=>await Resolve(false);
    private async Task Resolve(bool reconcile){if(cloudMode){var key=(records.SelectedItem as RecordItem)?.Record.Id??throw new InvalidOperationException("select_original_record");var record=await Cloud().ResolveAsync(key,reconcile,Cancellation);Cancellation.ThrowIfCancellationRequested();ShowCloud(record);}else if(client is not null)Show(await client.ResolveAsync());}
    private async Task Finish(){if(cloudMode){var key=(records.SelectedItem as RecordItem)?.Record.Id??throw new InvalidOperationException("select_original_record");await Cloud().ForgetAsync(key,Cancellation);Cancellation.ThrowIfCancellationRequested();}else if(client is not null)await client.FinishAsync();result.Text="所选记录已完成；未知结果保留，未提交的准备可明确放弃。";}
    private async Task Logout(){if(cloudMode)await Cloud().LogoutAsync(Cancellation);else if(client is not null)await client.Gateway.LogoutAsync();Cancellation.ThrowIfCancellationRequested();ResetRoute();result.Text="已退出，未核实任务保留在安全存储。";}
    private async Task ModelDraft(bool resolve){
        if(ai is null||spaces.SelectedItem is not string space)throw new InvalidOperationException("connect_and_select_space_first");
        if(!await ai.ConfiguredAsync(space))throw new InvalidOperationException("gateway_text_model_not_configured");
        var records=await ai.RecordsAsync(space);TextGenerationRecord record;
        if(resolve)record=await ai.ResolveAsync(space,aiKey??records.LastOrDefault()?.Key??throw new InvalidOperationException("no_original_model_task"));
        else record=await ai.SubmitAsync(space,TextGenerationClient.Input(draft.Text,"仅整理纯文本草稿，不执行设备动作。"));
        aiKey=record.Key;if(record.Text is string text)draft.Text=text;result.Text=record.Status+"；内容仅进入草稿，发送到电脑需另行确认。";
    }
    private async Task Dictate(){using var recognizer=new SpeechRecognizer(new Windows.Globalization.Language("zh-CN"));recognizer.UIOptions.ExampleText="说出你的草稿";var recognized=await recognizer.RecognizeWithUIAsync();if(recognized.Status==SpeechRecognitionResultStatus.Success)draft.Text=recognized.Text;}
    private async Task StartRuntime(){
        EnsureRuntimeStopped();if(localAgentSettingsBusy)throw new InvalidOperationException("runtime_already_running");
        string? path=null;runtimeTransition=true;RefreshLocalAgentSettings();
        try{var picker=new FileOpenPicker();picker.FileTypeFilter.Add(".json");WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));path=(await picker.PickSingleFileAsync())?.Path;}
        finally{runtimeTransition=false;RefreshLocalAgentSettings();}
        if(path is not null)StartConfiguredRuntime(path);
    }
    private void StartConfiguredRuntime(string path){
        EnsureRuntimeStopped();
        try{LoadLocalAgentSettings(path);}catch(Exception error)when(error is IOException or UnauthorizedAccessException or InvalidOperationException or System.Text.Json.JsonException){
            localAgentDocument=null;configuration=path;localConfigurationName.Text=Path.GetFileName(path);localConfigurationMessage.Text=AgentConfigurationError(error);localAgentEnabled.IsChecked=false;
        }
        var start=new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"limelink-runtime.exe")){UseShellExecute=false,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true};start.ArgumentList.Add(path);
        var process=new Process{StartInfo=start};
        try{if(!process.Start())throw new InvalidOperationException("runtime_start_failed");}catch{process.Dispose();throw;}
        runtime=process;runtimeInputClosed=false;configuration=path;lastView=null;visibleCards.Clear();sessionDrafts.Clear();local.Children.Clear();localAgents.Children.Clear();
        localRuntimeState="正在连接…";RefreshLocalAgentSettings();runtimeCompletion=ObserveRuntime(process);
        result.Text="本机设备通道正在连接。";
    }
    private async Task ObserveRuntime(Process process){
        async Task Frames(){
            while(await process.StandardOutput.ReadLineAsync().ConfigureAwait(false) is string line){
                if(line.Length>1_000_000){process.StandardInput.Close();break;}
                try{var frame=JsonNode.Parse(line)?.AsObject();DispatcherQueue.TryEnqueue(()=>{if(ReferenceEquals(runtime,process))Render(frame);});}catch(System.Text.Json.JsonException){}
            }
        }
        async Task Errors(){while(await process.StandardError.ReadLineAsync().ConfigureAwait(false) is not null){}}
        try{await Task.WhenAll(Frames(),Errors(),process.WaitForExitAsync()).ConfigureAwait(false);}
        catch(Exception error)when(error is IOException or InvalidOperationException){}
        finally{if(!DispatcherQueue.TryEnqueue(()=>{CompleteRuntime(process);process.Dispose();}))process.Dispose();}
    }
    private void CompleteRuntime(Process process){
        if(!ReferenceEquals(runtime,process))return;
        runtime=null;runtimeInputClosed=true;runtimeCompletion=null;lastView=null;visibleCards.Clear();sessionDrafts.Clear();local.Children.Clear();localAgents.Children.Clear();localRuntimeState="已断开";RefreshLocalAgentSettings();
    }
    private async Task StopRuntime(){
        var process=runtime;var completion=runtimeCompletion;if(process is null||runtimeTransition)return;
        runtimeTransition=true;localRuntimeState="正在断开，等待任务中断结果";RefreshLocalAgentSettings();
        try{
            runtimeInputClosed=true;
            try{process.StandardInput.Close();}catch(Exception error)when(error is IOException or InvalidOperationException){}
            using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(25));
            try{if(completion is not null)await completion.WaitAsync(deadline.Token);else await process.WaitForExitAsync(deadline.Token);}
            catch(OperationCanceledException){localRuntimeState="等待执行端退出";localConfigurationMessage.Text=result.Text="执行端尚未确认退出，任务结果需重新核实。";return;}
            CompleteRuntime(process);
        }finally{runtimeTransition=false;RefreshLocalAgentSettings();}
    }
    private async Task ExportDiagnostics(){
        if(configuration is null)throw new InvalidOperationException("start_runtime_first");
        var picker=new FileSavePicker{SuggestedFileName="LimeLink-diagnostics"};picker.FileTypeChoices.Add("JSON",new List<string>{".json"});WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));var file=await picker.PickSaveFileAsync();if(file is null)return;
        var start=new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"limelink-runtime.exe")){UseShellExecute=false,RedirectStandardOutput=true,CreateNoWindow=true};start.ArgumentList.Add("--diagnostics");start.ArgumentList.Add(configuration);
        using var process=Process.Start(start)??throw new InvalidOperationException("diagnostics_failed");var output=await process.StandardOutput.ReadToEndAsync();await process.WaitForExitAsync();if(process.ExitCode!=0||output.Length>100_000)throw new InvalidOperationException("diagnostics_failed");await File.WriteAllTextAsync(file.Path,output);result.Text="已导出计数与版本；不含正文、身份或凭据。";
    }
    private void SendLocal(string type,string id,long? revision=null,string? text=null){if(runtimeTransition||runtimeInputClosed||runtime is null)throw new InvalidOperationException("本机执行端尚未连接或正在断开。");var frame=new JsonObject{{"type",type},{"id",id}};if(revision is not null)frame["revision"]=revision;if(text is not null)frame["text"]=text;runtime.StandardInput.WriteLine(frame.ToJsonString());runtime.StandardInput.Flush();}
    private void ReportVisibleCards(){foreach(var card in visibleCards)ReportPresented(card.Key,card.Value);}
    private void ReportPresented(string id,FrameworkElement block){
        if(runtime is null||runtimeTransition||runtimeInputClosed||!visibleCards.TryGetValue(id,out var current)||!ReferenceEquals(current,block)||desktopPage!="terminal"||!active||!block.IsLoaded||block.ActualWidth<=0||block.ActualHeight<=0)return;
        var bounds=block.TransformToVisual(scroll).TransformBounds(new Windows.Foundation.Rect(0,0,block.ActualWidth,block.ActualHeight));
        if(bounds.Bottom>0&&bounds.Top<scroll.ActualHeight&&bounds.Right>0&&bounds.Left<scroll.ActualWidth){try{SendLocal("presented",id);}catch(Exception error)when(error is IOException or InvalidOperationException){result.Text="显示回执尚未确认，请核实执行端。";}}
    }
    private void Render(JsonObject? frame){
        if(frame?["type"]?.GetValue<string>()=="connection"){if(!runtimeInputClosed)localRuntimeState=frame["state"]?.GetValue<string>()=="ready"?"已连接":"连接中断，正在重连";RefreshLocalAgentSettings();return;}
        if(frame?["type"]?.GetValue<string>()=="error"){result.Text="本机操作未完成："+frame["code"]?.GetValue<string>();return;}
        if(frame?["type"]?.GetValue<string>()!="view")return;var view=frame.ToJsonString();if(lastView==view)return;lastView=view;RenderLocalAgents(frame);visibleCards.Clear();local.Children.Clear();
        foreach(var peer in frame["peers"]!.AsArray()){
            var id=peer!["id"]!.GetValue<string>();var state=peer["state"]!.GetValue<string>();
            local.Children.Add(new TextBlock{Text=peer["name"]!.GetValue<string>()+"，"+Status(state)+"\n"+peer["fingerprint"]!.GetValue<string>(),TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true});
            if(state=="pending"){local.Children.Add(Button("允许配对",()=>{SendLocal("approve",id);return Task.CompletedTask;}));local.Children.Add(Button("拒绝",()=>{SendLocal("reject",id);return Task.CompletedTask;}));}
            if(state=="approved")local.Children.Add(Button("取消配对",()=>{SendLocal("revoke",id);return Task.CompletedTask;}));
        }
        foreach(var card in frame["cards"]!.AsArray()){
            if(card!["state"]!.GetValue<string>() is not("queued" or "presented"))continue;
            var id=card["id"]!.GetValue<string>();var block=new TextBlock{Text=card["text"]!.GetValue<string>(),TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true};
            if(card["state"]!.GetValue<string>()=="queued"){visibleCards[id]=block;block.Loaded+=(_,_)=>ReportPresented(id,block);block.SizeChanged+=(_,_)=>ReportPresented(id,block);}local.Children.Add(block);
        }
        foreach(var item in frame["contents"]!.AsArray())local.Children.Add(new TextBlock{Text=item!["stale"]!.GetValue<bool>()?"内容已过期":item["text"]!.GetValue<string>(),TextWrapping=TextWrapping.Wrap});
        foreach(var item in frame["sessions"]!.AsArray()){
            var id=item!["id"]!.GetValue<string>();var revision=item["revision"]!.GetValue<long>();var expired=item["expired"]!.GetValue<bool>();
            local.Children.Add(new TextBlock{Text=id+"，版本 "+revision+(expired?"，已过期":""),TextWrapping=TextWrapping.Wrap});if(expired)continue;
            local.Children.Add(new TextBlock{Text=item["text"]!.GetValue<string>(),TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true});
            var edit=new TextBox{Header="修改内容",Text=sessionDrafts.GetValueOrDefault(id)??item["text"]!.GetValue<string>(),AcceptsReturn=true,TextWrapping=TextWrapping.Wrap};edit.TextChanged+=(_,_)=>sessionDrafts[id]=edit.Text;local.Children.Add(edit);
            local.Children.Add(Button("开始编辑",()=>{SendLocal("session_claim",id,revision);return Task.CompletedTask;}));
            if(item["writer"]?.GetValue<string>()=="local-desktop"){
                local.Children.Add(Button("保存修改",()=>{SendLocal("session_write",id,revision,edit.Text);return Task.CompletedTask;}));
                local.Children.Add(Button("结束编辑",()=>{SendLocal("session_release",id,revision);return Task.CompletedTask;}));
            }
        }
    }
}
