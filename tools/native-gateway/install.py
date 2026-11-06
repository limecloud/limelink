#!/usr/bin/env python3
"""安装固定原生网关包到新目录；不安装依赖、不修改Nginx/防火墙、不自动启动。"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import socket
import subprocess
from urllib.parse import urlsplit
import uuid

ROOT=Path(__file__).resolve().parent
USER="limelink"
UNIT_NAMES=("limelink-broker.service","limelink-gateway.service")


def verify(root):
    record=json.loads((root/"manifest.json").read_text())
    if record["kind"]!="limelink.native-gateway" or record["schema_version"]!=1:
        raise ValueError("unsupported_native_package")
    actual={str(p.relative_to(root)) for p in root.rglob("*") if p.is_file() and p!=root/"manifest.json"}
    if actual!=set(record["files"]):
        raise ValueError("native_package_files_changed")
    for relative,digest in record["files"].items():
        parts=Path(relative).parts
        if not parts or any(part in (".","..") for part in parts) or Path(relative).is_absolute():
            raise ValueError("invalid_native_package_path")
        path=root
        for part in parts:
            path=path/part
            if path.is_symlink():raise ValueError("native_package_symlink_refused")
        if not path.is_file() or path.stat().st_nlink!=1 or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
            raise ValueError("native_package_checksum_mismatch")
    return record


def units(release,state,mosquitto):
    common=f"""User={USER}
Group={USER}
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
InaccessiblePaths={state}/authority {state}/device-authority {state}/enrollment
Restart=on-failure
RestartSec=3
TimeoutStopSec=15
"""
    broker=f"""[Unit]
Description=LimeLink device broker (native mTLS)
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3
[Service]
{common}ExecStart={mosquitto} -c {state}/config/mosquitto.conf
[Install]
WantedBy=multi-user.target
"""
    gateway=f"""[Unit]
