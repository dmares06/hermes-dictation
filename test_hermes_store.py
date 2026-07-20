#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

from hermes_store import LocalStore


class LocalStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = LocalStore(Path(self.temp_dir.name) / "hermes.db")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_transcripts_and_stats(self):
        transcript_id = self.store.add_transcript(
            "Hello local history.", raw_text="hello local history", duration_seconds=6
        )
        self.assertIsInstance(transcript_id, int)
        rows = self.store.list_transcripts()
        self.assertEqual(rows[0]["text"], "Hello local history.")
        self.assertEqual(rows[0]["word_count"], 3)
        self.assertEqual(self.store.stats()["total"]["words"], 3)

    def test_snippet_upsert_and_case_insensitive_resolution(self):
        self.store.save_snippet("my LinkedIn", "https://linkedin.com/in/example", "open")
        result = self.store.resolve_snippet("My linkedin.")
        self.assertEqual(result["action"], "open")
        self.assertEqual(result["value"], "https://linkedin.com/in/example")

    def test_notes_can_be_updated(self):
        note_id = self.store.save_note("Ideas", "First thought")
        self.store.save_note("Ideas", "Second thought", note_id)
        note = self.store.list_notes()[0]
        self.assertEqual(note["id"], note_id)
        self.assertEqual(note["body"], "Second thought")


if __name__ == "__main__":
    unittest.main()
