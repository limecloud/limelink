#!/usr/bin/env python3
"""从固定 Git 对象构建离线网关包；不读取来源工作树或安装系统服务。"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_FILES = (
    "LICENSE",
    "deploy/dev/config.json",
    "deploy/nas/manage.py",
    "deploy/nas/device_identity.py",
    "deploy/nas/media_state.py",
    "deploy/nas/platform_install.py",
    "deploy/nas/nginx.conf",
)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--platform", choices=("linux/arm64", "linux/amd64"), required=True)
    parser.add_argument("--docker", default="docker")
    parser.add_argument("--edge-image", default="nginxinc/nginx-unprivileged:1.29-alpine")
    parser.add_argument("--artifacts", type=Path, help="复用上游制品，必须与固定提交的完整构建输入一致")
    parser.add_argument("--runtime-base", help="复用已校验运行依赖层；必须同时提供 --artifacts")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error("输出目录必须不存在，拒绝覆盖已有部署包")
    if args.runtime_base and not args.artifacts:
        parser.error("--runtime-base 需要显式 --artifacts")
    lock = json.loads((ROOT / "contracts/iot-sdk.lock.json").read_text())
    if lock["worktree_overlay"]:
        parser.error("网关包拒绝 SDK 工作树覆盖")
    revision = lock["head"]
    def git(*values):
        return subprocess.check_output(["git", "-C", str(source), *values])
    if Path(git("rev-parse", "--show-toplevel").decode().strip()).resolve() != source:
        parser.error("--source 必须指向上游 Git 仓库根目录")
    if git("rev-parse", revision + "^{commit}").decode().strip() != revision:
        parser.error("缺少固定 IoT 提交")
    def docker(*values, capture=False):
        return subprocess.run([args.docker, *values], check=True,
                              stdout=subprocess.PIPE if capture else None).stdout
    def image(name):
        result = json.loads(docker("image", "inspect", name, capture=True))[0]
        platform = result["Os"] + "/" + result["Architecture"]
        if platform != args.platform:
            raise ValueError("镜像平台不符：" + platform)
        return result["Id"]
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gateway-package-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        archive = temporary / "source.tar"
        with archive.open("wb") as stream:
            subprocess.run(["git", "-C", str(source), "archive", revision], stdout=stream, check=True)
        export = temporary / "source"
        export.mkdir()
        with tarfile.open(archive) as stream:
            stream.extractall(export, filter="data")
        tag = "limelink/gateway:" + revision + "-" + args.platform.replace("/", "-")
        build_context = export
        dockerfile = export / "deploy/nas/Dockerfile"
        artifact_record = None
        if args.artifacts:
            spec = importlib.util.spec_from_file_location("pinned_nas_builder", export / "tools/build-nas-artifacts.py")
            nas = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(nas)
            build_context = args.artifacts.resolve(strict=True)
            artifact_record = nas.verify(build_context)
            if artifact_record["platform"] != args.platform or artifact_record["source_files"] != nas.source_inputs():
                raise ValueError("制品与固定提交的构建输入不符，拒绝将旧镜像标记为新修订")
            dockerfile = temporary / "runtime.Dockerfile"
            content = (build_context / "Dockerfile").read_text()
            if args.runtime_base:
                base = json.loads(docker("image", "inspect", args.runtime_base, capture=True))[0]
                content = nas.cached_runtime_dockerfile(content, args.platform, base)
            dockerfile.write_text(content)
        docker("build", "--platform", args.platform,
               "--label", "org.opencontainers.image.source=" + lock["repository"],
               "--label", "org.opencontainers.image.revision=" + revision,
               "--file", str(dockerfile), "--tag", tag, str(build_context))
        if artifact_record is not None and nas.verify(build_context) != artifact_record:
            raise ValueError("镜像构建期间制品已变化")
        gateway = image(tag)
        try:
            edge = image(args.edge_image)
        except subprocess.CalledProcessError:
            docker("pull", "--platform", args.platform, args.edge_image)
            edge = image(args.edge_image)
        bundle = temporary / "bundle"
        bundle.mkdir()
        for relative in RUNTIME_FILES:
            target = bundle / "upstream" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(export / relative, target)
        shutil.copyfile(ROOT / "contracts/desktop.json", bundle / "desktop.json")
        docker("save", "--output", str(bundle / "images.tar"), gateway, edge)
        files = {str(path.relative_to(bundle)): digest(path)
                 for path in sorted(bundle.rglob("*")) if path.is_file()}
        record = {
            "schema_version": 1,
            "kind": "limelink.local-gateway",
            "upstream": {"repository": lock["repository"], "revision": revision,
                         "worktree_overlay": False, "archive_sha256": digest(archive)},
            "platform": args.platform,
            "images": {"gateway": gateway, "edge": edge},
            "files": files,
            "distribution": "development_unsigned",
        }
        if artifact_record is not None:
            record["upstream"]["artifact_source_digest"] = artifact_record["source_digest"]
        (bundle / "bundle.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
        bundle.rename(output)
    print(json.dumps({"bundle": str(output), "platform": args.platform,
                      "revision": revision, "images": record["images"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
