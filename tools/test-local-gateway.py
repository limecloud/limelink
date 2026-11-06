#!/usr/bin/env python3
"""在新目录验收本机网关离线包与容器生命周期，不修改系统证书信任。"""
import argparse
from datetime import datetime, timezone
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--docker", required=True)
    parser.add_argument("--compose", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    started = datetime.now(timezone.utc).isoformat()
    helper = args.helper.resolve(strict=True)
    runtime = args.runtime.resolve(strict=True)
    bundle = args.bundle.resolve(strict=True)
    temporary = Path(tempfile.mkdtemp(prefix="gateway-installation-", dir=ROOT / ".dev"))
    state = temporary / "installation"
    events = []
    common = ["--directory", str(state), "--docker", args.docker, "--compose", args.compose]
    def run(action, *values, expected=0, env=None):
        response = subprocess.run([str(helper), action, *values], capture_output=True,
                                  text=True, timeout=420, env=env)
        if response.returncode != expected:
            raise AssertionError({"action": action, "exit_code": response.returncode,
                                  "response": response.stderr or response.stdout})
        return json.loads(response.stdout if expected == 0 else response.stderr)
    def port():
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            return server.getsockname()[1]
    https, mqtt = port(), port()
    while https == mqtt:
        mqtt = port()
    original_files = None
    meta = None
    terminal = None
    try:
        inspected = run("inspect", "--bundle", str(bundle))
        assert inspected["platform"] == "linux/arm64"
        assert inspected["helper_sources"] == {path: digest(ROOT / path) for path in (
            "runtime/src/gateway_deployment.rs", "runtime/src/bin/limelink-gateway.rs")}
        events.append("bundle_checksums_verified")
        remote = run("initialize", *common, "--bundle", str(bundle), "--host", "127.0.0.1",
                     "--https-port", str(https), "--mqtt-port", str(mqtt), expected=1,
                     env={**os.environ, "DOCKER_HOST": "tcp://192.0.2.1:2375"})
        assert remote["code"] == "local_docker_socket_required" and not state.exists()
        events.append("remote_docker_rejected_before_installation")
        damaged = temporary / "damaged-bundle"
        damaged.mkdir()
        manifest = json.loads((bundle / "bundle.json").read_text())
        (damaged / "bundle.json").write_text(json.dumps(manifest))
        (damaged / "desktop.json").write_text("{}")
        rejected = run("inspect", "--bundle", str(damaged), expected=1)
        assert rejected["code"] == "bundle_checksum_mismatch"
        events.append("changed_bundle_refused")
        installed = run("initialize", *common, "--bundle", str(bundle), "--host", "127.0.0.1",
                        "--https-port", str(https), "--mqtt-port", str(mqtt))
        assert installed["state"] == "installed" and installed["started"] is False
        assert installed["agent_enabled"] is False
        assert installed["system_trust_changed"] is False
        meta = json.loads((state / "deployment.json").read_text())
        events.append("new_private_installation_prepared_without_starting")
        protected = ["state/secrets/owner-token", "state/secrets/gateway-identity.pk8",
                     "state/authority/ca.key", "state/device-authority/ca.key",
                     "enrollment/desktop/private.key", "desktop-runtime.json"]
        original_files = {path: digest(state / path) for path in protected}
        assert all((state / path).stat().st_mode & 0o077 == 0 for path in protected)
        refused = run("initialize", *common, "--bundle", str(bundle), "--host", "127.0.0.1",
                      "--https-port", str(https), "--mqtt-port", str(mqtt), expected=1)
        assert refused["ok"] is False
        assert original_files == {path: digest(state / path) for path in protected}
        events.append("reinitialization_refused_and_identity_preserved")
        running = run("start", *common)
        assert running["state"] == "running" and running["https_login_verified"] is False
        origin = installed["origin"]
        ca = ssl.create_default_context(cafile=state / "state/authority/ca.crt")
        def client():
            return urllib.request.build_opener(urllib.request.ProxyHandler({}),
                urllib.request.HTTPSHandler(context=ca),
                urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def request(opener, path, body=None):
            data = None if body is None else json.dumps(body).encode()
            req = urllib.request.Request(origin + path, data=data,
                headers={"Origin": origin, "Content-Type": "application/json"})
            with opener.open(req, timeout=10) as response:
                return json.load(response)
        opener = client()
        try:
            urllib.request.build_opener(urllib.request.ProxyHandler({})).open(origin + "/healthz", timeout=5)
            raise AssertionError("new_CA_unexpectedly_trusted_by_system")
        except urllib.error.URLError as failure:
            assert isinstance(failure.reason, ssl.SSLCertVerificationError)
        assert request(opener, "/healthz")["broker_connected"] is True
        token = (state / "state/secrets/owner-token").read_text().strip()
        assert request(opener, "/api/v1/auth/session", {"token": token})["authenticated"] is True
        spaces = request(opener, "/api/v1/spaces")["items"]
        assert [space["space_id"] for space in spaces] == [installed["space"]]
        devices_path = "/api/v1/spaces/" + installed["space"] + "/devices"
        devices = request(opener, devices_path)["items"]
        assert len(devices) == 1 and devices[0]["device_id"] == installed["desktop_device"]
        assert devices[0]["ready"] is False
        events.extend(["real_https_with_explicit_test_CA", "system_trust_unchanged",
                       "owner_cookie_login_and_unique_space", "only_enrolled_desktop_is_offline"])
        device_ca = ssl.create_default_context(cafile=state / "state/device-authority/ca.crt")
        try:
            with socket.create_connection(("127.0.0.1", mqtt), timeout=5) as connection:
                with device_ca.wrap_socket(connection, server_hostname="127.0.0.1") as secured:
                    secured.recv(1)
            raise AssertionError("broker_accepted_anonymous_TLS_client")
        except ssl.SSLError:
            events.append("broker_requires_device_client_certificate")
        terminal = subprocess.Popen([str(runtime), installed["runtime_configuration"]],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            assert terminal.poll() is None, "enrolled_runtime_exited"
            if request(opener, devices_path)["items"][0]["ready"] is True:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("enrolled_desktop_did_not_become_ready")
        terminal.stdin.close()
        assert terminal.wait(timeout=15) == 0
        terminal = None
        events.append("enrolled_desktop_connected_with_real_mTLS")
        stopped = run("stop", *common)
        assert all(service["state"] != "running" for service in stopped["services"])
        compose_file = state / "compose.json"
        original_compose = compose_file.read_bytes()
        compose_file.write_bytes(original_compose + b" ")
        changed = run("start", *common, expected=1)
        assert changed["code"] == "deployment_files_changed"
        compose_file.write_bytes(original_compose)
        events.append("modified_compose_refused_before_start")
        assert run("start", *common)["state"] == "running"
        opener = client()
        assert request(opener, "/api/v1/auth/session", {"token": token})["authenticated"] is True
        assert original_files == {path: digest(state / path) for path in protected}
        assert request(opener, "/api/v1/spaces")["items"] == spaces
        events.append("stop_restart_preserves_identity_and_space")
        result = {"passed": True}
    except Exception as error:
        result = {"passed": False, "error": str(error)}
        raise
    finally:
        if terminal is not None:
            if terminal.stdin and not terminal.stdin.closed:
                terminal.stdin.close()
            try:
                terminal.wait(timeout=15)
            except subprocess.TimeoutExpired:
                terminal.kill()
                terminal.wait(timeout=5)
        cleanup = "not_created"
        if meta is not None:
            host = os.environ.get("DOCKER_HOST")
            if not host:
                context = subprocess.check_output([args.docker, "context", "inspect", "--format",
                    "{{json .Endpoints.docker.Host}}"], text=True)
                host = json.loads(context)
            response = subprocess.run([args.compose, "--project-name", meta["project"],
                "--project-directory", str(state), "--file", str(state / "compose.json"),
                "down", "--timeout", "15"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=45, env={**os.environ, "DOCKER_HOST": host, "DOCKER_CONTEXT": ""})
            cleanup = "containers_removed_data_preserved" if response.returncode == 0 else "failed"
        evidence = {
            **result, "started_at": started, "finished_at": datetime.now(timezone.utc).isoformat(),
            "scope": "macOS宿主的真实Linux ARM64离线包、隔离Docker安装、HTTPS登录、正式设备证书入网/mTLS及停止重启；无原生窗口或手机",
            "sources": {path: digest(ROOT / path) for path in ["tools/package-gateway.py",
                "tools/test-local-gateway.py", "runtime/src/bin/limelink-gateway.rs",
                "runtime/src/gateway_deployment.rs", "contracts/desktop.json", "contracts/iot-sdk.lock.json"]},
            "bundle_manifest_sha256": digest(bundle / "bundle.json"),
            "helper_sha256": digest(helper), "runtime_sha256": digest(runtime),
            "events": events, "cleanup": cleanup,
            "system_trust_changed": False, "native_window": False, "physical_device": False,
            "formal_distribution": False,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"passed": result["passed"], "events": events, "cleanup": cleanup}))


if __name__ == "__main__":
    main()
