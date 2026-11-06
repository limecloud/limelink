#if os(macOS)
import Foundation
import CryptoKit
import LimeLinkCore

func mobileDeviceDeploymentChecks()throws{
    func check(_ condition:Bool,_ code:String)throws{if !condition{throw LinkError(code)}}
    let parsed=MobileDeviceDeployment.androidDevices("List of devices attached\nUSB123 device usb:1 product:test model:Xiaomi_13 transport_id:1\nUSB456 unauthorized usb:2\nUSB789 offline\n192.168.1.10:5555 device model:Wireless\n$(id) device\n")
    try check(parsed.count==3 && parsed[0].name=="Xiaomi 13" && parsed[0].installable && !parsed[1].installable && !parsed[2].installable,"usb_android_inventory")
    let identifier=UUID().uuidString
    func iphone(_ paired:String,_ developer:String,_ transport:String="wired")->[String:Any]{["identifier":identifier,"connectionProperties":["pairingState":paired,"transportType":transport],"deviceProperties":["developerModeStatus":developer,"name":"iPhone"],"hardwareProperties":["deviceType":"iPhone"]]}
    for(paired,developer,ready) in [("paired","enabled",true),("unpaired","enabled",false),("paired","disabled",false)]{
        let data=try JSONSerialization.data(withJSONObject:["result":["devices":[iphone(paired,developer),iphone("paired","enabled","network")]]])
        let devices=try MobileDeviceDeployment.iosDevices(data)
        try check(devices.count==1 && devices[0].installable==ready,"usb_ios_inventory")
    }
    let files=FileManager.default,root=files.temporaryDirectory.appendingPathComponent("limelink-mobile-\(UUID().uuidString)")
    try files.createDirectory(at:root,withIntermediateDirectories:false);defer{try? files.removeItem(at:root)}
    let executable=root.appendingPathComponent("adb"),record=root.appendingPathComponent("arguments.json"),restricted=root.appendingPathComponent("restricted")
    let script="""
    #!/usr/bin/python3
    import json,sys
    from pathlib import Path
    file=Path(\(String(reflecting:record.path)))
    rows=json.loads(file.read_text()) if file.exists() else []
    rows.append(sys.argv[1:]);file.write_text(json.dumps(rows))
    if sys.argv[1:]==['devices','-l']:print('List of devices attached\\nUSB123 device usb:1 product:test model:Xiaomi_13 transport_id:1')
    elif 'install' in sys.argv:
        if Path(\(String(reflecting:restricted.path))).exists():
            print('adb: failed to install: Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]',file=sys.stderr);sys.exit(1)
        print('Success')
    elif 'start' in sys.argv:print('Status: ok')
    else:sys.exit(2)
    """
    try Data(script.utf8).write(to:executable);try files.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
    let deployment=MobileDeviceDeployment(tools:MobileDeviceTools(adb:executable,devicectl:nil)),device=try deployment.devices()[0]
    let apk=root.appendingPathComponent("LimeLink 'literal' $(id).apk"),data=Data([0x50,0x4b,0x03,0x04,1,2,3,4])
    try data.write(to:apk)
    let sha=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),connection=try GatewayConnectionRequest(origin:"https://gateway.example.com")
    do{try deployment.install(device,package:apk,expectedSHA256:String(repeating:"0",count:64),connection:connection);throw LinkError("bad_apk_installed")}catch let error as LinkError{try check(error.code=="mobile_package_checksum_mismatch","bad_apk_failure")}
    try deployment.install(device,package:apk,expectedSHA256:sha,connection:connection)
    let rows=try JSONDecoder().decode([[String]].self,from:Data(contentsOf:record))
    let installs=rows.filter{$0.contains("install")}
    try check(installs==[["-s","USB123","install","-r","--no-incremental",apk.path]],"usb_install_target_or_literal_path")
    let launch=rows.last!
    try check(launch.prefix(2)==["-s","USB123"] && launch.last==connection.url.absoluteString && !launch.joined().contains("token") && !rows.contains(where:{$0.contains("uninstall")}),"usb_installation_preserves_identity")
    try Data().write(to:restricted)
    do{try deployment.install(device,package:apk,expectedSHA256:sha,connection:connection);throw LinkError("restricted_installation_succeeded")}catch let error as LinkError{try check(error.code=="android_usb_installation_restricted","usb_restriction_not_reported")}
    let failedRows=try JSONDecoder().decode([[String]].self,from:Data(contentsOf:record))
    try check(failedRows.count==rows.count+2 && failedRows.last?.contains("install")==true,"restricted_installation_retried_or_launched")
}
#endif
