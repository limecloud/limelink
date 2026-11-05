using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using Windows.Media.SpeechRecognition;
using LimeIoT.Client;
using LimeLink.Core;

namespace LimeLink.App;
public sealed class MainWindow:Window {
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
    private readonly StackPanel form=new(){Spacing=12,Padding=new Thickness(24),MaxWidth=900};
    private readonly ContentControl controls=new();
    private readonly StackPanel local=new(){Spacing=12};
    private readonly SecretStore secure=new();
    private LinkClient? client;
    private TextGenerationClient? ai;
    private string? aiKey,configuration,lastView;
    private readonly Dictionary<string,string> sessionDrafts=new();
    private Process? runtime;
    private bool busy,active=true;
    public MainWindow(){
        Title="LimeLink 柠联";
        form.Children.Add(new TextBlock{Text="LimeLink 柠联",FontSize=30});form.Children.Add(new TextBlock{Text="手机的灵感，电脑接着做。"});
        foreach(var element in new UIElement[]{endpoint,token,Button("连接 / 恢复会话",Connect),spaces,Button("刷新电脑与真实能力",Refresh),targets,name,fingerprint,Button("请求配对",()=>Action("pair")),Button("检查配对及展示状态",()=>Action("status")),draft,Button("确认发送到所选电脑",()=>Action("card")),Button("系统语音草稿",Dictate),result,Button("查询原请求",Resolve),Button("完成已核实记录",Finish),cancelId,Button("请求取消待展示卡片",()=>Action("cancel")),session,revision,Button("从草稿建立会话",()=>Action("session_create")),Button("取得 30 秒输入资格",()=>Action("session_claim")),Button("提交草稿修订",()=>Action("session_write")),Button("释放输入资格",()=>Action("session_release")),contentId,Button("安装纯文本内容（1小时）",()=>Action("content_put")),Button("移除所选内容",()=>Action("content_remove")),Button("撤销此客户端协同",()=>Action("revoke")),Button("退出用户会话",Logout),new TextBlock{Text="本机执行端",FontSize=24},Button("选择设备配置并启动",StartRuntime),Button("停止本机执行端",StopRuntime),local,new TextBlock{Text="系统语音服务可能处理录音；语音只生成草稿。模型服务通过网关配置，不会自动获得设备执行权。",TextWrapping=TextWrapping.Wrap}})form.Children.Add(element);
        form.Children.Insert(14,Button("网关模型生成草稿",()=>ModelDraft(false)));form.Children.Insert(15,Button("查询原模型任务",()=>ModelDraft(true)));
        form.Children.Add(Button("导出脱敏诊断",ExportDiagnostics));
        targets.SelectionChanged+=async(_,_)=>await Run(async()=>{if(client is not null&&targets.SelectedItem is Device d&&spaces.SelectedItem is string s)fingerprint.Text="本客户端指纹\n"+await client.FingerprintAsync(s,d.Id);});
        controls.Content=form;Content=new ScrollViewer{Content=controls};Activated+=(_,args)=>active=args.WindowActivationState!=WindowActivationState.Deactivated;
        Closed+=(_,_)=>{if(runtime is{HasExited:false})runtime.Kill();runtime?.Dispose();client?.Dispose();};
    }
    private Button Button(string label,Func<Task> action){var button=new Button{Content=label};button.Click+=async(_,_)=>await Run(action);return button;}
    private async Task Run(Func<Task> action){if(busy)return;busy=true;controls.IsEnabled=false;try{await action();}catch(Exception error){result.Text=error is GatewayException gateway?gateway.Code:error.Message;}finally{controls.IsEnabled=true;busy=false;}}
    private async Task Connect(){var next=new LinkClient(endpoint.Text,secure);if(token.Password.Length==0)await next.Gateway.RestoreAsync();else await next.Gateway.LoginAsync(token.Password);token.Password="";client?.Dispose();client=next;ai=new(next.Gateway,secure);aiKey=null;spaces.ItemsSource=await next.Gateway.SpacesAsync();targets.ItemsSource=null;result.Text="已连接，请明确选择空间并刷新。";}
    private async Task Refresh(){if(client is null||spaces.SelectedItem is not string space)throw new InvalidOperationException("select_space_first");var snapshot=await client.SnapshotAsync(space);targets.ItemsSource=snapshot.Devices.Where(d=>snapshot.Models[d.ModelRevision]?["model_id"]?.GetValue<string>()=="urn:limelink:model:desktop:1").ToArray();result.Text="已读取真实终端能力。";}
    private void Show(CommandReceipt receipt){var response=LinkClient.Response(receipt);result.Text=receipt.Status+"\n"+receipt.Id+"\n"+response?.ToJsonString();var value=response?["value"];if(value?["revision"] is JsonValue number)revision.Text=number.GetValue<long>().ToString();if(value?["text"] is JsonValue text)draft.Text=text.GetValue<string>();if(receipt.Document["request"]?["operation"]?["value"]?["kind"]?.GetValue<string>()=="card")cancelId.Text=value?["id"]?.GetValue<string>()??"";}
    private async Task Action(string kind){
        if(client is null||spaces.SelectedItem is not string space||targets.SelectedItem is not Device device)throw new InvalidOperationException("select_target_first");
        JsonObject payload=kind switch{
            "pair"=>new(){{"name",name.Text}},"card"=>new(){{"text",draft.Text},{"ttl",3600}},"cancel"=>new(){{"id",cancelId.Text}},
            "session_create"=>new(){{"id",session.Text.Length==0?(session.Text=Guid.NewGuid().ToString()):session.Text},{"text",draft.Text},{"ttl",3600}},
            "session_claim" or "session_release"=>new(){{"id",session.Text},{"revision",long.Parse(revision.Text)}},
            "session_write"=>new(){{"id",session.Text},{"revision",long.Parse(revision.Text)},{"text",draft.Text}},
            "content_put"=>new(){{"id",contentId.Text.Length==0?(contentId.Text=Guid.NewGuid().ToString()):contentId.Text},{"text",draft.Text},{"ttl",3600},{"sha256",LinkIdentity.Hash(draft.Text)}},
            "content_remove"=>new(){{"id",contentId.Text}},_=>new()
        };
        var command=await client.PerformAsync(space,device,kind,payload);
        for(var i=0;i<20&&command.Status is "accepted" or "dispatched";i++){await Task.Delay(200);command=await client.ResolveAsync();}Show(command);
    }
    private async Task Resolve(){if(client is not null)Show(await client.ResolveAsync());}
    private async Task Finish(){if(client is not null)await client.FinishAsync();result.Text="原结果已核实，可以继续。";}
    private async Task Logout(){if(client is not null)await client.Gateway.LogoutAsync();client?.Dispose();client=null;ai=null;aiKey=null;spaces.ItemsSource=null;targets.ItemsSource=null;fingerprint.Text="";result.Text="已退出，未核实任务保留在安全存储。";}
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
        if(runtime is{HasExited:false})throw new InvalidOperationException("runtime_already_running");
        var picker=new FileOpenPicker();picker.FileTypeFilter.Add(".json");WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));var file=await picker.PickSingleFileAsync();if(file is null)return;
        var start=new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"limelink-runtime.exe")){UseShellExecute=false,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true};start.ArgumentList.Add(file.Path);
        runtime=Process.Start(start)??throw new InvalidOperationException("runtime_start_failed");configuration=file.Path;lastView=null;var process=runtime;
        _=Task.Run(async()=>{while(await process.StandardOutput.ReadLineAsync() is string line){if(line.Length>1_000_000)break;try{var frame=JsonNode.Parse(line)?.AsObject();DispatcherQueue.TryEnqueue(()=>Render(frame));}catch(System.Text.Json.JsonException){}}});
        _=Task.Run(async()=>{while(await process.StandardError.ReadLineAsync() is not null){}});
        result.Text="本机设备通道正在连接。";
    }
    private Task StopRuntime(){if(runtime is{HasExited:false})runtime.Kill();runtime?.Dispose();runtime=null;lastView=null;local.Children.Clear();return Task.CompletedTask;}
    private async Task ExportDiagnostics(){
        if(configuration is null)throw new InvalidOperationException("start_runtime_first");
        var picker=new FileSavePicker{SuggestedFileName="LimeLink-diagnostics"};picker.FileTypeChoices.Add("JSON",new List<string>{".json"});WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(this));var file=await picker.PickSaveFileAsync();if(file is null)return;
        var start=new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory,"limelink-runtime.exe")){UseShellExecute=false,RedirectStandardOutput=true,CreateNoWindow=true};start.ArgumentList.Add("--diagnostics");start.ArgumentList.Add(configuration);
        using var process=Process.Start(start)??throw new InvalidOperationException("diagnostics_failed");var output=await process.StandardOutput.ReadToEndAsync();await process.WaitForExitAsync();if(process.ExitCode!=0||output.Length>100_000)throw new InvalidOperationException("diagnostics_failed");await File.WriteAllTextAsync(file.Path,output);result.Text="已导出计数与版本；不含正文、身份或凭据。";
    }
    private void SendLocal(string type,string id,long? revision=null,string? text=null){var frame=new JsonObject{{"type",type},{"id",id}};if(revision is not null)frame["revision"]=revision;if(text is not null)frame["text"]=text;runtime?.StandardInput.WriteLine(frame.ToJsonString());runtime?.StandardInput.Flush();}
    private void Render(JsonObject? frame){
        if(frame?["type"]?.GetValue<string>()=="error"){result.Text="本机操作未完成："+frame["code"]?.GetValue<string>();return;}
        if(frame?["type"]?.GetValue<string>()!="view")return;var view=frame.ToJsonString();if(lastView==view)return;lastView=view;local.Children.Clear();
        foreach(var peer in frame["peers"]!.AsArray()){
            var id=peer!["id"]!.GetValue<string>();var state=peer["state"]!.GetValue<string>();
            local.Children.Add(new TextBlock{Text=peer["name"]!.GetValue<string>()+" · "+state+"\n"+peer["fingerprint"]!.GetValue<string>(),TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true});
            if(state=="pending"){local.Children.Add(Button("核对后批准",()=>{SendLocal("approve",id);return Task.CompletedTask;}));local.Children.Add(Button("拒绝",()=>{SendLocal("reject",id);return Task.CompletedTask;}));}
            if(state=="approved")local.Children.Add(Button("撤销协同",()=>{SendLocal("revoke",id);return Task.CompletedTask;}));
        }
        foreach(var card in frame["cards"]!.AsArray()){
            if(card!["state"]!.GetValue<string>() is not("queued" or "presented"))continue;
            var id=card["id"]!.GetValue<string>();var block=new TextBlock{Text=card["text"]!.GetValue<string>(),TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true};
            block.Loaded+=(_,_)=>{if(active)SendLocal("presented",id);};local.Children.Add(block);
        }
        foreach(var item in frame["contents"]!.AsArray())local.Children.Add(new TextBlock{Text=item!["stale"]!.GetValue<bool>()?"内容已过期":item["text"]!.GetValue<string>(),TextWrapping=TextWrapping.Wrap});
        foreach(var item in frame["sessions"]!.AsArray()){
            var id=item!["id"]!.GetValue<string>();var revision=item["revision"]!.GetValue<long>();var expired=item["expired"]!.GetValue<bool>();
            local.Children.Add(new TextBlock{Text=id+" · 修订 "+revision+(expired?" · 已过期":""),TextWrapping=TextWrapping.Wrap});if(expired)continue;
            local.Children.Add(new TextBlock{Text=item["text"]!.GetValue<string>(),TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true});
            var edit=new TextBox{Header="本机会话草稿",Text=sessionDrafts.GetValueOrDefault(id)??item["text"]!.GetValue<string>(),AcceptsReturn=true,TextWrapping=TextWrapping.Wrap};edit.TextChanged+=(_,_)=>sessionDrafts[id]=edit.Text;local.Children.Add(edit);
            local.Children.Add(Button("取得本机输入资格",()=>{SendLocal("session_claim",id,revision);return Task.CompletedTask;}));
            if(item["writer"]?.GetValue<string>()=="local-desktop"){
                local.Children.Add(Button("提交本机草稿",()=>{SendLocal("session_write",id,revision,edit.Text);return Task.CompletedTask;}));
                local.Children.Add(Button("释放本机资格",()=>{SendLocal("session_release",id,revision);return Task.CompletedTask;}));
            }
        }
    }
}
