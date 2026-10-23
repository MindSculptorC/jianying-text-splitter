import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import core
import iteration
import workflow
import test_workflow


class IterationTests(unittest.TestCase):
    setUp = test_workflow.WorkflowTests.setUp
    fake_media = test_workflow.WorkflowTests.fake_media
    master = test_workflow.WorkflowTests.master

    def prepare(self, options=None):
        return workflow.prepare(self.source, self.output, expected_sha=workflow._sha(self.draft_file), options=options)

    def edit(self, mutate):
        data = json.loads(self.draft_file.read_text())
        mutate(data)
        self.draft_file.write_text(json.dumps(data))

    def complete(self):
        job = self.prepare()
        self.master(job)
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            result = workflow.split(job["job_path"])
        return job, result

    def test_cross_job_noop_does_not_close_or_render(self):
        self.complete()
        with patch.object(workflow, "_assert_editor_closed", side_effect=AssertionError("must not close")):
            result = self.prepare()
        self.assertEqual(result["status"], "up_to_date")
        self.assertEqual(result["skipped_count"], 2)
        self.assertEqual(len(self.cut_calls), 2)

    def test_insert_label_reuses_master_and_existing_clips_despite_number_change(self):
        _, first = self.complete()
        old_bytes = {x["path"]: Path(x["path"]).read_bytes() for x in first["outputs"]}
        def insert(d):
            d["materials"]["texts"].append({"id": "c", "content": '{"text":"分类A"}'})
            d["materials"]["material_animations"] = [{"id": "new-animation", "type": "animation"}]
            d["tracks"][0]["segments"].append({"id": "insert", "material_id": "c", "extra_material_refs": ["new-animation"],
                                               "target_timerange": {"start": 500000, "duration": 250000}})
        self.edit(insert)
        with patch.object(workflow, "_assert_editor_closed", side_effect=AssertionError("must reuse")):
            second = self.prepare()
        self.assertTrue(second["reused_master"])
        self.assertEqual(second["plan"]["skip_count"], 2)
        self.assertEqual(second["plan"]["export_count"], 1)
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            done = workflow.split(second["job_path"])
        self.assertEqual(done["completed_count"], 3)
        self.assertEqual(len(self.cut_calls), 3)
        for p, content in old_bytes.items():
            self.assertEqual(Path(p).read_bytes(), content)

    def test_changed_range_creates_version_and_preserves_other_clip(self):
        _, first = self.complete()
        old = first["outputs"][0]["path"]
        self.edit(lambda d: d["tracks"][0]["segments"][0]["target_timerange"].update(duration=500000))
        next_job = self.prepare()
        self.assertEqual(next_job["plan"]["skip_count"], 1)
        self.assertNotEqual(next_job["plan"]["segments"][0]["filename"], Path(old).name)
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            done = workflow.split(next_job["job_path"])
        self.assertTrue(Path(old).is_file())
        self.assertEqual(done["exported_count"], 1)

    def test_nontext_change_invalidates_every_clip(self):
        self.complete()
        self.edit(lambda d: d.update(color_space=2))
        p = core.make_plan(self.source, self.output)
        self.assertEqual(p["skip_count"], 0)
        self.assertNotIn("reusable_master", p)

    def test_same_path_media_replacement_invalidates_hash(self):
        media = self.base / "source.mp4"
        media.write_bytes(b"before")
        self.edit(lambda d: d["materials"].update(videos=[{"id": "v", "path": str(media)}]))
        self.complete()
        media.write_bytes(b"after!")
        self.assertEqual(core.make_plan(self.source, self.output)["skip_count"], 0)

    def test_changed_or_missing_output_regenerates_only_that_clip(self):
        _, first = self.complete()
        Path(first["outputs"][0]["path"]).write_bytes(b"user changed")
        plan = core.make_plan(self.source, self.output)
        self.assertEqual(plan["skip_count"], 1)
        self.assertNotEqual(plan["segments"][0]["filename"], Path(first["outputs"][0]["path"]).name)

    def test_reused_file_changed_after_prepare_blocks(self):
        _, first = self.complete()
        self.edit(lambda d: d["tracks"][0]["segments"][1]["target_timerange"].update(duration=500000))
        prepared = self.prepare()
        Path(first["outputs"][0]["path"]).write_bytes(b"changed later")
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            with self.assertRaises(workflow.WorkflowError) as caught:
                workflow.split(prepared["job_path"])
        self.assertEqual(caught.exception.code, "completed_file_changed")

    def test_incremental_off_produces_new_files(self):
        _, first = self.complete()
        plan = core.make_plan(self.source, self.output, options={"incremental": False})
        self.assertEqual(plan["skip_count"], 0)
        self.assertNotIn("reusable_master", plan)
        self.assertTrue(all(s["filename"] != Path(r["path"]).name for s, r in zip(plan["segments"], first["outputs"])))

    def test_external_per_segment_directory_and_direct_empty_root(self):
        outside = self.base / "任意外部目录"
        outside.mkdir()
        plan = core.make_plan(self.source, self.output)
        options = {"folder_overrides": {plan["segments"][0]["key"]: str(outside)}}
        prepared = self.prepare(options)
        self.master(prepared)
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            done = workflow.split(prepared["job_path"])
        self.assertEqual(Path(done["outputs"][0]["path"]).parent, outside)
        self.assertEqual(core.make_plan(self.source, self.output, options=options)["skip_count"], 2)
        direct = core.make_plan(self.source, outside, options={"output_mode": "direct"})
        self.assertTrue(direct["can_export"])
        self.assertTrue(all(s["folder"] == str(outside) for s in direct["segments"]))

    def test_manual_symlink_rejected_and_clear_override_restores_match(self):
        link = self.base / "link"
        link.symlink_to(self.output / "分类A", target_is_directory=True)
        key = core.make_plan(self.source, self.output)["segments"][0]["key"]
        plan = core.make_plan(self.source, self.output, options={"folder_overrides": {key: str(link)}})
        self.assertEqual(plan["segments"][0]["status"], "invalid_folder")
        self.assertEqual(core.make_plan(self.source, self.output)["segments"][0]["matched_by"], "exact")

    def test_synonym_mode_exact_priority_and_ambiguity(self):
        def labels(d):
            d["materials"]["texts"][0]["content"] = '{"text":"参考文献"}'
        self.edit(labels)
        (self.output / "文献资料").mkdir()
        self.assertEqual(core.make_plan(self.source, self.output)["segments"][0]["status"], "missing_folder")
        fuzzy = core.make_plan(self.source, self.output, options={"match_mode": "fuzzy"})
        self.assertEqual(fuzzy["segments"][0]["matched_by"], "fuzzy")
        (self.output / "论文资料").mkdir()
        self.assertEqual(core.make_plan(self.source, self.output, options={"match_mode": "fuzzy"})["segments"][0]["status"], "ambiguous_folder")
        (self.output / "参考文献").mkdir()
        self.assertEqual(core.make_plan(self.source, self.output, options={"match_mode": "fuzzy"})["segments"][0]["matched_by"], "exact")

    def test_fuzzy_unrelated_and_near_names(self):
        candidates, unique = iteration.fuzzy_matches("完全无关", {"折线图": ["/a"]})
        self.assertFalse(unique)
        candidates, unique = iteration.fuzzy_matches("财务趋势图", {"财务走势图": ["/b"]})
        self.assertTrue(unique)

    def test_deleted_label_does_not_delete_output(self):
        _, first = self.complete()
        self.edit(lambda d: d["tracks"][0]["segments"].pop())
        self.assertEqual(self.prepare()["status"], "up_to_date")
        self.assertTrue(all(Path(x["path"]).is_file() for x in first["outputs"]))

    def test_damaged_plan_history_is_ignored(self):
        job, first = self.complete()
        path = Path(job["job_dir"]) / "plan.json"
        path.write_text(path.read_text() + " ")
        plan = core.make_plan(self.source, self.output)
        self.assertEqual(plan["skip_count"], 0)
        self.assertTrue(any("校验不一致" in w for w in plan["warnings"]))
