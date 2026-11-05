#!/usr/bin/env python3
"""通过显式提供的 Mermaid CLI 渲染图形，记录源码与输出摘要。"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, help="Mermaid CLI 的 cli.js 路径")
    parser.add_argument("--browser", required=True, help="Chromium/Chrome 可执行文件路径")
    args = parser.parse_args()
    version = subprocess.check_output(["node", args.cli, "--version"], text=True).strip()
    target = ROOT / "docs/assets"
    preview = ROOT / ".dev/diagram-previews"
    target.mkdir(parents=True, exist_ok=True)
    preview.mkdir(parents=True, exist_ok=True)
    records = []
    record_path = ROOT / "docs/evidence/diagram-rendering.json"
    previous = json.loads(record_path.read_text()) if record_path.exists() else {}
    old_records = {row["source"]: row for row in previous.get("diagrams", [])}
    with tempfile.TemporaryDirectory(prefix="limelink-mermaid-") as temporary:
        config = Path(temporary) / "puppeteer.json"
        config.write_text(json.dumps({"executablePath": args.browser, "args": ["--no-sandbox"]}))
        theme = Path(temporary) / "theme.json"
        theme.write_text(json.dumps({"theme": "neutral", "fontFamily": "Arial, sans-serif", "flowchart": {"htmlLabels": True}}, ensure_ascii=False))
        for source in sorted((ROOT / "docs/diagrams").glob("*.mmd")):
            svg = target / f"{source.stem}.svg"
            png = preview / f"{source.stem}.png"
            old = old_records.get(str(source.relative_to(ROOT)))
            if old and previous.get("version") == version and svg.exists() and png.exists() and old.get("source_sha256") == sha(source) and old.get("svg_sha256") == sha(svg):
                records.append(old)
                continue
            common = ["node", args.cli, "-i", str(source), "-p", str(config), "-c", str(theme), "-b", "white", "-w", "1800"]
            subprocess.run([*common, "-o", str(svg)], check=True)
            subprocess.run([*common, "-o", str(png), "-s", "1.4"], check=True)
            digest = sha(source)
            svg.write_text(svg.read_text().replace("<svg ", f'<svg data-source-sha256="{digest}" ', 1))
            records.append({"source": str(source.relative_to(ROOT)), "svg": str(svg.relative_to(ROOT)), "source_sha256": digest, "svg_sha256": sha(svg), "rendered": True, "visual_review": "pending"})
    result = {"tool": "@mermaid-js/mermaid-cli", "version": version, "scope": "设计图渲染，不是运行架构验证", "diagrams": records}
    (ROOT / "docs/evidence/diagram-rendering.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"已渲染 {len(records)} 张图；视觉审阅状态需在实际查看后更新。")


if __name__ == "__main__":
    main()
