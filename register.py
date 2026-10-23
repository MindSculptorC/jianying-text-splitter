"""Register an already prepared Jianying copy without replacing other drafts.

Importing this module never reads or writes any user's Projects directory.
Every operation is explicit; undo removes only our unchanged registered entry.
"""
from __future__ import annotations

from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
from typing import Mapping, Any
import uuid


class RegistrationError(RuntimeError):
    pass


class ConcurrentIndexChange(RegistrationError):
    pass


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _entry_sha(value: Any) -> str:
    return _sha(json.dumps(value, ensure_ascii=False, sort_keys=True,
                           separators=(",", ":")).encode("utf-8"))


def _same_path(left: str | Path, right: str | Path) -> bool:
    return Path(left).expanduser().resolve() == Path(right).expanduser().resolve()


@contextmanager
def _lock(root: Path):
    # Serializes this tool's writers. The editor does not share this advisory
    # lock; a hash comparison immediately before replace detects its changes.
    lock_path = root / ".textsplit-index.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _read_index(index: Path) -> tuple[bytes, dict]:
    if index.is_symlink():
        raise RegistrationError("草稿索引不能是符号链接。")
    try:
        raw = index.read_bytes()
        data = json.loads(raw)
    except (OSError, ValueError) as exc:
        raise RegistrationError("无法读取剪映草稿索引，请先让剪映创建有效的草稿库。") from exc
    entries = data.get("all_draft_store") if isinstance(data, dict) else None
    if not isinstance(entries, list) or any(not isinstance(item, dict) for item in entries):
        raise RegistrationError("不支持当前草稿索引结构；没有修改索引。")
    if "draft_ids" in data and not (isinstance(data["draft_ids"], int) and not isinstance(data["draft_ids"], bool)):
        raise RegistrationError("不支持当前 draft_ids 类型；没有修改索引。")
    return raw, data


