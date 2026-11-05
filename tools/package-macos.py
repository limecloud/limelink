#!/usr/bin/env python3
"""构建独立、临时签名的本地 App，不安装系统服务或发布制品。"""
from pathlib import Path
import plistlib
import shutil
import subprocess

root=Path(__file__).resolve().parents[1]
subprocess.run(["swift","build","-c","release","-j","4","--product","LimeLink"],cwd=root,check=True)
subprocess.run(["cargo","build","--manifest-path","runtime/Cargo.toml","--release","--locked"],cwd=root,check=True)
app=root/".dev/artifacts/LimeLink.app"
mac=app/"Contents/MacOS"; resources=app/"Contents/Resources"
mac.mkdir(parents=True,exist_ok=True);resources.mkdir(parents=True,exist_ok=True)
shutil.copy2(root/".build/release/LimeLink",mac/"LimeLink")
shutil.copy2(root/"runtime/target/release/limelink-runtime",mac/"limelink-runtime")
for bundle in (root/".build/release").glob("*.bundle"):
    shutil.copytree(bundle,resources/bundle.name,dirs_exist_ok=True)
icon=root/"docs/brand/assets/macos/LimeLink.icns"
if icon.exists():shutil.copy2(icon,resources/"LimeLink.icns")
info={"CFBundleExecutable":"LimeLink","CFBundleIdentifier":"run.limeai.limelink","CFBundleName":"LimeLink","CFBundleDisplayName":"柠联 LimeLink","CFBundlePackageType":"APPL","CFBundleVersion":"1","CFBundleShortVersionString":"0.1.0","CFBundleIconFile":"LimeLink.icns","LSMinimumSystemVersion":"14.0","NSHighResolutionCapable":True,"NSMicrophoneUsageDescription":"仅在你主动创建语音草稿时录音。","NSSpeechRecognitionUsageDescription":"将录音识别为可编辑草稿，系统语音服务可能处理录音。","NSLocalNetworkUsageDescription":"连接你选择的 LimeIoT 网关。"}
(app/"Contents/Info.plist").write_bytes(plistlib.dumps(info))
subprocess.run(["codesign","--force","--sign","-",str(mac/"limelink-runtime")],check=True)
subprocess.run(["codesign","--force","--deep","--sign","-",str(app)],check=True)
subprocess.run(["codesign","--verify","--deep","--strict",str(app)],check=True)
print(app.relative_to(root))
