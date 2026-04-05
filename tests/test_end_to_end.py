from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Callable

import bootstrap
from imagerelay_client.database import Database
from imagerelay_client.progress import sync_progress_from_dict
from mock_imagerelay import MockImageRelayServer, MockImageRelayState


class SyncIntegrationTests(unittest.TestCase):
    def run_cli(
        self,
        env: dict[str, str],
        *args: str,
        check: bool = True,
        timeout: float = 30.0,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, "-m", "imagerelay_client", *args],
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        if check and result.returncode != 0:
            raise RuntimeError(
                f"Command failed: {' '.join(args)}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        return result

    def wait_for(
        self,
        predicate: Callable[[], bool],
        description: str,
        *,
        timeout: float = 15.0,
        interval: float = 0.2,
    ) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(interval)
        raise RuntimeError(f"Timed out while waiting for {description}.")

    def init_client(
        self,
        env: dict[str, str],
        server: MockImageRelayServer,
        local_root: Path,
        *,
        api_key: str = "test-key",
    ) -> None:
        self.run_cli(
            env,
            "init",
            "--api-key",
            api_key,
            "--api-base-url",
            server.api_base_url,
            "--local-root",
            str(local_root),
            "--remote-root-folder-id",
            "1",
            "--default-file-type-id",
            "7",
            "--user-agent",
            "ImageRelay Client Test (tests@example.com)",
            "--poll-interval-seconds",
            "1",
        )

    def file_content(self, state: MockImageRelayState, rel_path: str) -> bytes | None:
        remote_file = state.find_file_by_rel_path(rel_path)
        return remote_file.content if remote_file else None

    def load_sync_progress(self, client_home: Path):
        db = Database(client_home / "data" / "state.db")
        try:
            return sync_progress_from_dict(db.get_state_json("sync_progress", None))
        finally:
            db.close()

    def daemon_status_text(self, env: dict[str, str]) -> str:
        return self.run_cli(env, "daemon", "status").stdout.lower()

    def test_full_end_to_end_sync_flow(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            client_home = Path(tmp) / "client-home"
            local_root = Path(tmp) / "local-root"
            local_root.mkdir()

            state = MockImageRelayState()
            remote_only = state.add_folder(1, "RemoteOnly")
            state.add_file(remote_only.folder_id, "hello.txt", b"hello remote", file_type_id=7)
            state.throttle_next_download = True

            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

            with MockImageRelayServer(state) as server:
                self.init_client(env, server, local_root)

                self.run_cli(env, "sync", "once")
                self.assertEqual(
                    (local_root / "RemoteOnly" / "hello.txt").read_text(),
                    "hello remote",
                )
                self.assertEqual(state.download_throttle_count, 1)
                self.assertEqual(state.quick_links, {})
                initial_progress = self.load_sync_progress(client_home)
                self.assertIsNotNone(initial_progress.last_remote_poll_at)
                self.assertTrue(
                    any(activity.action == "Downloaded" for activity in initial_progress.recent_activity)
                )
                status_payload = json.loads(
                    self.run_cli(env, "sync", "status", "--json-output").stdout
                )
                self.assertEqual(status_payload["sync_state"], "idle")
                self.assertEqual(
                    status_payload["remote_pull"]["poll_interval_seconds"],
                    1,
                )

                self.run_cli(env, "daemon", "start")
                status = self.run_cli(env, "daemon", "status")
                self.assertIn("running", status.stdout.lower())
                self.wait_for(
                    lambda: self.load_sync_progress(client_home).next_remote_poll_at is not None,
                    "next remote pull schedule",
                )

                uploads_dir = local_root / "Uploads"
                uploads_dir.mkdir()
                local_file = uploads_dir / "from-local.txt"
                local_file.write_text("version one")
                self.wait_for(
                    lambda: self.file_content(state, "Uploads/from-local.txt") == b"version one",
                    "local upload",
                )

                local_file.write_text("version two")
                self.wait_for(
                    lambda: self.file_content(state, "Uploads/from-local.txt") == b"version two",
                    "version upload",
                )

                remote_later = state.add_folder(1, "RemoteLater")
                state.add_file(remote_later.folder_id, "fresh.txt", b"from remote", file_type_id=7)
                self.wait_for(
                    lambda: (local_root / "RemoteLater" / "fresh.txt").exists(),
                    "remote download through daemon poll",
                )

                state.delete_folder(remote_later.folder_id)
                self.wait_for(
                    lambda: not (local_root / "RemoteLater").exists(),
                    "remote deletion mirrored locally",
                )

                local_file.unlink()
                self.wait_for(
                    lambda: state.find_file_by_rel_path("Uploads/from-local.txt") is None,
                    "local deletion mirrored upstream",
                )

                self.run_cli(env, "daemon", "stop", check=False)
                stopped_status = self.run_cli(env, "daemon", "status")
                self.assertIn("not running", stopped_status.stdout.lower())
                final_progress = self.load_sync_progress(client_home)
                self.assertTrue(
                    {"Uploaded", "Updated", "Removed remote"}.issubset(
                        {activity.action for activity in final_progress.recent_activity}
                    )
                )

    def test_remote_multi_folder_asset_creates_symlink_alias(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            client_home = Path(tmp) / "client-home"
            local_root = Path(tmp) / "local-root"
            local_root.mkdir()

            state = MockImageRelayState()
            alpha = state.add_folder(1, "Alpha")
            beta = state.add_folder(1, "Beta")
            state.add_file(
                alpha.folder_id,
                "shared.txt",
                b"shared asset",
                file_type_id=7,
                folder_ids=[alpha.folder_id, beta.folder_id],
            )

            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

            with MockImageRelayServer(state) as server:
                self.init_client(env, server, local_root)
                self.run_cli(env, "sync", "once")

            canonical = local_root / "Alpha" / "shared.txt"
            alias = local_root / "Beta" / "shared.txt"
            self.assertTrue(canonical.exists())
            self.assertEqual(canonical.read_text(), "shared asset")
            self.assertTrue(alias.is_symlink())
            self.assertEqual(alias.read_text(), "shared asset")

    def test_local_file_move_updates_remote_parent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            client_home = Path(tmp) / "client-home"
            local_root = Path(tmp) / "local-root"
            local_root.mkdir()

            state = MockImageRelayState()
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

            with MockImageRelayServer(state) as server:
                self.init_client(env, server, local_root)

                source_dir = local_root / "A"
                destination_dir = local_root / "B"
                source_dir.mkdir()
                destination_dir.mkdir()
                move_file = source_dir / "move.txt"
                move_file.write_text("move me")

                self.run_cli(env, "sync", "once")
                self.assertEqual(self.file_content(state, "A/move.txt"), b"move me")

                destination_file = destination_dir / "move.txt"
                move_file.rename(destination_file)
                self.run_cli(env, "sync", "once")

            self.assertIsNone(state.find_file_by_rel_path("A/move.txt"))
            moved = state.find_file_by_rel_path("B/move.txt")
            self.assertIsNotNone(moved)
            self.assertEqual(moved.content, b"move me")

    def test_local_folder_rename_updates_remote_folder(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            client_home = Path(tmp) / "client-home"
            local_root = Path(tmp) / "local-root"
            local_root.mkdir()

            state = MockImageRelayState()
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

            with MockImageRelayServer(state) as server:
                self.init_client(env, server, local_root)

                campaigns = local_root / "Campaigns"
                campaigns.mkdir()
                brief = campaigns / "brief.txt"
                brief.write_text("launch brief")

                self.run_cli(env, "sync", "once")
                self.assertIsNotNone(state.find_folder_by_rel_path("Campaigns"))
                self.assertEqual(self.file_content(state, "Campaigns/brief.txt"), b"launch brief")

                archive = local_root / "Archive"
                campaigns.rename(archive)
                self.run_cli(env, "sync", "once")

            self.assertIsNone(state.find_folder_by_rel_path("Campaigns"))
            self.assertIsNotNone(state.find_folder_by_rel_path("Archive"))
            self.assertEqual(self.file_content(state, "Archive/brief.txt"), b"launch brief")

    def test_sync_direction_flags_respected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            client_home = Path(tmp) / "client-home"
            local_root = Path(tmp) / "local-root"
            local_root.mkdir()

            state = MockImageRelayState()
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

            with MockImageRelayServer(state) as server:
                self.init_client(env, server, local_root)

                self.run_cli(env, "config", "set", "sync_upload", "false")
                local_only_dir = local_root / "UploadOff"
                local_only_dir.mkdir()
                (local_only_dir / "ignored.txt").write_text("keep local")
                self.run_cli(env, "sync", "once")
                self.assertIsNone(state.find_file_by_rel_path("UploadOff/ignored.txt"))

                self.run_cli(env, "config", "set", "sync_download", "false")
                remote_only = state.add_folder(1, "DownloadOff")
                state.add_file(remote_only.folder_id, "ignored.txt", b"keep remote", file_type_id=7)
                self.run_cli(env, "sync", "once")
                self.assertFalse((local_root / "DownloadOff" / "ignored.txt").exists())

    def test_daemon_recovers_from_transient_remote_api_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            client_home = Path(tmp) / "client-home"
            local_root = Path(tmp) / "local-root"
            local_root.mkdir()

            state = MockImageRelayState()
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

            with MockImageRelayServer(state) as server:
                self.init_client(env, server, local_root)
                self.run_cli(env, "sync", "once")

                incoming = state.add_folder(1, "RecoveredLater")
                state.add_file(incoming.folder_id, "after-error.txt", b"recovered", file_type_id=7)
                state.fail_next_route(
                    "GET",
                    "folders.json",
                    status=503,
                    payload={"error": "Temporary outage"},
                )

                self.run_cli(env, "daemon", "start")
                try:
                    self.wait_for(
                        lambda: "running" in self.daemon_status_text(env),
                        "daemon staying alive after transient failure",
                    )
                    self.wait_for(
                        lambda: (local_root / "RecoveredLater" / "after-error.txt").exists(),
                        "recovered remote download after transient failure",
                        timeout=20.0,
                    )
                finally:
                    self.run_cli(env, "daemon", "stop", check=False)

    def test_pause_and_resume_hold_remote_updates_until_resumed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            client_home = Path(tmp) / "client-home"
            local_root = Path(tmp) / "local-root"
            local_root.mkdir()

            state = MockImageRelayState()
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

            with MockImageRelayServer(state) as server:
                self.init_client(env, server, local_root)
                self.run_cli(env, "sync", "once")
                self.run_cli(env, "daemon", "start")
                try:
                    self.run_cli(env, "sync", "pause", "--for", "indefinite")
                    status_payload = json.loads(
                        self.run_cli(env, "sync", "status", "--json-output").stdout
                    )
                    self.assertTrue(status_payload["paused"])
                    self.assertIsNone(status_payload["paused_until"])

                    incoming = state.add_folder(1, "PausedRemote")
                    state.add_file(incoming.folder_id, "wait.txt", b"hold", file_type_id=7)
                    time.sleep(2.5)
                    self.assertFalse((local_root / "PausedRemote" / "wait.txt").exists())

                    self.run_cli(env, "sync", "resume")
                    self.wait_for(
                        lambda: (local_root / "PausedRemote" / "wait.txt").exists(),
                        "remote download after resume",
                        timeout=20.0,
                    )
                finally:
                    self.run_cli(env, "daemon", "stop", check=False)


if __name__ == "__main__":
    unittest.main()
