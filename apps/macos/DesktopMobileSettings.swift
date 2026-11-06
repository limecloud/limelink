import SwiftUI
import AppKit
import LimeLinkCore

@MainActor final class MobileDeviceController:ObservableObject {
    @Published private(set) var tools:MobileDeviceTools?
    @Published private(set) var devices:[MobileDevice]=[]
    @Published private(set) var busy=false
    @Published private(set) var message=""
    @Published private(set) var iosPackage:URL?
    @Published var origin=""
    private var prepared=false
    private struct AndroidPackage:Decodable{let filename:String;let sha256:String;let packageId:String}
    private var androidPackage:(url:URL,sha256:String)? {
        guard let record=Bundle.main.url(forResource:"AndroidApp",withExtension:"json"),
              let value=try? JSONDecoder().decode(AndroidPackage.self,from:Data(contentsOf:record)),value.filename=="LimeLink-android.apk",value.packageId=="run.limeai.limelink",value.sha256.count==64,
              let url=Bundle.main.url(forResource:"LimeLink-android",withExtension:"apk") else{return nil}
        return(url,value.sha256)
    }
    var androidPackageAvailable:Bool{androidPackage != nil}
    var validOrigin:Bool {
        guard let request=try? GatewayConnectionRequest(origin:origin),let host=URL(string:request.origin)?.host else{return false}
        return !["127.0.0.1","localhost","[::1]","::1","0.0.0.0"].contains(host)
    }
    func prepare(origin:String){
        if self.origin.isEmpty{self.origin=origin}
        guard !prepared else{return};prepared=true;refresh()
    }
    func refresh(){
        guard !busy else{return};busy=true;message="正在检测 USB 设备…"
        Task{
            let result=await Task.detached(priority:.userInitiated){()->(MobileDeviceTools,Result<[MobileDevice],Error>) in
                let tools=MobileDeviceTools.discover()
                return(tools,Result{try MobileDeviceDeployment(tools:tools).devices()})
            }.value
            tools=result.0;busy=false
            switch result.1{case .success(let devices):self.devices=devices;message=devices.isEmpty ? "尚未发现已授权的手机。" : "";case .failure:devices=[];message="未完成设备检测，请检查 Android 工具或 Xcode。"}
        }
    }
    func chooseIOSPackage(){
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=true;panel.message="选择已签名、包含当前 iPhone 授权的 LimeLink .app"
        guard panel.runModal() == .OK,let url=panel.url,url.pathExtension=="app" else{return}
        iosPackage=url
    }
    func canInstall(_ device:MobileDevice)->Bool{!busy && validOrigin && device.installable && (device.platform == .android ? androidPackageAvailable : iosPackage != nil)}
    func install(_ device:MobileDevice){
        guard canInstall(device),let tools,let request=try? GatewayConnectionRequest(origin:origin) else{return}
        let package:URL,sha:String?
        if device.platform == .android{guard let androidPackage else{return};package=androidPackage.url;sha=androidPackage.sha256}
        else{guard let iosPackage else{return};package=iosPackage;sha=nil}
        busy=true;message="正在安装，请保持手机解锁，并允许手机上的安装提示。"
        Task{
            let result=await Task.detached(priority:.userInitiated){Result{try MobileDeviceDeployment(tools:tools).install(device,package:package,expectedSHA256:sha,connection:request)}}.value
            busy=false
            switch result {
            case .success:message="App 已安装并打开。请在手机确认网关地址，登录后连接。"
            case .failure(let error):
                switch (error as? LinkError)?.code {
                case "mobile_device_changed_refresh_required":message="手机连接状态已变化，请重新检测。"
                case "mobile_package_checksum_mismatch":message="安装包校验失败，请重新获取完整应用。"
                case "android_usb_installation_restricted":message="手机已阻止 USB 安装。请开启开发者选项中的“USB 安装”，并允许手机上的安装提示后重试。"
                case "signed_ios_app_required","ios_app_signature_invalid":message="请选择已正确签名的 LimeLink iOS App，并确认签名包含当前设备。"
                case "mobile_installed_launch_failed":message="App 已安装，但未能打开。请在手机打开 LimeLink。"
                default:message="安装未完成，请先核实手机上的 App 状态。Android 需允许 USB 安装，iPhone 需有效签名和开发者模式。"
                }
            }
        }
    }
}

