from __future__ import annotations

import math
import time
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING, Any

from .models import now_iso

if TYPE_CHECKING:
    from .database import Database


SYNC_PROGRESS_KEY = "sync_progress"
RECENT_ACTIVITY_LIMIT = 6


@dataclass(slots=True)
class SyncActivityEntry:
    action: str
    rel_path: str
    when: str


@dataclass(slots=True)
class SyncProgressState:
    state: str = "idle"
    phase: str = "Idle"
    started_at: str | None = None
    updated_at: str | None = None
    completed_steps: int = 0
    total_steps: int = 0
    eta_seconds: int | None = None
    current_item: str | None = None
    last_error: str | None = None
    last_remote_poll_at: str | None = None
    next_remote_poll_at: str | None = None
    recent_activity: list[SyncActivityEntry] = field(default_factory=list)


def sync_progress_to_dict(state: SyncProgressState) -> dict[str, Any]:
    return asdict(state)


def sync_progress_from_dict(raw: dict[str, Any] | None) -> SyncProgressState:
    if not isinstance(raw, dict):
        return SyncProgressState()

    activities: list[SyncActivityEntry] = []
    for item in raw.get("recent_activity", []):
        if not isinstance(item, dict):
            continue
        activities.append(
            SyncActivityEntry(
                action=str(item.get("action", "")),
                rel_path=str(item.get("rel_path", "")),
                when=str(item.get("when", "")),
            )
        )

    return SyncProgressState(
        state=str(raw.get("state", "idle")),
        phase=str(raw.get("phase", "Idle")),
        started_at=_optional_string(raw.get("started_at")),
        updated_at=_optional_string(raw.get("updated_at")),
        completed_steps=_optional_int(raw.get("completed_steps")) or 0,
        total_steps=_optional_int(raw.get("total_steps")) or 0,
        eta_seconds=_optional_int(raw.get("eta_seconds")),
        current_item=_optional_string(raw.get("current_item")),
        last_error=_optional_string(raw.get("last_error")),
        last_remote_poll_at=_optional_string(raw.get("last_remote_poll_at")),
        next_remote_poll_at=_optional_string(raw.get("next_remote_poll_at")),
        recent_activity=activities,
    )


class SyncProgressTracker:
    def __init__(self, db: Database) -> None:
        self.db = db
        self.state = self.load()
        self._started_monotonic: float | None = None

    def load(self) -> SyncProgressState:
        return sync_progress_from_dict(self.db.get_state_json(SYNC_PROGRESS_KEY, None))

    def begin_sync(self, phase: str) -> None:
        previous = self.load()
        started_at = now_iso()
        self._started_monotonic = time.monotonic()
        self.state = SyncProgressState(
            state="syncing",
            phase=phase,
            started_at=started_at,
            updated_at=started_at,
            completed_steps=0,
            total_steps=0,
            eta_seconds=None,
            current_item=None,
            last_error=None,
            last_remote_poll_at=previous.last_remote_poll_at,
            next_remote_poll_at=previous.next_remote_poll_at,
            recent_activity=previous.recent_activity,
        )
        self._save()

    def set_phase(self, phase: str, current_item: str | None = None) -> None:
        self.state.phase = phase
        self.state.current_item = current_item
        self.state.updated_at = now_iso()
        self._update_eta()
        self._save()

    def extend_total(self, steps: int) -> None:
        if steps <= 0:
            return
        self.state.total_steps += steps
        self.state.updated_at = now_iso()
        self._update_eta()
        self._save()

    def record_remote_poll(self) -> None:
        timestamp = now_iso()
        self.state.last_remote_poll_at = timestamp
        self.state.updated_at = timestamp
        self._save()

    def record_step(self, action: str, rel_path: str, *, phase: str | None = None) -> None:
        if phase is not None:
            self.state.phase = phase

        self.state.completed_steps += 1
        if self.state.total_steps and self.state.completed_steps > self.state.total_steps:
            self.state.total_steps = self.state.completed_steps

        timestamp = now_iso()
        self.state.updated_at = timestamp
        self.state.current_item = rel_path
        self.state.recent_activity = [
            SyncActivityEntry(action=action, rel_path=rel_path, when=timestamp),
            *self.state.recent_activity,
        ][:RECENT_ACTIVITY_LIMIT]
        self._update_eta()
        self._save()

    def update_next_remote_poll(self, seconds_from_now: float | None) -> None:
        if seconds_from_now is None:
            self.state.next_remote_poll_at = None
        else:
            next_poll = datetime.now(UTC) + timedelta(seconds=max(seconds_from_now, 0))
            self.state.next_remote_poll_at = next_poll.replace(microsecond=0).isoformat()
        self.state.updated_at = now_iso()
        self._save()

    def finish(self, phase: str) -> None:
        self.state.state = "idle"
        self.state.phase = phase
        self.state.current_item = None
        self.state.last_error = None
        self.state.eta_seconds = None
        if self.state.total_steps:
            self.state.completed_steps = self.state.total_steps
        self.state.updated_at = now_iso()
        self._save()
        self._started_monotonic = None

    def pause(self, phase: str) -> None:
        previous = self.load()
        self.state = SyncProgressState(
            state="paused",
            phase=phase,
            started_at=previous.started_at,
            updated_at=now_iso(),
            completed_steps=previous.completed_steps,
            total_steps=previous.total_steps,
            eta_seconds=None,
            current_item=None,
            last_error=None,
            last_remote_poll_at=previous.last_remote_poll_at,
            next_remote_poll_at=previous.next_remote_poll_at,
            recent_activity=previous.recent_activity,
        )
        self._save()
        self._started_monotonic = None

    def fail(self, error: Exception | str) -> None:
        self.state.state = "error"
        self.state.phase = "Sync Failed"
        self.state.current_item = None
        self.state.last_error = str(error)
        self.state.eta_seconds = None
        self.state.updated_at = now_iso()
        self._save()
        self._started_monotonic = None

    def _update_eta(self) -> None:
        if (
            self.state.state != "syncing"
            or self._started_monotonic is None
            or self.state.total_steps <= 0
            or self.state.completed_steps <= 0
            or self.state.completed_steps >= self.state.total_steps
        ):
            self.state.eta_seconds = None
            return

        elapsed = max(time.monotonic() - self._started_monotonic, 0.001)
        steps_per_second = self.state.completed_steps / elapsed
        if steps_per_second <= 0:
            self.state.eta_seconds = None
            return

        remaining_steps = self.state.total_steps - self.state.completed_steps
        self.state.eta_seconds = max(int(math.ceil(remaining_steps / steps_per_second)), 1)

    def _save(self) -> None:
        self.db.set_state_json(SYNC_PROGRESS_KEY, sync_progress_to_dict(self.state))


def _optional_string(value: object) -> str | None:
    if value in {None, ""}:
        return None
    return str(value)


def _optional_int(value: object) -> int | None:
    if value in {None, ""}:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
