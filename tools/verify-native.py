#!/usr/bin/env python3
"""执行指定的本机检查并记录真实退出码、源文件摘要；不把构建当真机验收。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument("--checks",nargs="+",required=True,choices=["runtime","apple","apple-agent","apple-workbench","discovery","macos","ios","android","dotnet"])
parser.add_argument("--gradle",default="gradle")
parser.add_argument("--dotnet",default="dotnet")
parser.add_argument("--gateway-bundle",help="macOS开发App显式附带的离线网关包")
parser.add_argument("--android-apk",help="macOS开发App显式附带的Android安装包")
parser.add_argument("--aapt",help="核验附带APK的Android aapt路径")
args=parser.parse_args()
specs={
    "runtime":(["cargo","test","--manifest-path","runtime/Cargo.toml","--locked"],".",["runtime"],"运行时存储、签名与协同状态；无原生 UI"),
    "apple":(["swift","run","-j","4","LinkChecks"],".",["packages/apple/Sources/LimeLinkCore","packages/apple/Tests","Package.swift","contracts/desktop.json"],"Apple 产品核心检查；非 iOS 构建"),
    "apple-agent":(["swift","run","-j","4","AgentChecks"],".",["packages/apple/Sources","packages/apple/AgentTests","Package.swift","contracts/desktop.json","contracts/fixtures/agent-responses.json","contracts/fixtures/agent-tools.json"],"Apple Agent 共用30组响应与57组工具合同、引用/设备意图持久化、逐次确认及原请求恢复；非模型或原生窗口"),
    "apple-workbench":(["swift","run","-j","4","WorkbenchChecks"],".",["packages/apple/Sources","packages/apple/WorkbenchTests","Package.swift"],"Apple 实际工作台模型的授权、路由、原操作与取消检查；非原生窗口或真机"),
    "discovery":(["swift","run","-j","4","DiscoveryChecks"],".",["packages/apple/Sources/LimeLinkCore/GatewayCandidate.swift","packages/apple/Sources/LimeLinkUI/GatewayDiscovery.swift","packages/apple/DiscoveryTests","contracts/fixtures/gateway-discovery.json","Package.swift"],"发现候选解析合同；真实 DNS-SD 生命周期见独立发现证据"),
    "macos":(["python3","tools/package-macos.py"],".",["packages/apple/Sources","apps/macos","assets/desktop","runtime","Package.swift","tools/package-macos.py","tools/generate-desktop-theme.py","tools/prepare-desktop-artwork.py"],"macOS release 构建与临时签名；非公证发行"),
    "ios":(["xcodebuild","-project","apps/ios/LimeLink.xcodeproj","-scheme","LimeLink","-sdk","iphonesimulator","-configuration","Debug","-derivedDataPath",".dev/ios-build","CODE_SIGNING_ALLOWED=NO","build"],".",["packages/apple/Sources","apps/ios","Package.swift"],"iOS 模拟器目标构建；非真机、签名或商店发行"),
    "android":([args.gradle,"--no-daemon",":core:test",":app:assembleDebug"],"apps/android",["apps/android","contracts/fixtures/agent-responses.json","contracts/fixtures/agent-tools.json","contracts/fixtures/gateway-discovery.json","contracts/desktop.json"],"Android Core（含 Agent 工具合同、确认与恢复、16组网关公告样例）和调试 APK；未配置的在线专项跳过，非 NSD 系统生命周期、原生窗口或真机验收"),
    "dotnet":([args.dotnet,"run","--project","apps/windows/LimeLink.Core.Checks"],".",["apps/windows/LimeLink.Core","apps/windows/LimeLink.Core.Checks","contracts/fixtures/agent-responses.json","contracts/fixtures/agent-tools.json","contracts/desktop.json"],"产品 .NET Core（含 Agent 共用30组响应、57组设备工具、确认与原请求恢复）；非 WinUI 运行"),
}
if args.gradle.endswith("gradlew"):
    specs["android"][0][:1]=["sh",str(Path(args.gradle).resolve())]
if args.gateway_bundle:
    specs["macos"][0].extend(["--gateway-bundle",str(Path(args.gateway_bundle).resolve())])
if args.android_apk:
    specs["macos"][0].extend(["--android-apk",str(Path(args.android_apk).resolve())])
if args.aapt:
    specs["macos"][0].extend(["--aapt",str(Path(args.aapt).resolve())])
for name in ("apple","android"):
    specs[name][2].append("contracts/fixtures/gateway-connection-links.json")
record_path=ROOT/"docs/evidence/native-validation.json"
record=json.loads(record_path.read_text()) if record_path.exists() else {"schema_version":1,"checks":{}}
sdk=json.loads((ROOT/"contracts/iot-sdk.lock.json").read_text())
assert sdk["worktree_overlay"] is False,"发布检查不接受 SDK 工作树覆盖"
ignored={"target","build","bin","obj",".gradle",".build","xcuserdata"}
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def sources(prefixes):
    result={"contracts/iot-sdk.lock.json":digest(ROOT/"contracts/iot-sdk.lock.json")}
    for prefix in prefixes:
        path=ROOT/prefix
        for file in ([path] if path.is_file() else path.rglob("*")):
            if file.is_file() and not ignored.intersection(file.relative_to(ROOT).parts):result[str(file.relative_to(ROOT))]=digest(file)
    return dict(sorted(result.items()))
failed=False
for name in args.checks:
    command,cwd,prefixes,scope=specs[name]
    output=ROOT/".dev"/("verify-"+name+".log");output.parent.mkdir(exist_ok=True)
    before=sources(prefixes);started=datetime.now(timezone.utc).isoformat()
    with output.open("w") as log:
        try:code=subprocess.run(command,cwd=ROOT/cwd,stdout=log,stderr=subprocess.STDOUT,env={**os.environ,"DOTNET_CLI_TELEMETRY_OPTOUT":"1"}).returncode
        except OSError as error:log.write(str(error));code=127
    after=sources(prefixes)
    status="passed" if code==0 and before==after else "failed"
    if name=="ios" and code!=0 and "requires Xcode" in output.read_text():status="blocked"
    record["checks"][name]={"status":status,"exit_code":code,"scope":scope,"started_at":started,"finished_at":datetime.now(timezone.utc).isoformat(),"sdk_revision":sdk["head"],"sources":after,"log_sha256":digest(output)}
    record_path.parent.mkdir(parents=True,exist_ok=True);record_path.write_text(json.dumps(record,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({"check":name,"status":status,"exit_code":code}),flush=True)
    failed|=status!="passed"
raise SystemExit(1 if failed else 0)
