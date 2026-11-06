#!/usr/bin/env python3
"""在非 Windows 主机核对 WinUI C# 类型；不验证 XAML、打包或窗口行为。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument("--dotnet",default="dotnet")
args=parser.parse_args()
app=ROOT/"apps/windows/LimeLink.App"
original=ET.parse(app/"LimeLink.App.csproj").getroot()
directory=ROOT/".dev/windows-source-check"
directory.mkdir(parents=True,exist_ok=True)
project=ET.Element("Project",Sdk="Microsoft.NET.Sdk")
properties=ET.SubElement(project,"PropertyGroup")
for name,value in {
    "TargetFramework":original.findtext(".//TargetFramework"),
    "EnableWindowsTargeting":"true","EnableDefaultCompileItems":"false",
    "ImplicitUsings":"enable","Nullable":"enable","TreatWarningsAsErrors":"true","OutputType":"Library"
}.items():ET.SubElement(properties,name).text=value
items=ET.SubElement(project,"ItemGroup")
for package in original.findall(".//PackageReference"):
    # 去掉平台构建任务，只消费真实 SDK 的编译引用。
    ET.SubElement(items,"PackageReference",**package.attrib,ExcludeAssets="build;buildTransitive")
for reference in original.findall(".//ProjectReference"):
    ET.SubElement(items,"ProjectReference",Include=str((app/reference.attrib["Include"]).resolve()))
files=sorted(path for path in app.glob("*.cs") if not path.name.endswith(".xaml.cs"))
for file in files:ET.SubElement(items,"Compile",Include=str(file))
ET.indent(project)
ET.ElementTree(project).write(directory/"check.csproj",encoding="unicode")
inputs=[ROOT/"tools/check-windows-sources.py",app/"LimeLink.App.csproj",*files,ROOT/"contracts/iot-sdk.lock.json"]
core=ROOT/"apps/windows/LimeLink.Core"
inputs.extend(core.glob("*.cs"));inputs.extend(core.glob("*.csproj"))
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def sources():return {str(path.relative_to(ROOT)):digest(path) for path in sorted(inputs)}
before=sources();started=datetime.now(timezone.utc).isoformat()
with (directory/"build.log").open("w") as output:
    result=subprocess.run([args.dotnet,"build",str(directory/"check.csproj")],cwd=ROOT,stdout=output,stderr=subprocess.STDOUT,env={**os.environ,"DOTNET_CLI_TELEMETRY_OPTOUT":"1"})
after=sources()
passed=result.returncode==0 and before==after
report={"passed":passed,"exit_code":result.returncode,"scope":"WinUI C# 类型检查，消费真实 SDK 引用；不运行 XAML 编译器，不证明完整 WinUI 构建或原生窗口", "started_at":started,"verified_at":datetime.now(timezone.utc).isoformat(),"sources":after,"log_sha256":digest(directory/"build.log"),"generated_project_sha256":digest(directory/"check.csproj"),"xaml_compiled":False,"native_ui":False,"package_created":False}
(ROOT/"docs/evidence/windows-source-check.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
print(json.dumps({"passed":passed,"exit_code":result.returncode,"scope":report["scope"]},ensure_ascii=False))
raise SystemExit(0 if passed else 1)
