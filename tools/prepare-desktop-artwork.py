#!/usr/bin/env python3
"""从保留原件确定性导出桌面与 Android 素材；不调用网络。"""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageChops

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
entries = [("welcome", "flare", "edit", (1200, 800)),
           ("devices", "sunburst", "edit", (1200, 800)),
           ("backdrop", "sunburst", "generate", (1440, 900)),
           ("icon", "flare", "edit", (1024, 1024))]
manifest = {"schema_version": 1, "mode": "imagegen bundled CLI, user-selected API and models",
            "reference": "output/imagegen/02-logo-sunburst.png", "assets": []}
for name, model, operation, bounds in entries:
    source = root / f"output/imagegen/desktop-{name}-v1.png"
    destination = root / f"assets/desktop/images/{name}.png"
    image = Image.open(source)
    original_size = list(image.size)
    alpha = image.getchannel("A").getextrema() if image.mode == "RGBA" else None
    if name == "icon":
        # 保留主体及其原始半透明边缘，移除模型在磁贴外生成的孤立像素。
        mask = image.getchannel("A").point(lambda p: 255 if p > 32 else 0)
        ImageDraw.floodfill(mask, (image.width // 2, image.height // 2), 128)
        connected = mask.point(lambda p: 255 if p == 128 else 0).filter(ImageFilter.MaxFilter(5))
        image.putalpha(ImageChops.multiply(image.getchannel("A"), connected))
    image.thumbnail(bounds, Image.Resampling.LANCZOS)
    from io import BytesIO
    data = BytesIO()
    image.save(data, format="PNG", optimize=True)
    exported = data.getvalue()
    if args.check:
        assert destination.read_bytes() == exported, f"导出过期：{destination}"
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(exported)
    manifest["assets"].append({
        "name": name, "model": f"gpt-image-2.5-{model}", "operation": operation,
        "prompt": f"docs/brand/prompts/desktop-{name}-v1.txt",
        "prompt_sha256": hashlib.sha256((root / f"docs/brand/prompts/desktop-{name}-v1.txt").read_bytes()).hexdigest(),
        "requested_size": [1024, 1024] if name == "icon" else [1536, 1024], "actual_size": original_size,
        "source": str(source.relative_to(root)), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "alpha_extrema": alpha, "export": str(destination.relative_to(root)),
        "export_size": list(image.size), "export_sha256": hashlib.sha256(exported).hexdigest(),
        "consumers": ["macOS SwiftPM resources", "Windows app content"]})
    if name in {"welcome", "devices", "icon"}:
        mobile = image.copy().convert("RGBA")
        mobile.thumbnail((128, 128) if name == "icon" else (800, 800))
        mobile_path = root / "apps/android/app/src/main/res/drawable-nodpi" / ("link_brand.webp" if name == "icon" else f"link_{name}.webp")
        mobile_data = BytesIO()
        mobile.save(mobile_data, format="WEBP", quality=90, method=6)
        if args.check:
            assert mobile_path.read_bytes() == mobile_data.getvalue(), f"Android 素材过期：{mobile_path}"
        else:
            mobile_path.parent.mkdir(parents=True, exist_ok=True)
            mobile_path.write_bytes(mobile_data.getvalue())
        manifest["assets"][-1]["consumers"].append("Android drawable-nodpi")
        manifest["assets"][-1]["android_export"] = {"path": str(mobile_path.relative_to(root)), "size": list(mobile.size), "sha256": hashlib.sha256(mobile_data.getvalue()).hexdigest()}
    if name == "icon":
        manifest["assets"][-1]["additional_reference"] = "docs/brand/references/shou-icon-user.png"
        manifest["assets"][-1]["additional_reference_sha256"] = hashlib.sha256((root / "docs/brand/references/shou-icon-user.png").read_bytes()).hexdigest()
        manifest["assets"][-1]["processing"] = "alpha > 32 center-connected component, 5px dilation; retain original alpha, Lanczos resize"
        for extension, options in [("icns", {}), ("ico", {"sizes": [(s, s) for s in [16, 24, 32, 48, 64, 128, 256]]})]:
            icon_path = root / f"assets/desktop/icons/LimeLink.{extension}"
            output = BytesIO()
            image.save(output, format=extension.upper(), **options)
            if args.check:
                assert icon_path.read_bytes() == output.getvalue(), f"图标过期：{icon_path}"
            else:
                icon_path.parent.mkdir(parents=True, exist_ok=True)
                icon_path.write_bytes(output.getvalue())
            manifest["assets"][-1].setdefault("system_icons", []).append({"path": str(icon_path.relative_to(root)), "sha256": hashlib.sha256(output.getvalue()).hexdigest()})
encoded = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
record = root / "docs/brand/desktop-generation.json"
if args.check:
    assert record.read_text() == encoded, "素材记录过期"
else:
    record.write_text(encoded)
print("4 desktop assets verified" if args.check else "4 desktop assets exported")
