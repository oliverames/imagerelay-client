from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from .appdirs import ensure_app_dirs
from .maestral_compat.database.core import Database as SqliteDatabase
from .maestral_compat.database.orm import Column, Manager, Model, NonNullColumn
from .maestral_compat.database.query import AllQuery, AndQuery, MatchQuery, PathTreeQuery
from .maestral_compat.database.types import SqlFloat, SqlInt, SqlPath, SqlString
from .models import TrackedEntry, normalize_rel_path


class EntryModel(Model):
    __tablename__ = "'entries'"

    rel_path = NonNullColumn(SqlPath(), primary_key=True)
    item_type = NonNullColumn(SqlString())
    remote_id = Column(SqlInt(), index=True)
    remote_parent_id = Column(SqlInt())
    remote_updated_on = Column(SqlString())
    remote_size = Column(SqlInt())
    remote_file_type_id = Column(SqlInt())
    local_inode = Column(SqlInt())
    local_mtime = Column(SqlFloat())
    local_size = Column(SqlInt())
    is_alias = NonNullColumn(SqlInt(), default=0, index=True)
    canonical_rel_path = Column(SqlPath())


class StateValueModel(Model):
    __tablename__ = "'state'"

    key = NonNullColumn(SqlString(), primary_key=True)
    value = NonNullColumn(SqlString())


class Database:
    def __init__(self, path: Path) -> None:
        ensure_app_dirs()
        self.path = path
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.db = SqliteDatabase(self.connection)
        self.entries = Manager(self.db, EntryModel)
        self.state = Manager(self.db, StateValueModel)

    def close(self) -> None:
        self.connection.close()

    def list_entries(self) -> list[TrackedEntry]:
        rows = self.entries.select(AllQuery().order_by("rel_path"))
        return [self._model_to_entry(row) for row in rows]

    def count_entries(self, include_aliases: bool = True) -> int:
        entries = self.list_entries()
        if include_aliases:
            return len(entries)
        return sum(1 for entry in entries if not entry.is_alias)

    def get_entry(self, rel_path: str) -> TrackedEntry | None:
        row = self.entries.get(normalize_rel_path(rel_path))
        if row is None:
            return None
        return self._model_to_entry(row)

    def list_aliases_for_remote(self, remote_id: int) -> list[TrackedEntry]:
        query = AndQuery(
            MatchQuery(EntryModel.remote_id, remote_id),
            MatchQuery(EntryModel.is_alias, 1),
        ).order_by("rel_path")
        rows = self.entries.select(query)
        return [self._model_to_entry(row) for row in rows]

    def find_canonical_by_remote_id(self, item_type: str, remote_id: int) -> TrackedEntry | None:
        rows = self.entries.select(
            AndQuery(
                MatchQuery(EntryModel.item_type, item_type),
                MatchQuery(EntryModel.remote_id, remote_id),
                MatchQuery(EntryModel.is_alias, 0),
            )
        )
        if not rows:
            return None
        return self._model_to_entry(rows[0])

    def upsert_entry(self, entry: TrackedEntry) -> None:
        self.entries.update(
            EntryModel(
                rel_path=normalize_rel_path(entry.rel_path),
                item_type=entry.item_type,
                remote_id=entry.remote_id,
                remote_parent_id=entry.remote_parent_id,
                remote_updated_on=entry.remote_updated_on,
                remote_size=entry.remote_size,
                remote_file_type_id=entry.remote_file_type_id,
                local_inode=entry.local_inode,
                local_mtime=entry.local_mtime,
                local_size=entry.local_size,
                is_alias=1 if entry.is_alias else 0,
                canonical_rel_path=normalize_rel_path(entry.canonical_rel_path or "") or None,
            )
        )

    def delete_entry(self, rel_path: str) -> None:
        self.entries.delete_primary_key(normalize_rel_path(rel_path))

    def delete_remote_aliases(self, remote_id: int) -> None:
        self.entries.delete(
            AndQuery(
                MatchQuery(EntryModel.remote_id, remote_id),
                MatchQuery(EntryModel.is_alias, 1),
            )
        )

    def delete_prefix(self, prefix: str) -> None:
        self.entries.delete(PathTreeQuery(EntryModel.rel_path, normalize_rel_path(prefix)))

    def rename_prefix(self, old_prefix: str, new_prefix: str) -> None:
        old_prefix = normalize_rel_path(old_prefix)
        new_prefix = normalize_rel_path(new_prefix)
        entries = self.list_entries()

        for entry in entries:
            updated = False
            original_rel_path = entry.rel_path

            if self._is_same_or_descendant(entry.rel_path, old_prefix):
                suffix = entry.rel_path[len(old_prefix):].lstrip("/")
                entry.rel_path = normalize_rel_path(
                    "/".join(part for part in (new_prefix, suffix) if part)
                )
                updated = True

            if entry.canonical_rel_path and self._is_same_or_descendant(
                entry.canonical_rel_path, old_prefix
            ):
                suffix = entry.canonical_rel_path[len(old_prefix):].lstrip("/")
                entry.canonical_rel_path = normalize_rel_path(
                    "/".join(part for part in (new_prefix, suffix) if part)
                )
                updated = True

            if updated:
                self.entries.delete_primary_key(original_rel_path)
                self.upsert_entry(entry)

    def get_state(self, key: str, default: str | None = None) -> str | None:
        row = self.state.get(key)
        if row is None:
            return default
        return row.value

    def set_state(self, key: str, value: str) -> None:
        self.state.update(StateValueModel(key=key, value=value))

    def get_state_json(self, key: str, default: object | None = None) -> object | None:
        raw = self.get_state(key)
        if raw is None:
            return default

        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return default

    def set_state_json(self, key: str, value: object) -> None:
        self.set_state(key, json.dumps(value, separators=(",", ":"), sort_keys=True))

    @staticmethod
    def _is_same_or_descendant(path: str, prefix: str) -> bool:
        if prefix == "":
            return True
        return path == prefix or path.startswith(f"{prefix}/")

    @staticmethod
    def _model_to_entry(row: EntryModel) -> TrackedEntry:
        canonical = row.canonical_rel_path or None
        return TrackedEntry(
            rel_path=str(row.rel_path),
            item_type=str(row.item_type),
            remote_id=row.remote_id,
            remote_parent_id=row.remote_parent_id,
            remote_updated_on=row.remote_updated_on,
            remote_size=row.remote_size,
            remote_file_type_id=row.remote_file_type_id,
            local_inode=row.local_inode,
            local_mtime=row.local_mtime,
            local_size=row.local_size,
            is_alias=bool(row.is_alias),
            canonical_rel_path=canonical,
        )
