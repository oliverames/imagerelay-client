from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from packaging.version import Version

from .appdirs import config_path, database_path, ensure_app_dirs
from .maestral_compat.user_config import UserConfig


DEFAULT_USER_AGENT = "ImageRelay Client/0.1.0 (github.com/oliverames/imagerelay-client)"
CONFIG_VERSION = Version("1.0")

CONFIG_DEFAULTS = {
    "api": {
        "api_key": "",
        "subdomain": "",
        "api_base_url": "",
        "user_agent": DEFAULT_USER_AGENT,
    },
    "sync": {
        "local_root": str(Path.home() / "Image Relay"),
        "remote_root_folder_id": 0,
        "default_file_type_id": 0,
        "poll_interval_seconds": 30,
        "sync_download": True,
        "sync_upload": True,
        "download_purpose": "imagerelay-client-sync",
        "upload_chunk_size": 5 * 1024 * 1024,
        "version_chunk_size": 5 * 1024 * 1024,
        "request_timeout_seconds": 60,
    },
}

STATE_DEFAULTS = {
    "sync": {
        "last_sync_at": "",
    }
}


class SyncConfigurationError(RuntimeError):
    """Raised when saved settings are not ready for sync."""


@dataclass(slots=True)
class Settings:
    api_key: str | None = None
    subdomain: str | None = None
    api_base_url: str | None = None
    user_agent: str = DEFAULT_USER_AGENT
    local_root: str = str(Path.home() / "Image Relay")
    remote_root_folder_id: int | None = None
    default_file_type_id: int | None = None
    poll_interval_seconds: int = 30
    sync_download: bool = True
    sync_upload: bool = True
    download_purpose: str = "imagerelay-client-sync"
    upload_chunk_size: int = 5 * 1024 * 1024
    version_chunk_size: int = 5 * 1024 * 1024
    request_timeout_seconds: int = 60

    def resolved_api_key(self) -> str | None:
        return os.environ.get("IMAGERELAY_API_KEY") or self.api_key

    def resolved_local_root(self) -> Path:
        return Path(self.local_root).expanduser().resolve()

    def resolved_base_url(self) -> str:
        if self.api_base_url:
            return self.api_base_url.rstrip("/")
        if self.subdomain:
            return f"https://{self.subdomain}.imagerelay.com/api/v2"
        return "https://api.imagerelay.com/api/v2"

    def missing_sync_fields(self) -> list[str]:
        missing: list[str] = []
        needs_remote = self.sync_download or self.sync_upload

        if needs_remote and not self.resolved_api_key():
            missing.append("api_key")
        if needs_remote and self.remote_root_folder_id is None:
            missing.append("remote_root_folder_id")
        if self.sync_upload and self.default_file_type_id is None:
            missing.append("default_file_type_id")
        return missing

    def validation_errors(self) -> list[str]:
        errors: list[str] = []

        if self.poll_interval_seconds < 1:
            errors.append("`poll_interval_seconds` must be 1 or greater.")
        if self.request_timeout_seconds < 1:
            errors.append("`request_timeout_seconds` must be 1 or greater.")
        if self.upload_chunk_size < 1:
            errors.append("`upload_chunk_size` must be 1 or greater.")
        if self.version_chunk_size < 1:
            errors.append("`version_chunk_size` must be 1 or greater.")
        if self.remote_root_folder_id is not None and self.remote_root_folder_id < 1:
            errors.append("`remote_root_folder_id` must be 1 or greater.")
        if self.default_file_type_id is not None and self.default_file_type_id < 1:
            errors.append("`default_file_type_id` must be 1 or greater.")
        if not self.local_root.strip():
            errors.append("`local_root` cannot be empty.")
        if not self.download_purpose.strip():
            errors.append("`download_purpose` cannot be empty.")
        return errors


def sync_configuration_message(settings: Settings) -> str | None:
    problems: list[str] = []
    missing = settings.missing_sync_fields()
    if missing:
        problems.append("Missing settings: " + ", ".join(missing))
    problems.extend(settings.validation_errors())

    if not problems:
        return None

    lines = ["The client is not ready to sync yet."]
    lines.extend(f"- {problem}" for problem in problems)
    lines.append(
        "Run `imagerelay-client init` for guided setup, or `imagerelay-client config show` to inspect the saved values."
    )
    return "\n".join(lines)


