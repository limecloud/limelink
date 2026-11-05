"""将已生成并入册的图像和文档显式复制到站点，不连接模型服务。"""
from pathlib import Path
from html import escape
from urllib.parse import quote
import json
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PUBLIC = ROOT / "site/public"
PUBLIC.mkdir(parents=True, exist_ok=True)
manifest = json.loads((ROOT / "docs/brand/image-generation.json").read_text())
for row in manifest["assets"]:
    source = ROOT / row["preview"]
    target = PUBLIC / "images" / source.name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
shutil.copytree(ROOT / "docs/brand/assets", PUBLIC / "brand", dirs_exist_ok=True)
shutil.copytree(ROOT / "docs", PUBLIC / "resources/docs", dirs_exist_ok=True,
                ignore=shutil.ignore_patterns("__pycache__"))
shutil.copytree(ROOT / "output/imagegen", PUBLIC / "resources/output/imagegen", dirs_exist_ok=True)
for name in ["README.md", "AGENTS.md", "LICENSE", "llms.txt"]:
    shutil.copy2(ROOT / name, PUBLIC / "resources" / name)
for relative in ["contracts/desktop.json", "contracts/iot-sdk.lock.json", ".github/workflows/native.yml"]:
    target=PUBLIC / "resources" / relative
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT / relative,target)
with zipfile.ZipFile(PUBLIC / "brand/limelink-brand-kit.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted((ROOT / "docs/brand/assets").rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(ROOT / "docs/brand"))
    for name in ["tokens.json", "exports.json", "vi-spec.md", "identity.md"]:
        archive.write(ROOT / "docs/brand" / name, name)
for name in ["ningning-hero.webp", "og-cover.jpg"]:
    shutil.copy2(ROOT / "docs/brand/derived" / name, PUBLIC / "images" / name)
(PUBLIC / "scene-manifest.json").write_text(json.dumps([{
    "id":r["id"],"title":r["title"],"phase":r["phase"],"image":"/images/"+Path(r["preview"]).name
} for r in manifest["assets"]], ensure_ascii=False, indent=2)+"\n")
for base in [PUBLIC / "resources", PUBLIC / "brand"]:
    folders=[base, *sorted(p for p in base.rglob("*") if p.is_dir())]
    for folder in folders:
        if folder == PUBLIC / "brand":
            (folder / "index.html").unlink(missing_ok=True)
            continue
        entries=[p for p in sorted(folder.iterdir()) if p.name!="index.html"]
        links="".join('<li><a href="'+quote(p.name)+('/' if p.is_dir() else '')+'">'+escape(p.name)+('/' if p.is_dir() else '')+'</a></li>' for p in entries)
        page='<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LimeLink 设计资源</title><body><main><h1>LimeLink 设计资源</h1><a href="/docs/">返回文档中心</a><ul>'+links+'</ul></main></body></html>'
        (folder / "index.html").write_text(page)
print(f"已准备 {len(manifest['assets'])} 张场景图、品牌资源与站内文档。")
