from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import PurePosixPath


def normalize_rel_path(path: str) -> str:
    raw = path.replace("\\", "/").strip("/")
    if not raw or raw == ".":
        return ""
    return str(PurePosixPath(raw))


def path_depth(path: str) -> int:
    normalized = normalize_rel_path(path)
    if not normalized:
        return 0
    return normalized.count("/") + 1


def is_same_or_descendant(path: str, prefix: str) -> bool:
    path = normalize_rel_path(path)
    prefix = normalize_rel_path(prefix)

    if prefix == "":
        return True
    return path == prefix or path.startswith(f"{prefix}/")


def now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


@dataclass(slots=True)
class RemoteFolder:
    folder_id: int
    name: str
    parent_id: int | None
    full_path: str
    updated_on: str | None
    rel_path: str = ""
    child_count: int = 0


@dataclass(slots=True)
class RemoteFile:
    file_id: int
    name: str
    size: int
    updated_on: str | None
    content_type: str | None
    file_type_id: int | None
    folder_ids: list[int] = field(default_factory=list)
    canonical_rel_path: str = ""
    alias_rel_paths: list[str] = field(default_factory=list)
    deleted: bool = False


@dataclass(slots=True)
class QuickLink:
    quick_link_id: int
    url: str


@dataclass(slots=True)
class ScannedEntry:
    rel_path: str
    abs_path: str
    item_type: str
    inode: int
    mtime: float
    size: int

    @property
    def is_file(self) -> bool:
        return self.item_type == "file"

    @property
    def is_folder(self) -> bool:
        return self.item_type == "folder"


@dataclass(slots=True)
class TrackedEntry:
    rel_path: str
    item_type: str
    remote_id: int | None
    remote_parent_id: int | None
    remote_updated_on: str | None
    remote_size: int | None
    remote_file_type_id: int | None
    local_inode: int | None
    local_mtime: float | None
    local_size: int | None
    is_alias: bool = False
    canonical_rel_path: str | None = None

    @property
    def is_file(self) -> bool:
        return self.item_type == "file"

    @property
    def is_folder(self) -> bool:
        return self.item_type == "folder"


@dataclass(slots=True)
class RemoteSnapshot:
    folders: dict[int, RemoteFolder]
    files: dict[int, RemoteFile]


@dataclass(slots=True)
class LocalChangeSet:
    changed_paths: set[str] = field(default_factory=set)
    changed_remote_ids: set[int] = field(default_factory=set)
