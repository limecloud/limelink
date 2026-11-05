import SwiftUI
import AppKit
import LimeLinkUI

@main struct LimeLinkApp:App {
    var body:some Scene {
        WindowGroup { TabView { WorkbenchView().tabItem{Label("工作台",systemImage:"rectangle.connected.to.line.below")};LocalTerminalView().tabItem{Label("本机终端",systemImage:"desktopcomputer")} }.frame(minWidth:680,minHeight:700).onAppear{NSApplication.shared.setActivationPolicy(.regular);NSApplication.shared.activate(ignoringOtherApps:true)} }
            .defaultSize(width:860,height:820)
    }
}
