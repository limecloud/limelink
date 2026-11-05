#!/usr/bin/env python3
"""从生成的 Logo 母版提取固定双色矢量与跨端 PNG；不调用模型。"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/brand/assets"
LIME, FOREST, CREAM = "#A8D85D", "#263D2C", "#F7F8EF"


def write(name: str, value: str) -> None:
    path = OUT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    source = ROOT / "output/imagegen/03-mark-master.png"
    rgba = Image.open(source).convert("RGBA")
    white = Image.new("RGBA", rgba.size, "white")
    white.alpha_composite(rgba)
    rgb = np.asarray(white.convert("RGB")).astype(np.int16)
    r, g, b = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
    green = ((g > r + 5) & (g > b + 5) & (g - np.minimum(r, b) > 20)).astype(np.uint8) * 255
    contours, _ = cv2.findContours(green, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    body = np.zeros_like(green)
    cv2.drawContours(body, [max(contours, key=cv2.contourArea)], -1, 255, cv2.FILLED)
    dark = ((r < 95) & (g < 130) & (body > 0)).astype(np.uint8) * 255
    ys, xs = np.where(body > 0)
    bounds = (int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1))
    scale = 800 / (bounds[3] - bounds[1])
    offset_x = 512 - (bounds[0] + bounds[2]) / 2 * scale
    offset_y = 112 - bounds[1] * scale

    def paths(mask: np.ndarray) -> list[tuple[str, float]]:
        rows = []
        outlines, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for contour in sorted(outlines, key=cv2.contourArea, reverse=True):
            if cv2.contourArea(contour) < 50:
                continue
            points = cv2.approxPolyDP(contour, 0.85, True).reshape(-1, 2)
            data = "M" + " L".join(f"{x*scale+offset_x:.2f},{y*scale+offset_y:.2f}" for x, y in points) + " Z"
            rows.append((data, float(np.mean(contour[:, 0, 1]))))
        return rows

    body_path = paths(body)[0][0]
    details = paths(dark)
    facial = [path for path, y in details if y > rgba.height * .4]
    leaf = [path for path, y in details if y <= rgba.height * .4]
    for name, fill, detail, knockout in [
        ("mark-color", LIME, FOREST, False),
        ("mark-mono", FOREST, FOREST, True),
        ("mark-inverse", CREAM, CREAM, True),
        ("mark-dark", LIME, CREAM, False),
    ]:
        if knockout:
            inner = f'<path fill="{fill}" fill-rule="evenodd" d="{body_path} {" ".join(facial)}"/>'
        else:
            inner = f'<path fill="{fill}" d="{body_path}"/>' + "".join(f'<path fill="{detail}" d="{p}"/>' for p, _ in details)
        write(name + ".svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="LimeLink"><title>LimeLink</title>{inner}</svg>\n')
    # 脸部挖空的单色模板；叶片随轮廓同色。
    face_mask = np.zeros_like(body)
    dark_contours, _ = cv2.findContours(dark, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    for contour in dark_contours:
        if cv2.contourArea(contour) > 50 and np.mean(contour[:, 0, 1]) > rgba.height * .4:
            cv2.drawContours(face_mask, [contour], -1, 255, cv2.FILLED)
    crop_body = Image.fromarray(body).crop(bounds)
    crop_dark = Image.fromarray(dark).crop(bounds)
    crop_face = Image.fromarray(face_mask).crop(bounds)

    def symbol(size: int, height: float = .78, mode: str = "color") -> Image.Image:
        canvas = Image.new("RGBA", (size, size))
        box_h = round(size * height)
        box_w = round(box_h * crop_body.width / crop_body.height)
        pos = ((size - box_w) // 2, (size - box_h) // 2)
        mask = crop_body.resize((box_w, box_h), Image.Resampling.LANCZOS)
        ink = crop_dark.resize((box_w, box_h), Image.Resampling.LANCZOS)
        if mode == "color":
            canvas.paste(Image.new("RGBA", (box_w, box_h), LIME), pos, mask)
            canvas.paste(Image.new("RGBA", (box_w, box_h), FOREST), pos, ink)
        else:
            alpha = np.asarray(crop_body).astype(np.int16) - np.asarray(crop_face).astype(np.int16)
            mask = Image.fromarray(np.clip(alpha, 0, 255).astype(np.uint8)).resize((box_w, box_h), Image.Resampling.LANCZOS)
            canvas.paste(Image.new("RGBA", (box_w, box_h), "white" if mode == "inverse" else FOREST), pos, mask)
        return canvas

    def save(im: Image.Image, name: str) -> None:
        path = OUT / name
        path.parent.mkdir(parents=True, exist_ok=True)
        im.save(path)

    for mode in ["color", "mono", "inverse"]:
        save(symbol(1024, mode=mode), f"mark-{mode}.png")
    opaque = Image.new("RGBA", (1024, 1024), CREAM)
    opaque.alpha_composite(symbol(1024, .72))
    save(opaque.convert("RGB"), "ios/AppIcon-1024.png")
    (OUT / "ios/Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "LimeLink", "version": 1}}, indent=2) + "\n")
    # macOS 磁贴保留透明外边距；最终仍需在目标系统检查。
    mac = Image.new("RGBA", (1024, 1024))
    ImageDraw.Draw(mac).rounded_rectangle((56, 56, 968, 968), radius=205, fill=CREAM)
    mac.alpha_composite(symbol(1024, .70))
    for size in [16, 32, 128, 256, 512]:
        save(mac.resize((size, size), Image.Resampling.LANCZOS), f"macos/LimeLink.iconset/icon_{size}x{size}.png")
        save(mac.resize((size*2, size*2), Image.Resampling.LANCZOS), f"macos/LimeLink.iconset/icon_{size}x{size}@2x.png")
    (OUT / "macos").mkdir(exist_ok=True)
    mac.save(OUT / "macos/LimeLink.icns", format="ICNS")
    base = symbol(1024, .80)
    for size in [16, 24, 32, 48, 64, 128, 256, 512]:
        save(base.resize((size, size), Image.Resampling.LANCZOS), f"windows/icon-{size}.png")
    base.save(OUT / "windows/LimeLink.ico", format="ICO", sizes=[(x, x) for x in [16, 24, 32, 48, 64, 128, 256]])
    save(symbol(432, .55), "android/ic_launcher_foreground.png")
    save(Image.new("RGB", (432, 432), CREAM), "android/ic_launcher_background.png")
    save(symbol(432, .55, "mono"), "android/ic_launcher_monochrome.png")
    for size in [48, 72, 96, 144, 192]:
        im = Image.new("RGBA", (size, size), CREAM)
        im.alpha_composite(symbol(size, .72))
        save(im.convert("RGB"), f"android/legacy-{size}.png")
    write("android/ic_launcher.xml", '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@drawable/ic_launcher_background"/><foreground android:drawable="@drawable/ic_launcher_foreground"/><monochrome android:drawable="@drawable/ic_launcher_monochrome"/></adaptive-icon>\n')
    for size in [16, 32, 48, 180, 192, 512]:
        im = Image.new("RGBA", (size, size), CREAM)
        im.alpha_composite(symbol(size, .72))
        save(im.convert("RGB"), f"web/icon-{size}.png")
    base.save(OUT / "web/favicon.ico", format="ICO", sizes=[(x, x) for x in [16, 32, 48]])
    for size in [16, 32, 64]:
        save(symbol(size, .9, "mono"), f"templates/menu-{size}.png")
    # 字标 SVG 保留可编辑文本，不打包系统字体。
    for orientation, view, transform, text in [
        ("horizontal", "0 0 2200 800", "translate(0,-112) scale(.78)", '<text x="830" y="505" font-family="Arial, sans-serif" font-size="310" font-weight="700">LimeLink</text>'),
        ("stacked", "0 0 1024 1240", "translate(0,-25)", '<text x="512" y="1120" text-anchor="middle" font-family="Arial, sans-serif" font-size="172" font-weight="700">LimeLink</text>'),
    ]:
        master = ET.parse(OUT / "mark-color.svg").getroot()
        content = "".join(ET.tostring(child, encoding="unicode") for child in master if not child.tag.endswith("title"))
        write(f"logo-{orientation}.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}" fill="{FOREST}" role="img" aria-label="LimeLink"><g transform="{transform}">{content}</g>{text}</svg>\n')
    tokens = {"version": 1, "brand": {"lime": LIME, "forest": FOREST, "cream": CREAM}, "semantic": {"text": FOREST, "surface": CREAM, "action_background": FOREST, "action_text": CREAM, "success": "#267047", "warning": "#8A4B00", "error": "#A52D36", "unknown": "#5D6572"}, "clear_space": "symbol-height / 8", "minimum_symbol_px": 24, "android_foreground_height_fraction": .55}
    (OUT.parent / "tokens.json").write_text(json.dumps(tokens, ensure_ascii=False, indent=2) + "\n")
    files = []
    for path in sorted(OUT.rglob("*")):
        if not path.is_file():
            continue
        entry = {"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        if path.suffix in [".png", ".ico", ".icns"]:
            im = Image.open(path)
            entry.update(width=im.width, height=im.height, mode=im.mode)
            if "A" in im.getbands():
                entry["alpha_extrema"] = list(im.getchannel("A").getextrema())
        files.append(entry)
    (OUT.parent / "exports.json").write_text(json.dumps({"source": str(source.relative_to(ROOT)), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "method": "生成母版颜色分割、轮廓追踪、固定色板与尺寸导出；不新增模型生成图数量", "files": files}, ensure_ascii=False, indent=2) + "\n")
    print(f"已导出 {len(files)} 个文件。")


if __name__ == "__main__":
    main()
