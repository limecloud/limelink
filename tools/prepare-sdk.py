#!/usr/bin/env python3
"""从显式 Git 来源导出固定 SDK；默认核验 lock，不消费未提交内容。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "contracts/iot-sdk.lock.json"
PREFIXES = ("apps/ios/Sources/", "apps/ios/Tests/", "apps/android/core/src/", "packages/dotnet/LimeIoT.Client/")
EXACT = {"apps/ios/Package.swift", "apps/android/core/build.gradle.kts"}
EXCLUDED = {"bin", "obj", ".build"}

def include(path):
    return not (set(Path(path).parts) & EXCLUDED) and (path in EXACT or path.startswith(PREFIXES))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--revision")
    parser.add_argument("--update-lock", action="store_true")
    parser.add_argument("--accept-worktree", action="store_true", help="仅开发快照，不能作为发布依赖")
    args = parser.parse_args()
    source = args.source.resolve()
    previous = json.loads(LOCK.read_text()) if LOCK.exists() else None
    def git(*values):
        return subprocess.check_output(["git", "-C", str(source), *values])
    if args.accept_worktree and (args.revision or not args.update_lock):
        parser.error("工作树快照必须使用 --update-lock，且不能指定 --revision")
    revision = args.revision or ("HEAD" if args.accept_worktree else previous["head"] if previous else "HEAD")
    head = git("rev-parse", revision + "^{commit}").decode().strip()
    names = [p for p in git("ls-tree", "-r", "--name-only", head).decode().splitlines() if include(p)]
    if args.accept_worktree:
        names = sorted(set(names) | {str(p.relative_to(source)) for prefix in PREFIXES for p in (source / prefix).rglob("*") if p.is_file() and include(str(p.relative_to(source)))})
    files, rows = {}, []
    for name in sorted(names):
        committed = git("show", head + ":" + name) if name in git_names(source, head) else None
        data = (source / name).read_bytes() if args.accept_worktree else committed
        if data is None:
            raise SystemExit("固定修订缺少 SDK 文件：" + name)
        files[name] = data
        rows.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(), "matches_head": data == committed})
    if not any(name.startswith("packages/dotnet/LimeIoT.Client/") for name in files):
        raise SystemExit("此修订尚无 .NET SDK，不能用于四端构建")
    record = {"repository": "https://github.com/limecloud/iot", "head": head, "worktree_overlay": any(not row["matches_head"] for row in rows), "files": rows}
    if not args.update_lock and record != previous:
        raise SystemExit("SDK 与 lock 不符；更新依赖需显式 --revision 和 --update-lock")
    parent = ROOT / ".dev"
    parent.mkdir(exist_ok=True)
    # 全量确定性替换，避免旧修订移除的源文件或缓存继续参与构建。
    with tempfile.TemporaryDirectory(prefix="sdk-export-", dir=parent) as temp:
        export = Path(temp) / "upstream"
        for name, data in files.items():
            target = export / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        destination = parent / "upstream"
        if destination.exists():
            destination.rename(Path(temp) / "previous")
        export.rename(destination)
    if args.update_lock:
        LOCK.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"sdk_files": len(rows), "head": head, "worktree_overlay": record["worktree_overlay"]}))

_cached_names = None

def git_names(source, head):
    global _cached_names
    if _cached_names is None:
        _cached_names = set(subprocess.check_output(["git", "-C", str(source), "ls-tree", "-r", "--name-only", head]).decode().splitlines())
    return _cached_names

if __name__ == "__main__":
    main()