struct DesktopMobileSettings:View {
    @ObservedObject var mobile:MobileDeviceController
    var currentOrigin:String
    @State private var connectionExpanded=false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    private var p:DesktopPalette{DesktopPalette(scheme:scheme)}
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            HStack{Text("连接手机").fontWeight(.semibold);Spacer();Button("重新检测",action:mobile.refresh).disabled(mobile.busy)}
            if !mobile.devices.isEmpty{
                DesktopRule()
                ForEach(mobile.devices){device in
                    HStack(spacing:16){Image(systemName:device.platform == .ios ? "iphone" : "smartphone");VStack(alignment:.leading,spacing:4){Text(device.name);Text(device.stateText).font(.system(size:12)).foregroundStyle(p("slate11"))};Spacer();
                        if device.platform == .ios && device.installable && mobile.iosPackage == nil{Button("选择安装包",action:mobile.chooseIOSPackage)}
                        else{Button("安装并连接"){mobile.install(device)}.buttonStyle(DesktopButtonStyle(primary:true)).disabled(!mobile.canInstall(device))}
                    }
                }
            }
            if mobile.devices.contains(where:{$0.platform == .android}) && !mobile.androidPackageAvailable{Text("未找到手机安装包，请更新电脑应用。").font(.system(size:12)).foregroundStyle(p("slate11"))}
            if mobile.devices.isEmpty && !mobile.busy{Text("用 USB 连接手机，解锁后允许此电脑。").font(.system(size:12)).foregroundStyle(p("slate11"))}
            DisclosureGroup("连接设置",isExpanded:$connectionExpanded){connectionSettings.padding(.top,12)}
            DisclosureGroup("安装准备"){
                VStack(alignment:.leading,spacing:16){
                    Text("Android").fontWeight(.medium)
                    Text("开启 USB 调试与 USB 安装，连接后允许此电脑。").font(.system(size:12)).foregroundStyle(p("slate11"))
                    if mobile.tools?.adb == nil{Button("获取 Android 工具"){openURL(URL(string:"https://developer.android.com/tools/releases/platform-tools")!)}}
                    DesktopRule()
                    Text("iPhone").fontWeight(.medium)
                    Text("解锁并信任此电脑，开启开发者模式。安装包须包含当前设备的签名授权。").font(.system(size:12)).foregroundStyle(p("slate11"))
                    if mobile.tools?.devicectl == nil{Button("获取 Xcode"){openURL(URL(string:"https://apps.apple.com/app/xcode/id497799835")!)}}
                    else{HStack{Text(mobile.iosPackage?.lastPathComponent ?? "尚未选择 iOS App");Spacer();Button("选择已签名 App",action:mobile.chooseIOSPackage)}}
                }.padding(.top,12)
            }
            if !mobile.message.isEmpty{Text(mobile.message).font(.system(size:12)).foregroundStyle(p("slate11")).accessibilityLabel("手机安装状态："+mobile.message)}
        }.buttonStyle(DesktopButtonStyle()).disabled(mobile.busy).task{mobile.prepare(origin:currentOrigin);connectionExpanded = !mobile.validOrigin}
    }
    private var connectionSettings:some View {
        VStack(alignment:.leading,spacing:8){
            Text("网关地址")
            DesktopInput{TextField("手机可访问的网关地址",text:$mobile.origin).accessibilityLabel("手机连接的网关地址")}
            if !mobile.origin.isEmpty && !mobile.validOrigin{Text("请使用手机能访问的局域网地址或公网域名。").font(.system(size:12)).foregroundStyle(p("slate11"))}
        }
    }
}

struct DesktopMobileSetup:View {
    @ObservedObject var mobile:MobileDeviceController
    var origin:String
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:0){
            HStack{Text("连接手机").font(.system(size:22,weight:.semibold));Spacer();Button("完成"){dismiss()}.buttonStyle(DesktopButtonStyle())}.padding(28)
            DesktopRule()
            ScrollView{DesktopMobileSettings(mobile:mobile,currentOrigin:origin).padding(28)}
        }.font(.system(size:14)).frame(width:680,height:720).background{DesktopBackdrop()}
    }
}
