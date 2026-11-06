#!/usr/bin/env python3
"""校验 LimeLink 文档结构与追踪关系，不连接运行环境。"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import struct
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
ERRORS: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        ERRORS.append(message)


def load(relative: str):
    path = ROOT / relative
    try:
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError(f"重复 JSON 键: {key}")
                result[key] = value
            return result
        return json.loads(path.read_text(), object_pairs_hook=unique)
    except (OSError, ValueError) as error:
        ERRORS.append(f"{relative}: {error}")
        return {}


def unique_ids(rows: list, field: str, label: str) -> set[str]:
    ids = [row.get(field) for row in rows]
    require(all(isinstance(value, str) and value for value in ids), f"{label}: ID 无效")
    require(len(ids) == len(set(ids)), f"{label}: ID 重复")
    return set(ids)


def anchors(path: Path) -> set[str]:
    result: set[str] = set()
    counts: dict[str, int] = {}
    fenced = False
    for line in path.read_text().splitlines():
        if re.match(r"^\s*(`{3,}|~{3,})", line):
            fenced = not fenced
        if fenced:
            continue
        match = re.match(r"^#{1,6}\s+(.+?)(?:\s+#+)?$", line)
        if match:
            slug = re.sub(r"[^\w\- ]", "", match[1].lower()).replace(" ", "-")
            ordinal = counts.get(slug, 0)
            counts[slug] = ordinal + 1
            result.add(slug if ordinal == 0 else f"{slug}-{ordinal}")
    return result


def main() -> int:
    catalog = load("docs/catalog.json")
    requirements = load("docs/requirements.json")
    cases = load("docs/test-cases.json")
    status = load("docs/status.json")
    sources = load("docs/evidence/sources.json")
    snapshots = load("docs/evidence/upstream-snapshot.json")
    diagrams = load("docs/evidence/diagram-rendering.json")
    implementation = load("docs/implementation.json")
    validation = load("docs/evidence/native-validation.json")
    implementation_rows = implementation.get("requirements", [])
    unique_ids(implementation_rows, "requirement", "需求实现")
    for path in DOCS.rglob("*.json"):
        load(str(path.relative_to(ROOT)))

    documents = catalog.get("documents", [])
    doc_ids = unique_ids(documents, "id", "文档")
    doc_paths = [item.get("path", "") for item in documents]
    require(len(doc_paths) == len(set(doc_paths)), "文档路径重复")
    expected = {str(path.relative_to(ROOT)) for path in DOCS.rglob("*.md")}
    require(set(doc_paths) == expected, "文档目录必须覆盖全部 docs Markdown")
    for item in documents:
        require((ROOT / item.get("path", "")).is_file(), f"文档不存在: {item}")
        require(bool(item.get("summary")), f"文档缺少摘要: {item.get('id')}")
    for route, ids in catalog.get("reading_routes", {}).items():
        require(set(ids) <= doc_ids, f"阅读路线引用未知文档: {route}")

    req_rows = requirements.get("requirements", [])
    req_ids = unique_ids(req_rows, "id", "需求")
    case_rows = cases.get("test_cases", [])
    case_ids = unique_ids(case_rows, "id", "测试用例")
    phase_rows = status.get("phases", [])
    phase_ids = unique_ids(phase_rows, "id", "阶段")
    source_rows = sources.get("sources", [])
    source_ids = unique_ids(source_rows, "id", "来源")
    for row in req_rows:
        require(row.get("status") in {"planned", "partial", "implemented", "verified"}, f"需求状态无效: {row.get('id')}")
        require(row.get("phase") in phase_ids, f"需求阶段不存在: {row.get('id')}")
        require(bool(row.get("documents")) and set(row["documents"]) <= doc_ids, f"需求文档不存在: {row.get('id')}")
        require(bool(row.get("test_cases")) and set(row["test_cases"]) <= case_ids, f"需求缺少有效用例: {row.get('id')}")
        for case_id in row.get("test_cases", []):
            case = next((value for value in case_rows if value.get("id") == case_id), {})
            require(row.get("id") in case.get("requirements", []), f"需求/用例双向追踪不一致: {row.get('id')} / {case_id}")
    for row in case_rows:
        require(row.get("status") in {"not_run", "partial", "passed", "failed", "blocked"}, f"用例状态无效: {row.get('id')}")
        if row.get("status") != "not_run":
            require(bool(row.get("evidence")), f"已执行用例必须引用证据: {row.get('id')}")
            require(bool(row.get("verification_note")), f"用例缺少实际验收范围: {row.get('id')}")
        require(bool(row.get("requirements")) and set(row["requirements"]) <= req_ids, f"用例需求无效: {row.get('id')}")
        require(bool(row.get("steps")) and bool(row.get("expected")) and bool(row.get("environment")), f"用例内容不完整: {row.get('id')}")
        for req_id in row.get("requirements", []):
            req = next((value for value in req_rows if value.get("id") == req_id), {})
            require(row.get("id") in req.get("test_cases", []), f"用例/需求双向追踪不一致: {row.get('id')} / {req_id}")
    require({row.get("requirement") for row in implementation_rows} == req_ids, "实现矩阵必须覆盖全部需求")
    def valid_evidence(relative):
        require(isinstance(relative, str) and relative.startswith("docs/evidence/"), f"证据路径无效: {relative}")
        record = load(relative)
        for source, digest in record.get("sources", {}).items():
            path = ROOT / source
            require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest, f"证据源码已变化: {relative} / {source}")
        if "sdk_revision" in record:
            require(record["sdk_revision"] == status.get("upstream", {}).get("revision"), f"证据使用不同 SDK 修订: {relative}")
        return record.get("passed") is True or any(check.get("status") == "passed" and check.get("exit_code") == 0 for check in record.get("checks", {}).values())
    for row in implementation_rows:
        req = next((item for item in req_rows if item.get("id") == row.get("requirement")), {})
        require(row.get("status") == req.get("status"), f"实现/需求状态不一致: {row.get('requirement')}")
        require(bool(row.get("limits")), f"实现范围不明确: {row.get('requirement')}")
        if row.get("status") != "planned":
            require(bool(row.get("sources")) and bool(row.get("evidence")), f"实现缺少源码或证据: {row.get('requirement')}")
            for relative in row.get("sources", []):
                require((ROOT / relative).is_file(), f"实现源码不存在: {relative}")
            for relative in row.get("evidence", []):
                require(valid_evidence(relative), f"实现未取得通过证据: {relative}")
        if row.get("status") == "verified":
            require(all(next((case for case in case_rows if case.get("id") == case_id), {}).get("status") == "passed" for case_id in req.get("test_cases", [])), f"需求未通过完整用例: {row.get('requirement')}")
    for row in case_rows:
        for relative in row.get("evidence", []):
            require((ROOT / relative).is_file(), f"用例证据不存在: {relative}")
        if row.get("status") == "passed":
            require(all(valid_evidence(relative) for relative in row.get("evidence", [])), f"用例引用未通过证据: {row.get('id')}")
    for name, check in validation.get("checks", {}).items():
        require(check.get("status") in {"passed", "failed", "blocked"}, f"构建检查状态无效: {name}")
        require(bool(check.get("scope")) and bool(check.get("sources")), f"检查缺少范围/源码: {name}")
        if check.get("status") == "passed":
            require(check.get("exit_code") == 0, f"失败退出码不得标为通过: {name}")
            for relative, digest in check.get("sources", {}).items():
                path = ROOT / relative
                require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest, f"通过检查的源码已变化: {name} / {relative}")
    if status.get("runtime_implemented"):
        require((ROOT / "runtime/src/main.rs").is_file(), "运行时实现声明缺少源码")
    if status.get("product_tests_run"):
        require(valid_evidence("docs/evidence/iot-runtime-mtls-integration.json"), "产品运行检查声明缺少实际集成证据")
    lock = load("contracts/iot-sdk.lock.json")
    require(lock.get("worktree_overlay") is False, "产品基线不得消费未发布工作树 SDK")
    require(status.get("upstream", {}).get("revision") == lock.get("head"), "状态与上游依赖锁不一致")
    release = status.get("release", {})
    if release.get("status") == "released":
        require(not release.get("blockers"), "有发布阻塞时不得声明 released")
        require(all(case.get("status") == "passed" for case in case_rows), "完整发布必须通过全部产品用例")
    for row in phase_rows:
        require(row.get("status") in {"not_started", "documented", "in_progress", "verified", "released"}, f"阶段状态无效: {row.get('id')}")
        if row.get("status") in {"verified", "released"}:
            related = [item for item in req_rows if item.get("phase") == row.get("id")]
            require(all(item.get("status") == "verified" for item in related), f"阶段未取得完整需求证据: {row.get('id')}")
        require(set(row.get("depends_on", [])) <= phase_ids, f"阶段依赖无效: {row.get('id')}")

    markdown = sorted([*DOCS.rglob("*.md"), *ROOT.glob("*.md")])
    link_count = 0
    for path in markdown:
        content = path.read_text()
        fence = None
        for line in content.splitlines():
            match = re.match(r"^\s*(`{3,}|~{3,})", line)
            if match:
                token = match[1]
                if fence is None:
                    fence = token
                elif token[0] == fence[0] and len(token) >= len(fence):
                    fence = None
        require(fence is None, f"围栏未关闭: {path.relative_to(ROOT)}")
        for target in re.findall(r"!?\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)", content):
            parsed = urlsplit(target.strip("<>"))
            if parsed.scheme or parsed.netloc:
                continue
            destination = (path.parent / unquote(parsed.path)).resolve() if parsed.path else path
            require(destination.is_relative_to(ROOT), f"链接越出本仓库: {path.name} -> {target}")
            require(destination.exists(), f"本地链接不存在: {path.name} -> {target}")
            if destination.is_file() and destination.suffix == ".md" and parsed.fragment:
                require(unquote(parsed.fragment) in anchors(destination), f"锚点不存在: {path.name} -> {target}")
            link_count += 1
        for source_id in re.findall(r"SRC-[A-Z0-9-]+", content):
            require(source_id in source_ids, f"未知来源: {source_id} in {path.name}")
        require(not re.search(r"/Users/|file://|sk-[A-Za-z0-9]{24,}", content), f"存在本地路径或疑似秘密: {path.name}")

    source_paths: dict[str, set[str]] = {}
    for row in source_rows:
        require(bool(row.get("observed_scope")) and bool(row.get("supports")) and bool(row.get("does_not_prove")), f"来源边界不完整: {row.get('id')}")
        source_paths.setdefault(row.get("repository", ""), set()).update(row.get("paths", []))
    for row in snapshots.get("repositories", []):
        require(bool(re.fullmatch(r"[0-9a-f]{40}", row.get("head", ""))), "参考 HEAD 无效")
        files = row.get("files", [])
        unique_ids(files, "path", "参考文件")
        require({item.get("path") for item in files} == source_paths.get(row.get("repository"), set()), f"来源/快照文件不一致: {row.get('repository')}")
        for item in files:
            require(bool(re.fullmatch(r"[0-9a-f]{64}", item.get("sha256", ""))), "参考文件摘要无效")
            require(isinstance(item.get("matches_head"), bool), "缺少工作树比较结果")

    records = diagrams.get("diagrams", [])
    unique_ids(records, "source", "图形")
    actual_sources = {str(path.relative_to(ROOT)) for path in (DOCS / "diagrams").glob("*.mmd")}
    require({row.get("source") for row in records} == actual_sources, "图形记录必须覆盖全部 Mermaid 源码")
    for row in records:
        source = ROOT / row.get("source", "")
        target = ROOT / row.get("svg", "")
        require(source.is_file() and target.is_file(), f"图源或输出不存在: {row.get('source')}")
        if source.is_file() and target.is_file():
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            require(row.get("source_sha256") == digest, f"图形源码摘要过期: {source.name}")
            require(row.get("svg_sha256") == hashlib.sha256(target.read_bytes()).hexdigest(), f"SVG 摘要过期: {target.name}")
            try:
                element = ET.fromstring(target.read_text())
                require(element.tag.endswith("svg") and bool(element.get("viewBox")), f"SVG 无效: {target.name}")
                require(element.get("data-source-sha256") == digest, f"SVG 与源码不匹配: {target.name}")
            except ET.ParseError as error:
                ERRORS.append(f"SVG 解析失败: {target.name}: {error}")
        require(row.get("rendered") is True, f"图形未渲染: {row.get('source')}")
    generation = load("docs/brand/image-generation.json")
    exports = load("docs/brand/exports.json")
    visual = load("docs/brand/visual-verification.json")
    plan = load("docs/brand/scene-plan.json")
    assets = generation.get("assets", [])
    asset_ids = unique_ids(assets, "id", "生成图")
    require(len(assets) == generation.get("generated_count") == 28, "生成图必须完整覆盖本轮 28 张")
    require({row.get("model_requested") for row in assets} == {"gpt-image-2.5-flare", "gpt-image-2.5-sunburst"}, "必须使用指定的两种请求模型")
    require(len({row.get("image_sha256") for row in assets}) == len(assets), "不同生成图不应重复使用同一文件")
    for row in assets:
        require(row.get("status") == "generated", f"生成图未完成: {row.get('id')}")
        require(row.get("visual_review") == "reviewed-at-contact-sheet-scale", f"生成图未审阅: {row.get('id')}")
        for field, digest_field in [("output", "image_sha256"), ("prompt", "prompt_sha256"), ("preview", "preview_sha256")]:
            path = ROOT / row.get(field, "")
            require(path.is_file(), f"图像资产或提示词不存在: {row.get(field)}")
            if path.is_file():
                require(hashlib.sha256(path.read_bytes()).hexdigest() == row.get(digest_field), f"图像记录摘要过期: {row.get(field)}")
        for reference in row.get("references", []):
            path = ROOT / reference
            require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == row.get("reference_sha256", {}).get(reference), f"母版引用已变化: {reference}")
        path = ROOT / row.get("output", "")
        if path.is_file():
            data = path.read_bytes()
            require(data[:8] == b"\x89PNG\r\n\x1a\n", f"不是有效 PNG 头: {path.name}")
            require(list(struct.unpack(">II", data[16:24])) == row.get("actual_size"), f"原图实际尺寸过期: {path.name}")
    desktop_assets = load("docs/brand/desktop-generation.json").get("assets", [])
    require(len(desktop_assets) == 4, "桌面生成素材必须覆盖插画、背景与 3D 图标")
    for row in desktop_assets:
        for field, digest_field in [("source", "source_sha256"), ("prompt", "prompt_sha256"), ("export", "export_sha256")]:
            path = ROOT / row.get(field, "")
            require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == row.get(digest_field), f"桌面图像记录过期: {row.get(field)}")
        for icon in row.get("system_icons", []):
            path = ROOT / icon.get("path", "")
            require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == icon.get("sha256"), f"桌面图标过期: {icon.get('path')}")
    require({str(path.relative_to(ROOT)) for path in (ROOT / "output/imagegen").glob("*.png")} == {row.get("output") for row in assets} | {row.get("source") for row in desktop_assets}, "原图必须全部入册")
    require({row.get("id") for row in plan.get("assets", [])} == {value for value in asset_ids if int(value[:2]) >= 5}, "场景计划与实际图册不一致")
    for row in exports.get("files", []):
        path = ROOT / row.get("path", "")
        require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == row.get("sha256"), f"导出文件不存在或摘要变化: {row.get('path')}")
    require(visual.get("generated_images") == 28 and visual.get("exports") == len(exports.get("files", [])), "视觉检查覆盖不足")
    for row in generation.get("derivatives", []):
        path = ROOT / row.get("path", "")
        require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == row.get("sha256"), f"网站派生图过期: {row.get('path')}")

    result = {
        "markdown_files": len(markdown), "catalog_documents": len(documents),
        "requirements": len(req_rows), "planned_test_cases": len(case_rows),
        "sources": len(source_rows), "diagrams": len(records), "local_links": link_count,
        "generated_images": len(assets), "brand_exports": len(exports.get("files", [])),
        "product_runtime_tested": status.get("product_tests_run", False), "errors": ERRORS,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if ERRORS else 0


if __name__ == "__main__":
    sys.exit(main())
