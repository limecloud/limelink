using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;

namespace LimeLink.App;
public sealed partial class MainWindow {
    private readonly Dictionary<string,FrameworkElement> pages=new();
    private readonly Dictionary<string,ToggleButton> navigation=new();
    private FrameworkElement sendEmpty=null!,sendForm=null!,historyBody=null!,footer=null!;
    private string desktopPage="home";
    private static readonly string preferencePath=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"LimeLink","appearance.txt");
    private static string ReadAppearance(){try{return File.ReadAllText(preferencePath).Trim();}catch(IOException){return "system";}catch(UnauthorizedAccessException){return "system";}}

    private static TextBlock Text(string value,double size=14)=>new(){Text=value,FontSize=size,TextWrapping=TextWrapping.Wrap};
    private static StackPanel Column(params UIElement[] items){var panel=new StackPanel{Spacing=20};foreach(var item in items)panel.Children.Add(item);return panel;}
    private static StackPanel Row(params UIElement[] items){var panel=new StackPanel{Orientation=Orientation.Horizontal,Spacing=12};foreach(var item in items)panel.Children.Add(item);return panel;}
    private static Image Artwork(string name,double height)=>new(){Source=new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory,"Assets","Desktop",name+".png"))),Height=height,Stretch=Microsoft.UI.Xaml.Media.Stretch.Uniform,IsHitTestVisible=false};
    private static Expander Details(string title,UIElement content)=>new(){Header=title,Content=content,HorizontalAlignment=HorizontalAlignment.Stretch,HorizontalContentAlignment=HorizontalAlignment.Stretch};
    private static Grid Split(FrameworkElement left,FrameworkElement right,double rightWidth=300){var grid=new Grid{ColumnSpacing=48};grid.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});grid.ColumnDefinitions.Add(new(){Width=new GridLength(rightWidth)});grid.Children.Add(left);Grid.SetColumn(right,1);grid.Children.Add(right);return grid;}
    private ToggleButton NavigateButton(string label,string page){var button=new ToggleButton{Content=label};button.Click+=(_,_)=>Navigate(page);navigation[page]=button;return button;}
    private Button LinkButton(string label,string page){var button=new Button{Content=label};button.Click+=(_,_)=>Navigate(page);return button;}
    private static Button Primary(Button button){button.Style=(Style)Application.Current.Resources["LimeLinkPrimaryButton"];return button;}
    private void Navigate(string page){desktopPage=page;foreach(var item in pages)item.Value.Visibility=item.Key==page?Visibility.Visible:Visibility.Collapsed;foreach(var item in navigation)item.Value.IsChecked=item.Key==page;scroll.ChangeView(null,0,null,true);if(page=="terminal")DispatcherQueue.TryEnqueue(ReportVisibleCards);}
    private void UpdateWorkspaceState(){
        UpdateAssistantRoute();
        if(sendForm is null)return;
        var connected=(spaces.ItemsSource as IEnumerable<string>)?.Any()==true;
        sendForm.Visibility=connected?Visibility.Visible:Visibility.Collapsed;sendEmpty.Visibility=connected?Visibility.Collapsed:Visibility.Visible;
        historyBody.Visibility=result.Text=="连接网关后，请选择空间并刷新电脑。"?Visibility.Collapsed:Visibility.Visible;
        footer.Visibility=historyBody.Visibility;
    }
    private static TextBlock Summary(TextBlock source){var label=Text("");label.SetBinding(TextBlock.TextProperty,new Binding{Source=source,Path=new PropertyPath("Text"),Mode=BindingMode.OneWay,Converter=new StatusConverter()});return label;}
    private sealed class StatusConverter:IValueConverter {
        public object Convert(object value,Type targetType,object parameter,string language)=>Status(value?.ToString()??"");
        public object ConvertBack(object value,Type targetType,object parameter,string language)=>throw new NotSupportedException();
    }
    private static string Status(string raw){
        var known=new Dictionary<string,string>{{"select_target_first","请选择电脑"},{"connect_first","请先连接网关"},{"pairing_required","请先与电脑配对"},{"pairing_not_approved","等待电脑批准配对"},{"gateway_text_model_not_configured","网关尚未配置 AI 服务"},{"select_space_first","请选择工作空间"},{"select_original_record","请选择一条记录"},{"no_original_model_task","暂无 AI 任务"},{"unauthenticated","登录已失效，请重新连接"},{"pending","等待批准"},{"approved","已配对"},{"rejected","已拒绝"},{"revoked","已取消配对"},{"expired","已过期"},{"confirmed","已完成"},{"accepted","已接收"},{"dispatched","已发送"},{"failed","未完成"},{"queued","等待显示"},{"presented","已显示"}};
        var first=raw.Split('\n')[0];if(known.TryGetValue(first,out var text))return text;foreach(var item in known)if(first.Contains(item.Key))return item.Value;
        if(first.Contains("unknown")||first.Contains("结果未知"))return "结果待确认，请查看历史";
        return first.Length>36?"请查看操作详情":first;
    }
    private void BuildWorkspace(out StackPanel modelCommands,out Button reconcile){
        var root=(Grid)XamlReader.Load("<Grid xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Background=\"{ThemeResource LLWorkspaceBackground}\" />");
        root.RowDefinitions.Add(new(){Height=GridLength.Auto});root.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});root.RowDefinitions.Add(new(){Height=GridLength.Auto});
        var top=new Grid{Height=72,Padding=new Thickness(28,0,28,0),ColumnSpacing=24};top.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});top.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        var mainNav=Row(NavigateButton("概览","home"),NavigateButton("助手","assistant"),NavigateButton("设备","terminal"),NavigateButton("协同","send"));mainNav.VerticalAlignment=VerticalAlignment.Center;top.Children.Add(mainNav);
        var settings=new ToggleButton{Content=new SymbolIcon(Symbol.Setting)};Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(settings,"设置");ToolTipService.SetToolTip(settings,"设置");settings.Click+=(_,_)=>Navigate("settings");navigation["settings"]=settings;
        var utility=Row(NavigateButton("网关","connection"),NavigateButton("历史","history"),settings);utility.VerticalAlignment=VerticalAlignment.Center;Grid.SetColumn(utility,1);top.Children.Add(utility);root.Children.Add(top);
        var canvas=new Grid{Padding=new Thickness(32),MaxWidth=1100,HorizontalAlignment=HorizontalAlignment.Stretch};controls.Content=canvas;scroll.Content=controls;scroll.HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled;Grid.SetRow(scroll,1);root.Children.Add(scroll);
        void Page(string key,FrameworkElement page){pages[key]=page;page.VerticalAlignment=VerticalAlignment.Top;canvas.Children.Add(page);}
        var hero=Split(Column(Text("连接你的设备，\n让助手接着做。",36),Row(Primary(LinkButton("打开助手","assistant")),LinkButton("连接网关","connection"))),Artwork("welcome",290),360);hero.MinHeight=310;Page("home",Column(hero,Row(LinkButton("设备","terminal"),LinkButton("内容协同","send"))));
        Page("assistant",BuildAssistant());
        sendEmpty=Split(Column(Text("连接后选择接收电脑",22),LinkButton("连接网关","connection")),Artwork("devices",240),280);
        var aiMenu=new MenuFlyout();var generate=new MenuFlyoutItem{Text="发送草稿到 AI 服务并整理"};generate.Click+=async(_,_)=>await Run(()=>ModelDraft(false));aiMenu.Items.Add(generate);var query=new MenuFlyoutItem{Text="查询上次结果"};query.Click+=async(_,_)=>await Run(()=>ModelDraft(true));aiMenu.Items.Add(query);modelCommands=Row(new Button{Content="AI 整理",Flyout=aiMenu});
        var pairing=Column(Text("与电脑配对",22),name,fingerprint,Row(Button("请求配对",()=>Action("pair")),Button("查询状态",()=>Action("status"))),Details("管理配对",Column(Button("重新配对",Reapply),Button("取消配对",()=>Action("revoke")))));
        var pair=new Button{Content="配对",Flyout=new Flyout{Content=pairing}};
        draft.Header=null;draft.MinHeight=260;targets.Header="发送到";name.Header="此设备名称";session.Header="会话编号（新建时留空）";revision.Header="版本";contentId.Header="内容编号（新建时留空）";
        var sessionActions=Column(session,revision,Row(Button("新建会话",()=>Action("session_create")),Button("开始编辑",()=>Action("session_claim")),Button("保存修改",()=>Action("session_write")),Button("结束编辑",()=>Action("session_release"))));
        var contentActions=Column(contentId,Row(Button("保存到电脑（1 小时）",()=>Action("content_put")),Button("删除保存内容",()=>Action("content_remove"))));
        sendForm=Column(Text("发送内容",22),Row(targets,pair),draft,Row(Button("语音输入",Dictate),modelCommands,Primary(Button("发送",()=>Action("card")))),Details("会话与保存",Column(Details("共同编辑",sessionActions),Details("保存内容",contentActions))));
        Page("send",Column(sendEmpty,sendForm));
        cloudControls.Children.Add(Button("登录",BeginCloud));cloudControls.Children.Add(authorizationView);cloudControls.Children.Add(Button("在浏览器中批准",OpenAuthorization));cloudControls.Children.Add(Row(Button("检查登录结果",PollCloud),Button("取消",CancelCloud)));cloudControls.Children.Add(cloudIdentity);
        route.Header="连接方式";route.ItemsSource=new[]{"网关连接","账号登录"};endpoint.Header="网关地址";token.Header="访问密钥";spaces.Header="工作空间";
        var connection=Column(Text("连接",22),route,endpoint,Details("使用访问密钥",token),Button("连接 / 恢复登录",Connect),cloudControls,spaces,Row(Button("查找电脑",Refresh),Button("断开连接",Logout)));connection.MaxWidth=620;connection.HorizontalAlignment=HorizontalAlignment.Left;Page("connection",connection);
        reconcile=Button("向网关核实",()=>Resolve(true));reconcile.Visibility=Visibility.Collapsed;
        cancelId.Header="消息编号";records.Header="记录";
        historyBody=Column(records,Summary(result),Row(Button("查询结果",Resolve),reconcile,Button("归档记录",Finish)),Details("操作详情",result),Details("取消发送",Column(cancelId,Button("取消尚未显示的内容",()=>Action("cancel")))));
        Page("history",Column(Text("历史",22),historyBody));
        Page("terminal",Column(Text("本机设备",22),Row(Button("导入设备配置",StartRuntime),Button("断开连接",StopRuntime)),Details("诊断",Button("导出诊断",ExportDiagnostics)),local));
        var status=Summary(result);status.FontSize=12;status.MaxLines=1;status.TextTrimming=TextTrimming.CharacterEllipsis;
        footer=new Grid{Padding=new Thickness(32,12,32,12)};var footerGrid=(Grid)footer;footerGrid.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});footerGrid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});footerGrid.Children.Add(status);var detail=LinkButton("详情","history");Grid.SetColumn(detail,1);footerGrid.Children.Add(detail);Grid.SetRow(footer,2);root.Children.Add(footer);
        var appearance=new ComboBox{Header="外观",ItemsSource=new[]{"浅色","深色","跟随系统"},SelectedIndex=ReadAppearance() switch{"light"=>0,"dark"=>1,_=>2},MinWidth=280};
        void ApplyAppearance(){root.RequestedTheme=appearance.SelectedIndex switch{0=>ElementTheme.Light,1=>ElementTheme.Dark,_=>ElementTheme.Default};}
        ApplyAppearance();appearance.SelectionChanged+=(_,_)=>{ApplyAppearance();try{Directory.CreateDirectory(Path.GetDirectoryName(preferencePath)!);File.WriteAllText(preferencePath,appearance.SelectedIndex switch{0=>"light",1=>"dark",_=>"system"});}catch(IOException){result.Text="外观设置未能保存";}catch(UnauthorizedAccessException){result.Text="外观设置未能保存";}};
        Page("settings",Column(Text("设置",22),Row(Artwork("icon",64),Column(Text("LimeLink",22),Text("0.1.0 开发版",12))),appearance,BuildLocalAgentSettings()));
        Content=root;var hwnd=WinRT.Interop.WindowNative.GetWindowHandle(this);var scale=Math.Max(1,GetDpiForWindow(hwnd)/96.0);var area=Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id,Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;AppWindow.Resize(new SizeInt32((int)Math.Min(1280*scale,area.Width),(int)Math.Min(800*scale,area.Height)));AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory,"Assets","Desktop","LimeLink.ico"));Navigate("home");UpdateWorkspaceState();
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")]private static extern uint GetDpiForWindow(IntPtr hwnd);
}
