import SwiftUI

struct DesktopSettingsView:View {
    @ObservedObject var runtime:RuntimeBridge
    @AppStorage("limelink.appearance") private var appearance="system"
    @ObservedObject var gateway:LocalGatewayController
    @ObservedObject var mobile:MobileDeviceController
    @State private var section="gateway"
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        let p=DesktopPalette(scheme:scheme)
        ScrollView{VStack(alignment:.leading,spacing:24){
            HStack(spacing:16){DesktopArtwork(name:"icon").frame(width:64,height:64);VStack(alignment:.leading,spacing:6){Text("LimeLink").font(.system(size:22,weight:.semibold));Text("0.1.0 开发版").font(.system(size:12)).foregroundStyle(p("slate11"))}}
            DesktopRule()
            HStack(spacing:24){Text("外观");Picker("外观",selection:$appearance){Text("浅色").tag("light");Text("深色").tag("dark");Text("跟随系统").tag("system")}.labelsHidden().pickerStyle(.segmented)}
            DesktopRule()
            Picker("设置分类",selection:$section){Text("网关").tag("gateway");Text("本机助手").tag("agent");Text("手机").tag("mobile")}.labelsHidden().pickerStyle(.segmented)
            if section == "gateway"{DesktopGatewaySettings(gateway:gateway,runtime:runtime)}
            else if section == "mobile"{DesktopMobileSettings(mobile:mobile,currentOrigin:UserDefaults.standard.string(forKey:"limelink.endpoint") ?? "")}
            else{DesktopAgentSettings(runtime:runtime)}
        }.padding(28)}.font(.system(size:14)).foregroundStyle(p("slate12")).frame(width:640,height:720).background{DesktopBackdrop()}
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}
