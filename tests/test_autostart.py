from __future__ import annotations

import plistlib
import tempfile
import unittest
from pathlib import Path

import bootstrap
from imagerelay_client.autostart import AutoStart


class AutoStartTests(unittest.TestCase):
    def test_enable_and_disable_launch_agent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "com.imagerelay.client.daemon.plist"
            autostart = AutoStart(target="daemon", destination=destination, python_executable="/usr/bin/python3")

            path = autostart.enable()
            self.assertEqual(path, destination)
            self.assertTrue(destination.exists())

            with destination.open("rb") as handle:
                payload = plistlib.load(handle)

            self.assertEqual(payload["Label"], "com.imagerelay.client.daemon")
            self.assertEqual(
                payload["ProgramArguments"],
                ["/usr/bin/python3", "-m", "imagerelay_client", "daemon", "run"],
            )

            autostart.disable()
            self.assertFalse(destination.exists())

    def test_gui_target_uses_gui_entrypoint(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "com.imagerelay.client.gui.plist"
            autostart = AutoStart(target="gui", destination=destination, python_executable="/usr/bin/python3")

            autostart.enable()

            with destination.open("rb") as handle:
                payload = plistlib.load(handle)

            self.assertEqual(
                payload["ProgramArguments"],
                ["/usr/bin/python3", "-m", "imagerelay_client", "gui"],
            )


if __name__ == "__main__":
    unittest.main()
