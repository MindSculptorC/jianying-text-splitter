"""Local matching and verified cross-job incremental planning. No network services."""
import copy
import hashlib
import json
from difflib import SequenceMatcher
from pathlib import Path
import re
import unicodedata


SYNONYMS = (
    ("关键词", "关键字", "重点词", "核心词"),
    ("文献资料", "参考文献", "文献", "参考资料", "论文资料", "论文引用"),
    ("单张", "单图", "单张图片", "单张照片"),
    ("多张", "多图", "多张图片", "图片合集", "组图"),
    ("折线图", "折线", "趋势图", "曲线图", "走势图"),
    ("柱状图", "柱形图", "条形图"),
    ("饼图", "饼状图", "圆饼图"),
    ("局部边框", "局部框选", "局部框", "框选局部"),
    ("全屏", "全屏视频", "满屏", "满屏视频", "通屏"),
    ("png", "透明图", "透明背景图", "抠图素材"),
    ("人物", "人像", "肖像"),
    ("截图", "屏幕截图", "截屏"),
)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                     separators=(",", ":")).encode()).hexdigest()


def normalized(value):
    return re.sub(r"[\W_]+", "", unicodedata.normalize("NFKC", value).casefold())


def fuzzy_matches(label, folders):
    term = normalized(label)
    group = next((set(map(normalized, g)) for g in SYNONYMS if term in map(normalized, g)), set())
    candidates = []
    for name, paths in folders.items():
        other = normalized(name)
        score = SequenceMatcher(None, term, other).ratio()
        reason = "名称相似"
        if term == other:
            score, reason = 1.0, "规范化名称"
        elif other in group:
            score, reason = 1.0, "近义词"
        # Single-character overlap is not enough for a useful suggestion.
        if score >= .72 and min(len(term), len(other)) >= 2:
            candidates.extend({"folder": p, "score": round(score, 3), "reason": reason} for p in paths)
    candidates.sort(key=lambda c: (-c["score"], c["folder"]))
    unique = bool(candidates) and (len(candidates) == 1 or candidates[0]["score"] - candidates[1]["score"] >= .12)
    return candidates[:5], unique


def render_fingerprint(source, snapshot, decoder, app):
    """Conservative whole-render identity, excluding labels and label-only assets.

    Any uncertain non-text edit invalidates all clips. Media content is hashed,
    so replacing a source at the same path cannot silently reuse stale output.
    """
    import core
    documents, media = {}, {}

    def strings(v):
        if isinstance(v, str):
            yield v
        elif isinstance(v, list):
            for item in v:
                yield from strings(item)
        elif isinstance(v, dict):
            for item in v.values():
                yield from strings(item)

    def prune(v):
        if isinstance(v, list):
            for item in v:
                prune(item)
        elif isinstance(v, dict):
            if "tracks" in v and "materials" in v:
                index = core._material_index(v)
                text_tracks = [t for t in v["tracks"] if core._text_like(t.get("type", ""))]
                other_tracks = [t for t in v["tracks"] if t not in text_tracks]
                def closure(value):
                    found = set(strings(value)) & index.keys()
                    pending = list(found)
                    while pending:
                        extra = (set(strings(index[pending.pop()][1])) & index.keys()) - found
                        found.update(extra)
                        pending.extend(extra)
                    return found
                removable = closure(text_tracks) - closure(other_tracks)
                for category, values in v["materials"].items():
                    if isinstance(values, list):
                        v["materials"][category] = [x for x in values if not isinstance(x, dict) or x.get("id") not in removable]
            for key, item in list(v.items()):
                if isinstance(item, str) and item.lstrip().startswith("{"):
                    try:
                        parsed = json.loads(item)
                        prune(parsed)
                        v[key] = json.dumps(parsed, sort_keys=True, separators=(",", ":"))
                    except ValueError:
                        pass
                else:
                    prune(item)

    def assets(v):
        if isinstance(v, str) and v.lstrip().startswith("{"):
            try:
                assets(json.loads(v))
            except ValueError:
                pass
        elif isinstance(v, list):
            for item in v:
                assets(item)
        elif isinstance(v, dict):
            if isinstance(v.get("materials"), dict):
                v["materials"] = {k: value for k, value in v["materials"].items() if value != []}
            for k, item in v.items():
                if k in core.PATH_KEYS and isinstance(item, str) and item:
                    p = Path(item).expanduser()
                    p = p if p.is_absolute() else source.parent / p
                    if p.is_file() and p.name not in core.DRAFT_FILES and str(p) not in media:
                        media[str(p)] = sha(p)
                assets(item)

    for relative in sorted(snapshot):
        data = copy.deepcopy(core.read_json(source.parent / relative, decoder, app))
        prune(data)
        core._strip_text(data)
        assets(data)
        documents[relative] = data
    return digest({"version": 1, "documents": documents, "media": media})


