#if os(macOS)
import Foundation
import CryptoKit

public enum MobilePlatform:String,Sendable {case android,ios}
public struct MobileDevice:Identifiable,Equatable,Sendable {
    public let identifier:String
    public let name:String
    public let platform:MobilePlatform
    public let state:String
    public var id:String{platform.rawValue+":"+identifier}
    public var installable:Bool{state=="ready"}
    public var stateText:String {
        switch state{case "ready":return "已连接";case "unauthorized":return "请在手机允许 USB 调试";case "offline":return "设备离线，请重新连接";case "developer_mode_required":return "请开启开发者模式";default:return "请解锁并信任此电脑"}
    }
}
public struct MobileDeviceTools:Sendable {
    public let adb:URL?
    public let devicectl:URL?
    public init(adb:URL?,devicectl:URL?){self.adb=adb;self.devicectl=devicectl}
    public static func discover(environment:[String:String]=ProcessInfo.processInfo.environment,bundle:URL=Bundle.main.bundleURL)->Self {
        let directories=(environment["PATH"] ?? "").split(separator:":").map(String.init)+["/opt/homebrew/bin","/usr/local/bin",NSHomeDirectory()+"/Library/Android/sdk/platform-tools"]
        let candidates=[environment["LIMELINK_ADB"],bundle.appendingPathComponent("Contents/Resources/AndroidTools/adb").path,environment["ANDROID_HOME"].map{$0+"/platform-tools/adb"}].compactMap{$0}+directories.map{$0+"/adb"}
        let adb=candidates.first{path in
            guard path.hasPrefix("/"),let result=try? GatewayProcess.run(path,["version"],timeout:3) else{return false}
            return result.status==0 && String(decoding:result.data,as:UTF8.self).contains("Android Debug Bridge version ")
        }.map{URL(fileURLWithPath:$0)}
        let devicectl:URL?
        if let result=try? GatewayProcess.run("/usr/bin/xcrun",["--find","devicectl"],timeout:5),result.status==0,
           let path=String(data:result.data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),path.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:path){devicectl=URL(fileURLWithPath:path)}else{devicectl=nil}
        return Self(adb:adb,devicectl:devicectl)
    }
}

