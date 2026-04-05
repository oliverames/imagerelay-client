from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path

import bootstrap
from imagerelay_client.database import Database
from imagerelay_client.progress import SyncProgressTracker


class SyncProgressTrackerTests(unittest.TestCase):
    def test_tracker_records_progress_recent_activity_and_poll_schedule(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Database(Path(tmp) / "state.db")
            try:
                tracker = SyncProgressTracker(db)
                tracker.begin_sync("Scanning local state")
                tracker.extend_total(2)
                tracker.record_remote_poll()
                tracker.update_next_remote_poll(30)

                time.sleep(0.02)
                tracker.record_step("Downloaded", "RemoteOnly/hello.txt", phase="Pulling remote changes")
                mid_sync = tracker.load()
                self.assertEqual(mid_sync.state, "syncing")
                self.assertEqual(mid_sync.phase, "Pulling remote changes")
                self.assertEqual(mid_sync.completed_steps, 1)
                self.assertEqual(mid_sync.total_steps, 2)
                self.assertIsNotNone(mid_sync.eta_seconds)
                self.assertIsNotNone(mid_sync.last_remote_poll_at)
                self.assertIsNotNone(mid_sync.next_remote_poll_at)
                self.assertEqual(mid_sync.recent_activity[0].action, "Downloaded")

                tracker.finish("Waiting for the next remote pull")
                finished = tracker.load()
                self.assertEqual(finished.state, "idle")
                self.assertEqual(finished.phase, "Waiting for the next remote pull")
                self.assertIsNone(finished.eta_seconds)
                self.assertEqual(finished.completed_steps, 2)
            finally:
                db.close()

    def test_tracker_can_enter_paused_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Database(Path(tmp) / "state.db")
            try:
                tracker = SyncProgressTracker(db)
                tracker.begin_sync("Scanning local state")
                tracker.extend_total(3)
                tracker.record_step("Downloaded", "RemoteOnly/hello.txt", phase="Pulling remote changes")

                tracker.pause("Syncing paused")
                paused = tracker.load()

                self.assertEqual(paused.state, "paused")
                self.assertEqual(paused.phase, "Syncing paused")
                self.assertEqual(paused.completed_steps, 1)
                self.assertEqual(paused.total_steps, 3)
                self.assertIsNone(paused.eta_seconds)
                self.assertIsNone(paused.current_item)
            finally:
                db.close()


if __name__ == "__main__":
    unittest.main()
