import SwiftUI
import AppKit
import LimeLinkUI

@main struct LimeLinkApp:App {
    @AppStorage("limelink.appearance") private var appearance="system"
    @StateObject private var runtime=RuntimeBridge()
    @StateObject private var gateway=LocalGatewayController()
    @StateObject private var mobile=MobileDeviceController()
    var body:some Scene {
        WindowGroup { DesktopWorkspace(runtime:runtime,gateway:gateway,mobile:mobile).preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil).frame(minWidth:960,minHeight:600).onAppear{NSApplication.shared.setActivationPolicy(.regular);NSApplication.shared.activate(ignoringOtherApps:true)} }
            .defaultSize(width:1280,height:800)
        Settings { DesktopSettingsView(runtime:runtime,gateway:gateway,mobile:mobile) }
    }
}
