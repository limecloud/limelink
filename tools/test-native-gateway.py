#!/usr/bin/env python3
"""验收原生网关的真实systemd、回环HTTPS、mTLS与重启保留；不验证公网DNS或手机。"""
import argparse
from datetime import datetime, timezone
import hashlib
import http.client
from http.cookies import SimpleCookie
import json
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import time

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state",type=Path,default=Path("/var/lib/limelink"))
    parser.add_argument("--tls-port",type=int,default=18443)
    parser.add_argument("--restart",action="store_true")
    parser.add_argument("--output",type=Path)
    args=parser.parse_args();state=args.state
    metadata=json.loads((state/"native.json").read_text())
    from urllib.parse import urlsplit
    host=urlsplit(metadata["origin"]).hostname
    context=ssl.create_default_context(cafile=state/"authority/ca.crt")
    events=[]
    def check(condition,code):
        if not condition:raise AssertionError(code)
        events.append(code)
    class VerifiedLoopback(http.client.HTTPSConnection):
        def connect(self):
            raw=socket.create_connection(("127.0.0.1",args.tls_port),timeout=8)
            self.sock=context.wrap_socket(raw,server_hostname=host)
    cookie=""
    def request(path,body=None):
        connection=VerifiedLoopback(host,timeout=8)
        headers={"Host":urlsplit(metadata["origin"]).netloc,"Origin":metadata["origin"],"Content-Type":"application/json"}
        if cookie:headers["Cookie"]=cookie
        try:
            connection.request("POST" if body is not None else "GET",path,body=None if body is None else json.dumps(body),headers=headers)
            response=connection.getresponse();data=response.read(65537)
            if response.status!=200 or len(data)>65536:raise AssertionError("unexpected_https_response")
            return json.loads(data),response.getheaders()
        finally:connection.close()
    protected=("secrets/owner-token","secrets/gateway-identity.pk8","authority/ca.key","device-authority/ca.key","enrollment/desktop/private.key","config/gateway.json","native.json")
    digests={name:hashlib.sha256((state/name).read_bytes()).hexdigest() for name in protected}
    check(metadata["agent_enabled"] is False and metadata["system_trust_changed"] is False,"agent_off_and_system_trust_unchanged")
    check(all((state/name).stat().st_mode & 0o077==0 for name in protected),"private_identity_permissions")
    for unit in ("limelink-broker.service","limelink-gateway.service"):
        facts=dict(line.split("=",1) for line in subprocess.check_output(["systemctl","show",unit,"--property=ActiveState,SubState,User,MainPID"],text=True).splitlines())
        check(facts["ActiveState"]=="active" and facts["SubState"]=="running" and facts["User"]=="limelink",unit+"_nonroot_running")
        for relative in ("authority/ca.key","device-authority/ca.key","enrollment/desktop/private.key"):
            read=subprocess.run(["nsenter","--target",facts["MainPID"],"--mount","--","runuser","-u","limelink","--","test","-r",str(state/relative)],capture_output=True)
            check(read.returncode==1,unit+"_"+relative.replace("/","_")+"_inaccessible")
    check(request("/healthz")[0]["broker_connected"] is True,"verified_https_and_broker_health")
    session,headers=request("/api/v1/auth/session",{"token":(state/"secrets/owner-token").read_text().strip()})
    jar=SimpleCookie()
    for key,value in headers:
        if key.lower()=="set-cookie":jar.load(value)
    cookie="; ".join(key+"="+value.value for key,value in jar.items())
    check(session["authenticated"] and bool(cookie),"owner_https_cookie_login")
    check([s["space_id"] for s in request("/api/v1/spaces")[0]["items"]]==[metadata["space"]],"unique_space")
    devices=request("/api/v1/spaces/"+metadata["space"]+"/devices")[0]["items"]
    check(len(devices)==1 and devices[0]["device_id"]==metadata["desktop_device"] and not devices[0]["ready"],"only_registered_desktop_offline")
    tls=ssl.create_default_context(cafile=state/"device-authority/ca.crt")
    tls.load_cert_chain(state/"enrollment/desktop/device.crt",state/"enrollment/desktop/private.key")
    device=metadata["desktop_device"].encode()
    payload=b"\x00\x04MQTT\x04\x02\x00\x1e"+struct.pack("!H",len(device))+device
    with socket.create_connection(("127.0.0.1",metadata["mqtt_port"]),timeout=5) as raw:
        with tls.wrap_socket(raw,server_hostname=host) as secured:
            secured.sendall(b"\x10"+bytes([len(payload)])+payload)
            check(secured.recv(4)==b"\x20\x02\x00\x00","enrolled_mtls_mqtt_connect")
            secured.sendall(b"\xe0\x00")
    anonymous=ssl.create_default_context(cafile=state/"device-authority/ca.crt")
    rejected=False
    try:
        with socket.create_connection(("127.0.0.1",metadata["mqtt_port"]),timeout=5) as raw:
            with anonymous.wrap_socket(raw,server_hostname=host) as secured:
                secured.sendall(b"\x10"+bytes([len(payload)])+payload);secured.recv(4)
    except ssl.SSLError:rejected=True
    check(rejected,"anonymous_device_tls_rejected")
    if args.restart:
        subprocess.run(["systemctl","restart","limelink-broker.service","limelink-gateway.service"],check=True)
        deadline=time.monotonic()+20
        while True:
            try:
                if request("/healthz")[0]["broker_connected"]:break
            except (OSError,AssertionError):pass
            if time.monotonic()>=deadline:raise AssertionError("restart_health_deadline")
            time.sleep(0.2)
        check(all(hashlib.sha256((state/name).read_bytes()).hexdigest()==digest for name,digest in digests.items()),"restart_preserved_space_identity_and_configuration")
    report={"passed":True,"verified_at":datetime.now(timezone.utc).isoformat(),"scope":"用户授权Ubuntu 22.04 amd64主机，原生systemd、回环TLS HTTPS、独立登录、设备mTLS和重启；无公网或手机验收","events":events,"docker_used":False,"gateway_origin":metadata["origin"],"public_endpoint_verified":False,"physical_phone":False,"system_trust_changed":False}
    if args.output:args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps(report,ensure_ascii=False))
if __name__=="__main__":main()
