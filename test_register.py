import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import register


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="jianying-registration-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "原草稿"
        self.source.mkdir()
        self.destination = self.root / "无文本副本"
        self.destination.mkdir()
        (self.destination / "draft_info.json").write_text('{"id":"copy-id","tracks":[]}', encoding="utf-8")
        self.original_entry = {"draft_id": "source-id", "draft_name": "原草稿",
                               "draft_fold_path": str(self.source), "tm_duration": 1000000,
                               "tm_draft_cloud_user_id": 99, "draft_cloud_template_id": "source-cloud",
                               "future_field": {"preserve": [1, 2, 3]}}
        self.index = self.root / "root_meta_info.json"
        self.original = {"all_draft_store": [self.original_entry], "draft_ids": 1,
                         "root_path": str(self.root), "future_root_field": {"keep": True}}
        self.index.write_text(json.dumps(self.original, ensure_ascii=False), encoding="utf-8")
        self.prepared = {"draft_path": str(self.destination), "draft_name": "无文本副本",
                         "draft_id": "copy-id", "duration_us": 1000000,
                         "source_draft_path": str(self.source)}

    def read(self):
        return json.loads(self.index.read_text(encoding="utf-8"))

    def test_register_backs_up_and_preserves_source(self):
        original_bytes = self.index.read_bytes()
        receipt = register.register_draft(self.root, self.prepared)
        current = self.read()
        self.assertEqual(current["all_draft_store"][1], self.original_entry)
        self.assertEqual(current["future_root_field"], self.original["future_root_field"])
        self.assertEqual(current["draft_ids"], 2)
        self.assertEqual(current["all_draft_store"][0]["tm_draft_cloud_user_id"], -1)
        self.assertEqual(Path(receipt["backup_path"]).read_bytes(), original_bytes)
        self.assertTrue(Path(receipt["receipt_path"]).is_file())

    def test_duplicate_is_refused_without_changes(self):
        register.register_draft(self.root, self.prepared)
        before = self.index.read_bytes()
        with self.assertRaises(register.RegistrationError):
            register.register_draft(self.root, self.prepared)
        self.assertEqual(before, self.index.read_bytes())

    def test_undo_preserves_newer_drafts_and_other_edits(self):
        receipt = register.register_draft(self.root, self.prepared)
        latest = self.read()
        other = {"draft_id": "later-id", "draft_name": "后建草稿", "draft_fold_path": str(self.root / "later")}
        latest["all_draft_store"].append(other)
        latest["all_draft_store"][1]["draft_name"] = "原草稿后来改名"
        latest["future_root_field"] = {"newer": True}
        latest["draft_ids"] = 3
        self.index.write_text(json.dumps(latest), encoding="utf-8")
        result = register.undo_registration(receipt["receipt_path"])
        current = self.read()
        self.assertEqual(result["status"], "removed_registration")
        self.assertEqual(current["all_draft_store"], latest["all_draft_store"][1:])
        self.assertEqual(current["future_root_field"], {"newer": True})
        self.assertEqual(current["draft_ids"], 2)
        self.assertTrue(self.destination.exists())
        self.assertEqual(register.undo_registration(receipt)["status"], "already_absent")

    def test_undo_refuses_modified_registered_entry(self):
        receipt = register.register_draft(self.root, self.prepared)
        current = self.read()
        current["all_draft_store"][0]["draft_name"] = "用户修改了副本"
        self.index.write_text(json.dumps(current), encoding="utf-8")
        before = self.index.read_bytes()
        with self.assertRaises(register.ConcurrentIndexChange):
            register.undo_registration(receipt)
        self.assertEqual(before, self.index.read_bytes())

    def test_concurrent_editor_write_is_preserved(self):
        original_new_file = register._new_file
        latest = dict(self.original, editor_changed=True)
        count = 0

        def racing_new_file(path, content):
            nonlocal count
            original_new_file(path, content)
            count += 1
            if count == 2:
                self.index.write_text(json.dumps(latest), encoding="utf-8")

        with patch.object(register, "_new_file", side_effect=racing_new_file):
            with self.assertRaises(register.ConcurrentIndexChange):
                register.register_draft(self.root, self.prepared)
        self.assertEqual(self.read(), latest)

    def test_outside_root_and_index_symlink_rejected(self):
        with tempfile.TemporaryDirectory(prefix="jianying-outside-") as outside:
            bad = dict(self.prepared, draft_path=outside)
            with self.assertRaises(register.RegistrationError):
                register.register_draft(self.root, bad)
        original = self.index.read_bytes()
        other = self.root / "other-index.json"
        other.write_bytes(original)
        self.index.unlink()
        self.index.symlink_to(other)
        with self.assertRaises(register.RegistrationError):
            register.register_draft(self.root, self.prepared)
        self.assertEqual(other.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