def _new_file(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
    finally:
        os.close(fd)


def _sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _commit(index: Path, before: bytes, updated: dict, operation: dict) -> dict:
    """Called under our advisory lock; never restores an entire old index."""
    if _sha(index.read_bytes()) != _sha(before):
        raise ConcurrentIndexChange("剪映草稿列表已变化，请刷新后重试；没有覆盖最新列表。")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    token = uuid.uuid4().hex[:12]
    backup_dir = index.parent / ".textsplit-index-backups"
    if backup_dir.is_symlink():
        raise RegistrationError("备份目录不能是符号链接。")
    backup_dir.mkdir(mode=0o700, exist_ok=True)
    backup = backup_dir / f"root_meta_info.{stamp}.{token}.json"
    receipt_path = backup_dir / f"receipt.{stamp}.{token}.json"
    after = _json_bytes(updated)
    receipt = {"version": 1, "operation": operation["operation"],
               "index_path": str(index), "backup_path": str(backup),
               "receipt_path": str(receipt_path), "created_utc": stamp,
               "index_sha_before": _sha(before), "index_sha_after": _sha(after),
               **operation}
    _new_file(backup, before)
    # A prewritten receipt also supports recovery if the process exits after
    # atomic replacement but before returning to its caller.
    _new_file(receipt_path, _json_bytes(receipt))
    fd, temporary = tempfile.mkstemp(prefix=".root_meta_info.textsplit-", suffix=".tmp", dir=index.parent)
    temp_path = Path(temporary)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(after)
            output.flush()
            os.fsync(output.fileno())
        if index.is_symlink() or _sha(index.read_bytes()) != _sha(before):
            raise ConcurrentIndexChange("写入前检测到剪映修改了列表，请重试；最新列表已保留。")
        os.replace(temp_path, index)
        _sync_directory(index.parent)
    finally:
        temp_path.unlink(missing_ok=True)
    return receipt


def _make_entry(root: Path, prepared: Mapping[str, Any], template: dict) -> dict:
    destination = Path(prepared["draft_path"]).expanduser().resolve()
    if not destination.is_dir() or destination.parent != root:
        raise RegistrationError("无文本副本必须是指定剪映草稿库下已存在的直接子文件夹。")
    draft_json = next((destination / name for name in ("draft_info.json", "draft_content.json")
                       if (destination / name).is_file()), None)
    if draft_json is None or draft_json.is_symlink():
        raise RegistrationError("副本中没有有效的草稿主文件。")
    draft_id = str(prepared.get("draft_id") or "").strip()
    name = str(prepared.get("draft_name") or "").strip()
    if not draft_id or not name:
        raise RegistrationError("prepare 结果必须提供 draft_id 和 draft_name。")
    now = time.time_ns() // 1_000
    entry = deepcopy(template)
    # The registered copy is a local draft, independent of the source's cloud
    # identity. Existing entries in the index are never changed.
    for key in list(entry):
        if "cloud" in key:
            value = entry[key]
            entry[key] = False if isinstance(value, bool) else (0 if isinstance(value, (int, float)) else "")
    entry.update({
        "cloud_draft_cover": False, "cloud_draft_sync": False,
        "draft_cloud_last_action_download": False,
        "draft_cloud_purchase_info": "", "draft_cloud_template_id": "",
        "draft_cloud_tutorial_info": "", "draft_cloud_videocut_purchase_info": "",
        "draft_id": draft_id, "draft_name": name,
        "draft_fold_path": str(destination), "draft_root_path": str(root),
        "draft_json_file": str(draft_json),
        "draft_cover": str(destination / "draft_cover.jpg") if (destination / "draft_cover.jpg").is_file() else "",
        "draft_is_invisible": False, "draft_is_cloud_temp_draft": False,
        "tm_draft_create": now, "tm_draft_modified": now, "tm_draft_removed": 0,
        "tm_duration": int(prepared.get("duration_us", template.get("tm_duration", 0))),
        "tm_draft_cloud_completed": "", "tm_draft_cloud_entry_id": -1,
        "tm_draft_cloud_modified": 0, "tm_draft_cloud_parent_entry_id": -1,
        "tm_draft_cloud_space_id": -1, "tm_draft_cloud_user_id": -1,
    })
    return entry


def register_draft(root: str | Path, prepared: Mapping[str, Any],
                   source_draft_dir: str | Path | None = None) -> dict:
    """Register core.prepare's existing copy; returns a persisted undo receipt.

    Required prepare keys: draft_path, draft_id, draft_name. Optional:
    source_draft_path (template lookup), duration_us. No draft files are changed.
    """
    root = Path(root).expanduser().resolve()
    if not root.is_dir():
        raise RegistrationError("剪映草稿库不存在。")
    index = root / "root_meta_info.json"
    with _lock(root):
        raw, data = _read_index(index)
        entries = data["all_draft_store"]
        source = source_draft_dir or prepared.get("source_draft_path")
        template = next((item for item in entries if source and item.get("draft_fold_path")
                         and _same_path(item["draft_fold_path"], source)), {})
        entry = _make_entry(root, prepared, template)
        for previous in entries:
            same_id = str(previous.get("draft_id", "")).casefold() == entry["draft_id"].casefold()
            same_folder = previous.get("draft_fold_path") and _same_path(previous["draft_fold_path"], entry["draft_fold_path"])
            if same_id or same_folder:
                raise RegistrationError("该草稿 ID 或文件夹已经注册；没有重复写入。")
        updated = deepcopy(data)
        updated["all_draft_store"].insert(0, entry)
        if "draft_ids" in updated:
            updated["draft_ids"] = len(updated["all_draft_store"])
        return _commit(index, raw, updated, {"operation": "register", "registered_entry": entry,
                                            "entry_sha": _entry_sha(entry), "draft_id": entry["draft_id"],
                                            "draft_path": entry["draft_fold_path"]})


def undo_registration(receipt: Mapping[str, Any] | str | Path) -> dict:
    """Safely undo one registration, preserving later drafts and other changes.

    If the app changed our entry, fail rather than deleting an edited entry.
    If our entry is already absent, return a no-op. Never deletes draft files.
    """
    if isinstance(receipt, (str, Path)):
        receipt = json.loads(Path(receipt).read_text(encoding="utf-8"))
    if receipt.get("version") != 1 or receipt.get("operation") != "register":
        raise RegistrationError("不是可撤销的注册凭据。")
    index = Path(receipt["index_path"]).expanduser().resolve()
    if index.name != "root_meta_info.json":
        raise RegistrationError("凭据中的索引路径无效。")
    original_entry = receipt.get("registered_entry")
    if not isinstance(original_entry, dict) or _entry_sha(original_entry) != receipt.get("entry_sha"):
        raise RegistrationError("注册凭据不完整或已变化。")
    with _lock(index.parent):
        raw, data = _read_index(index)
        entries = data["all_draft_store"]
        matches = [i for i, entry in enumerate(entries)
                   if str(entry.get("draft_id", "")).casefold() == str(receipt["draft_id"]).casefold()]
        if not matches:
            return {"status": "already_absent", "draft_id": receipt["draft_id"]}
        if len(matches) != 1 or _entry_sha(entries[matches[0]]) != receipt["entry_sha"]:
            raise ConcurrentIndexChange("该副本条目已被剪映修改，自动撤销已停止；现有草稿列表保持不变。")
        updated = deepcopy(data)
        del updated["all_draft_store"][matches[0]]
        if "draft_ids" in updated:
            updated["draft_ids"] = len(updated["all_draft_store"])
        result = _commit(index, raw, updated, {"operation": "undo_registration",
                                              "draft_id": receipt["draft_id"],
                                              "registration_receipt_path": receipt.get("receipt_path")})
        result["status"] = "removed_registration"
        return result


def restore_registration(receipt: Mapping[str, Any] | str | Path) -> dict:
    """Recovery alias: undo only our entry, never restore the whole old backup."""
    return undo_registration(receipt)
