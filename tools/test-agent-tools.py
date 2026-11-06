#!/usr/bin/env python3
"""显式使用真实 Codex 验证动态工具协议；设备结果仅为合成夹具。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--agent-executable", required=True)
args = parser.parse_args()
executable = Path(args.agent_executable)
if not executable.is_absolute() or not executable.is_file():
    parser.error("需要真实 Codex 的绝对可执行文件路径")
files = ["runtime/Cargo.toml", "runtime/Cargo.lock", "runtime/src/agent.rs", "runtime/src/agent/codex.rs", "runtime/src/agent/tools.rs", "runtime/examples/agent_tools_probe.rs", "tools/test-agent-tools.py", "contracts/desktop.json"]
def sources():
    return {file: hashlib.sha256((ROOT/file).read_bytes()).hexdigest() for file in files}
before = sources()
started = datetime.now(timezone.utc).isoformat()
directory = ROOT/".dev"/"agent-tool-probes"
directory.mkdir(parents=True, exist_ok=True)
workspace = tempfile.mkdtemp(prefix="protocol-", dir=directory)
version = subprocess.run([str(executable), "--version"], text=True, capture_output=True, check=True).stdout.strip()
result = subprocess.run(["cargo", "run", "--quiet", "--locked", "--manifest-path", "runtime/Cargo.toml", "--example", "agent_tools_probe", "--", str(executable), workspace], cwd=ROOT, text=True, capture_output=True, timeout=320)
(ROOT/".dev"/"agent-tools-probe.log").write_text(result.stdout+result.stderr)
try:
    report = json.loads(result.stdout)
except json.JSONDecodeError:
    report = {"passed": False, "error": "probe_output_invalid"}
after = sources()
report["passed"] = result.returncode == 0 and report.get("passed") is True and before == after
report.update({"started_at": started, "verified_at": datetime.now(timezone.utc).isoformat(), "exit_code": result.returncode, "cli_version": version, "sources": after, "native_ui": False, "physical_device": False, "real_gateway": False, "synthetic_device_results": True, "official_reference": "https://developers.openai.com/codex/app-server/"})
output = ROOT/"docs/evidence/agent-tools-protocol.json"
output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
print(json.dumps({"passed": report["passed"], "exit_code": result.returncode, "scope": "真实模型动态工具与恢复，合成设备结果", "evidence": str(output.relative_to(ROOT))}, ensure_ascii=False), flush=True)
raise SystemExit(0 if report["passed"] else 1)