Description=LimeLink gateway (native)
Requires=limelink-broker.service
After=network.target limelink-broker.service
StartLimitIntervalSec=60
StartLimitBurst=3
[Service]
{common}WorkingDirectory={release}
ReadWritePaths={state}/data
ExecStart=/usr/bin/python3 -B {release}/run.py {state}
[Install]
WantedBy=multi-user.target
"""
    return dict(zip(UNIT_NAMES,(broker,gateway)))


def initialize(state,origin,record,http_port,plain_port,mqtt_port,mqtt_bind):
    # 此函数必须由专用普通用户执行；沿固定上游管理入口签发身份。
    import sys
    sys.path.insert(0,str(ROOT/"upstream/deploy/nas"))
    import manage
    import device_identity
    manage.init(state,origin)
    space="space-"+uuid.uuid4().hex[:16];device="desktop-"+uuid.uuid4().hex[:16]
    desktop=json.loads((ROOT/"desktop.json").read_text())
    revision="sha256:"+hashlib.sha256(json.dumps(desktop,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
    manage.save(state/"config/gateway.json",json.dumps({"space_id":space,"models":[desktop],"devices":[{"device_id":device,"model_revision":revision}]})+"\n")
    password=next(line for line in (state/"secrets/mqtt-passwords").read_text().splitlines() if line.startswith("gateway:"))
    manage.save(state/"secrets/mqtt-passwords",password+"\n")
    manage.save(state/"config/mqtt-acl",f"user gateway\ntopic read limeiot/v1/{space}/+/up/+\ntopic write limeiot/v1/{space}/+/down/+\nuser {device}\ntopic read limeiot/v1/{space}/{device}/down/+\ntopic write limeiot/v1/{space}/{device}/up/+\n")
    manage.save(state/"config/mosquitto.conf",device_identity.broker_config(str(state/"config"),str(state/"secrets"),str(state/"broker-tls"),plain_port,mqtt_port,mqtt_bind))
    enrollment=state/"enrollment";enrollment.mkdir(mode=0o700)
    device_identity.issue(state,device,enrollment/"desktop")
    metadata={"schema_version":1,"origin":origin,"http_port":http_port,"plain_port":plain_port,"mqtt_port":mqtt_port,"mqtt_bind":mqtt_bind,"space":space,"desktop_device":device,"upstream":record["upstream"],"started":False,"agent_enabled":False,"system_trust_changed":False}
    manage.save(state/"native.json",json.dumps(metadata,indent=2)+"\n")
    manage.save(state/"operation.json",json.dumps({"operation":"initialize","state":"installed"})+"\n")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action",choices=("inspect","install","initialize"))
    parser.add_argument("--origin")
    parser.add_argument("--directory",type=Path,default=Path("/var/lib/limelink"))
    parser.add_argument("--http-port",type=int,default=17880)
    parser.add_argument("--plain-port",type=int,default=18884)
    parser.add_argument("--mqtt-port",type=int,default=8883)
    parser.add_argument("--mqtt-bind",default="127.0.0.1")
    args=parser.parse_args();record=verify(ROOT)
    if args.action=="inspect":print(json.dumps({"ok":True,"platform":record["platform"],"upstream":record["upstream"],"distribution":record["distribution"]}));return
    url=urlsplit(args.origin or "")
    if url.scheme!="https" or not url.hostname or url.username or url.password or url.path or url.query or url.fragment or any(c in url.hostname for c in ("\n","\r","\x00")):
        parser.error("需要不含路径或凭据的HTTPS来源")
    ports=(args.http_port,args.plain_port,args.mqtt_port)
    if any(not 1024<=p<=65535 for p in ports) or len(set(ports))!=3:parser.error("三个服务端口必须不同且在1024至65535之间")
    bind=ipaddress.ip_address(args.mqtt_bind)
    if bind.version!=4 or not (bind.is_private or bind.is_loopback or bind.is_unspecified):parser.error("MQTT监听地址必须是回环、私网IPv4或0.0.0.0")
    existing_empty=args.action=="initialize" and args.directory.is_dir() and not any(args.directory.iterdir()) and args.directory.stat().st_uid==os.geteuid() and args.directory.stat().st_mode & 0o077==0
    if not args.directory.is_absolute() or (args.directory.exists() and not existing_empty) or args.directory.is_symlink() or any(part in (".","..") for part in args.directory.parts) or any(c not in "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-" for c in str(args.directory)):
        parser.error("安装目录须为新绝对路径；内部初始化只接受当前账号拥有的私有空目录")
    if args.action=="initialize":
        if os.geteuid()==0:parser.error("初始化必须由服务用户执行")
        initialize(args.directory,args.origin,record,*ports,args.mqtt_bind);return
    if os.geteuid()!=0:parser.error("安装系统服务需要管理员权限")
    if platform.system()!="Linux" or {"x86_64":"linux/amd64","aarch64":"linux/arm64"}.get(platform.machine())!=record["platform"]:parser.error("原生包架构与主机不符")
    for dependency in ("systemctl","openssl","mosquitto","runuser","useradd"):
        if not shutil.which(dependency):parser.error("缺少系统依赖："+dependency)
    if any((Path("/etc/systemd/system")/name).exists() for name in UNIT_NAMES):parser.error("已有同名服务，拒绝覆盖")
    for port in ports:
        with socket.socket() as probe:probe.bind(("0.0.0.0",port))
    try:
        account=pwd.getpwnam(USER)
        if account.pw_shell not in ("/usr/sbin/nologin","/sbin/nologin"):parser.error("同名账号不是专用服务账号")
    except KeyError:
        subprocess.run(["useradd","--system","--user-group","--home-dir",str(args.directory),"--no-create-home","--shell","/usr/sbin/nologin",USER],check=True)
        account=pwd.getpwnam(USER)
    releases=Path("/opt/limelink/releases");releases.mkdir(mode=0o755,parents=True,exist_ok=True)
    release=releases/(record["upstream"]["revision"]+"-native-"+record["platform"].split("/")[1])
    if release.exists():parser.error("版本目录已存在，保留原目录核实安装状态")
    shutil.copytree(ROOT,release)
    verify(release)
    parent=args.directory.parent
    if not parent.is_dir() or parent.is_symlink():parser.error("状态目录父级不存在或是符号链接")
    command=["runuser","-u",USER,"--","/usr/bin/python3","-B",str(release/"install.py"),"initialize","--origin",args.origin,"--directory",str(args.directory),"--http-port",str(args.http_port),"--plain-port",str(args.plain_port),"--mqtt-port",str(args.mqtt_port),"--mqtt-bind",args.mqtt_bind]
    # 先创建仅该账号可写的空目录；上游fresh会保留其所有权和权限。
    args.directory.mkdir(mode=0o700);os.chown(args.directory,account.pw_uid,account.pw_gid)
    subprocess.run(command,check=True)
    definitions=units(release,args.directory,shutil.which("mosquitto"))
    for name,body in definitions.items():(Path("/etc/systemd/system")/name).write_text(body)
    subprocess.run(["systemctl","daemon-reload"],check=True)
    print(json.dumps({"ok":True,"state":"installed","directory":str(args.directory),"release":str(release),"started":False,"agent_enabled":False,"system_trust_changed":False}))


if __name__=="__main__":
    try:main()
    except Exception:
        # 管理异常可能携带证书路径或工具输出；保留原安装，日志只给固定错误码。
        print(json.dumps({"ok":False,"code":"native_installation_incomplete_query_original"}))
        raise SystemExit(1)
