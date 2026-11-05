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
parser.add_argument("--checks",nargs="+",required=True,choices=["runtime","apple","macos","android","dotnet"])
parser.add_argument("--gradle",default="gradle")
parser.add_argument("--dotnet",default="dotnet")
args=parser.parse_args()
specs={
    "runtime":(["cargo","test","--manifest-path","runtime/Cargo.toml","--locked"],".",["runtime"],"运行时存储、签名与协同状态；无原生 UI"),
    "apple":(["swift","run","-j","4","LinkChecks"],".",["packages/apple/Sources/LimeLinkCore","packages/apple/Tests","Package.swift"],"Apple 产品核心检查；非 iOS 构建"),
    "macos":(["python3","tools/package-macos.py"],".",["packages/apple/Sources","apps/macos","runtime","Package.swift","tools/package-macos.py"],"macOS release 构建与临时签名；非公证发行"),
    "android":([args.gradle,"--no-daemon",":core:test",":app:assembleDebug"],"apps/android",["apps/android"],"Android Core 检查与调试 APK；非真机"),
    "dotnet":([args.dotnet,"run","--project","apps/windows/LimeLink.Core.Checks"],".",["apps/windows/LimeLink.Core","apps/windows/LimeLink.Core.Checks"],"产品 .NET Core；非 WinUI 运行"),
}
if args.gradle.endswith("gradlew"):
    specs["android"][0][:1]=["sh",str(Path(args.gradle).resolve())]
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
    record["checks"][name]={"status":status,"exit_code":code,"scope":scope,"started_at":started,"finished_at":datetime.now(timezone.utc).isoformat(),"sdk_revision":sdk["head"],"sources":after,"log_sha256":digest(output)}
    record_path.parent.mkdir(parents=True,exist_ok=True);record_path.write_text(json.dumps(record,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({"check":name,"status":status,"exit_code":code}),flush=True)
    failed|=status!="passed"
raise SystemExit(1 if failed else 0)