def ensure_sync_ready(settings: Settings) -> None:
    message = sync_configuration_message(settings)
    if message is not None:
        raise SyncConfigurationError(message)


class ConfigStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or config_path()
        self._config: UserConfig | None = None

    def load(self) -> Settings:
        config = self._open_config()
        return Settings(
            api_key=self._empty_to_none(config.get("api", "api_key")),
            subdomain=self._empty_to_none(config.get("api", "subdomain")),
            api_base_url=self._empty_to_none(config.get("api", "api_base_url")),
            user_agent=config.get("api", "user_agent"),
            local_root=config.get("sync", "local_root"),
            remote_root_folder_id=self._zero_to_none(config.get("sync", "remote_root_folder_id")),
            default_file_type_id=self._zero_to_none(config.get("sync", "default_file_type_id")),
            poll_interval_seconds=config.get("sync", "poll_interval_seconds"),
            sync_download=config.get("sync", "sync_download"),
            sync_upload=config.get("sync", "sync_upload"),
            download_purpose=config.get("sync", "download_purpose"),
            upload_chunk_size=config.get("sync", "upload_chunk_size"),
            version_chunk_size=config.get("sync", "version_chunk_size"),
            request_timeout_seconds=config.get("sync", "request_timeout_seconds"),
        )

    def save(self, settings: Settings) -> None:
        ensure_app_dirs()
        config = self._open_config()
        config.set("api", "api_key", settings.api_key or "")
        config.set("api", "subdomain", settings.subdomain or "")
        config.set("api", "api_base_url", settings.api_base_url or "")
        config.set("api", "user_agent", settings.user_agent)
        config.set("sync", "local_root", settings.local_root)
        config.set("sync", "remote_root_folder_id", settings.remote_root_folder_id or 0)
        config.set("sync", "default_file_type_id", settings.default_file_type_id or 0)
        config.set("sync", "poll_interval_seconds", settings.poll_interval_seconds)
        config.set("sync", "sync_download", settings.sync_download)
        config.set("sync", "sync_upload", settings.sync_upload)
        config.set("sync", "download_purpose", settings.download_purpose)
        config.set("sync", "upload_chunk_size", settings.upload_chunk_size)
        config.set("sync", "version_chunk_size", settings.version_chunk_size)
        config.set("sync", "request_timeout_seconds", settings.request_timeout_seconds)

    def update(self, **changes: Any) -> Settings:
        settings = self.load()
        for key, value in changes.items():
            if value is not None and hasattr(settings, key):
                setattr(settings, key, value)
        self.save(settings)
        return settings

    def _open_config(self) -> UserConfig:
        if self._config is None:
            ensure_app_dirs()
            self._config = UserConfig(
                str(self.path),
                defaults=CONFIG_DEFAULTS,
                version=CONFIG_VERSION,
                backup=True,
            )
        return self._config

    @staticmethod
    def _empty_to_none(value: str) -> str | None:
        return value or None

    @staticmethod
    def _zero_to_none(value: int) -> int | None:
        return value or None


class StateStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or database_path().with_suffix(".ini")
        self._state: UserConfig | None = None

    def get(self, key: str, default: str | None = None) -> str | None:
        state = self._open_state()
        value = state.get("sync", key, default if default is not None else "")
        return value or default

    def set(self, key: str, value: str) -> None:
        state = self._open_state()
        state.set("sync", key, value)

    def _open_state(self) -> UserConfig:
        if self._state is None:
            ensure_app_dirs()
            self._state = UserConfig(
                str(self.path),
                defaults=STATE_DEFAULTS,
                version=CONFIG_VERSION,
                backup=True,
            )
        return self._state


def mask_api_key(value: str | None) -> str | None:
    if not value:
        return value
    if len(value) <= 8:
        return "*" * len(value)
    return f"{value[:4]}...{value[-4:]}"