/// 只操作明确选中的USB设备；安装失败不会卸载、擦除数据或自动重试。
public struct MobileDeviceDeployment:Sendable {
    public let tools:MobileDeviceTools
    public init(tools:MobileDeviceTools){self.tools=tools}
    public func devices()throws->[MobileDevice] {
        var devices=[MobileDevice]()
        if let adb=tools.adb {
            let result=try GatewayProcess.run(adb.path,["devices","-l"],timeout:10)
            guard result.status==0 else{throw LinkError("android_device_listing_failed")}
            devices += Self.androidDevices(String(decoding:result.data,as:UTF8.self))
        }
        if let devicectl=tools.devicectl {
            let file=FileManager.default.temporaryDirectory.appendingPathComponent("limelink-iphone-\(UUID().uuidString).json")
            defer{try? FileManager.default.removeItem(at:file)}
            let result=try GatewayProcess.run(devicectl.path,["list","devices","--json-output",file.path],timeout:15)
            guard result.status==0 else{throw LinkError("ios_device_listing_failed")}
            let data=try Data(contentsOf:file)
            guard data.count<=1_000_000 else{throw LinkError("ios_device_listing_budget")}
            devices += try Self.iosDevices(data)
        }
        return devices
    }
    public static func androidDevices(_ output:String)->[MobileDevice] {
        output.split(whereSeparator:{$0.isNewline}).compactMap{line in
            let fields=line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            guard fields.count>=2,fields[0].range(of:"^[A-Za-z0-9_-]{1,128}$",options:.regularExpression) != nil,
                  ["device","unauthorized","offline"].contains(fields[1]) else{return nil}
            let model=fields.first{$0.hasPrefix("model:")}.map{String($0.dropFirst(6)).replacingOccurrences(of:"_",with:" ")}
            return MobileDevice(identifier:fields[0],name:model ?? "Android 手机",platform:.android,state:fields[1]=="device" ? "ready" : fields[1])
        }
    }
    public static func iosDevices(_ data:Data)throws->[MobileDevice] {
        guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],let result=json["result"] as? [String:Any],let rows=result["devices"] as? [[String:Any]] else{throw LinkError("invalid_ios_device_listing")}
        return rows.compactMap{row in
            guard let identifier=row["identifier"] as? String,UUID(uuidString:identifier) != nil,
                  let connection=row["connectionProperties"] as? [String:Any],connection["transportType"] as? String=="wired",
                  let hardware=row["hardwareProperties"] as? [String:Any],["iPhone","iPad"].contains(hardware["deviceType"] as? String ?? ""),
                  let device=row["deviceProperties"] as? [String:Any] else{return nil}
            let paired=connection["pairingState"] as? String=="paired",developer=device["developerModeStatus"] as? String=="enabled"
            return MobileDevice(identifier:identifier,name:String((device["name"] as? String ?? "iPhone").prefix(80)),platform:.ios,state:!paired ? "unpaired" : !developer ? "developer_mode_required" : "ready")
        }
    }
    public func install(_ device:MobileDevice,package:URL,expectedSHA256:String?=nil,connection:GatewayConnectionRequest)throws {
        guard device.installable,try devices().contains(device) else{throw LinkError("mobile_device_changed_refresh_required")}
        guard package.isFileURL,package.path.hasPrefix("/"),(try package.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else{throw LinkError("invalid_mobile_package")}
        let executable:URL,arguments:[String],launch:[String]
        switch device.platform {
        case .android:
            guard let adb=tools.adb,package.pathExtension=="apk",let expectedSHA256 else{throw LinkError("verified_android_package_required")}
            let attributes=try FileManager.default.attributesOfItem(atPath:package.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,((attributes[.size] as? NSNumber)?.int64Value ?? Int64.max)<=256_000_000 else{throw LinkError("invalid_mobile_package")}
            let data=try Data(contentsOf:package,options:.mappedIfSafe)
            guard data.starts(with:[0x50,0x4b,0x03,0x04]),Data(SHA256.hash(data:data)).hex==expectedSHA256 else{throw LinkError("mobile_package_checksum_mismatch")}
            executable=adb;arguments=["-s",device.identifier,"install","-r","--no-incremental",package.path]
            launch=["-s",device.identifier,"shell","am","start","-W","-n","run.limeai.limelink/run.limeai.link.MainActivity","-a","android.intent.action.VIEW","-d",connection.url.absoluteString]
        case .ios:
            guard let devicectl=tools.devicectl,package.pathExtension=="app",
                  let plist=try PropertyListSerialization.propertyList(from:Data(contentsOf:package.appendingPathComponent("Info.plist")),format:nil) as? [String:Any],plist["CFBundleIdentifier"] as? String=="run.limeai.limelink" else{throw LinkError("signed_ios_app_required")}
            let verification=try GatewayProcess.run("/usr/bin/codesign",["--verify","--deep","--strict",package.path],timeout:30)
            guard verification.status==0 else{throw LinkError("ios_app_signature_invalid")}
            executable=devicectl;arguments=["device","install","app","--device",device.identifier,package.path]
            // devicectl随Xcode提供；签名和设备开发授权由Apple工具核验。
            launch=["device","process","launch","--device",device.identifier,"--environment-variables",String(decoding:try JSONSerialization.data(withJSONObject:["LIMELINK_ENDPOINT":connection.origin]),as:UTF8.self),"run.limeai.limelink"]
        }
        let result=try GatewayProcess.run(executable.path,arguments,timeout:180)
        guard result.status==0 else{
            if device.platform == .android,String(decoding:result.data,as:UTF8.self).contains("Failure [INSTALL_FAILED_USER_RESTRICTED:"){
                throw LinkError("android_usb_installation_restricted")
            }
            throw LinkError("mobile_installation_failed_query_device")
        }
        if device.platform == .android{guard String(decoding:result.data,as:UTF8.self).split(whereSeparator:{$0.isNewline}).contains("Success") else{throw LinkError("mobile_installation_result_unknown")}}
        let opened=try GatewayProcess.run(executable.path,launch,timeout:30)
        guard opened.status==0,!String(decoding:opened.data,as:UTF8.self).contains("Error:") else{throw LinkError("mobile_installed_launch_failed")}
    }
}
#endif
