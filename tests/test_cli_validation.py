from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import bootstrap
from mock_imagerelay import MockImageRelayServer, MockImageRelayState


class CliValidationTests(unittest.TestCase):
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

    def test_sync_once_without_setup_shows_guidance(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = tmp

            result = self.run_cli(env, "sync", "once", check=False)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("The client is not ready to sync yet.", result.stderr)
            self.assertIn("Missing settings: api_key, remote_root_folder_id, default_file_type_id", result.stderr)
            self.assertIn("Run `imagerelay-client init`", result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_daemon_start_without_setup_shows_guidance(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = tmp

            result = self.run_cli(env, "daemon", "start", check=False)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("The client is not ready to sync yet.", result.stderr)
            self.assertNotIn("did not become ready before the timeout expired", result.stderr)

    def test_config_set_rejects_invalid_boolean_value(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = tmp

            result = self.run_cli(env, "config", "set", "sync_upload", "potato", check=False)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be one of: true, false, yes, no, on, off, 1, 0", result.stderr)
            payload = json.loads(self.run_cli(env, "config", "show").stdout)
            self.assertTrue(payload["sync_upload"])

    def test_config_set_rejects_zero_poll_interval(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = tmp

            result = self.run_cli(env, "config", "set", "poll_interval_seconds", "0", check=False)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("`poll_interval_seconds` must be 1 or greater.", result.stderr)

    def test_download_only_mode_does_not_require_default_file_type_id(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            client_home = Path(tmp) / "client-home"
            local_root = Path(tmp) / "local-root"
            local_root.mkdir()

            state = MockImageRelayState()
            remote_only = state.add_folder(1, "RemoteOnly")
            state.add_file(remote_only.folder_id, "hello.txt", b"hello remote", file_type_id=7)

            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

            with MockImageRelayServer(state) as server:
                self.run_cli(
                    env,
                    "init",
                    "--api-key",
                    "test-key",
                    "--api-base-url",
                    server.api_base_url,
                    "--local-root",
                    str(local_root),
                    "--remote-root-folder-id",
                    "1",
                    "--user-agent",
                    "ImageRelay Client Test (tests@example.com)",
                    "--poll-interval-seconds",
                    "1",
                )
                self.run_cli(env, "config", "set", "sync_upload", "false")
                self.run_cli(env, "sync", "once")

            self.assertEqual((local_root / "RemoteOnly" / "hello.txt").read_text(), "hello remote")

    def test_sync_once_reports_paused_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            client_home = Path(tmp) / "client-home"
            local_root = Path(tmp) / "local-root"
            local_root.mkdir()

            state = MockImageRelayState()
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

            with MockImageRelayServer(state) as server:
                self.run_cli(
                    env,
                    "init",
                    "--api-key",
                    "test-key",
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
                self.run_cli(env, "sync", "pause", "--for", "indefinite")

                result = self.run_cli(env, "sync", "once", check=False)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Syncing is paused until you resume it.", result.stderr)

    def test_config_set_can_clear_nullable_field(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["IMAGERELAY_CLIENT_HOME"] = tmp

            self.run_cli(env, "config", "set", "default_file_type_id", "7")
            cleared = self.run_cli(env, "config", "set", "default_file_type_id", "clear")

            self.assertIn("Updated default_file_type_id: (cleared)", cleared.stdout)
            payload = json.loads(self.run_cli(env, "config", "show").stdout)
            self.assertIsNone(payload["default_file_type_id"])


if __name__ == "__main__":
    unittest.main()
