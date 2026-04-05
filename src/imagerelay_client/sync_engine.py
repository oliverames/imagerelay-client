from __future__ import annotations

import os
import shutil
import signal
import time
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Iterable

from watchdog.events import FileSystemEvent, FileSystemEventHandler

from .api import ImageRelayApiClient
from .config import Settings
from .database import Database
from .maestral_compat.fsevents import Observer
from .models import (
    LocalChangeSet,
    RemoteFile,
    RemoteFolder,
    RemoteSnapshot,
    ScannedEntry,
    TrackedEntry,
    is_same_or_descendant,
    normalize_rel_path,
    now_iso,
    path_depth,
)
from .progress import SyncProgressTracker
from .sync_pause import SyncPausedError, SyncPauseState, describe_pause_state, load_pause_state
from .user_messages import cross_parent_move_message


IGNORED_EXACT_NAMES = {".DS_Store"}
TEMP_MARKER = ".imagerelay-download"
CONFLICT_MARKER = "imagerelay conflict"


@dataclass(slots=True)
class RemotePlan:
    folder_creates: list[RemoteFolder] = field(default_factory=list)
    folder_updates: list[tuple[RemoteFolder, TrackedEntry]] = field(default_factory=list)
    folder_deletes: list[TrackedEntry] = field(default_factory=list)
    file_creates: list[RemoteFile] = field(default_factory=list)
    file_updates: list[tuple[RemoteFile, TrackedEntry]] = field(default_factory=list)
    file_deletes: list[TrackedEntry] = field(default_factory=list)


@dataclass(slots=True)
class LocalAction:
    kind: str
    item_type: str
    rel_path: str
    tracked: TrackedEntry | None = None
    current: ScannedEntry | None = None
    previous_rel_path: str | None = None


class DirtyEventHandler(FileSystemEventHandler):
    def __init__(self, engine: "SyncEngine") -> None:
        self.engine = engine

    def on_any_event(self, event: FileSystemEvent) -> None:
        candidates = [getattr(event, "src_path", None), getattr(event, "dest_path", None)]
        for candidate in candidates:
            if not candidate:
                continue
            if self.engine.should_ignore_local_name(Path(candidate).name):
                return

        self.engine.mark_local_dirty()