def history(root, draft_path, warnings):
    """Only frozen plans with their matching completion manifests are candidates."""
    jobs = root / ".剪映切段任务"
    records = []
    if jobs.is_symlink() or not jobs.is_dir():
        return records
    for folder in sorted(jobs.iterdir(), reverse=True):
        if not folder.is_dir() or folder.is_symlink():
            continue
        try:
            files = [folder / n for n in ("job.json", "plan.json", "manifest.json")]
            if not all(p.is_file() and not p.is_symlink() for p in files):
                continue
            job, plan, manifest = [json.loads(p.read_text()) for p in files]
            if plan.get("draft_path") != draft_path:
                continue
            if (plan.get("output_root") != str(root) or job.get("plan_sha256") != sha(files[1])
                    or manifest.get("plan_sha256") != job.get("plan_sha256")):
                warnings.append("忽略校验不一致的历史任务：" + folder.name)
                continue
            for record in manifest.get("outputs", []):
                i = record.get("index")
                if not isinstance(i, int) or not 0 <= i < len(plan["segments"]):
                    continue
                old = plan["segments"][i]
                if (record.get("path") != str(Path(old["folder"]) / old["filename"])
                        or record.get("segment_id") != old["id"]
                        or record.get("start_us") != old["start_us"]
                        or record.get("requested_duration_us") != old["duration_us"]):
                    continue
                records.append((plan, old, record))
        except (OSError, ValueError, KeyError, TypeError):
            warnings.append("无法读取历史任务，未采用其导出记录：" + folder.name)
    return records


def apply_incremental(plan, enabled):
    root = Path(plan["output_root"])
    records = history(root, plan["draft_path"], plan["warnings"]) if enabled else []
    if records and all(not old.get("export_key") for _, old, _ in records):
        plan["warnings"].append("旧版历史任务没有素材指纹：本次将建立新版增量记录，旧视频保留。")
    for segment in plan["segments"]:
        segment["action"] = "new"
        segment["export_key"] = digest([plan["render_fingerprint"], segment["track_id"], segment["id"],
                                         segment["start_us"], segment["duration_us"]])
        if segment["status"] != "ready":
            continue
        for old_plan, old, record in records:
            if old["id"] != segment["id"] or old["track_id"] != segment["track_id"]:
                continue
            segment["action"] = "updated"
            # v1 records lack media fingerprints and must be rendered once in v2.
            same = old.get("export_key") == segment["export_key"]
            target = Path(record["path"])
            if (same and old["text"] == segment["text"] and str(target.parent) == segment["folder"]
                    and target.is_file() and not target.is_symlink() and target.parent.resolve() == target.parent
                    and record.get("sha256") == sha(target)):
                segment.update(action="skip", filename=target.name, reuse=record)
                break
        target = Path(segment["folder"]) / segment["filename"]
        if segment["action"] != "skip" and target.exists():
            # Preserve every old or unrelated file. No destructive replacement.
            stem = target.stem + "_更新_" + segment["export_key"][:8]
            candidate = target.with_name(stem + ".mp4")
            n = 2
            while candidate.exists() or candidate.is_symlink():
                candidate = target.with_name(stem + "_%d.mp4" % n)
                n += 1
            segment["filename"] = candidate.name
    plan["skip_count"] = sum(s["action"] == "skip" for s in plan["segments"])
    plan["export_count"] = sum(s["status"] == "ready" and s["action"] != "skip" for s in plan["segments"])
    plan["incremental"] = enabled
    # A changed set of labels need not send the same text-free picture to the
    # editor again. Reuse only a complete, hashed master from a verified job.
    if enabled and plan["export_count"]:
        for old_plan, old, record in records:
            if old_plan.get("render_fingerprint") != plan["render_fingerprint"]:
                continue
            # Find the job via its frozen plan (paths are deliberately not taken
            # from arbitrary media/output names).
            for job_dir in sorted((root / ".剪映切段任务").iterdir(), reverse=True):
                if job_dir.is_symlink() or not job_dir.is_dir():
                    continue
                try:
                    job = json.loads((job_dir / "job.json").read_text())
                    old_path = job_dir / "plan.json"
                    if old_path.is_symlink() or sha(old_path) != job.get("plan_sha256"):
                        continue
                    candidate = json.loads(old_path.read_text())
                    master = Path(job.get("master_path", ""))
                    if (candidate.get("draft_path") == plan["draft_path"]
                            and candidate.get("render_fingerprint") == plan["render_fingerprint"]
                            and candidate.get("duration_us") == plan["duration_us"]
                            and master.is_file() and not master.is_symlink() and master.resolve() == master
                            and job.get("master_sha256") == sha(master)
                            and all((job_dir / n).is_file() and not (job_dir / n).is_symlink()
                                    for n in ("prepared.json", "registration.json"))):
                        plan["reusable_master"] = {"path": str(master), "sha256": job["master_sha256"], "job_dir": str(job_dir)}
                        return
                except (OSError, ValueError, TypeError, KeyError):
                    continue
            break
