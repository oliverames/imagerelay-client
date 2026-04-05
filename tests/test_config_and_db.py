from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import bootstrap
from imagerelay_client.config import ConfigStore, Settings
from imagerelay_client.database import Database
from imagerelay_client.models import TrackedEntry, is_same_or_descendant, normalize_rel_path


class ConfigStoreTests(unittest.TestCase):
    def test_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = ConfigStore(Path(tmp) / "config.json")
            settings = Settings(
                api_key="secret",
                local_root="~/Image Relay",
                remote_root_folder_id=123,
                default_file_type_id=456,
            )

            store.save(settings)
            loaded = store.load()

            self.assertEqual(loaded.api_key, "secret")
            self.assertEqual(loaded.remote_root_folder_id, 123)
            self.assertEqual(loaded.default_file_type_id, 456)

    def test_download_only_mode_does_not_require_upload_file_type(self) -> None:
        settings = Settings(
            api_key="secret",
            remote_root_folder_id=123,
            default_file_type_id=None,
            sync_download=True,
            sync_upload=False,
        )

        self.assertEqual(settings.missing_sync_fields(), [])

    def test_validation_errors_catch_invalid_numbers(self) -> None:
        settings = Settings(
            api_key="secret",
            remote_root_folder_id=0,
            default_file_type_id=0,
            poll_interval_seconds=0,
            request_timeout_seconds=0,
            upload_chunk_size=0,
            version_chunk_size=0,
        )

        errors = settings.validation_errors()

        self.assertIn("`poll_interval_seconds` must be 1 or greater.", errors)
        self.assertIn("`remote_root_folder_id` must be 1 or greater.", errors)
        self.assertIn("`default_file_type_id` must be 1 or greater.", errors)


class DatabaseTests(unittest.TestCase):
    def test_rename_prefix_updates_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Database(Path(tmp) / "state.db")
            db.upsert_entry(
                TrackedEntry(
                    rel_path="Designs",
                    item_type="folder",
                    remote_id=10,
                    remote_parent_id=1,
                    remote_updated_on=None,
                    remote_size=None,
                    remote_file_type_id=None,
                    local_inode=100,
                    local_mtime=1.0,
                    local_size=0,
                )
            )
            db.upsert_entry(
                TrackedEntry(
                    rel_path="Designs/logo.png",
                    item_type="file",
                    remote_id=11,
                    remote_parent_id=10,
                    remote_updated_on="2026-04-02T12:00:00+00:00",
                    remote_size=1024,
                    remote_file_type_id=5,
                    local_inode=101,
                    local_mtime=2.0,
                    local_size=1024,
                )
            )

            db.rename_prefix("Designs", "Brand/Designs")

            self.assertIsNone(db.get_entry("Designs"))
            self.assertIsNotNone(db.get_entry("Brand/Designs"))
            self.assertIsNotNone(db.get_entry("Brand/Designs/logo.png"))

    def test_delete_prefix_removes_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Database(Path(tmp) / "state.db")
            db.upsert_entry(
                TrackedEntry(
                    rel_path="Photos",
                    item_type="folder",
                    remote_id=20,
                    remote_parent_id=1,
                    remote_updated_on=None,
                    remote_size=None,
                    remote_file_type_id=None,
                    local_inode=200,
                    local_mtime=1.0,
                    local_size=0,
                )
            )
            db.upsert_entry(
                TrackedEntry(
                    rel_path="Photos/campaign.jpg",
                    item_type="file",
                    remote_id=21,
                    remote_parent_id=20,
                    remote_updated_on="2026-04-02T12:00:00+00:00",
                    remote_size=2048,
                    remote_file_type_id=5,
                    local_inode=201,
                    local_mtime=2.0,
                    local_size=2048,
                )
            )

            db.delete_prefix("Photos")
            self.assertEqual(db.list_entries(), [])


class PathHelperTests(unittest.TestCase):
    def test_normalize_rel_path(self) -> None:
        self.assertEqual(normalize_rel_path("./Brand//Logos"), "Brand/Logos")

    def test_descendant_match(self) -> None:
        self.assertTrue(is_same_or_descendant("Brand/Logos", "Brand"))
        self.assertFalse(is_same_or_descendant("Branding", "Brand"))


if __name__ == "__main__":
    unittest.main()
