#!/usr/bin/env python3
"""构建独立、临时签名的本地 App，不安装系统服务或发布制品。"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--gateway-bundle",type=Path,help="显式附带已校验的离线网关包")
parser.add_argument("--android-apk",type=Path,help="显式附带当前产品的Android安装包")
parser.add_argument("--aapt",type=Path,help="核验Android安装包标识的Android Build Tools aapt")
args=parser.parse_args()
subprocess.run(["swift","build","-c","release","-j","4","--product","LimeLink"],cwd=root,check=True)
subprocess.run(["cargo","build","--manifest-path","runtime/Cargo.toml","--release","--locked"],cwd=root,check=True)
app=root/".dev/artifacts/LimeLink.app"
mac=app/"Contents/MacOS"; resources=app/"Contents/Resources"
mac.mkdir(parents=True,exist_ok=True);resources.mkdir(parents=True,exist_ok=True)
shutil.copy2(root/".build/release/LimeLink",mac/"LimeLink")
shutil.copy2(root/"runtime/target/release/limelink-runtime",mac/"limelink-runtime")
shutil.copy2(root/"runtime/target/release/limelink-gateway",mac/"limelink-gateway")
sdk=json.loads((root/"contracts/iot-sdk.lock.json").read_text())
assert sdk["worktree_overlay"] is False,"部署引导只接受固定上游提交"
(resources/"IoTDeploymentSource.json").write_text(json.dumps({key:sdk[key] for key in ("repository","head","worktree_overlay")},indent=2)+"\n")
android_manifest=resources/"AndroidApp.json"
if args.android_apk:
    apk=args.android_apk.resolve(strict=True)
    aapt=args.aapt or Path(os.environ.get("ANDROID_HOME","/missing"))/"build-tools/36.0.0/aapt"
    badging=subprocess.run([str(aapt),"dump","badging",str(apk)],check=True,capture_output=True,text=True,timeout=30).stdout
    assert badging.startswith("package: name='run.limeai.limelink' "),"只允许附带LimeLink Android安装包"
    sha=hashlib.sha256(apk.read_bytes()).hexdigest()
    target=resources/"LimeLink-android.apk";shutil.copy2(apk,target)
    assert hashlib.sha256(target.read_bytes()).hexdigest()==sha,"复制过程中Android安装包发生变化"
    android_manifest.write_text(json.dumps({"filename":target.name,"sha256":sha,"packageId":"run.limeai.limelink","sdkRevision":sdk["head"]},indent=2)+"\n")
elif android_manifest.exists():
    raise SystemExit("已有App包含Android包，请显式传入 --android-apk，避免沿用旧制品")
embedded=resources/"GatewayBundle"
if args.gateway_bundle:
    source=args.gateway_bundle.resolve(strict=True)
    subprocess.run([str(mac/"limelink-gateway"),"inspect","--bundle",str(source)],check=True,stdout=subprocess.DEVNULL)
    shutil.copytree(source,embedded,dirs_exist_ok=True)
    subprocess.run([str(mac/"limelink-gateway"),"inspect","--bundle",str(embedded)],check=True,stdout=subprocess.DEVNULL)
elif embedded.exists():
    raise SystemExit("已有App包含网关包，请显式传入 --gateway-bundle，避免隐式沿用旧制品")
for bundle in (root/".build/release").glob("*.bundle"):
    shutil.copytree(bundle,resources/bundle.name,dirs_exist_ok=True)
icon=root/"assets/desktop/icons/LimeLink.icns"
if icon.exists():shutil.copy2(icon,resources/"LimeLink.icns")
info={"CFBundleExecutable":"LimeLink","CFBundleIdentifier":"run.limeai.limelink","CFBundleName":"LimeLink","CFBundleDisplayName":"柠联 LimeLink","CFBundlePackageType":"APPL","CFBundleVersion":"1","CFBundleShortVersionString":"0.1.0","CFBundleIconFile":"LimeLink.icns","LSMinimumSystemVersion":"14.0","NSHighResolutionCapable":True,"NSMicrophoneUsageDescription":"仅在你主动创建语音草稿时录音。","NSSpeechRecognitionUsageDescription":"将录音识别为可编辑草稿，系统语音服务可能处理录音。","NSLocalNetworkUsageDescription":"发现同一网络中的 LimeIoT 网关，并连接你选择的网关。","NSBonjourServices":["_limeiot._tcp"]}
(app/"Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["codesign","--force","--sign","-",str(mac/"limelink-runtime")],check=True)
subprocess.run(["codesign","--force","--sign","-",str(mac/"limelink-gateway")],check=True)
subprocess.run(["codesign","--force","--deep","--sign","-",str(app)],check=True)
subprocess.run(["codesign","--verify","--deep","--strict",str(app)],check=True)
print(app.relative_to(root))
