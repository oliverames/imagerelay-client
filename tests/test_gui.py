from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import bootstrap
from imagerelay_client.config import ConfigStore, Settings
from imagerelay_client.database import Database
from imagerelay_client.gui import (
    MenuStatusSnapshot,
    _primary_status_label,
    _status_symbol_name,
    load_menu_status,
)
from imagerelay_client.models import TrackedEntry
from imagerelay_client.progress import SyncActivityEntry, SyncProgressState, sync_progress_to_dict


class MenuStatusTests(unittest.TestCase):
    def test_status_symbol_name_prefers_filled_sd_card_when_running(self) -> None:
        idle = MenuStatusSnapshot(
            running=False,
            pid=None,
            missing_fields=[],
            local_root=Path("/tmp/example"),
            tracked_items=0,
            poll_interval_seconds=30,
            last_sync="Never",
            sync_upload=True,
            sync_download=True,
            sync_state="idle",
            sync_phase="Idle",
            completed_steps=0,
            total_steps=0,
            eta_seconds=None,
            current_item=None,
            last_error=None,
            last_remote_poll_at=None,
            next_remote_poll_at=None,
            paused=False,
            paused_until=None,
            recent_activity=[],
        )
        running = MenuStatusSnapshot(
            running=True,
            pid=123,
            missing_fields=[],
            local_root=Path("/tmp/example"),
            tracked_items=0,
            poll_interval_seconds=30,
            last_sync="Never",
            sync_upload=True,
            sync_download=True,
            sync_state="syncing",
            sync_phase="Pulling remote changes",
            completed_steps=1,
            total_steps=2,
            eta_seconds=4,
            current_item="RemoteOnly/hello.txt",
            last_error=None,
            last_remote_poll_at="2026-04-02T12:14:32+00:00",
            next_remote_poll_at="2026-04-02T12:15:00+00:00",
            paused=False,
            paused_until=None,
            recent_activity=[],
        )

        self.assertEqual(_status_symbol_name(idle), "xmark.circle")
        self.assertEqual(_status_symbol_name(running), "arrow.triangle.2.circlepath")

    def test_primary_status_label_prefers_pause_and_running_states(self) -> None:
        paused = MenuStatusSnapshot(
            running=True,
            pid=123,
            missing_fields=[],
            local_root=Path("/tmp/example"),
            tracked_items=0,
            poll_interval_seconds=30,
            last_sync="Never",
            sync_upload=True,
            sync_download=True,
            sync_state="paused",
            sync_phase="Syncing paused",
            completed_steps=0,
            total_steps=0,
            eta_seconds=None,
            current_item=None,
            last_error=None,
            last_remote_poll_at=None,
            next_remote_poll_at="2099-04-02T12:45:00+00:00",
            paused=True,
            paused_until="2099-04-02T12:45:00+00:00",
            recent_activity=[],
        )
        running = MenuStatusSnapshot(
            running=True,
            pid=123,
            missing_fields=[],
            local_root=Path("/tmp/example"),
            tracked_items=0,
            poll_interval_seconds=30,
            last_sync="Never",
            sync_upload=True,
            sync_download=True,
            sync_state="idle",
            sync_phase="Idle",
            completed_steps=0,
            total_steps=0,
            eta_seconds=None,
            current_item=None,
            last_error=None,
            last_remote_poll_at=None,
            next_remote_poll_at=None,
            paused=False,
            paused_until=None,
            recent_activity=[],
        )

        self.assertTrue(_primary_status_label(paused).startswith("Syncing Paused Until"))
        self.assertEqual(_primary_status_label(running), "Files Are Up to Date")

    def test_load_menu_status_reads_config_and_database(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            with patch.dict(os.environ, {"IMAGERELAY_CLIENT_HOME": str(home)}, clear=False):
                ConfigStore().save(
                    Settings(
                        api_key="secret",
                        local_root=str(home / "local-root"),
                        remote_root_folder_id=1,
                        default_file_type_id=7,
                        poll_interval_seconds=15,
                        sync_upload=False,
                        sync_download=True,
                    )
                )

                db = Database(home / "data" / "state.db")
                try:
                    db.upsert_entry(
                        TrackedEntry(
                            rel_path="Marketing",
                            item_type="folder",
                            remote_id=2,
                            remote_parent_id=1,
                            remote_updated_on="2026-04-02T12:00:00+00:00",
                            remote_size=None,
                            remote_file_type_id=None,
                            local_inode=100,
                            local_mtime=1.0,
                            local_size=0,
                        )
                    )
                    db.upsert_entry(
                        TrackedEntry(
                            rel_path="Marketing/hero.psd",
                            item_type="file",
                            remote_id=3,
                            remote_parent_id=2,
                            remote_updated_on="2026-04-02T12:00:00+00:00",
                            remote_size=1024,
                            remote_file_type_id=7,
                            local_inode=101,
                            local_mtime=2.0,
                            local_size=1024,
                        )
                    )
                    db.set_state("last_sync_at", "2026-04-02T12:15:00+00:00")
                    db.set_state_json(
                        "sync_pause",
                        {
                            "paused": True,
                            "until": "2099-04-02T12:45:00+00:00",
                            "updated_at": "2099-04-02T12:16:00+00:00",
                        },
                    )
                    db.set_state_json(
                        "sync_progress",
                        sync_progress_to_dict(
                            SyncProgressState(
                                state="syncing",
                                phase="Pushing local changes",
                                started_at="2026-04-02T12:14:30+00:00",
                                updated_at="2026-04-02T12:14:45+00:00",
                                completed_steps=2,
                                total_steps=5,
                                eta_seconds=18,
                                current_item="Marketing/hero.psd",
                                last_remote_poll_at="2026-04-02T12:14:32+00:00",
                                next_remote_poll_at="2026-04-02T12:15:00+00:00",
                                recent_activity=[
                                    SyncActivityEntry(
                                        action="Uploaded",
                                        rel_path="Marketing/hero.psd",
                                        when="2026-04-02T12:14:45+00:00",
                                    )
                                ],
                            )
                        ),
                    )
                finally:
                    db.close()

                snapshot = load_menu_status()

            self.assertFalse(snapshot.running)
            self.assertIsNone(snapshot.pid)
            self.assertEqual(snapshot.tracked_items, 2)
            self.assertEqual(snapshot.missing_fields, [])
            self.assertFalse(snapshot.sync_upload)
            self.assertTrue(snapshot.sync_download)
            self.assertEqual(snapshot.poll_interval_seconds, 15)
            self.assertEqual(snapshot.local_root, (home / "local-root").resolve())
            self.assertNotEqual(snapshot.last_sync, "Never")
            self.assertEqual(snapshot.sync_state, "paused")
            self.assertEqual(snapshot.sync_phase, "Syncing paused")
            self.assertEqual(snapshot.completed_steps, 2)
            self.assertEqual(snapshot.total_steps, 5)
            self.assertIsNone(snapshot.eta_seconds)
            self.assertIsNone(snapshot.current_item)
            self.assertEqual(snapshot.last_remote_poll_at, "2026-04-02T12:14:32+00:00")
            self.assertEqual(snapshot.next_remote_poll_at, "2099-04-02T12:45:00+00:00")
            self.assertTrue(snapshot.paused)
            self.assertEqual(snapshot.paused_until, "2099-04-02T12:45:00+00:00")
            self.assertEqual(snapshot.recent_activity[0].action, "Uploaded")


if __name__ == "__main__":
    unittest.main()
