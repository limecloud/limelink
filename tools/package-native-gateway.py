#!/usr/bin/env python3
"""构建Linux原生网关开发包：固定Git来源、glibc基线、独立systemd服务，不依赖Docker。"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parents[1]
MANAGEMENT=("LICENSE","deploy/dev/config.json","deploy/nas/manage.py","deploy/nas/device_identity.py","deploy/nas/media_state.py","deploy/nas/platform_install.py")


def sha(path):
    with path.open("rb") as source:return hashlib.file_digest(source,"sha256").hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source",type=Path,required=True)
    parser.add_argument("--build-source",type=Path,help="可选已有导出，完整输入必须匹配固定Git对象")
    parser.add_argument("--home-artifacts",type=Path,required=True,help="源码一致的已校验NAS网页制品，网页不区分CPU架构")
    parser.add_argument("--toolchain-cache",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args();output=args.output.absolute();source=args.source.resolve(strict=True)
    if output.exists():parser.error("输出目录已存在，拒绝覆盖")
    sdk=json.loads((ROOT/"contracts/iot-sdk.lock.json").read_text())
    if sdk["worktree_overlay"]:parser.error("拒绝SDK工作树覆盖")
    revision=sdk["head"]
    if subprocess.check_output(["git","-C",str(source),"rev-parse",revision+"^{commit}"],text=True).strip()!=revision:parser.error("上游固定提交不存在")
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="native-gateway-",dir=output.parent) as temporary:
        temporary=Path(temporary);archive=temporary/"source.tar";export=temporary/"source";export.mkdir()
        with archive.open("wb") as stream:subprocess.run(["git","-C",str(source),"archive",revision],stdout=stream,check=True)
        with tarfile.open(archive) as stream:stream.extractall(export,filter="data")
        spec=importlib.util.spec_from_file_location("pinned_nas",export/"tools/build-nas-artifacts.py")
        nas=importlib.util.module_from_spec(spec);spec.loader.exec_module(nas)
        inputs=nas.source_inputs()
        home=args.home_artifacts.resolve(strict=True);home_record=nas.verify(home)
        if home_record["source_files"]!=inputs:raise ValueError("网页制品与当前固定源码不一致")
        build_source=args.build_source.resolve(strict=True) if args.build_source else export
        nas.ROOT=build_source
        if nas.source_inputs()!=inputs:raise ValueError("已有导出存在源码差异")
        triple,_,machine,interpreter,std_hash=nas.TARGETS["linux/amd64"]
        nas.TARGETS["linux/amd64"]=(triple,"x86_64-linux-gnu.2.35",machine,interpreter,std_hash)
        environment,toolchain=nas.prepare_toolchain(args.toolchain_cache.resolve(),"linux/amd64",jobs=2)
        subprocess.run(["cargo","build","--locked","--release","--bin","limeiot-gateway","--target",triple],cwd=build_source,env=environment,check=True)
        binary=args.toolchain_cache.resolve()/"target"/triple/"release/limeiot-gateway"
        nas.check_elf(binary,"linux/amd64")
        if nas.source_inputs()!=inputs or nas.verify(home)!=home_record:raise ValueError("构建期间输入变化")
        package=temporary/"package";package.mkdir();(package/"bin").mkdir()
        shutil.copy2(binary,package/"bin/limeiot-gateway")
        shutil.copytree(home/"home",package/"home")
        for relative in MANAGEMENT:
            target=package/"upstream"/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(export/relative,target)
        shutil.copy2(ROOT/"contracts/desktop.json",package/"desktop.json")
        for name in ("install.py","run.py"):shutil.copy2(ROOT/"tools/native-gateway"/name,package/name)
        record={"schema_version":1,"kind":"limelink.native-gateway","platform":"linux/amd64","glibc_minimum":"2.35","distribution":"development_unsigned","upstream":{"repository":sdk["repository"],"revision":revision,"worktree_overlay":False,"archive_sha256":sha(archive),"source_digest":nas.canonical_digest(inputs)},"toolchain":toolchain,"files":{str(p.relative_to(package)):sha(p) for p in sorted(package.rglob("*")) if p.is_file()}}
        (package/"manifest.json").write_text(json.dumps(record,indent=2)+"\n")
        subprocess.run(["python3","-B",str(package/"install.py"),"inspect"],check=True)
        package.rename(output)
    with tarfile.open(output.with_suffix(".tar.gz"),"w:gz") as stream:stream.add(output,arcname="limelink-native")
    print(json.dumps({"ok":True,"directory":str(output),"platform":record["platform"],"glibc_minimum":record["glibc_minimum"],"revision":revision}))


if __name__=="__main__":main()
