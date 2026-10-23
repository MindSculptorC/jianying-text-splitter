#!/usr/bin/env python3
"""Prepare a text-free Jianying copy, then split a rendered master safely."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

import core
import register

HERE = Path(__file__).resolve().parent
MEDIA = HERE / "native/media-export"
APP_STATUS = HERE / "native/app-status"


class WorkflowError(Exception):
    def __init__(self, message, code="workflow_error", **context):
        super().__init__(message)
        self.code, self.context = code, context


def _sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write(path, value):
    path = Path(path)
    if path.is_symlink():
        raise WorkflowError("任务文件已变成符号链接，停止写入。", "unsafe_path")
    fd, name = tempfile.mkstemp(prefix=".workflow-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(value, out, ensure_ascii=False, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def _load(path):
    with Path(path).open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise WorkflowError("任务文件必须是 JSON 对象。", "invalid_job")
    return value


def _directory(path):
    path = Path(path).expanduser().absolute()
    if not path.is_dir() or path.resolve() != path:
        raise WorkflowError("文件夹不存在、包含符号链接或路径已改变：%s" % path, "unsafe_path")
    return path


def _assert_editor_closed(app):
    identifiers = {"com.lemon.lvpro"}
    try:
        with (Path(app) / "Contents/Info.plist").open("rb") as handle:
            identifier = plistlib.load(handle).get("CFBundleIdentifier")
            if identifier:
                identifiers.add(identifier)
    except (OSError, ValueError):
        pass
    try:
        result = subprocess.run([str(APP_STATUS), *sorted(identifiers)], capture_output=True, timeout=15)
        state = json.loads(result.stdout)
        if result.returncode or "running" not in state:
            raise ValueError("invalid process status")
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        raise WorkflowError("无法确认剪映已退出；为保护草稿列表，没有写入。", "editor_status_unavailable") from exc
    if state["running"]:
        raise WorkflowError("请先退出剪映，再准备无文本副本。", "editor_running")


@contextmanager
def _job_lock(job_dir):
    fd = os.open(job_dir / ".split.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise WorkflowError("这个任务正在另一个窗口中导出。", "job_running") from exc
        yield
    finally:
        os.close(fd)


def _target(segment, root):
    folder = _directory(segment.get("folder", ""))
    try:
        folder.relative_to(root)
    except ValueError as exc:
        if segment.get("explicit_folder") != str(folder):
            raise WorkflowError("片段输出路径不属于明确指定的目录。", "unsafe_path") from exc
    filename = segment.get("filename", "")
    if not filename or Path(filename).name != filename or "/" in filename or "\\" in filename or not filename.endswith(".mp4"):
        raise WorkflowError("片段文件名无效。", "invalid_plan")
    if segment.get("status") != "ready":
        raise WorkflowError("冻结计划仍有未就绪片段。", "invalid_plan")
    if not all(isinstance(segment.get(k), int) and not isinstance(segment[k], bool) for k in ("start_us", "duration_us")):
        raise WorkflowError("片段时间不是整数微秒。", "invalid_plan")
    if segment["start_us"] < 0 or segment["duration_us"] <= 0:
        raise WorkflowError("片段时间无效。", "invalid_plan")
    target = folder / filename
    if target.is_symlink():
        raise WorkflowError("目标视频路径是符号链接，未写入。", "unsafe_path")
    return target


def prepare(draft, output, app=None, aliases=None, tracks=None, expected_sha=None, expected_fingerprint=None, options=None):
    app = Path(app or core.DEFAULT_APP)
    if not expected_sha:
        raise WorkflowError("准备副本必须提供已预览草稿的 SHA-256。", "expected_sha_required")
    plan = core.make_plan(draft, output, tracks=tracks, app=app, aliases=aliases, options=options)
    if plan["source_sha256"] != expected_sha:
        raise WorkflowError("草稿已在预览后发生变化，请重新读取。", "draft_changed")
    if expected_fingerprint and plan["source_fingerprint"] != expected_fingerprint:
        raise WorkflowError("子时间轴已在预览后发生变化，请重新读取。", "draft_changed")
    if not plan.get("can_export"):
        raise WorkflowError("请先解决所有未匹配、重名或时间范围问题。", "plan_blocked", plan=plan)
    root = _directory(plan["output_root"])
    for segment in plan["segments"]:
        target = _target(segment, root)
        if segment.get("action") == "skip":
            if not target.is_file() or _sha(target) != segment["reuse"]["sha256"]:
                raise WorkflowError("历史视频已变化，请重新读取。", "completed_file_changed")
        elif target.exists():
            raise WorkflowError("输出视频已存在，未覆盖。", "output_exists")
    if not plan["export_count"]:
        return {"ok": True, "status": "up_to_date", "plan": plan, "completed_count": len(plan["segments"]),
                "skipped_count": plan["skip_count"], "exported_count": 0}
    reusable = plan.get("reusable_master")
    if reusable:
        if _sha(reusable["path"]) != reusable["sha256"]:
            raise WorkflowError("可复用母版已改变，请重新读取。", "master_changed")
    else:
        _assert_editor_closed(app)
    identifier = time.strftime("%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:10]
    jobs = root / ".剪映切段任务"
    if jobs.is_symlink():
        raise WorkflowError("任务目录不能是符号链接。", "unsafe_path")
    jobs.mkdir(exist_ok=True)
    job_dir = jobs / identifier
    job_dir.mkdir()
    job_path = job_dir / "job.json"
    plan_path = job_dir / "plan.json"
    master = job_dir / ("无文本母版_" + identifier.rsplit("_", 1)[-1] + ".mp4")
    _write(plan_path, plan)
    job = {"version": 1, "id": identifier, "status": "preparing", "created_at": time.time(),
           "output_root": str(root), "plan_path": str(plan_path), "plan_sha256": _sha(plan_path),
           "master_path": str(master), "manifest_path": str(job_dir / "manifest.json"),
           "completed_count": 0, "total_count": len(plan["segments"])}
    _write(job_path, job)
    prepared = receipt = None
    try:
        if reusable:
            previous = _directory(reusable["job_dir"])
            prepared = _load(previous / "prepared.json")
            receipt = _load(previous / "registration.json")
            _write(job_dir / "prepared.json", prepared)
            _write(job_dir / "registration.json", receipt)
            job.update(status="awaiting_master", master_path=reusable["path"], master_sha256=reusable["sha256"],
                       prepared_path=str(job_dir / "prepared.json"), registration_path=str(job_dir / "registration.json"),
                       draft_path=prepared["draft_path"], draft_name=prepared["draft_name"], reused_master=True)
            _write(job_path, job)
            return {"ok": True, "plan": plan, "prepared": prepared, "job_dir": str(job_dir),
                    "master_path": reusable["path"], "job_path": str(job_path), "reused_master": True}
        source = Path(plan["draft_path"])
        destination = source.parent / ("切段助手_" + identifier)
        prepared = core.prepare_draft(source, destination, app=app, name=destination.name,
                                      expected_sha=expected_sha,
                                      expected_fingerprint=plan["source_fingerprint"])
        _write(job_dir / "prepared.json", prepared)
        _assert_editor_closed(app)
        receipt = register.register_draft(source.parent, prepared)
        _write(job_dir / "registration.json", receipt)
        job.update(status="awaiting_master", prepared_path=str(job_dir / "prepared.json"),
                   registration_path=str(job_dir / "registration.json"), draft_path=prepared["draft_path"],
                   draft_name=prepared["draft_name"])
        _write(job_path, job)
        return {"ok": True, "plan": plan, "prepared": prepared, "job_dir": str(job_dir),
                "master_path": str(master), "job_path": str(job_path)}
    except BaseException as exc:
        job.update(status="prepare_failed", error=str(exc))
        recovery = {"error": str(exc), "prepared": prepared, "registration": receipt,
                    "source_unchanged_by_workflow": True,
                    "registry_recovery_directory": str(Path(plan["draft_path"]).parent / ".textsplit-index-backups"),
                    "instructions": "原草稿保留。若已经注册副本，可用 registration 凭据调用 undo_registration；不要整份覆盖旧索引。"}
        _write(job_dir / "recovery.json", recovery)
        _write(job_path, job)
        raise WorkflowError(str(exc), getattr(exc, "code", "prepare_failed"),
                            job_path=str(job_path), recovery_path=str(job_dir / "recovery.json")) from exc


def _media(*args, timeout=300):
    try:
        result = subprocess.run([str(MEDIA), *map(str, args)], capture_output=True, timeout=timeout)
        if result.returncode:
            try:
                detail = json.loads(result.stderr)
            except ValueError:
                detail = {}
            raise WorkflowError(detail.get("message", "系统视频处理失败。"), detail.get("error", "media_failed"))
        return json.loads(result.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        raise WorkflowError("系统视频处理失败：%s" % exc, "media_failed") from exc


def _tolerance(info):
    fps = float(info.get("fps", 0))
    if not math.isfinite(fps) or fps <= 0:
        raise WorkflowError("母版视频帧率无法识别。", "invalid_master")
    return math.ceil(max(20000, 2000000 / fps))


def split(job_path, master=None):
    job_path = Path(job_path).expanduser().absolute()
    if job_path.is_symlink() or job_path.name != "job.json":
        raise WorkflowError("任务路径无效。", "invalid_job")
    job_dir = _directory(job_path.parent)
    with _job_lock(job_dir):
        job = _load(job_path)
        try:
            if job.get("version") != 1 or job.get("status") in {"preparing", "prepare_failed"}:
                raise WorkflowError("任务尚未完成无文本副本准备。", "invalid_job")
            if job.get("prepared_path") != str(job_dir / "prepared.json") or job.get("registration_path") != str(job_dir / "registration.json"):
                raise WorkflowError("任务缺少无文本副本和注册凭据。", "invalid_job")
            if not (job_dir / "prepared.json").is_file() or not (job_dir / "registration.json").is_file():
                raise WorkflowError("无文本副本准备凭据已丢失。", "invalid_job")
            root = _directory(job["output_root"])
            if job_dir.parent != root / ".剪映切段任务":
                raise WorkflowError("任务目录不在冻结的导出根目录中。", "invalid_job")
            plan_path = job_dir / "plan.json"
            if plan_path.is_symlink() or _sha(plan_path) != job["plan_sha256"]:
                raise WorkflowError("切段计划已变化，不能继续原任务。", "plan_changed")
            plan = _load(plan_path)
            if plan.get("output_root") != str(root) or not plan.get("can_export") or not plan.get("segments"):
                raise WorkflowError("冻结切段计划无效。", "invalid_plan")
            targets = [_target(segment, root) for segment in plan["segments"]]
            if len(set(targets)) != len(targets):
                raise WorkflowError("多个片段指向同一输出文件。", "invalid_plan")
            master_path = Path(master or job["master_path"]).expanduser().absolute()
            if not master_path.is_file() or master_path.is_symlink():
                raise WorkflowError("请先从无文本副本导出完整母版视频。", "master_missing")
            master_info = _media("probe", master_path)
            tolerance = _tolerance(master_info)
            duration = int(master_info.get("duration_us", 0))
            if duration <= 0 or abs(duration - plan["duration_us"]) > tolerance:
                raise WorkflowError("母版时长与完整时间轴不一致，请导出整个无文本副本后重试。", "master_duration_mismatch")
            master_hash = _sha(master_path)
            if job.get("master_sha256") and job["master_sha256"] != master_hash:
                raise WorkflowError("母版与任务开始时不同，不能混用新旧母版续传。", "master_changed")
            master_stat = (master_path.stat().st_size, master_path.stat().st_mtime_ns)
            manifest_path = job_dir / "manifest.json"
            if manifest_path.is_symlink():
                raise WorkflowError("完成清单不能是符号链接。", "unsafe_path")
            manifest = _load(manifest_path) if manifest_path.exists() else {"version": 1, "plan_sha256": job["plan_sha256"], "outputs": []}
            if manifest.get("plan_sha256") != job["plan_sha256"]:
                raise WorkflowError("完成清单不属于当前计划。", "invalid_manifest")
            completed = {}
            for record in manifest.get("outputs", []):
                number = record.get("index")
                if not isinstance(number, int) or number in completed or not 0 <= number < len(targets):
                    raise WorkflowError("完成清单片段编号无效。", "invalid_manifest")
                target = targets[number]
                segment = plan["segments"][number]
                if (record.get("segment_id") != segment["id"] or record.get("start_us") != segment["start_us"]
                        or record.get("requested_duration_us") != segment["duration_us"]):
                    raise WorkflowError("完成清单与冻结片段不一致。", "invalid_manifest")
                if record.get("path") != str(target) or not target.is_file() or record.get("sha256") != _sha(target):
                    raise WorkflowError("已完成片段缺失或内容改变，停止续传。", "completed_file_changed")
                completed[number] = record
            for number, segment in enumerate(plan["segments"]):
                if number in completed or segment.get("action") != "skip":
                    continue
                target = targets[number]
                record = dict(segment["reuse"])
                if record.get("path") != str(target) or not target.is_file() or record.get("sha256") != _sha(target):
                    raise WorkflowError("待复用视频缺失或改变，请重新读取草稿。", "completed_file_changed")
                record.update(index=number, reused=True, export_key=segment.get("export_key"))
                completed[number] = record
            for number, target in enumerate(targets):
                if target.exists() and number not in completed:
                    raise WorkflowError("目标存在未登记视频，未覆盖：%s" % target, "output_exists")
            job.update(status="splitting", master_path=str(master_path), master_sha256=master_hash,
                       master_info=master_info, completed_count=len(completed), error=None)
            _write(job_path, job)
            manifest["outputs"] = [completed[k] for k in sorted(completed)]
            _write(manifest_path, manifest)
            exported_now = 0
            for number, segment in enumerate(plan["segments"]):
                if number in completed:
                    continue
                target = _target(segment, _directory(root))
                if (master_path.stat().st_size, master_path.stat().st_mtime_ns) != master_stat:
                    raise WorkflowError("导出过程中母版发生变化。", "master_changed")
                cut_duration = min(segment["duration_us"], duration - segment["start_us"])
                if cut_duration <= 0 or segment["duration_us"] - cut_duration > tolerance:
                    raise WorkflowError("片段范围超出母版。", "invalid_range")
                actual = _media("cut", master_path, target, segment["start_us"], cut_duration,
                                timeout=max(300, math.ceil(cut_duration / 1000000 * 20)))
                if (master_path.stat().st_size, master_path.stat().st_mtime_ns) != master_stat:
                    raise WorkflowError("导出过程中母版发生变化，当前文件没有登记为完成。", "master_changed")
                if not target.is_file() or abs(int(actual.get("duration_us", 0)) - cut_duration) > tolerance:
                    raise WorkflowError("片段导出后时长校验失败。", "duration_mismatch")
                record = {"index": number, "segment_id": segment["id"], "text": segment["text"],
                          "export_key": segment.get("export_key"), "reused": False,
                          "path": str(target), "start_us": segment["start_us"],
                          "requested_duration_us": segment["duration_us"], "cut_duration_us": cut_duration,
                          "actual_duration_us": actual["duration_us"], "sha256": _sha(target),
                          "bytes": target.stat().st_size, "media": actual, "completed_at": time.time()}
                completed[number] = record
                exported_now += 1
                manifest["outputs"] = [completed[k] for k in sorted(completed)]
                _write(manifest_path, manifest)
                job["completed_count"] = len(completed)
                _write(job_path, job)
            if _sha(master_path) != master_hash:
                raise WorkflowError("母版内容在处理期间发生变化，任务未标记完成。", "master_changed")
            job.update(status="complete", completed_at=time.time(), completed_count=len(completed))
            _write(job_path, job)
            return {"ok": True, "status": "complete", "job_path": str(job_path), "manifest_path": str(manifest_path),
                    "completed_count": len(completed), "total_count": len(targets), "outputs": manifest["outputs"],
                    "skipped_count": len(completed) - exported_now, "exported_count": exported_now}
        except BaseException as exc:
            job.update(status="split_failed", error=str(exc), failed_at=time.time())
            _write(job_path, job)
            raise WorkflowError(str(exc), getattr(exc, "code", "split_failed"), job_path=str(job_path)) from exc


def main(argv=None):
    parser = argparse.ArgumentParser(description="剪映无文本切段与归档工作流")
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("--draft", required=True)
    prep.add_argument("--output", required=True)
    prep.add_argument("--app", default=str(core.DEFAULT_APP))
    prep.add_argument("--aliases")
    prep.add_argument("--options")
    prep.add_argument("--track", action="append")
    prep.add_argument("--expected-sha", required=True)
    prep.add_argument("--expected-fingerprint")
    cut = commands.add_parser("split")
    cut.add_argument("--job", required=True)
    cut.add_argument("--master")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            aliases = _load(args.aliases) if args.aliases else None
            result = prepare(args.draft, args.output, args.app, aliases, args.track, args.expected_sha, args.expected_fingerprint,
                             _load(args.options) if args.options else None)
        else:
            result = split(args.job, args.master)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc), "code": getattr(exc, "code", "workflow_error"),
                          **getattr(exc, "context", {})}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    sys.exit(main())
