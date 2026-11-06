#!/usr/bin/env python3
"""从服务器外验证原生网关的公开TLS、用户登录和桌面mTLS；凭据仅从私有目录读取。"""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
from http.cookies import SimpleCookie
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import time
from urllib.parse import urlsplit


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials",required=True,type=Path)
    parser.add_argument("--expected-address",required=True)
    parser.add_argument("--runtime",required=True,type=Path)
    parser.add_argument("--output",required=True,type=Path)
    args=parser.parse_args()
    root=args.credentials.resolve(strict=True)
    assert root.stat().st_mode & 0o077==0,"credential_directory_not_private"
    for name in ("native.json","device-ca.crt","device.crt","device.key","owner-token"):
        path=root/name
        assert path.is_file() and not path.is_symlink() and path.stat().st_mode & 0o077==0,"credential_file_not_private"
    meta=json.loads((root/"native.json").read_text())
    parts=urlsplit(meta["origin"])
    assert parts.scheme=="https" and parts.hostname and not parts.username and not parts.path
    host=parts.hostname
    events=[]

    def check(condition,code):
        assert condition,code
        events.append(code)

    check(args.expected_address in socket.gethostbyname_ex(host)[2],"public_dns_matches_authorized_server")
    cookie=""
    csrf=""

    def request(path,body=None,authenticated=True):
        connection=http.client.HTTPSConnection(host,parts.port or 443,timeout=12,context=ssl.create_default_context())
        headers={"Origin":meta["origin"],"Content-Type":"application/json"}
        if authenticated and cookie:headers.update({"Cookie":cookie,"X-CSRF-Token":csrf})
        try:
            connection.request("GET" if body is None else "POST",path,None if body is None else json.dumps(body),headers)
            response=connection.getresponse()
            data=response.read(65537)
            assert len(data)<=65536,"public_response_budget_exceeded"
            return response.status,json.loads(data) if data else {},response.getheaders()
        finally:connection.close()

    status,health,_=request("/healthz")
    check(status==200 and health.get("broker_connected") is True,"public_https_system_trust_and_broker_health")
    check(request("/api/v1/spaces",authenticated=False)[0]==401,"anonymous_https_owner_api_rejected")
    status,session,headers=request("/api/v1/auth/session",{"token":(root/"owner-token").read_text().strip()},authenticated=False)
    jar=SimpleCookie()
    for key,value in headers:
        if key.lower()=="set-cookie":jar.load(value)
    assert "__Host-limeiot_session" in jar,"secure_cookie_missing"
    morsel=jar["__Host-limeiot_session"]
    check(status==200 and session.get("authenticated") is True and morsel["secure"] and morsel["httponly"],"public_owner_login_secure_httponly_cookie")
    cookie=morsel.key+"="+morsel.value
    csrf=session["csrf_token"]
    try:
        spaces=request("/api/v1/spaces")[1]["items"]
        check([x["space_id"] for x in spaces]==[meta["space"]],"public_owner_unique_space")
        device_path="/api/v1/spaces/"+meta["space"]+"/devices"
        devices=request(device_path)[1]["items"]
        check(len(devices)==1 and devices[0]["device_id"]==meta["desktop_device"] and not devices[0]["ready"],"reserved_desktop_offline_before_test")
        context=ssl.create_default_context(cafile=root/"device-ca.crt")
        context.load_cert_chain(root/"device.crt",root/"device.key")
        device=meta["desktop_device"].encode()
        payload=b"\x00\x04MQTT\x04\x02\x00\x1e"+struct.pack("!H",len(device))+device
        packet=b"\x10"+bytes([len(payload)])+payload
        with socket.create_connection((host,meta["mqtt_port"]),timeout=10) as raw:
            with context.wrap_socket(raw,server_hostname=host) as secured:
                secured.sendall(packet)
                response=b""
                while len(response)<4:
                    chunk=secured.recv(4-len(response))
                    if not chunk:break
                    response+=chunk
                check(response==b"\x20\x02\x00\x00","public_device_mtls_and_mqtt_connack")
                secured.sendall(b"\xe0\x00")
        anonymous=ssl.create_default_context(cafile=root/"device-ca.crt")
        rejected=False
        try:
            with socket.create_connection((host,meta["mqtt_port"]),timeout=10) as raw:
                with anonymous.wrap_socket(raw,server_hostname=host) as secured:
                    secured.sendall(packet)
                    rejected=not bool(secured.recv(4))
        except ssl.SSLError:rejected=True
        check(rejected,"public_device_without_client_certificate_rejected")

        configuration=root/"desktop-runtime.json"
        # 使用网关登记的实际物模型修订，独立于用户会话配置设备身份。
        revision=devices[0]["model_revision"]
        config={"mqtt_host":host,"mqtt_port":meta["mqtt_port"],"space":meta["space"],"device":meta["desktop_device"],"model_revision":revision,"database":str(root/"desktop-runtime.sqlite"),"ca":str(root/"device-ca.crt"),"certificate":str(root/"device.crt"),"private_key":str(root/"device.key")}
        if configuration.exists():
            assert not configuration.is_symlink() and json.loads(configuration.read_text())==config,"existing_runtime_configuration_changed"
        else:
            with open(configuration,"x",opener=lambda name,flags:os.open(name,flags,0o600)) as f:json.dump(config,f,indent=2)
        with open(root/"runtime.log","a",opener=lambda name,flags:os.open(name,flags,0o600)) as log:
            process=subprocess.Popen([str(args.runtime.resolve(strict=True)),str(configuration)],stdin=subprocess.PIPE,stdout=log,stderr=subprocess.STDOUT)
            try:
                deadline=time.monotonic()+25
                while time.monotonic()<deadline:
                    assert process.poll() is None,"desktop_runtime_exited"
                    current=request(device_path)[1]["items"]
                    if any(x["device_id"]==meta["desktop_device"] and x["ready"] for x in current):break
                    time.sleep(0.5)
                else:raise AssertionError("public_desktop_ready_timeout")
                check(True,"actual_desktop_runtime_online_over_public_mtls")
                check("agent" not in config,"desktop_agent_remains_disabled")
            finally:
                process.terminate()
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:process.kill();process.wait()
                process.stdin.close()
    finally:
        status,_,_=request("/api/v1/auth/logout",{})
        check(status==204,"test_owner_session_logged_out")
    report={"passed":True,"verified_at":datetime.now(timezone.utc).isoformat(),"scope":"服务器外部macOS主机，公网DNS、系统受信HTTPS、所有者登录、设备mTLS和实际桌面运行时上线；无手机或Agent任务","origin":meta["origin"],"events":events,"docker_used":False,"physical_phone":False,"agent_enabled":False,"system_trust_changed":False,"runtime_binary_sha256":hashlib.sha256(args.runtime.read_bytes()).hexdigest()}
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps(report,ensure_ascii=False))


if __name__=="__main__":main()
