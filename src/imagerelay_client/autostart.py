from __future__ import annotations

import logging
import os
import plistlib
import platform
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from .appdirs import APP_HOME_ENV, autostart_path, ensure_app_dirs, log_path

log = logging.getLogger(__name__)

BUNDLE_ID = "com.imagerelay.client"


class AutoStartError(RuntimeError):
    """Raised when autostart is not supported for the current platform."""


@dataclass(slots=True)
class LaunchAgentSpec:
    label: str
    program_arguments: list[str]
    destination: Path
    environment_variables: dict[str, str] | None = None

    def plist(self) -> dict[str, object]:
        payload: dict[str, object] = {
            "Label": self.label,
            "ProcessType": "Interactive",
            "RunAtLoad": True,
            "ProgramArguments": self.program_arguments,
            "StandardOutPath": str(log_path()),
            "StandardErrorPath": str(log_path()),
        }
        if self.environment_variables:
            payload["EnvironmentVariables"] = self.environment_variables
        return payload


class AutoStart:
    def __init__(
        self,
        target: str = "daemon",
        destination: Path | None = None,
        python_executable: str | None = None,
    ) -> None:
        if platform.system() != "Darwin":
            raise AutoStartError("Autostart is only implemented for macOS launchd.")

        if target not in {"daemon", "gui"}:
            raise ValueError("target must be 'daemon' or 'gui'")

        executable = python_executable or sys.executable
        label = f"{BUNDLE_ID}.{target}"
        filename = f"{label}.plist"
        if target == "gui":
            command = [executable, "-m", "imagerelay_client", "gui"]
        else:
            command = [executable, "-m", "imagerelay_client", "daemon", "run"]
        env: dict[str, str] = {}

        client_home = os.environ.get(APP_HOME_ENV)
        if client_home:
            env[APP_HOME_ENV] = client_home

        self.spec = LaunchAgentSpec(
            label=label,
            program_arguments=command,
            destination=destination or autostart_path(filename),
            environment_variables=env or None,
        )

    @property
    def enabled(self) -> bool:
        return self.spec.destination.exists()

    @property
    def path(self) -> Path:
        return self.spec.destination

    def _run_launchctl(self, *args: str) -> bool:
        """Run a launchctl command, returning True on success."""
        result = subprocess.run(
            ["launchctl", *args],
            capture_output=True,
        )
        return result.returncode == 0

    def enable(self) -> Path:
        ensure_app_dirs()
        self.spec.destination.parent.mkdir(parents=True, exist_ok=True)
        with self.spec.destination.open("wb") as handle:
            plistlib.dump(self.spec.plist(), handle, sort_keys=False)

        gui_target = f"gui/{os.getuid()}"
        if not self._run_launchctl("bootstrap", gui_target, str(self.spec.destination)):
            if not self._run_launchctl("load", str(self.spec.destination)):
                log.warning(
                    "Plist written to %s but could not be loaded immediately; "
                    "it will activate on next login.",
                    self.spec.destination,
                )

        return self.spec.destination

    def disable(self) -> None:
        gui_target = f"gui/{os.getuid()}/{self.spec.label}"
        if not self._run_launchctl("bootout", gui_target):
            if not self._run_launchctl("unload", str(self.spec.destination)):
                log.warning(
                    "Could not unload %s; removing plist anyway.",
                    self.spec.destination,
                )

        self.spec.destination.unlink(missing_ok=True)
