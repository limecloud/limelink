#!/usr/bin/env python3
"""检查安装引导的真实网络探测：公网就绪、未受信证书与关闭端口。"""
import argparse
from datetime import datetime,timezone
import hashlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-host",required=True)
    parser.add_argument("--https-port",type=int,default=443)
    parser.add_argument("--mqtt-port",type=int,default=8883)
    args=parser.parse_args()
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as route:
        route.connect(("1.1.1.1",53))
        address=route.getsockname()[0]
    assert ipaddress.IPv4Address(address) in ipaddress.IPv4Network("10.0.0.0/8") or ipaddress.IPv4Address(address) in ipaddress.IPv4Network("172.16.0.0/12") or ipaddress.IPv4Address(address) in ipaddress.IPv4Network("192.168.0.0/16"),"private_test_interface_required"
    directory=Path(tempfile.mkdtemp(prefix="remote-probe-",dir=ROOT/".dev"))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200);self.end_headers();self.wfile.write(b'{"status":"ok","broker_connected":true}')
        def log_message(self,*_):pass

    class Device(socketserver.BaseRequestHandler):
        def handle(self):pass

    cert=directory/"server.crt"
    key=directory/"server.key"
    subprocess.run(["openssl","req","-x509","-newkey","ec","-pkeyopt","ec_paramgen_curve:P-256","-nodes","-days","1","-subj","/CN=LimeLink Probe Fixture","-addext","subjectAltName=IP:"+address,"-keyout",str(key),"-out",str(cert)],check=True,capture_output=True)
    https=http.server.HTTPServer((address,0),Handler)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cert,key)
    https.socket=context.wrap_socket(https.socket,server_side=True)
    device=socketserver.TCPServer((address,0),Device)
    # 保留绑定且不监听，确保关闭端口不会被其他进程占用后误判可达。
    closed_https=socket.socket();closed_https.bind((address,0))
    closed_device=socket.socket();closed_device.bind((address,0))
    for server in (https,device):threading.Thread(target=server.serve_forever,daemon=True).start()
    cases=[
        {"host":args.public_host,"privateNetwork":False,"https":args.https_port,"mqtt":args.mqtt_port,"httpsReady":True,"deviceReady":True,"certificateError":False},
        {"host":address,"privateNetwork":True,"https":https.server_port,"mqtt":device.server_address[1],"httpsReady":False,"deviceReady":True,"certificateError":True},
        {"host":address,"privateNetwork":True,"https":closed_https.getsockname()[1],"mqtt":closed_device.getsockname()[1],"httpsReady":False,"deviceReady":False,"certificateError":False},
    ]
    inputs=directory/"cases.json";inputs.write_text(json.dumps(cases))
    paths=["tools/test-remote-gateway-probe.py","packages/apple/Sources/LimeLinkCore/RemoteGatewayPlan.swift","packages/apple/Sources/LimeLinkCore/RemoteGatewayProbe.swift","packages/apple/Tests/RemoteGatewayPlanChecks.swift","packages/apple/Tests/IdentityTests.swift","contracts/iot-sdk.lock.json"]
    def sources():return {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in paths}
    before=sources()
    try:
        with (directory/"checks.log").open("w") as log:
            result=subprocess.run(["swift","run","-j","4","LinkChecks"],cwd=ROOT,env={**os.environ,"LIMELINK_REMOTE_PROBE_CASES":str(inputs)},stdout=log,stderr=subprocess.STDOUT,timeout=180)
    finally:
        for server in (https,device):server.shutdown();server.server_close()
        closed_https.close();closed_device.close()
    after=sources()
    report={"passed":result.returncode==0 and before==after,"exit_code":result.returncode,"verified_at":datetime.now(timezone.utc).isoformat(),"scope":"Apple核心安装引导网络探测，公网HTTPS/设备TCP可达、未受信证书拒绝与关闭端口；不是设备证书或手机验收","cases":cases,"sources":after,"log_sha256":hashlib.sha256((directory/"checks.log").read_bytes()).hexdigest(),"native_ui":False,"system_trust_changed":False}
    (ROOT/".dev/remote-gateway-probe.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({"passed":report["passed"],"cases":len(cases),"exit_code":result.returncode,"log":str(directory/"checks.log")},ensure_ascii=False))
    raise SystemExit(0 if report["passed"] else 1)


if __name__=="__main__":main()
