import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import core


def sample(labels=("产品A", "产品A", "产品B")):
    texts, segments = [], []
    for i, label in enumerate(labels):
        texts.append({"id": "text-%s" % i, "type": "text", "content": json.dumps({"text": label, "styles": []})})
        segments.append({"id": "segment-%s" % i, "material_id": "text-%s" % i,
                         "target_timerange": {"start": i * 2000000, "duration": 1500000}})
    return {"id": "timeline-old", "duration": 10000000,
            "tracks": [{"id": "video-track", "type": "video", "segments": [{"id": "video-segment", "material_id": "video", "target_timerange": {"duration": 10000000}}]},
                       {"id": "labels", "type": "text", "segments": segments}],
            "materials": {"texts": texts, "videos": [{"id": "video", "type": "video", "path": "/tmp/source.mp4"}]}}


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.draft = self.root / "原草稿"
        self.draft.mkdir()
        self.output = self.root / "输出"
        self.output.mkdir()
        for name in ("产品A", "产品B"):
            (self.output / name).mkdir()
        self.data = sample()
        self.write(self.data)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, data, relative="draft_info.json"):
        path = self.draft / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    def test_full_text_exact_matching_and_self_timing(self):
        plan = core.make_plan(self.draft, self.output)
        self.assertTrue(plan["can_export"])
        self.assertEqual([s["start_us"] for s in plan["segments"]], [0, 2000000, 4000000])
        self.assertEqual([s["end_us"] for s in plan["segments"]], [1500000, 3500000, 5500000])
        self.assertEqual(len({s["filename"] for s in plan["segments"]}), 3)
        self.assertEqual(plan["segments"][0]["folder"], str(self.output / "产品A"))

    def test_sparse_zero_start_and_unicode_nfc(self):
        data = sample(("  Café  ",))
        del data["tracks"][1]["segments"][0]["target_timerange"]["start"]
        self.write(data)
        (self.output / "Cafe\u0301").mkdir()
        plan = core.make_plan(self.draft, self.output)
        self.assertTrue(plan["can_export"])
        self.assertEqual(plan["segments"][0]["text"], "Café")
        self.assertEqual(plan["segments"][0]["start_us"], 0)

    def test_missing_ambiguous_and_path_traversal_block(self):
        self.write(sample(("不存在", "产品A", "../产品B", "产品B\n产品A")))
        (self.output / "嵌套" / "产品A").mkdir(parents=True)
        plan = core.make_plan(self.draft, self.output)
        self.assertEqual([s["status"] for s in plan["segments"]], ["missing_folder", "ambiguous_folder", "invalid_text", "invalid_text"])
        self.assertFalse(plan["can_export"])
        self.assertFalse((self.output / "不存在").exists())

    def test_symlink_cannot_escape_output(self):
        self.write(sample(("外部",)))
        outside = self.root / "外部"
        outside.mkdir()
        (self.output / "外部").symlink_to(outside, target_is_directory=True)
        plan = core.make_plan(self.draft, self.output)
        self.assertEqual(plan["segments"][0]["status"], "missing_folder")
        self.assertTrue(plan["warnings"])

    def test_explicit_alias_and_exact_match_are_distinguished(self):
        self.write(sample(("关键字", "产品A")))
        (self.output / "数据文本" / "关键词").mkdir(parents=True)
        plan = core.make_plan(self.draft, self.output, aliases={"关键字": "数据文本/关键词"})
        self.assertTrue(plan["can_export"])
        self.assertEqual([s["matched_by"] for s in plan["segments"]], ["alias", "exact"])
        self.assertEqual(plan["segments"][0]["text"], "关键字")
        self.assertEqual(plan["segments"][0]["folder"], str(self.output / "数据文本/关键词"))

    def test_invalid_aliases_cannot_escape_or_create_folders(self):
        self.write(sample(("关键字",)))
        (self.output / "链接").symlink_to(self.output / "产品A", target_is_directory=True)
        for alias in ("../原草稿", "不存在", str(self.output / "产品A"), "链接", ""):
            plan = core.make_plan(self.draft, self.output, aliases={"关键字": alias})
            self.assertFalse(plan["can_export"])
            self.assertEqual(plan["segments"][0]["status"], "invalid_alias")
        self.assertFalse((self.output / "不存在").exists())

    def test_stale_plan_rejected_before_prepare(self):
        plan = core.make_plan(self.draft, self.output)
        self.data["duration"] += 1
        self.write(self.data)
        destination = self.root / "副本"
        with self.assertRaises(core.DraftError):
            core.prepare_draft(self.draft, destination, expected_fingerprint=plan["source_fingerprint"])
        self.assertFalse(destination.exists())

    def test_invalid_range_and_existing_output_block(self):
        data = sample(("产品A", "产品B"))
        data["tracks"][1]["segments"][1]["target_timerange"] = {"start": 9999999, "duration": 100}
        self.write(data)
        plan = core.make_plan(self.draft, self.output)
        first = plan["segments"][0]
        (Path(first["folder"]) / first["filename"]).write_bytes(b"existing")
        plan = core.make_plan(self.draft, self.output)
        self.assertEqual([s["status"] for s in plan["segments"]], ["ready", "invalid_range"])
        self.assertNotEqual(plan["segments"][0]["filename"], first["filename"])
        self.assertEqual((Path(first["folder"]) / first["filename"]).read_bytes(), b"existing")

    def test_track_selection_and_missing_material(self):
        data = sample()
        second = copy.deepcopy(data["tracks"][1])
        second["id"] = "second-labels"
        second["segments"] = second["segments"][:1]
        data["tracks"].append(second)
        self.write(data)
        self.assertEqual(len(core.make_plan(self.draft, self.output, ["second-labels"])["segments"]), 1)
        with self.assertRaises(core.DraftError):
            core.make_plan(self.draft, self.output, ["deleted"])
        data["tracks"][1]["segments"][0]["material_id"] = "missing"
        self.write(data)
        self.assertEqual(core.make_plan(self.draft, self.output)["segments"][0]["status"], "invalid_text")

    def test_prepare_preserves_source_and_media_updates_every_timeline(self):
        self.write(self.data, "Timelines/timeline-old/draft_info.json")
        self.write({"id": "project-old", "main_timeline_id": "timeline-old", "timelines": [{"id": "timeline-old"}]}, "Timelines/project.json")
        self.write({"draft_id": "draft-old", "draft_name": "原草稿", "cloud_draft_sync": True, "tm_draft_cloud_entry_id": 111}, "draft_meta_info.json")
        self.write(self.data, ".backup/draft_info.json")
        (self.draft / "draft_info.json.bak").write_text("old text")
        (self.draft / "draft_cover.jpg").write_bytes(b"old text in image")
        before = {str(p.relative_to(self.draft)): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.draft.rglob("*") if p.is_file()}
        destination = self.root / "新副本"
        result = core.prepare_draft(self.draft, destination)
        after = {str(p.relative_to(self.draft)): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.draft.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(result["removed_text_count"], 3)
        main = json.loads((destination / "draft_info.json").read_text())
        self.assertEqual(main["tracks"], self.data["tracks"][:1])
        self.assertEqual(main["materials"]["videos"], self.data["materials"]["videos"])
        self.assertEqual(main["materials"]["texts"], [])
        self.assertNotEqual(main["id"], "timeline-old")
        timeline = json.loads((destination / "Timelines" / main["id"] / "draft_info.json").read_text())
        self.assertEqual(main, timeline)
        project = json.loads((destination / "Timelines/project.json").read_text())
        self.assertEqual(project["main_timeline_id"], main["id"])
        meta = json.loads((destination / "draft_meta_info.json").read_text())
        self.assertEqual(meta["draft_name"], "新副本")
        self.assertEqual(meta["draft_id"], result["draft_id"])
        self.assertFalse(meta["cloud_draft_sync"])
        self.assertEqual(meta["tm_draft_cloud_entry_id"], -1)
        self.assertFalse((destination / ".backup").exists())
        self.assertFalse((destination / "draft_info.json.bak").exists())
        self.assertFalse((destination / "draft_cover.jpg").exists())
        self.assertFalse((destination / "root_meta_info.json").exists())

    def test_prepare_embedded_compound_and_relative_assets(self):
        data = sample()
        nested = sample(("复合片段里的文字",))
        data["materials"]["drafts"] = [{"id": "compound", "draft": nested}]
        media = self.draft / "source.mp4"
        media.write_bytes(b"test source")
        data["materials"]["videos"][0]["path"] = "source.mp4"
        self.write(data)
        destination = self.root / "副本"
        core.prepare_draft(self.draft, destination)
        clean = json.loads((destination / "draft_info.json").read_text())
        self.assertEqual(clean["materials"]["drafts"][0]["draft"]["materials"]["texts"], [])
        self.assertEqual(clean["materials"]["videos"][0]["path"], str(media))
        self.assertFalse((destination / "source.mp4").exists())

    def test_prepare_unknown_text_fails_without_partial_output(self):
        self.data["tracks"][1]["type"] = "fancy_text_unknown"
        self.write(self.data)
        destination = self.root / "副本"
        with self.assertRaises(core.DraftError):
            core.prepare_draft(self.draft, destination)
        self.assertFalse(destination.exists())

    def test_prepare_unknown_and_external_compound_fail_safe(self):
        for material in ({"id": "unknown"}, {"id": "outside", "draft_path": "/tmp/another-project/draft_info.json"}):
            data = sample()
            data["materials"]["drafts"] = [material]
            self.write(data)
            destination = self.root / "副本"
            with self.assertRaises(core.DraftError):
                core.prepare_draft(self.draft, destination)
            self.assertFalse(destination.exists())

    def test_prepare_internal_compound_path_retargets_clean_copy(self):
        data = sample()
        data["materials"]["drafts"] = [{"id": "nested", "draft_path": "nested/draft_info.json"}]
        self.write(data)
        self.write(sample(("产品A",)), "nested/draft_info.json")
        destination = self.root / "副本"
        core.prepare_draft(self.draft, destination)
        clean = json.loads((destination / "draft_info.json").read_text())
        self.assertEqual(clean["materials"]["drafts"][0]["draft_path"], str(destination / "nested/draft_info.json"))
        self.assertEqual(json.loads((destination / "nested/draft_info.json").read_text())["materials"]["texts"], [])

    def test_prepare_refuses_overwrite_and_overlap(self):
        for destination in (self.draft, self.draft / "child", self.root):
            with self.assertRaises(core.DraftError):
                core.prepare_draft(self.draft, destination)

    def test_verify_clean_read_only_and_finds_child_text(self):
        destination = self.root / "副本"
        core.prepare_draft(self.draft, destination)
        main_path = destination / "draft_info.json"
        before = main_path.read_bytes()
        result = core.verify_clean(destination)
        self.assertTrue(result["clean"])
        self.assertEqual(result["duration_us"], self.data["duration"])
        self.assertEqual(main_path.read_bytes(), before)
        child = destination / "Timelines/child/draft_info.json"
        child.parent.mkdir(parents=True)
        child.write_text(json.dumps(sample(("残留",))))
        with self.assertRaises(core.DraftError):
            core.verify_clean(destination)

    def test_verify_clean_rejects_orphan_text_and_empty_text_tracks(self):
        for kind in ("material", "empty_track", "embedded"):
            data = sample()
            data["tracks"] = data["tracks"][:1]
            data["materials"]["texts"] = []
            if kind == "material":
                data["materials"]["texts"] = [{"id": "orphan", "content": '{"text":"文字"}'}]
            elif kind == "empty_track":
                data["tracks"].append({"id": "empty", "type": "text", "segments": []})
            else:
                data["materials"]["drafts"] = [{"id": "embedded", "draft_json": json.dumps(sample(("嵌套文字",)))}]
            self.write(data)
            with self.assertRaises(core.DraftError):
                core.verify_clean(self.draft)

    def test_cli_emits_one_json_document_on_error(self):
        run = subprocess.run([sys.executable, str(Path(core.__file__)), "plan", "--draft", str(self.root / "none"), "--output", str(self.output)], capture_output=True, text=True)
        self.assertEqual(run.returncode, 2)
        self.assertEqual(json.loads(run.stdout)["code"], "draft_not_found")


if __name__ == "__main__":
    unittest.main()
