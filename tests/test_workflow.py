import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import core
import workflow


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="jianying-workflow-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.projects = self.base / "projects"
        self.projects.mkdir()
        self.source = self.projects / "测试源草稿"
        self.source.mkdir()
        self.output = self.base / "output"
        self.output.mkdir()
        for name in ("分类A", "分类B"):
            (self.output / name).mkdir()
        timeline = {"id": "timeline-id", "duration": 2000000, "tracks": [
            {"id": "text-track", "type": "text", "segments": [
                {"id": "seg-a", "material_id": "a", "target_timerange": {"start": 0, "duration": 1000000}},
                {"id": "seg-b", "material_id": "b", "target_timerange": {"start": 1000000, "duration": 1000000}}]}],
                    "materials": {"texts": [{"id": "a", "content": json.dumps({"text": "分类A"})},
                                               {"id": "b", "content": json.dumps({"text": "分类B"})}]}}
        self.draft_file = self.source / "draft_info.json"
        self.draft_file.write_text(json.dumps(timeline), encoding="utf-8")
        (self.source / "draft_meta_info.json").write_text('{"draft_id":"source-id"}', encoding="utf-8")
        self.index = self.projects / "root_meta_info.json"
        self.index.write_text(json.dumps({"all_draft_store": [{"draft_id": "source-id", "draft_fold_path": str(self.source)}],
                                          "draft_ids": 1, "root_path": str(self.projects)}), encoding="utf-8")
        self.sha = workflow._sha(self.draft_file)
        self.editor = patch.object(workflow, "_assert_editor_closed")
        self.editor.start()
        self.addCleanup(self.editor.stop)
        self.cut_calls = []

    def prepare(self):
        return workflow.prepare(self.source, self.output, expected_sha=self.sha)

    def fake_media(self, *args, **kwargs):
        info = {"duration_us": 2000000, "width": 640, "height": 360, "fps": 30, "has_audio": True}
        if args[0] == "cut":
            self.cut_calls.append(str(args[2]))
            with Path(args[2]).open("xb") as handle:
                handle.write(("frame-data:" + str(args[3])).encode())
            info["duration_us"] = int(args[4])
        return info

    def master(self, prepared):
        Path(prepared["master_path"]).write_bytes(b"fake-master-unchanging")

    def test_prepare_registers_copy_and_freezes_plan(self):
        result = self.prepare()
        self.assertTrue(result["ok"])
        self.assertEqual(workflow._sha(self.draft_file), self.sha)
        job = workflow._load(result["job_path"])
        self.assertEqual(job["status"], "awaiting_master")
        self.assertEqual(job["plan_sha256"], workflow._sha(job["plan_path"]))
        self.assertEqual(len(workflow._load(self.index)["all_draft_store"]), 2)
        self.assertEqual(core.read_json(Path(result["prepared"]["draft_path"]) / "draft_info.json")["tracks"], [])

    def test_changed_preview_and_running_editor_refused(self):
        with self.assertRaises(workflow.WorkflowError) as error:
            workflow.prepare(self.source, self.output, expected_sha="old-sha")
        self.assertEqual(error.exception.code, "draft_changed")
        with self.assertRaises(workflow.WorkflowError):
            workflow.prepare(self.source, self.output, expected_sha=self.sha, expected_fingerprint="old-fingerprint")
        with patch.object(workflow, "_assert_editor_closed", side_effect=workflow.WorkflowError("running", "editor_running")):
            with self.assertRaises(workflow.WorkflowError):
                self.prepare()
        self.assertEqual(len(workflow._load(self.index)["all_draft_store"]), 1)

    def test_complete_and_resume_skip_only_verified_records(self):
        prepared = self.prepare()
        self.master(prepared)
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            result = workflow.split(prepared["job_path"])
            again = workflow.split(prepared["job_path"])
        self.assertEqual(result["completed_count"], 2)
        self.assertEqual(len(self.cut_calls), 2)
        self.assertEqual(again["completed_count"], 2)
        self.assertEqual(again["exported_count"], 0)
        self.assertEqual(again["skipped_count"], 2)
        Path(result["outputs"][0]["path"]).write_bytes(b"changed")
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            with self.assertRaises(workflow.WorkflowError) as error:
                workflow.split(prepared["job_path"])
        self.assertEqual(error.exception.code, "completed_file_changed")

    def test_interruption_resumes_only_remaining_segment(self):
        prepared = self.prepare()
        self.master(prepared)
        def interrupted(*args, **kwargs):
            if args[0] == "cut" and len(self.cut_calls) == 1:
                raise workflow.WorkflowError("interrupted", "media_failed")
            return self.fake_media(*args, **kwargs)
        with patch.object(workflow, "_media", side_effect=interrupted):
            with self.assertRaises(workflow.WorkflowError):
                workflow.split(prepared["job_path"])
        self.assertEqual(workflow._load(prepared["job_path"])["completed_count"], 1)
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            done = workflow.split(prepared["job_path"])
        self.assertEqual(done["completed_count"], 2)
        self.assertEqual(len(self.cut_calls), 2)

    def test_duration_mismatch_blocks_all_exports(self):
        prepared = self.prepare()
        self.master(prepared)
        with patch.object(workflow, "_media", return_value={"duration_us": 1000000, "fps": 30}):
            with self.assertRaises(workflow.WorkflowError) as error:
                workflow.split(prepared["job_path"])
        self.assertEqual(error.exception.code, "master_duration_mismatch")
        self.assertFalse(list((self.output / "分类A").iterdir()))

    def test_conflict_and_symlink_blocked(self):
        prepared = self.prepare()
        self.master(prepared)
        segment = prepared["plan"]["segments"][0]
        conflict = Path(segment["folder"]) / segment["filename"]
        conflict.write_bytes(b"keep me")
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            with self.assertRaises(workflow.WorkflowError) as error:
                workflow.split(prepared["job_path"])
        self.assertEqual(error.exception.code, "output_exists")
        self.assertEqual(conflict.read_bytes(), b"keep me")
        conflict.unlink()
        folder = Path(segment["folder"])
        folder.rmdir()
        elsewhere = self.base / "elsewhere"
        elsewhere.mkdir()
        folder.symlink_to(elsewhere, target_is_directory=True)
        with self.assertRaises(workflow.WorkflowError) as error:
            workflow.split(prepared["job_path"])
        self.assertEqual(error.exception.code, "unsafe_path")

    def test_modified_plan_and_master_refused(self):
        prepared = self.prepare()
        self.master(prepared)
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            workflow.split(prepared["job_path"])
        Path(prepared["master_path"]).write_bytes(b"different master")
        with patch.object(workflow, "_media", side_effect=self.fake_media):
            with self.assertRaises(workflow.WorkflowError) as error:
                workflow.split(prepared["job_path"])
        self.assertEqual(error.exception.code, "master_changed")
        plan_path = Path(prepared["job_dir"]) / "plan.json"
        plan_path.write_text("{}", encoding="utf-8")
        with self.assertRaises(workflow.WorkflowError) as error:
            workflow.split(prepared["job_path"])
        self.assertEqual(error.exception.code, "plan_changed")

    def test_prepare_failure_keeps_recovery_report(self):
        with patch.object(register := workflow.register, "register_draft", side_effect=RuntimeError("test register failure")):
            with self.assertRaises(workflow.WorkflowError) as error:
                self.prepare()
        self.assertTrue(Path(error.exception.context["recovery_path"]).is_file())
        self.assertEqual(workflow._load(error.exception.context["job_path"])["status"], "prepare_failed")
        self.assertEqual(workflow._sha(self.draft_file), self.sha)


if __name__ == "__main__":
    unittest.main()
