#!/usr/bin/env python3
"""Read Jianying drafts and prepare a separate, text-free export draft.

The command line always emits one JSON document. It never writes to the source
draft or the Jianying project registry. Time values are integer microseconds.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid
import iteration


DEFAULT_ROOT = Path.home() / "Movies/JianyingPro/User Data/Projects/com.lveditor.draft"
DEFAULT_APP = Path("/Applications/VideoFusion-macOS.app")
DEFAULT_DECODER = Path(__file__).resolve().parent / "native/draft_decode"
DRAFT_FILES = ("draft_info.json", "draft_content.json")
TEXT_TYPES = {"text", "subtitle", "subtitles", "caption", "captions", "text_template", "texttemplate"}
TEXT_COLLECTIONS = {"texts", "text_templates", "captions", "subtitles", "subtitle_templates"}
SKIP_DIRS = {".backup", "backup", "backups", "cache", "caches", "resources", "materials", "media", "deepagent", ".git"}
PATH_KEYS = {"path", "file_path", "local_path", "media_path", "source_path", "font_path"}
DRAFT_PATH_KEYS = {"draft_path", "draft_file_path", "draft_content_path", "draft_info_path"}


class DraftError(Exception):
    def __init__(self, message, code="draft_error"):
        super().__init__(message)
        self.code = code


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _normal(text: str) -> str:
    return unicodedata.normalize("NFC", text.strip())


def _source_snapshot(source):
    files = {source}
    for current, dirs, names in os.walk(source.parent, followlinks=False):
        dirs[:] = [d for d in dirs if d.lower() not in SKIP_DIRS and not d.startswith(".") and not (Path(current) / d).is_symlink()]
        files.update(Path(current) / name for name in names if name in DRAFT_FILES and not (Path(current) / name).is_symlink())
    return {str(p.relative_to(source.parent)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}


def _fingerprint(snapshot):
    return hashlib.sha256(json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def _text_like(value) -> bool:
    value = str(value).lower()
    return any(token in value for token in ("text", "caption", "subtitle"))


def _draft_file(path) -> Path:
    path = Path(path).expanduser().resolve()
    if path.is_file():
        return path
    for name in DRAFT_FILES:
        if (path / name).is_file():
            return path / name
    raise DraftError("所选路径中没有 draft_info.json 或 draft_content.json。", "draft_not_found")


def read_json(path, decoder=None, app=None):
    """Read plain JSON, otherwise invoke the bundled read-only decoder."""
    path = Path(path)
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise DraftError("无法读取草稿：%s" % exc, "read_failed")
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeError):
        helper = Path(decoder).expanduser() if decoder else DEFAULT_DECODER
        app_path = Path(app).expanduser() if app else DEFAULT_APP
        library = app_path if app_path.name.endswith(".dylib") else app_path / "Contents/Frameworks/libvideoeditor.dylib"
        if not helper.is_file() or not library.is_file():
            raise DraftError("该草稿需要本机剪映解码器；请检查剪映应用和 native/draft_decode。", "decoder_unavailable")
        try:
            with tempfile.TemporaryDirectory(prefix="jianying-read-") as temp:
                decoded = Path(temp) / "decoded.json"
                result = subprocess.run([str(helper), str(library), str(path), str(decoded)], capture_output=True, timeout=40, env={**os.environ, "DYLD_LIBRARY_PATH": str(library.parent)})
                if result.returncode != 0 or not decoded.is_file():
                    raise DraftError("剪映未能解码 %s（退出码 %s）。" % (path.name, result.returncode), "decode_failed")
                data = json.loads(decoded.read_bytes())
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            raise DraftError("解码草稿失败：%s" % exc, "decode_failed")
    if not isinstance(data, dict):
        raise DraftError("草稿根节点不是 JSON 对象。", "unsupported_schema")
    return data


def _write_json(path, data, encoded=False, decoder=None, app=None):
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    if not encoded:
        path.write_text(payload, encoding="utf-8")
        return
    helper = Path(decoder).expanduser() if decoder else DEFAULT_DECODER
    app_path = Path(app).expanduser() if app else DEFAULT_APP
    library = app_path if app_path.name.endswith(".dylib") else app_path / "Contents/Frameworks/libvideoeditor.dylib"
    try:
        with tempfile.TemporaryDirectory(prefix="jianying-write-") as temp:
            plain = Path(temp) / "plain.json"
            plain.write_text(payload, encoding="utf-8")
            result = subprocess.run([str(helper), "--encode", str(library), str(plain), str(path)], capture_output=True, timeout=40, env={**os.environ, "DYLD_LIBRARY_PATH": str(library.parent)})
            if result.returncode != 0 or not path.is_file():
                raise DraftError("副本编码失败（退出码 %s），未改动原草稿。" % result.returncode, "encode_failed")
            if read_json(path, decoder, app) != data:
                raise DraftError("副本编码后复读不一致，已停止。", "encode_failed")
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DraftError("副本编码失败：%s" % exc, "encode_failed")


def _timeline(data):
    if not isinstance(data.get("tracks"), list) or not isinstance(data.get("materials"), dict):
        raise DraftError("无法识别草稿时间轴结构，已停止以避免错误导出。", "unsupported_schema")
    for track in data["tracks"]:
        if not isinstance(track, dict) or not isinstance(track.get("segments", []), list):
            raise DraftError("无法识别轨道结构。", "unsupported_schema")
    return data


def list_drafts(root=None, decoder=None, app=None):
    root = Path(root).expanduser().resolve() if root else DEFAULT_ROOT
    if not root.is_dir():
        return {"root": str(root), "drafts": [], "warnings": ["没有找到草稿目录，请手动选择草稿文件夹。"]}
    drafts = []
    for folder in root.iterdir():
        if folder.name.startswith(".") or not folder.is_dir() or folder.is_symlink():
            continue
        try:
            path = _draft_file(folder)
        except DraftError:
            continue
        with path.open("rb") as handle:
            encoded = handle.read(16).lstrip()[:1] != b"{"
        drafts.append({"name": folder.name, "path": str(folder), "modified_at": path.stat().st_mtime, "encoded": encoded})
    drafts.sort(key=lambda d: (-d["modified_at"], d["name"]))
    return {"root": str(root), "drafts": drafts, "warnings": []}


def _material_index(data):
    index = {}
    for category, values in data["materials"].items():
        if not isinstance(values, list):
            continue
        for value in values:
            if isinstance(value, dict) and value.get("id"):
                if value["id"] in index:
                    raise DraftError("草稿材料 ID 重复，无法可靠关联文本。", "unsupported_schema")
                index[value["id"]] = (category, value)
    return index


def _extract_text(material):
    content = material.get("content")
    if isinstance(content, str):
        try:
            parsed = json.loads(content)
        except ValueError:
            return content
        if isinstance(parsed, dict) and isinstance(parsed.get("text"), str):
            return parsed["text"]
        if isinstance(parsed, str):
            return parsed
    elif isinstance(content, dict) and isinstance(content.get("text"), str):
        return content["text"]
    if isinstance(material.get("text"), str):
        return material["text"]
    raise DraftError("文字素材没有可识别的完整文本内容。", "unsupported_text")


def _folder_index(root):
    root = Path(root).expanduser().resolve()
    if not root.is_dir():
        raise DraftError("导出根文件夹不存在。请先选择已经建好分类子文件夹的位置。", "output_not_found")
    index = {}
    warnings = []
    def walk_error(error):
        raise DraftError("无法完整扫描目标文件夹：%s" % error, "output_unreadable")
    for current, dirs, _ in os.walk(root, followlinks=False, onerror=walk_error):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in list(dirs):
            folder = Path(current) / name
            if folder.is_symlink():
                dirs.remove(name)
                warnings.append("忽略符号链接文件夹：%s" % folder.relative_to(root))
                continue
            resolved = folder.resolve()
            if not _inside(resolved, root):
                dirs.remove(name)
                continue
            index.setdefault(_normal(name), []).append(str(resolved))
    return root, index, warnings


def _label_error(label):
    if not label:
        return "文本为空。"
    if label in (".", "..") or any(c in label for c in ("/", "\\", "\x00", "\n", "\r")):
        return "文本必须是单个文件夹名称，不能包含路径或换行。"
    if any(unicodedata.category(c) == "Cc" for c in label):
        return "文本含有控制字符。"
    return ""


def _filename(label, sequence, start):
    label = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", label).strip(" .") or "未命名"
    # Keep names below the common 255-byte filesystem limit, including Chinese.
    while len(label.encode("utf-8")) > 150:
        label = label[:-1]
    return "%03d_%s_%dus.mp4" % (sequence, label, max(0, start))


def make_plan(draft, output, tracks=None, decoder=None, app=None, aliases=None, options=None):
    source = _draft_file(draft)
    snapshot = _source_snapshot(source)
    data = _timeline(read_json(source, decoder, app))
    root, folders, warnings = _folder_index(output)
    options = options or {}
    mode = options.get("match_mode", "exact")
    layout = options.get("output_mode", "matched")
    overrides = options.get("folder_overrides", {})
    if mode not in {"exact", "fuzzy"} or layout not in {"matched", "direct"} or not isinstance(overrides, dict):
        raise DraftError("匹配模式或目标目录设置无效。", "invalid_options")
    if aliases is None:
        aliases = {}
    if not isinstance(aliases, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in aliases.items()):
        raise DraftError("文件夹别名必须是文本到相对目录路径的 JSON 对象。", "invalid_aliases")
    normalized_aliases = {_normal(k): v for k, v in aliases.items()}
    if len(normalized_aliases) != len(aliases):
        raise DraftError("文件夹别名中存在重复的规范化文本名称。", "invalid_aliases")
    materials = _material_index(data)
    track_list, segments = [], []
    selected = set(tracks or [])
    duration = data.get("duration", 0)
    if not isinstance(duration, int) or isinstance(duration, bool) or duration < 0:
        raise DraftError("时间轴总时长无效。", "unsupported_schema")
    removed = 0
    for track_position, track in enumerate(data["tracks"]):
        kind = str(track.get("type", "")).lower()
        if _text_like(kind) and kind not in TEXT_TYPES:
            raise DraftError("发现暂不支持的文字轨道类型：%s。" % kind, "unsupported_text")
        if kind not in TEXT_TYPES:
            continue
        track_id = str(track.get("id") or "track-%d" % track_position)
        items = track.get("segments", [])
        removed += len(items)
        track_list.append({"id": track_id, "name": track.get("name") or "文本轨道 %d" % (len(track_list) + 1), "count": len(items)})
        if selected and track_id not in selected:
            continue
        for position, segment in enumerate(items):
            if not isinstance(segment, dict):
                raise DraftError("文字片段结构无法识别。", "unsupported_schema")
            segment_id = str(segment.get("id") or "%s-%d" % (track_id, position))
            segment_key = iteration.digest([track_id, segment_id])
            timerange = segment.get("target_timerange", {})
            start = timerange.get("start", 0) if isinstance(timerange, dict) else -1
            length = timerange.get("duration", 0) if isinstance(timerange, dict) else 0
            valid_time = all(isinstance(v, int) and not isinstance(v, bool) for v in (start, length)) and start >= 0 and length > 0
            end = start + length if valid_time else 0
            if duration and end > duration:
                valid_time = False
            text, status, error = "", "ready", ""
            try:
                item = materials.get(segment.get("material_id"))
                if not item:
                    raise DraftError("找不到文字片段对应的材料。", "unsupported_text")
                text = _normal(_extract_text(item[1]))
                error = _label_error(text)
                if error:
                    status = "invalid_text"
            except DraftError as exc:
                status, error = "invalid_text", str(exc)
            if not valid_time:
                status, error = "invalid_range", "文本起止时间无效或超出时间轴范围。"
            matched_by = "alias" if text in normalized_aliases else "exact"
            suggestions = []
            matches = folders.get(text, []) if status == "ready" else []
            if status == "ready" and text in normalized_aliases:
                relative = Path(normalized_aliases[text])
                candidate = root / relative
                invalid_alias = (not normalized_aliases[text] or relative.is_absolute() or ".." in relative.parts
                                 or candidate == root or not candidate.is_dir() or not _inside(candidate.resolve(), root))
                cursor = root
                for component in relative.parts:
                    cursor = cursor / component
                    if cursor.is_symlink():
                        invalid_alias = True
                if invalid_alias:
                    status, error, matches = "invalid_alias", "指定映射必须是导出根目录内已存在的真实子文件夹，不能使用路径跳转或符号链接。", []
                else:
                    matches = [str(candidate.resolve())]
            # Explicit per-segment destinations take priority, including outside root.
            explicit = overrides.get(segment_key)
            if explicit is not None and valid_time and status not in {"invalid_text", "invalid_range"}:
                candidate = Path(explicit).expanduser() if isinstance(explicit, str) else Path("")
                if not isinstance(explicit, str) or not candidate.is_absolute() or not candidate.is_dir() or candidate.resolve() != candidate:
                    status, error, matches = "invalid_folder", "指定目录不存在或含符号链接，请重新选择。", []
                else:
                    status, error, matches, matched_by = "ready", "", [str(candidate)], "manual"
            elif layout == "direct" and status not in {"invalid_text", "invalid_range"}:
                status, error, matches, matched_by = "ready", "", [str(root)], "direct"
            elif status == "ready" and not matches and mode == "fuzzy":
                suggestions, unique = iteration.fuzzy_matches(text, folders)
                if unique:
                    matches, matched_by = [suggestions[0]["folder"]], "fuzzy"
                elif suggestions:
                    status, error = "ambiguous_folder", "多个相近目录，请指定一个。"
            folder = ""
            if status == "ready":
                if len(matches) == 0:
                    status, error = "missing_folder", "未找到同名子文件夹。"
                elif len(matches) > 1:
                    status, error = "ambiguous_folder", "有多个同名子文件夹，无法唯一匹配。"
                else:
                    folder = matches[0]
            segments.append({"id": segment_id, "key": segment_key, "track_id": track_id, "text": text,
                             "start_us": start if isinstance(start, int) else 0, "duration_us": length if isinstance(length, int) else 0,
                             "end_us": end, "folder": folder, "status": status, "error": error, "matches": matches, "matched_by": matched_by,
                             "suggestions": suggestions, "explicit_folder": folder if matched_by == "manual" else ""})
    if selected - {t["id"] for t in track_list}:
        raise DraftError("选择的文字轨道已不存在，请重新读取草稿。", "track_not_found")
    segments.sort(key=lambda s: (s["start_us"], s["track_id"], s["id"]))
    for sequence, segment in enumerate(segments, 1):
        segment["filename"] = _filename(segment["text"], sequence, segment["start_us"])
    if not segments:
        warnings.append("没有发现可用于切段的文字片段。")
    if any(s["start_us"] < earlier["end_us"] for earlier, s in zip(segments, segments[1:])):
        warnings.append("存在时间重叠的文字片段；每条仍按自身起止时间单独导出。")
    warnings.append("只移除剪映可编辑的文本；源视频画面中已经存在的文字无法通过删除文本轨道去掉。")
    ready = sum(s["status"] == "ready" for s in segments)
    plan = {"draft_name": source.parent.name, "draft_path": str(source.parent), "duration_us": duration,
            "source_sha256": snapshot[source.name], "source_fingerprint": _fingerprint(snapshot),
            "output_root": str(root), "tracks": track_list, "segments": segments, "removed_text_count": removed,
            "warnings": warnings, "ready_count": ready, "blocked_count": len(segments) - ready,
            "can_export": bool(segments) and ready == len(segments), "options": options,
            "match_mode": mode, "output_mode": layout,
            "render_fingerprint": iteration.render_fingerprint(source, snapshot, decoder, app)}
    iteration.apply_incremental(plan, options.get("incremental", True) is not False)
    if _source_snapshot(source) != snapshot:
        raise DraftError("读取期间时间轴发生变化，请等待剪映保存完成后重新读取。", "source_changed")
    return plan


def _validate_compounds(data, source_root, documents):
    """Reject unresolved compound references that could preserve original text."""
    timeline_ids = {v.get("id") for p, v in documents.items() if p.name in DRAFT_FILES}
    def embedded(value):
        if isinstance(value, dict):
            return "tracks" in value or any(embedded(v) for v in value.values())
        if isinstance(value, list):
            return any(embedded(v) for v in value)
        if isinstance(value, str) and value.lstrip().startswith("{"):
            try:
                return embedded(json.loads(value))
            except ValueError:
                return False
        return False
    def validate(item):
        if not isinstance(item, dict):
            raise DraftError("复合草稿材料格式无法识别。", "unsupported_compound")
        if embedded(item):
            return
        for key, value in item.items():
            if key in {"draft_id", "timeline_id"} and value in timeline_ids:
                return
            if key in DRAFT_PATH_KEYS | {"path"} and isinstance(value, str) and value:
                path = Path(value).expanduser()
                path = path.resolve() if path.is_absolute() else (source_root / path).resolve()
                if not _inside(path, source_root):
                    raise DraftError("复合片段引用原草稿目录以外的时间轴，无法保证去除全部文字。", "external_timeline")
                if path.is_dir():
                    path = _draft_file(path)
                if path.relative_to(source_root) in documents and path.name in DRAFT_FILES:
                    return
        raise DraftError("无法解析复合片段的时间轴，已停止以避免保留文字。", "unsupported_compound")
    def visit(value):
        if isinstance(value, list):
            for v in value:
                visit(v)
        elif isinstance(value, dict):
            materials = value.get("materials")
            if isinstance(materials, dict):
                for category in ("drafts", "subdrafts", "compound_drafts"):
                    for item in materials.get(category, []):
                        validate(item)
            for v in value.values():
                visit(v)
    visit(data)


def _strip_text(data, location="draft"):
    """Recursively remove editable text, including embedded compound timelines."""
    removed = 0
    if isinstance(data, list):
        for value in data:
            removed += _strip_text(value, location)
        return removed
    if not isinstance(data, dict):
        return 0
    if "tracks" in data:
        _timeline(data)
        materials = data["materials"]
        text_ids = set()
        for category, values in list(materials.items()):
            if _text_like(category) and category not in TEXT_COLLECTIONS:
                if values:
                    raise DraftError("尚不支持的文字材料分类：%s。" % category, "unsupported_text")
            if category in TEXT_COLLECTIONS:
                if not isinstance(values, list):
                    raise DraftError("文字材料结构无法识别。", "unsupported_text")
                text_ids.update(v.get("id") for v in values if isinstance(v, dict))
                materials[category] = []
            elif isinstance(values, list):
                retained = []
                for value in values:
                    if isinstance(value, dict) and _text_like(value.get("type", "")):
                        if value.get("type") not in TEXT_TYPES:
                            raise DraftError("尚不支持的文字材料类型：%s。" % value.get("type"), "unsupported_text")
                        text_ids.add(value.get("id"))
                    else:
                        retained.append(value)
                materials[category] = retained
        retained_tracks = []
        for track in data["tracks"]:
            kind = str(track.get("type", "")).lower()
            if _text_like(kind) and kind not in TEXT_TYPES:
                raise DraftError("尚不支持的文字轨道类型：%s。" % kind, "unsupported_text")
            if kind in TEXT_TYPES:
                removed += len(track.get("segments", []))
                continue
            retained_segments = []
            for segment in track.get("segments", []):
                if not isinstance(segment, dict):
                    raise DraftError("片段结构无法识别。", "unsupported_schema")
                if segment.get("material_id") in text_ids:
                    removed += 1
                    continue
                refs = segment.get("extra_material_refs", [])
                if "extra_material_refs" in segment and isinstance(refs, list):
                    segment["extra_material_refs"] = [ref for ref in refs if ref not in text_ids]
                retained_segments.append(segment)
            track["segments"] = retained_segments
            retained_tracks.append(track)
        data["tracks"] = retained_tracks
    for key, value in list(data.items()):
        if isinstance(value, (list, dict)):
            removed += _strip_text(value, location + "/" + key)
        elif isinstance(value, str) and value.lstrip().startswith("{"):
            try:
                nested = json.loads(value)
            except ValueError:
                continue
            if isinstance(nested, dict) and ("tracks" in nested or key in {"draft", "draft_content", "draft_info", "draft_json"}):
                removed += _strip_text(nested, location + "/" + key)
                data[key] = json.dumps(nested, ensure_ascii=False, separators=(",", ":"))
    return removed


def _rewrite(data, ids, source_root, destination, context=None):
    """Change project identity and keep local source assets absolute."""
    if isinstance(data, list):
        return [_rewrite(v, ids, source_root, destination, context) for v in data]
    if not isinstance(data, dict):
        return ids.get(data, data) if isinstance(data, str) else data
    result = {}
    for key, value in data.items():
        if isinstance(value, str):
            if value in ids:
                value = ids[value]
            elif key.lower() in PATH_KEYS | DRAFT_PATH_KEYS and value and not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", value):
                if "##_draftpath_placeholder_" in value:
                    raise DraftError("草稿存在尚不支持的素材路径占位符，未生成副本。", "unsupported_path")
                candidate = Path(value).expanduser()
                if not candidate.is_absolute():
                    choices = [(context or source_root) / candidate, source_root / candidate]
                    candidate = next((p for p in choices if p.exists()), choices[-1])
                    if not candidate.exists():
                        raise DraftError("相对素材路径无法解析：%s。" % value, "missing_media")
                # Nested draft references require coordinated copies, not a reference to original text.
                is_draft_directory = candidate.is_dir() and any((candidate / f).is_file() for f in DRAFT_FILES)
                if candidate.name in DRAFT_FILES or key.lower() in DRAFT_PATH_KEYS or is_draft_directory:
                    if not _inside(candidate.resolve(), source_root):
                        raise DraftError("复合片段引用草稿目录以外的时间轴，无法保证去除全部文字。", "external_timeline")
                    rel = candidate.resolve().relative_to(source_root)
                    value = str(destination.joinpath(*(ids.get(p, p) for p in rel.parts)))
                elif not Path(value).expanduser().is_absolute():
                    value = str(candidate.resolve())
            elif value.lstrip().startswith("{"):
                try:
                    nested = json.loads(value)
                except ValueError:
                    nested = None
                if isinstance(nested, dict) and "tracks" in nested:
                    value = json.dumps(_rewrite(nested, ids, source_root, destination, context), ensure_ascii=False, separators=(",", ":"))
        elif isinstance(value, (dict, list)):
            value = _rewrite(value, ids, source_root, destination, context)
        result[key] = value
    return result


def prepare_draft(draft, destination, decoder=None, app=None, name=None, expected_sha=None, expected_fingerprint=None):
    source_file = _draft_file(draft)
    snapshot = _source_snapshot(source_file)
    if expected_sha and snapshot[source_file.name] != expected_sha:
        raise DraftError("草稿在生成分段计划后发生变化，请重新读取并确认计划。", "source_changed")
    if expected_fingerprint and _fingerprint(snapshot) != expected_fingerprint:
        raise DraftError("草稿时间轴在生成分段计划后发生变化，请重新读取并确认计划。", "source_changed")
    source_root = source_file.parent.resolve()
    destination = Path(destination).expanduser().absolute()
    if destination.is_symlink() or destination.exists():
        raise DraftError("副本目标已经存在；请使用全新的副本目录。", "destination_exists")
    if _inside(destination.resolve(), source_root) or _inside(source_root, destination.resolve()):
        raise DraftError("副本目录不能与原草稿目录重叠。", "unsafe_destination")
    draft_name = name or destination.name
    documents, empty_files, encoded_files, source_hashes = {}, [], set(), {}
    for current, dirs, files in os.walk(source_root, followlinks=False):
        dirs[:] = [d for d in dirs if d.lower() not in SKIP_DIRS and not d.startswith(".") and not (Path(current) / d).is_symlink()]
        for filename in sorted(files):
            path = Path(current) / filename
            # Templates, SQLite stores, backups, thumbnails and rendered caches can contain old text.
            if path.is_symlink() or not filename.endswith(".json") or filename.startswith("."):
                continue
            if filename in {"root_meta_info.json", "key_value.json"}:
                continue
            relative = path.relative_to(source_root)
            source_hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
            if path.stat().st_size == 0:
                empty_files.append(relative)
            else:
                documents[relative] = read_json(path, decoder, app)
                try:
                    json.loads(path.read_bytes())
                except (ValueError, UnicodeError):
                    encoded_files.add(relative)
    if source_file.relative_to(source_root) not in documents:
        documents[source_file.relative_to(source_root)] = read_json(source_file, decoder, app)
    timelines = {rel: data for rel, data in documents.items() if rel.name in DRAFT_FILES}
    for data in timelines.values():
        _timeline(data)
    for data in documents.values():
        _validate_compounds(data, source_root, documents)
    new_id = str(uuid.uuid4()).upper()
    ids = {}
    meta_rel = Path("draft_meta_info.json")
    meta = documents.get(meta_rel, {})
    if meta.get("draft_id"):
        ids[meta["draft_id"]] = new_id
    for data in timelines.values():
        if data.get("id"):
            ids.setdefault(data["id"], str(uuid.uuid4()).upper())
    project = documents.get(Path("Timelines/project.json"), {})
    if project.get("id"):
        ids.setdefault(project["id"], str(uuid.uuid4()).upper())
    removed_main = 0
    removed_total = 0
    for rel, data in documents.items():
        removed = _strip_text(data, str(rel))
        if rel == source_file.relative_to(source_root):
            removed_main = removed
        removed_total += removed
    for rel, data in list(documents.items()):
        documents[rel] = _rewrite(data, ids, source_root, destination, source_root / rel.parent)
    meta = documents.setdefault(meta_rel, {})
    for key, value in list(meta.items()):
        if "cloud" in key:
            meta[key] = False if isinstance(value, bool) else (0 if isinstance(value, (int, float)) else "")
    meta.update({"draft_id": new_id, "draft_name": draft_name, "draft_fold_path": str(destination), "draft_root_path": str(destination.parent),
                 "cloud_draft_sync": False, "draft_is_invisible": False, "draft_need_rename_folder": False,
                 "tm_draft_cloud_entry_id": -1, "tm_draft_cloud_parent_entry_id": -1, "tm_draft_cloud_space_id": -1, "tm_draft_cloud_user_id": -1,
                 "tm_draft_create": int(time.time() * 1000000), "tm_draft_modified": int(time.time() * 1000000), "tm_draft_removed": 0})
    if "draft_cover" in meta:
        meta["draft_cover"] = ""
    for rel, data in documents.items():
        if rel.name in DRAFT_FILES and "draft_name" in data:
            data["draft_name"] = draft_name
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".jianying-prepare-", dir=str(destination.parent)))
    try:
        for rel, data in documents.items():
            remapped = Path(*(ids.get(part, part) for part in rel.parts))
            out = stage / remapped
            out.parent.mkdir(parents=True, exist_ok=True)
            _write_json(out, data, rel in encoded_files, decoder, app)
        for rel in empty_files:
            remapped = Path(*(ids.get(part, part) for part in rel.parts))
            out = stage / remapped
            out.parent.mkdir(parents=True, exist_ok=True)
            out.touch()
        # Verify every generated timeline before making the new project visible.
        for rel in timelines:
            remapped = Path(*(ids.get(part, part) for part in rel.parts))
            decoded = _timeline(read_json(stage / remapped, decoder, app))
            if _strip_text(copy.deepcopy(decoded)):
                raise DraftError("副本文字移除校验失败。", "text_remains")
        if destination.exists():
            raise DraftError("副本目标在处理过程中已被创建，未覆盖。", "destination_exists")
        for rel, original_hash in source_hashes.items():
            if hashlib.sha256((source_root / rel).read_bytes()).hexdigest() != original_hash:
                raise DraftError("读取期间原草稿发生变化，请等待剪映保存完成后重新生成。", "source_changed")
        if _source_snapshot(source_file) != snapshot:
            raise DraftError("读取期间原时间轴发生变化，请重新生成。", "source_changed")
        stage.rename(destination)
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return {"draft_name": draft_name, "draft_path": str(destination), "draft_id": new_id, "source_draft_path": str(source_root),
            "duration_us": timelines[source_file.relative_to(source_root)].get("duration", 0),
            "source_sha256": source_hashes.get(source_file.relative_to(source_root), ""),
            "source_fingerprint": _fingerprint(snapshot),
            "removed_text_count": removed_main, "removed_text_count_all_files": removed_total,
            "timeline_files": len(timelines), "warnings": ["副本保持完整时间轴，已移除全部可识别的可编辑文字；请在剪映中检查画面后导出。"]}


def verify_clean(draft, decoder=None, app=None):
    """Read-only pre-render guard for all editable timelines in a prepared copy."""
    source = _draft_file(draft)
    source_root = source.parent
    snapshot = _source_snapshot(source)
    documents = {}
    for current, dirs, files in os.walk(source_root, followlinks=False):
        dirs[:] = [d for d in dirs if d.lower() not in SKIP_DIRS and not d.startswith(".") and not (Path(current) / d).is_symlink()]
        for filename in files:
            path = Path(current) / filename
            if path.is_symlink() or not filename.endswith(".json") or filename in {"root_meta_info.json", "key_value.json"} or not path.stat().st_size:
                continue
            documents[path.relative_to(source_root)] = read_json(path, decoder, app)
    if source.relative_to(source_root) not in documents:
        documents[source.relative_to(source_root)] = read_json(source, decoder, app)
    main = _timeline(documents[source.relative_to(source_root)])
    checked = 0

    def inspect(value):
        nonlocal checked
        if isinstance(value, list):
            for item in value:
                inspect(item)
        elif isinstance(value, dict):
            if "tracks" in value:
                _timeline(value)
                checked += 1
                if any(_text_like(track.get("type", "")) for track in value["tracks"]):
                    raise DraftError("无文本副本中仍有文字轨道，请重新生成副本后再导出。", "text_remains")
                for category, materials in value["materials"].items():
                    if _text_like(category) and materials:
                        raise DraftError("无文本副本中仍有文字材料，请重新生成副本后再导出。", "text_remains")
                    if isinstance(materials, list) and any(isinstance(m, dict) and _text_like(m.get("type", "")) for m in materials):
                        raise DraftError("无文本副本中仍有可编辑文字材料。", "text_remains")
            for item in value.values():
                inspect(item)
        elif isinstance(value, str) and value.lstrip().startswith("{"):
            try:
                parsed = json.loads(value)
            except ValueError:
                return
            if isinstance(parsed, dict):
                inspect(parsed)

    for data in documents.values():
        _validate_compounds(data, source_root, documents)
        _strip_text(copy.deepcopy(data))  # Validate unknown text schemas without changing any file.
        inspect(data)
    if _source_snapshot(source) != snapshot:
        raise DraftError("验证期间副本时间轴发生变化，请等待剪映保存完成后重试。", "source_changed")
    return {"ok": True, "clean": True, "duration_us": main.get("duration", 0), "checked_count": checked}


def main(argv=None):
    parser = argparse.ArgumentParser(description="剪映按文本切段：草稿读取与去文字副本")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("--root")
    plan = commands.add_parser("plan")
    plan.add_argument("--draft", required=True)
    plan.add_argument("--output", required=True)
    plan.add_argument("--track", action="append")
    plan.add_argument("--aliases", help="文本到导出根目录相对路径的 JSON 文件")
    plan.add_argument("--options", help="匹配、增量和逐段目录设置 JSON 文件")
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--draft", required=True)
    prepare.add_argument("--destination", required=True)
    prepare.add_argument("--name")
    prepare.add_argument("--expected-sha")
    prepare.add_argument("--expected-fingerprint")
    verify = commands.add_parser("verify-clean")
    verify.add_argument("--draft", required=True)
    for command in (listing, plan, prepare, verify):
        command.add_argument("--decoder")
        command.add_argument("--app")
    args = parser.parse_args(argv)
    try:
        if args.command == "list":
            result = list_drafts(args.root, args.decoder, args.app)
        elif args.command == "plan":
            aliases = read_json(args.aliases) if args.aliases else None
            result = make_plan(args.draft, args.output, args.track, args.decoder, args.app, aliases,
                               read_json(args.options) if args.options else None)
        elif args.command == "prepare":
            result = prepare_draft(args.draft, args.destination, args.decoder, args.app, args.name, args.expected_sha, args.expected_fingerprint)
        else:
            result = verify_clean(args.draft, args.decoder, args.app)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (DraftError, OSError, ValueError, TypeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc), "code": getattr(exc, "code", "io_error")}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    sys.exit(main())