class SyncEngine:
    def __init__(self, settings: Settings, api: ImageRelayApiClient, db: Database, logger) -> None:
        self.settings = settings
        self.api = api
        self.db = db
        self.logger = logger
        self.progress = SyncProgressTracker(db)
        self.local_root = settings.resolved_local_root()
        self._observer: Observer | None = None
        self._stop_requested = False
        self._local_dirty = True

    def mark_local_dirty(self) -> None:
        self._local_dirty = True

    def stop(self, *_args) -> None:
        self._stop_requested = True

    def run_forever(self) -> None:
        self.local_root.mkdir(parents=True, exist_ok=True)
        self.logger.info("Watching local root %s", self.local_root)

        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)

        handler = DirtyEventHandler(self)
        observer = Observer()
        observer.schedule(handler, str(self.local_root), recursive=True)
        observer.start()
        self._observer = observer

        try:
            next_remote_poll = 0.0
            active_pause_marker: str | None = None

            while not self._stop_requested:
                pause_state = load_pause_state(self.db)
                if pause_state.paused:
                    pause_marker = pause_state.until or "indefinite"
                    if active_pause_marker != pause_marker:
                        self.progress.pause(self._pause_phase(pause_state))
                        self.progress.update_next_remote_poll(pause_state.remaining_seconds())
                        self.logger.info(describe_pause_state(pause_state))
                        active_pause_marker = pause_marker
                    time.sleep(1.0)
                    continue

                if active_pause_marker is not None:
                    active_pause_marker = None
                    self._local_dirty = True
                    next_remote_poll = 0.0
                    self.logger.info("Sync pause cleared. Resuming sync checks.")

                now = time.monotonic()
                if self._local_dirty or now >= next_remote_poll:
                    self._local_dirty = False
                    try:
                        self.sync_once()
                    except SyncPausedError as exc:
                        pause_state = exc.pause_state
                        pause_marker = pause_state.until or "indefinite"
                        active_pause_marker = pause_marker
                        self.progress.pause(self._pause_phase(pause_state))
                        self.progress.update_next_remote_poll(pause_state.remaining_seconds())
                        self.logger.info(describe_pause_state(pause_state))
                    except Exception:
                        retry_delay = self._retry_delay_seconds()
                        next_remote_poll = time.monotonic() + retry_delay
                        if self.settings.sync_download:
                            self.progress.update_next_remote_poll(retry_delay)
                        self.logger.exception(
                            "Sync pass failed. Retrying in %.1f seconds.", retry_delay
                        )
                    else:
                        poll_interval = max(self.settings.poll_interval_seconds, 1)
                        next_remote_poll = time.monotonic() + poll_interval
                        if self.settings.sync_download:
                            self.progress.update_next_remote_poll(poll_interval)

                time.sleep(1.0)
        finally:
            observer.stop()
            observer.join(timeout=5.0)
            self._observer = None
            self.progress.update_next_remote_poll(None)

    def sync_once(self) -> None:
        self.local_root.mkdir(parents=True, exist_ok=True)
        self.logger.info("Starting sync pass")

        try:
            self._raise_if_paused()
            self.progress.begin_sync("Scanning local state")
            entries_before = self.db.list_entries()
            local_before = self._scan_local()
            local_changes = self._detect_tracked_local_changes(entries_before, local_before)

            if self.settings.sync_download:
                self.progress.set_phase("Polling remote account")
                remote_snapshot = self._fetch_remote_snapshot()
                self.progress.record_remote_poll()
                remote_plan = self._plan_remote_changes(entries_before, remote_snapshot)
                self.progress.extend_total(self._count_remote_actions(remote_plan))
                if self._count_remote_actions(remote_plan) > 0:
                    self.progress.set_phase("Pulling remote changes")
                self._apply_remote_changes(remote_plan, local_changes)
            else:
                self.logger.debug("Skipping remote download phase because sync_download is disabled.")

            entries_after_remote = self.db.list_entries()
            local_after = self._scan_local()
            if self.settings.sync_upload:
                local_actions = self._plan_local_actions(entries_after_remote, local_after)
                self.progress.extend_total(len(local_actions))
                if local_actions:
                    self.progress.set_phase("Pushing local changes")
                self._apply_local_actions(local_actions)
            else:
                self.logger.debug("Skipping local upload phase because sync_upload is disabled.")

            self.db.set_state("last_sync_at", now_iso())
            finish_phase = "Waiting for the next remote pull" if self.settings.sync_download else "Idle"
            self.progress.finish(finish_phase)
            self.logger.info("Sync pass complete")
        except SyncPausedError:
            raise
        except Exception as exc:
            self.progress.fail(exc)
            raise

    def _fetch_remote_snapshot(self) -> RemoteSnapshot:
        configured_root_id = self.settings.remote_root_folder_id
        if configured_root_id is None:
            raise RuntimeError("remote_root_folder_id is required for sync.")

        folders = self.api.list_folders()
        folders_by_id = {folder.folder_id: folder for folder in folders}

        if configured_root_id not in folders_by_id:
            root_folder = self.api.get_root_folder()
            folders_by_id[root_folder.folder_id] = root_folder

        descendants = self._descendant_folder_ids(folders_by_id, configured_root_id)
        remote_folders: dict[int, RemoteFolder] = {}

        for folder_id in descendants:
            if folder_id == configured_root_id:
                continue

            folder = folders_by_id[folder_id]
            rel_path = self._relative_folder_path(folder_id, folders_by_id, configured_root_id)
            remote_folders[folder_id] = RemoteFolder(
                folder_id=folder.folder_id,
                name=folder.name,
                parent_id=folder.parent_id,
                full_path=folder.full_path,
                updated_on=folder.updated_on,
                rel_path=rel_path,
            )

        files = self.api.list_files(configured_root_id, recursive=True)
        remote_files: dict[int, RemoteFile] = {}

        for remote_file in files:
            if remote_file.deleted:
                continue

            rel_paths = sorted(
                {
                    normalize_rel_path(
                        str(PurePosixPath(remote_folders[folder_id].rel_path) / remote_file.name)
                    )
                    if folder_id in remote_folders
                    else normalize_rel_path(remote_file.name)
                    for folder_id in remote_file.folder_ids
                    if folder_id == configured_root_id or folder_id in remote_folders
                }
            )

            if not rel_paths:
                continue

            remote_file.canonical_rel_path = rel_paths[0]
            remote_file.alias_rel_paths = rel_paths[1:]
            remote_files[remote_file.file_id] = remote_file

        return RemoteSnapshot(folders=remote_folders, files=remote_files)

    def _plan_remote_changes(self, entries: list[TrackedEntry], snapshot: RemoteSnapshot) -> RemotePlan:
        plan = RemotePlan()

        canonical_entries = [entry for entry in entries if not entry.is_alias]
        folder_entries = {entry.remote_id: entry for entry in canonical_entries if entry.is_folder and entry.remote_id is not None}
        file_entries = {entry.remote_id: entry for entry in canonical_entries if entry.is_file and entry.remote_id is not None}
        alias_entries_by_remote: dict[int, list[TrackedEntry]] = defaultdict(list)

        for entry in entries:
            if entry.is_alias and entry.remote_id is not None:
                alias_entries_by_remote[entry.remote_id].append(entry)

        for folder in sorted(snapshot.folders.values(), key=lambda item: path_depth(item.rel_path)):
            existing = folder_entries.get(folder.folder_id)
            if existing is None:
                plan.folder_creates.append(folder)
            elif existing.rel_path != folder.rel_path:
                plan.folder_updates.append((folder, existing))

        raw_folder_deletes = [
            entry for remote_id, entry in folder_entries.items() if remote_id not in snapshot.folders
        ]
        plan.folder_deletes = self._compact_folder_deletes(raw_folder_deletes)
        deleted_folder_prefixes = [entry.rel_path for entry in plan.folder_deletes]

        for remote_file in snapshot.files.values():
            existing = file_entries.get(remote_file.file_id)
            aliases = sorted(alias.rel_path for alias in alias_entries_by_remote.get(remote_file.file_id, []))

            if existing is None:
                plan.file_creates.append(remote_file)
                continue

            if (
                existing.rel_path != remote_file.canonical_rel_path
                or existing.remote_updated_on != remote_file.updated_on
                or existing.remote_size != remote_file.size
                or aliases != sorted(remote_file.alias_rel_paths)
            ):
                plan.file_updates.append((remote_file, existing))

        raw_file_deletes = [
            entry for remote_id, entry in file_entries.items() if remote_id not in snapshot.files
        ]
        plan.file_deletes = [
            entry
            for entry in raw_file_deletes
            if not any(is_same_or_descendant(entry.rel_path, prefix) for prefix in deleted_folder_prefixes)
        ]

        return plan

    def _apply_remote_changes(self, plan: RemotePlan, local_changes: LocalChangeSet) -> None:
        for folder in plan.folder_creates:
            self._raise_if_paused()
            self._apply_remote_folder_create(folder)
            self.progress.record_step("Pulled folder", folder.rel_path, phase="Pulling remote changes")

        for folder, existing in plan.folder_updates:
            self._raise_if_paused()
            self._apply_remote_folder_update(folder, existing)
            self.progress.record_step("Updated folder", folder.rel_path, phase="Pulling remote changes")

        for entry in sorted(plan.file_deletes, key=lambda item: path_depth(item.rel_path), reverse=True):
            self._raise_if_paused()
            self._apply_remote_file_delete(entry, local_changes.changed_paths)
            self.progress.record_step("Removed local", entry.rel_path, phase="Pulling remote changes")

        for entry in sorted(plan.folder_deletes, key=lambda item: path_depth(item.rel_path), reverse=True):
            self._raise_if_paused()
            self._apply_remote_folder_delete(entry, local_changes.changed_paths)
            self.progress.record_step("Removed folder", entry.rel_path, phase="Pulling remote changes")

        for remote_file in plan.file_creates:
            self._raise_if_paused()
            self._apply_remote_file_sync(remote_file, local_changes.changed_paths)
            self.progress.record_step(
                "Downloaded",
                remote_file.canonical_rel_path,
                phase="Pulling remote changes",
            )

        for remote_file, _existing in plan.file_updates:
            self._raise_if_paused()
            self._apply_remote_file_sync(remote_file, local_changes.changed_paths)
            self.progress.record_step(
                "Downloaded",
                remote_file.canonical_rel_path,
                phase="Pulling remote changes",
            )

    def _plan_local_actions(self, entries: list[TrackedEntry], scan: dict[str, ScannedEntry]) -> list[LocalAction]:
        tracked = {entry.rel_path: entry for entry in entries if not entry.is_alias and entry.rel_path}
        missing = {rel_path: entry for rel_path, entry in tracked.items() if rel_path not in scan}
        new = {rel_path: entry for rel_path, entry in scan.items() if rel_path not in tracked}

        actions: list[LocalAction] = []
        consumed_missing: set[str] = set()
        consumed_new: set[str] = set()

        for old_rel, tracked_entry in missing.items():
            if tracked_entry.local_inode is None:
                continue

            for new_rel, current in new.items():
                if new_rel in consumed_new:
                    continue
                if current.item_type == tracked_entry.item_type and current.inode == tracked_entry.local_inode:
                    actions.append(
                        LocalAction(
                            kind="move",
                            item_type=current.item_type,
                            rel_path=new_rel,
                            tracked=tracked_entry,
                            current=current,
                            previous_rel_path=old_rel,
                        )
                    )
                    consumed_missing.add(old_rel)
                    consumed_new.add(new_rel)
                    break

        for rel_path, entry in missing.items():
            if rel_path in consumed_missing:
                continue
            actions.append(
                LocalAction(
                    kind="delete",
                    item_type=entry.item_type,
                    rel_path=rel_path,
                    tracked=entry,
                )
            )

        for rel_path, current in scan.items():
            tracked_entry = tracked.get(rel_path)
            if tracked_entry is None:
                if rel_path in consumed_new:
                    continue
                actions.append(
                    LocalAction(
                        kind="create",
                        item_type=current.item_type,
                        rel_path=rel_path,
                        current=current,
                    )
                )
                continue

            if current.is_file and self._file_differs(tracked_entry, current):
                actions.append(
                    LocalAction(
                        kind="update",
                        item_type="file",
                        rel_path=rel_path,
                        tracked=tracked_entry,
                        current=current,
                    )
                )

        return self._filter_nested_local_actions(actions)

    def _apply_local_actions(self, actions: list[LocalAction]) -> None:
        folder_creates = sorted(
            [action for action in actions if action.item_type == "folder" and action.kind == "create"],
            key=lambda action: path_depth(action.rel_path),
        )
        folder_moves = sorted(
            [action for action in actions if action.item_type == "folder" and action.kind == "move"],
            key=lambda action: path_depth(action.rel_path),
        )
        file_moves = sorted(
            [action for action in actions if action.item_type == "file" and action.kind == "move"],
            key=lambda action: path_depth(action.rel_path),
        )
        file_updates = [action for action in actions if action.item_type == "file" and action.kind == "update"]
        file_creates = sorted(
            [action for action in actions if action.item_type == "file" and action.kind == "create"],
            key=lambda action: path_depth(action.rel_path),
        )
        file_deletes = sorted(
            [action for action in actions if action.item_type == "file" and action.kind == "delete"],
            key=lambda action: path_depth(action.rel_path),
            reverse=True,
        )
        folder_deletes = sorted(
            [action for action in actions if action.item_type == "folder" and action.kind == "delete"],
            key=lambda action: path_depth(action.rel_path),
            reverse=True,
        )

        for action in folder_creates:
            self._raise_if_paused()
            if self._apply_local_folder_create(action):
                self.progress.record_step("Created folder", action.rel_path, phase="Pushing local changes")

        for action in folder_moves:
            self._raise_if_paused()
            if self._apply_local_folder_move(action):
                self.progress.record_step("Renamed folder", action.rel_path, phase="Pushing local changes")

        for action in file_moves:
            self._raise_if_paused()
            if self._apply_local_file_move(action):
                self.progress.record_step("Moved", action.rel_path, phase="Pushing local changes")

        for action in file_updates:
            self._raise_if_paused()
            if self._apply_local_file_update(action):
                self.progress.record_step("Updated", action.rel_path, phase="Pushing local changes")

        for action in file_creates:
            self._raise_if_paused()
            if self._apply_local_file_create(action):
                self.progress.record_step("Uploaded", action.rel_path, phase="Pushing local changes")

        for action in file_deletes:
            self._raise_if_paused()
            if self._apply_local_file_delete(action):
                self.progress.record_step("Removed remote", action.rel_path, phase="Pushing local changes")

        for action in folder_deletes:
            self._raise_if_paused()
            if self._apply_local_folder_delete(action):
                self.progress.record_step("Deleted folder", action.rel_path, phase="Pushing local changes")

    def _apply_local_folder_create(self, action: LocalAction) -> bool:
        parent_remote_id = self._remote_parent_for_rel_path(action.rel_path)
        if parent_remote_id is None:
            self.logger.warning("Skipping folder create for %s because its parent is not tracked remotely.", action.rel_path)
            return False

        created = self.api.create_folder(parent_id=parent_remote_id, name=Path(action.rel_path).name)
        self._upsert_local_entry(
            rel_path=action.rel_path,
            item_type="folder",
            remote_id=created.folder_id,
            remote_parent_id=created.parent_id,
            remote_updated_on=created.updated_on,
            remote_size=None,
            remote_file_type_id=None,
        )
        self.logger.info("Created remote folder %s", action.rel_path)
        return True

    def _apply_local_folder_move(self, action: LocalAction) -> bool:
        if action.tracked is None or action.tracked.remote_id is None or action.previous_rel_path is None:
            return False

        old_parent = self._remote_parent_for_rel_path(action.previous_rel_path)
        new_parent = self._remote_parent_for_rel_path(action.rel_path)

        if old_parent == new_parent:
            updated = self.api.update_folder(action.tracked.remote_id, Path(action.rel_path).name)
            self.db.rename_prefix(action.previous_rel_path, action.rel_path)
            self._refresh_prefix_local_state(action.rel_path)
            root_entry = self.db.get_entry(action.rel_path)
            if root_entry:
                root_entry.remote_parent_id = updated.parent_id
                root_entry.remote_updated_on = updated.updated_on
                self.db.upsert_entry(root_entry)
            self.logger.info("Renamed remote folder %s -> %s", action.previous_rel_path, action.rel_path)
            return True

        # Cross-parent folder moves are not supported by Image Relay.
        # Revert the local folder back to its original location to keep local and remote in sync.
        msg = cross_parent_move_message(action.previous_rel_path, action.rel_path)
        self.logger.warning(
            "Reverting cross-parent folder move: %s -> %s",
            action.previous_rel_path,
            action.rel_path,
        )

        src = self.local_root / action.rel_path
        dst = self.local_root / action.previous_rel_path

        if dst.exists():
            dst = dst.with_name(dst.name + " (reverted)")

        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dst))
        except OSError as exc:
            self.logger.error(
                "Failed to revert cross-parent folder move %s -> %s: %s",
                action.rel_path,
                dst.relative_to(self.local_root),
                exc,
            )
            self.progress.state.last_error = msg
            self.progress.record_step("Blocked", action.rel_path, phase="Pushing local changes")
            return False

        self.progress.state.last_error = msg
        self.progress.record_step("Blocked", action.rel_path, phase="Pushing local changes")
        return False

    def _apply_local_folder_delete(self, action: LocalAction) -> bool:
        if action.tracked is None or action.tracked.remote_id is None:
            return False

        self.api.delete_folder(action.tracked.remote_id)
        self.db.delete_prefix(action.rel_path)
        self.logger.info("Deleted remote folder %s", action.rel_path)
        return True

    def _apply_local_file_create(self, action: LocalAction) -> bool:
        if action.current is None:
            return False

        parent_remote_id = self._remote_parent_for_rel_path(action.rel_path)
        if parent_remote_id is None:
            self.logger.warning("Skipping upload for %s because its parent folder is not tracked.", action.rel_path)
            return False

        if self.settings.default_file_type_id is None:
            self.logger.warning("Skipping upload for %s because default_file_type_id is not configured.", action.rel_path)
            return False

        asset_id = self.api.upload_new_asset(
            local_path=Path(action.current.abs_path),
            folder_id=parent_remote_id,
            file_type_id=self.settings.default_file_type_id,
        )

        self._upsert_local_entry(
            rel_path=action.rel_path,
            item_type="file",
            remote_id=asset_id,
            remote_parent_id=parent_remote_id,
            remote_updated_on=now_iso(),
            remote_size=action.current.size,
            remote_file_type_id=self.settings.default_file_type_id,
        )
        self.logger.info("Uploaded new asset %s", action.rel_path)
        return True

    def _apply_local_file_update(self, action: LocalAction) -> bool:
        if action.tracked is None or action.current is None or action.tracked.remote_id is None:
            return False

        self.api.upload_new_version(action.tracked.remote_id, Path(action.current.abs_path))
        self._upsert_local_entry(
            rel_path=action.rel_path,
            item_type="file",
            remote_id=action.tracked.remote_id,
            remote_parent_id=action.tracked.remote_parent_id,
            remote_updated_on=now_iso(),
            remote_size=action.current.size,
            remote_file_type_id=action.tracked.remote_file_type_id,
        )
        self.logger.info("Uploaded new version for %s", action.rel_path)
        return True

    def _apply_local_file_delete(self, action: LocalAction) -> bool:
        if action.tracked is None or action.tracked.remote_id is None:
            return False

        self.api.delete_file(action.tracked.remote_id)
        self.db.delete_entry(action.rel_path)
        self.db.delete_remote_aliases(action.tracked.remote_id)
        self.logger.info("Deleted remote file %s", action.rel_path)
        return True

    def _apply_local_file_move(self, action: LocalAction) -> bool:
        if (
            action.tracked is None
            or action.current is None
            or action.tracked.remote_id is None
            or action.previous_rel_path is None
        ):
            return False

        old_name = Path(action.previous_rel_path).name
        new_name = Path(action.rel_path).name
        old_parent = self._remote_parent_for_rel_path(action.previous_rel_path)
        new_parent = self._remote_parent_for_rel_path(action.rel_path)

        if old_name == new_name and new_parent is not None and old_parent != new_parent:
            moved = self.api.move_file(action.tracked.remote_id, [new_parent])
            self.db.delete_entry(action.previous_rel_path)
            self._upsert_local_entry(
                rel_path=action.rel_path,
                item_type="file",
                remote_id=moved.file_id,
                remote_parent_id=new_parent,
                remote_updated_on=moved.updated_on,
                remote_size=action.current.size,
                remote_file_type_id=moved.file_type_id or action.tracked.remote_file_type_id,
            )
            self.logger.info("Moved remote file %s -> %s", action.previous_rel_path, action.rel_path)
            return True

        self.logger.info("Re-uploading renamed file %s -> %s", action.previous_rel_path, action.rel_path)
        create_action = LocalAction(
            kind="create",
            item_type="file",
            rel_path=action.rel_path,
            current=action.current,
        )
        if not self._apply_local_file_create(create_action):
            return False

        replacement = self.db.get_entry(action.rel_path)
        if replacement is None or replacement.remote_id is None:
            self.logger.warning(
                "Skipping delete of original remote file %s because the replacement upload did not complete.",
                action.previous_rel_path,
            )
            return False

        self.api.delete_file(action.tracked.remote_id)
        self.db.delete_entry(action.previous_rel_path)
        self.db.delete_remote_aliases(action.tracked.remote_id)
        return True

    def _apply_remote_folder_create(self, folder: RemoteFolder) -> None:
        local_path = self.local_root / folder.rel_path
        if local_path.exists() and not local_path.is_dir():
            self._backup_path(local_path)
        local_path.mkdir(parents=True, exist_ok=True)
        self._upsert_local_entry(
            rel_path=folder.rel_path,
            item_type="folder",
            remote_id=folder.folder_id,
            remote_parent_id=folder.parent_id,
            remote_updated_on=folder.updated_on,
            remote_size=None,
            remote_file_type_id=None,
        )
        self.logger.info("Created local folder %s", folder.rel_path)

    def _apply_remote_folder_update(self, folder: RemoteFolder, existing: TrackedEntry) -> None:
        old_path = self.local_root / existing.rel_path
        new_path = self.local_root / folder.rel_path

        if old_path != new_path:
            if new_path.exists():
                self._backup_path(new_path)
            new_path.parent.mkdir(parents=True, exist_ok=True)
            if old_path.exists():
                old_path.rename(new_path)
            else:
                new_path.mkdir(parents=True, exist_ok=True)

        self.db.rename_prefix(existing.rel_path, folder.rel_path)
        self._refresh_prefix_local_state(folder.rel_path)

        root_entry = self.db.get_entry(folder.rel_path)
        if root_entry:
            root_entry.remote_id = folder.folder_id
            root_entry.remote_parent_id = folder.parent_id
            root_entry.remote_updated_on = folder.updated_on
            self.db.upsert_entry(root_entry)
        else:
            self._upsert_local_entry(
                rel_path=folder.rel_path,
                item_type="folder",
                remote_id=folder.folder_id,
                remote_parent_id=folder.parent_id,
                remote_updated_on=folder.updated_on,
                remote_size=None,
                remote_file_type_id=None,
            )

        self.logger.info("Renamed local folder %s -> %s", existing.rel_path, folder.rel_path)

    def _apply_remote_folder_delete(self, entry: TrackedEntry, changed_paths: set[str]) -> None:
        local_path = self.local_root / entry.rel_path
        if self._path_has_conflict(entry.rel_path, changed_paths):
            self._backup_path(local_path)
        else:
            self._remove_path(local_path)
        self.db.delete_prefix(entry.rel_path)
        self.logger.info("Deleted local folder %s", entry.rel_path)

    def _apply_remote_file_sync(self, remote_file: RemoteFile, changed_paths: set[str]) -> None:
        existing = self.db.find_canonical_by_remote_id("file", remote_file.file_id)
        existing_aliases = sorted(alias.rel_path for alias in self.db.list_aliases_for_remote(remote_file.file_id))

        if (
            existing is not None
            and existing.rel_path == remote_file.canonical_rel_path
            and existing.remote_updated_on == remote_file.updated_on
            and existing.remote_size == remote_file.size
            and existing_aliases == sorted(remote_file.alias_rel_paths)
        ):
            self._sync_aliases(remote_file)
            return

        target_path = self.local_root / remote_file.canonical_rel_path
        target_path.parent.mkdir(parents=True, exist_ok=True)

        if target_path.exists() and (
            existing is None or existing.rel_path != remote_file.canonical_rel_path
        ):
            self._backup_path(target_path)

        if existing is not None and existing.rel_path != remote_file.canonical_rel_path:
            self._remove_path(self.local_root / existing.rel_path)
            self.db.delete_entry(existing.rel_path)

        if existing is not None and self._path_has_conflict(existing.rel_path, changed_paths):
            self._backup_path(target_path)

        temp_path = target_path.parent / f".{target_path.name}{TEMP_MARKER}"
        if temp_path.exists():
            temp_path.unlink()

        self.api.download_asset(remote_file.file_id, temp_path, purpose=self.settings.download_purpose)
        os.replace(temp_path, target_path)

        self._upsert_local_entry(
            rel_path=remote_file.canonical_rel_path,
            item_type="file",
            remote_id=remote_file.file_id,
            remote_parent_id=self._remote_parent_for_rel_path(remote_file.canonical_rel_path),
            remote_updated_on=remote_file.updated_on,
            remote_size=remote_file.size,
            remote_file_type_id=remote_file.file_type_id,
        )
        self._sync_aliases(remote_file)
        self.logger.info("Downloaded remote file %s", remote_file.canonical_rel_path)

    def _apply_remote_file_delete(self, entry: TrackedEntry, changed_paths: set[str]) -> None:
        local_path = self.local_root / entry.rel_path
        if self._path_has_conflict(entry.rel_path, changed_paths):
            self._backup_path(local_path)
        else:
            self._remove_path(local_path)

        aliases = self.db.list_aliases_for_remote(entry.remote_id or -1)
        for alias in aliases:
            self._remove_path(self.local_root / alias.rel_path)
            self.db.delete_entry(alias.rel_path)

        self.db.delete_entry(entry.rel_path)
        self.logger.info("Deleted local file %s", entry.rel_path)

    def _sync_aliases(self, remote_file: RemoteFile) -> None:
        canonical_path = self.local_root / remote_file.canonical_rel_path
        desired_aliases = set(remote_file.alias_rel_paths)
        existing_aliases = {alias.rel_path: alias for alias in self.db.list_aliases_for_remote(remote_file.file_id)}

        for stale_rel_path, _alias in existing_aliases.items():
            if stale_rel_path not in desired_aliases:
                self._remove_path(self.local_root / stale_rel_path)
                self.db.delete_entry(stale_rel_path)

        for alias_rel_path in sorted(desired_aliases):
            alias_path = self.local_root / alias_rel_path
            alias_path.parent.mkdir(parents=True, exist_ok=True)

            if alias_path.exists() or alias_path.is_symlink():
                if alias_path.is_symlink():
                    alias_path.unlink()
                else:
                    self._backup_path(alias_path)

            relative_target = os.path.relpath(canonical_path, start=alias_path.parent)
            alias_path.symlink_to(relative_target)
            stat_result = alias_path.lstat()
            self.db.upsert_entry(
                TrackedEntry(
                    rel_path=alias_rel_path,
                    item_type="file",
                    remote_id=remote_file.file_id,
                    remote_parent_id=self._remote_parent_for_rel_path(alias_rel_path),
                    remote_updated_on=remote_file.updated_on,
                    remote_size=remote_file.size,
                    remote_file_type_id=remote_file.file_type_id,
                    local_inode=stat_result.st_ino,
                    local_mtime=stat_result.st_mtime,
                    local_size=0,
                    is_alias=True,
                    canonical_rel_path=remote_file.canonical_rel_path,
                )
            )

    def _detect_tracked_local_changes(
        self,
        entries: list[TrackedEntry],
        scan: dict[str, ScannedEntry],
    ) -> LocalChangeSet:
        changes = LocalChangeSet()

        for entry in entries:
            if entry.is_alias or not entry.rel_path:
                continue

            current = scan.get(entry.rel_path)
            if current is None:
                changes.changed_paths.add(entry.rel_path)
                if entry.remote_id is not None:
                    changes.changed_remote_ids.add(entry.remote_id)
                continue

            if entry.is_file and self._file_differs(entry, current):
                changes.changed_paths.add(entry.rel_path)
                if entry.remote_id is not None:
                    changes.changed_remote_ids.add(entry.remote_id)

        return changes

    def _scan_local(self) -> dict[str, ScannedEntry]:
        snapshot: dict[str, ScannedEntry] = {}

        def walk(directory: Path, prefix: str = "") -> None:
            for child in directory.iterdir():
                if self.should_ignore_local_name(child.name):
                    continue
                if child.is_symlink():
                    continue

                rel_path = normalize_rel_path(str(PurePosixPath(prefix) / child.name))
                stat_result = child.stat()

                if child.is_dir():
                    snapshot[rel_path] = ScannedEntry(
                        rel_path=rel_path,
                        abs_path=str(child),
                        item_type="folder",
                        inode=stat_result.st_ino,
                        mtime=stat_result.st_mtime,
                        size=0,
                    )
                    walk(child, rel_path)
                else:
                    snapshot[rel_path] = ScannedEntry(
                        rel_path=rel_path,
                        abs_path=str(child),
                        item_type="file",
                        inode=stat_result.st_ino,
                        mtime=stat_result.st_mtime,
                        size=stat_result.st_size,
                    )

        walk(self.local_root)
        return snapshot

    def should_ignore_local_name(self, name: str) -> bool:
        return (
            name in IGNORED_EXACT_NAMES
            or name.endswith(TEMP_MARKER)
            or CONFLICT_MARKER in name
        )

    def _descendant_folder_ids(
        self,
        folders_by_id: dict[int, RemoteFolder],
        root_folder_id: int,
    ) -> set[int]:
        children_by_parent: dict[int | None, list[int]] = defaultdict(list)
        for folder in folders_by_id.values():
            children_by_parent[folder.parent_id].append(folder.folder_id)

        descendants: set[int] = set()
        stack = [root_folder_id]
        while stack:
            folder_id = stack.pop()
            if folder_id in descendants:
                continue
            descendants.add(folder_id)
            stack.extend(children_by_parent.get(folder_id, []))
        return descendants

    def _relative_folder_path(
        self,
        folder_id: int,
        folders_by_id: dict[int, RemoteFolder],
        root_folder_id: int,
    ) -> str:
        parts: list[str] = []
        current_id = folder_id

        while current_id != root_folder_id:
            folder = folders_by_id[current_id]
            parts.append(folder.name)
            parent_id = folder.parent_id
            if parent_id is None:
                break
            current_id = parent_id

        return normalize_rel_path("/".join(reversed(parts)))

    def _compact_folder_deletes(self, entries: Iterable[TrackedEntry]) -> list[TrackedEntry]:
        selected: list[TrackedEntry] = []
        for entry in sorted(entries, key=lambda item: path_depth(item.rel_path)):
            if any(is_same_or_descendant(entry.rel_path, chosen.rel_path) for chosen in selected):
                continue
            selected.append(entry)
        return sorted(selected, key=lambda item: path_depth(item.rel_path), reverse=True)

    @staticmethod
    def _count_remote_actions(plan: RemotePlan) -> int:
        return (
            len(plan.folder_creates)
            + len(plan.folder_updates)
            + len(plan.folder_deletes)
            + len(plan.file_creates)
            + len(plan.file_updates)
            + len(plan.file_deletes)
        )

    def _pause_phase(self, pause_state: SyncPauseState) -> str:
        return "Syncing paused until resumed" if pause_state.until is None else "Syncing paused"

    def _raise_if_paused(self) -> None:
        pause_state = load_pause_state(self.db)
        if not pause_state.paused:
            return
        self.progress.pause(self._pause_phase(pause_state))
        self.progress.update_next_remote_poll(pause_state.remaining_seconds())
        raise SyncPausedError(pause_state)

    def _retry_delay_seconds(self) -> float:
        return min(max(self.settings.poll_interval_seconds, 5), 30)

    def _file_differs(self, tracked: TrackedEntry, current: ScannedEntry) -> bool:
        if tracked.local_inode is None or tracked.local_mtime is None or tracked.local_size is None:
            return True
        return (
            tracked.local_inode != current.inode
            or tracked.local_size != current.size
            or abs(tracked.local_mtime - current.mtime) > 0.0001
        )

    def _filter_nested_local_actions(self, actions: list[LocalAction]) -> list[LocalAction]:
        folder_deletes = [
            action.rel_path
            for action in actions
            if action.item_type == "folder" and action.kind == "delete"
        ]
        folder_moves = [
            (action.previous_rel_path or "", action.rel_path)
            for action in actions
            if action.item_type == "folder" and action.kind == "move"
        ]

        filtered: list[LocalAction] = []
        for action in actions:
            if action.item_type == "folder" and action.kind in {"delete", "move"}:
                filtered.append(action)
                continue

            if any(is_same_or_descendant(action.rel_path, prefix) for prefix in folder_deletes):
                continue

            skip_for_move = False
            for old_prefix, new_prefix in folder_moves:
                if old_prefix and action.previous_rel_path and is_same_or_descendant(action.previous_rel_path, old_prefix):
                    skip_for_move = True
                    break
                if new_prefix and is_same_or_descendant(action.rel_path, new_prefix):
                    skip_for_move = True
                    break
            if skip_for_move:
                continue

            filtered.append(action)

        return filtered

    def _remote_parent_for_rel_path(self, rel_path: str) -> int | None:
        parent_rel_path = normalize_rel_path(str(PurePosixPath(rel_path).parent))
        if parent_rel_path in {"", "."}:
            return self.settings.remote_root_folder_id

        parent_entry = self.db.get_entry(parent_rel_path)
        if parent_entry and parent_entry.is_folder:
            return parent_entry.remote_id
        return None

    def _upsert_local_entry(
        self,
        *,
        rel_path: str,
        item_type: str,
        remote_id: int | None,
        remote_parent_id: int | None,
        remote_updated_on: str | None,
        remote_size: int | None,
        remote_file_type_id: int | None,
    ) -> None:
        local_path = self.local_root / rel_path
        if not local_path.exists() and not local_path.is_symlink():
            local_inode = None
            local_mtime = None
            local_size = None
        else:
            stat_result = local_path.lstat() if local_path.is_symlink() else local_path.stat()
            local_inode = stat_result.st_ino
            local_mtime = stat_result.st_mtime
            local_size = 0 if item_type == "folder" else stat_result.st_size

        self.db.upsert_entry(
            TrackedEntry(
                rel_path=rel_path,
                item_type=item_type,
                remote_id=remote_id,
                remote_parent_id=remote_parent_id,
                remote_updated_on=remote_updated_on,
                remote_size=remote_size,
                remote_file_type_id=remote_file_type_id,
                local_inode=local_inode,
                local_mtime=local_mtime,
                local_size=local_size,
            )
        )

    def _refresh_prefix_local_state(self, prefix: str) -> None:
        for entry in self.db.list_entries():
            if entry.is_alias or not is_same_or_descendant(entry.rel_path, prefix):
                continue
            local_path = self.local_root / entry.rel_path
            if not local_path.exists():
                continue
            stat_result = local_path.stat()
            entry.local_inode = stat_result.st_ino
            entry.local_mtime = stat_result.st_mtime
            entry.local_size = 0 if entry.is_folder else stat_result.st_size
            self.db.upsert_entry(entry)

    def _path_has_conflict(self, rel_path: str, changed_paths: set[str]) -> bool:
        return any(is_same_or_descendant(changed_path, rel_path) for changed_path in changed_paths)

    def _backup_path(self, path: Path) -> Path | None:
        if not path.exists() and not path.is_symlink():
            return None

        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        if path.is_dir():
            candidate = path.with_name(f"{path.name} ({CONFLICT_MARKER} {timestamp})")
        else:
            candidate = path.with_name(f"{path.stem} ({CONFLICT_MARKER} {timestamp}){path.suffix}")

        counter = 1
        while candidate.exists():
            if path.is_dir():
                candidate = path.with_name(f"{path.name} ({CONFLICT_MARKER} {timestamp}-{counter})")
            else:
                candidate = path.with_name(
                    f"{path.stem} ({CONFLICT_MARKER} {timestamp}-{counter}){path.suffix}"
                )
            counter += 1

        path.rename(candidate)
        self.logger.warning("Backed up conflicting local path %s -> %s", path, candidate)
        return candidate

    def _remove_path(self, path: Path) -> None:
        if path.is_symlink() or path.is_file():
            path.unlink(missing_ok=True)
        elif path.is_dir():
            shutil.rmtree(path, ignore_errors=True)
