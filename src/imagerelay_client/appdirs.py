from __future__ import annotations

import os
from pathlib import Path

from .maestral_compat.appdirs import (
    get_autostart_path,
    get_conf_path,
    get_data_path,
    get_log_path,
    get_runtime_path,
)


APP_NAME = "ImageRelay Client"
APP_SLUG = "imagerelay-client"
APP_HOME_ENV = "IMAGERELAY_CLIENT_HOME"


def _override_root() -> Path | None:
    value = os.environ.get(APP_HOME_ENV)
    if not value:
        return None
    return Path(value).expanduser().resolve()


def _override_path(folder: str, filename: str | None = None) -> Path | None:
    root = _override_root()
    if root is None:
        return None
    path = root / folder
    return path / filename if filename else path


def app_support_dir() -> Path:
    override = _override_path("data")
    if override is not None:
        return override
    return Path(get_data_path(APP_SLUG))


def log_dir() -> Path:
    override = _override_path("logs")
    if override is not None:
        return override
    return Path(get_log_path(APP_SLUG))


def ensure_app_dirs() -> None:
    config_path().parent.mkdir(parents=True, exist_ok=True)
    database_path().parent.mkdir(parents=True, exist_ok=True)
    rate_limit_path().parent.mkdir(parents=True, exist_ok=True)
    lock_path().parent.mkdir(parents=True, exist_ok=True)
    pid_path().parent.mkdir(parents=True, exist_ok=True)
    log_path().parent.mkdir(parents=True, exist_ok=True)


def config_path() -> Path:
    override = _override_path("config", "client.ini")
    if override is not None:
        return override
    return Path(get_conf_path(APP_SLUG, "client.ini"))


def database_path() -> Path:
    override = _override_path("data", "state.db")
    if override is not None:
        return override
    return Path(get_data_path(APP_SLUG, "state.db"))


def rate_limit_path() -> Path:
    override = _override_path("data", "rate_limit.db")
    if override is not None:
        return override
    return Path(get_data_path(APP_SLUG, "rate_limit.db"))


def pid_path() -> Path:
    override = _override_path("runtime", "client.pid")
    if override is not None:
        return override
    return Path(get_runtime_path(APP_SLUG, "client.pid"))


def lock_path() -> Path:
    override = _override_path("runtime", "client.lock")
    if override is not None:
        return override
    return Path(get_runtime_path(APP_SLUG, "client.lock"))


def log_path() -> Path:
    override = _override_path("logs", "client.log")
    if override is not None:
        return override
    return Path(get_log_path(APP_SLUG, "client.log"))


def autostart_path(filename: str) -> Path:
    override = _override_path("LaunchAgents", filename)
    if override is not None:
        return override
    return Path(get_autostart_path(filename))
