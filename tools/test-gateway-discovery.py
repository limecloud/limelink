#!/usr/bin/env python3
"""使用真实 DNS-SD 公告与原生浏览器验证发现生命周期，不启动或登录用户网关。"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import selectors
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--iot-root", type=Path, required=True)
parser.add_argument("--python", required=True, help="已安装公告器 requirements.txt 的隔离 Python")
args = parser.parse_args()
iot = args.iot_root.resolve()
publisher = iot / "deploy/nas/discovery/publish.py"
subprocess.run(["swift", "build", "-j", "4", "--product", "DiscoveryChecks"], cwd=ROOT, check=True)
subprocess.run([args.python, str(publisher.with_name("test_publish.py"))], check=True)
address = subprocess.check_output([args.python, "-c", "import ifaddr,ipaddress; print(next(ip.ip for a in ifaddr.get_adapters() for ip in a.ips if isinstance(ip.ip,str) and ipaddress.ip_address(ip.ip).is_private and not ipaddress.ip_address(ip.ip).is_loopback and not ipaddress.ip_address(ip.ip).is_link_local))"], text=True).strip()
assert ipaddress.ip_address(address).is_private
origin = f"https://{address}:58443"
label = "LimeLink-Test-" + uuid.uuid4().hex[:8]
children = []
events = []
started = datetime.now(timezone.utc).isoformat()


def announce(suffix):
    child = subprocess.Popen([args.python, str(publisher)], env={**os.environ, "LIMEIOT_PUBLIC_ORIGIN": origin, "LIMEIOT_DISCOVERY_ADDRESS": address, "LIMEIOT_DISCOVERY_NAME": label + suffix}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    children.append(child)
    ready = selectors.DefaultSelector(); ready.register(child.stdout, selectors.EVENT_READ)
    try:
        assert ready.select(10), "publisher_start_timeout"
        assert child.stdout.readline().strip() == "gateway_discovery_started", "publisher_failed"
    finally:
        ready.close()
    return child


def stop(child):
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=8)
        except subprocess.TimeoutExpired:
            child.kill(); child.wait(); raise


probe = subprocess.Popen([str(ROOT / ".build/debug/DiscoveryChecks")], cwd=ROOT, env={**os.environ, "LIMELINK_DISCOVERY_EXPECT_ORIGIN": origin}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
children.append(probe)
lines = selectors.DefaultSelector(); lines.register(probe.stdout, selectors.EVENT_READ)


def expect(wanted, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if lines.select(min(1, deadline-time.monotonic())):
            line = probe.stdout.readline().strip()
            if line:
                events.append(line); print(line, flush=True)
                if line == wanted:
                    return
            elif probe.poll() is not None:
                raise AssertionError("native_probe_exited: " + probe.stderr.read()[-1500:])
    raise AssertionError("missing_event: " + wanted)


status = "failed"
try:
    expect("discovery_contract_passed")
    first = announce("-A"); second = announce("-B")
    expect("gateway_seen")
    # 撤回一个重复来源后，另一个公告仍必须保留候选。
    stop(first)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if lines.select(0.1):
            line = probe.stdout.readline().strip()
            if line:
                events.append(line)
                assert line != "gateway_removed", "removed_while_duplicate_still_present"
    stop(second); expect("gateway_removed")
    third = announce("-A"); expect("gateway_reappeared")
    assert probe.wait(timeout=5) == 0
    status = "passed"
finally:
    lines.close()
    for child in reversed(children):
        stop(child)
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    sources = ["Package.swift", "packages/apple/Sources/LimeLinkCore/GatewayCandidate.swift", "packages/apple/Sources/LimeLinkUI/GatewayDiscovery.swift", "packages/apple/DiscoveryTests/DiscoveryChecks.swift", "contracts/fixtures/gateway-discovery.json", "tools/test-gateway-discovery.py"]
    upstream = ["contracts/gateway-discovery.md", "deploy/nas/compose.discovery.yaml", *[str(p.relative_to(iot)) for p in publisher.parent.iterdir() if p.is_file()]]
    report = {"status": status, "started_at": started, "finished_at": datetime.now(timezone.utc).isoformat(), "scope": "macOS Foundation 原生浏览与 Python NAS 公告器的真实 DNS-SD 发现、重复来源、撤回、重现及无效公告合同；未登录实际网关", "events": events, "physical_phone": False, "windows": "not_run", "container_runtime": "not_run", "gateway_login": "not_run", "sources": {p: digest(ROOT / p) for p in sources}, "upstream": {"repository": "https://github.com/limecloud/iot", "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=iot, text=True).strip(), "worktree_overlay": True, "files": {p: digest(iot / p) for p in upstream}}}
    (ROOT / "docs/evidence/gateway-discovery.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": status, "scope": report["scope"]}, ensure_ascii=False), flush=True)
