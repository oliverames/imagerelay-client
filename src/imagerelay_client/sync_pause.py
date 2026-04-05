from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import UTC, datetime, time, timedelta
from typing import Any

from .database import Database


SYNC_PAUSE_KEY = "sync_pause"
TOMORROW_RESUME_HOUR = 9


@dataclass(slots=True)
class SyncPauseState:
    paused: bool = False
    until: str | None = None
    updated_at: str | None = None

    def resume_at(self) -> datetime | None:
        return _parse_iso(self.until)

    def is_active(self, now: datetime | None = None) -> bool:
        if not self.paused:
            return False
        resume_at = self.resume_at()
        if resume_at is None:
            return True
        return resume_at > _coerce_now(now)

    def remaining_seconds(self, now: datetime | None = None) -> int | None:
        resume_at = self.resume_at()
        if resume_at is None:
            return None
        delta = resume_at - _coerce_now(now)
        return max(int(delta.total_seconds()), 0)


class SyncPausedError(RuntimeError):
    def __init__(self, pause_state: SyncPauseState) -> None:
        self.pause_state = pause_state
        super().__init__(describe_pause_state(pause_state))


def sync_pause_to_dict(state: SyncPauseState) -> dict[str, Any]:
    return asdict(state)


def sync_pause_from_dict(raw: dict[str, Any] | None) -> SyncPauseState:
    if not isinstance(raw, dict):
        return SyncPauseState()
    return SyncPauseState(
        paused=bool(raw.get("paused", False)),
        until=_optional_string(raw.get("until")),
        updated_at=_optional_string(raw.get("updated_at")),
    )


def load_pause_state(db: Database, *, now: datetime | None = None) -> SyncPauseState:
    state = sync_pause_from_dict(db.get_state_json(SYNC_PAUSE_KEY, None))
    if state.paused and not state.is_active(now):
        state = clear_pause_state(db, now=now)
    return state


def set_pause_state(db: Database, until: datetime | None, *, now: datetime | None = None) -> SyncPauseState:
    current = _coerce_now(now)
    normalized_until = until.astimezone(UTC).replace(microsecond=0).isoformat() if until else None
    state = SyncPauseState(paused=True, until=normalized_until, updated_at=current.replace(microsecond=0).isoformat())
    db.set_state_json(SYNC_PAUSE_KEY, sync_pause_to_dict(state))
    return state


def clear_pause_state(db: Database, *, now: datetime | None = None) -> SyncPauseState:
    current = _coerce_now(now)
    state = SyncPauseState(paused=False, until=None, updated_at=current.replace(microsecond=0).isoformat())
    db.set_state_json(SYNC_PAUSE_KEY, sync_pause_to_dict(state))
    return state


def pause_deadline_for_choice(choice: str, *, now: datetime | None = None) -> datetime | None:
    current_local = _coerce_local_now(now)
    if choice == "30m":
        return current_local + timedelta(minutes=30)
    if choice == "1h":
        return current_local + timedelta(hours=1)
    if choice == "tomorrow":
        next_day = current_local.date() + timedelta(days=1)
        return datetime.combine(next_day, time(hour=TOMORROW_RESUME_HOUR), tzinfo=current_local.tzinfo)
    if choice == "indefinite":
        return None
    raise ValueError(f"Unsupported pause choice: {choice}")


def describe_pause_state(state: SyncPauseState) -> str:
    if not state.paused:
        return "Syncing is active."
    if state.until is None:
        return "Syncing is paused until you resume it."
    return f"Syncing is paused until {format_pause_deadline(state.until)}."


def pause_menu_label(state: SyncPauseState) -> str:
    if not state.paused:
        return "Not paused"
    if state.until is None:
        return "Until resumed"
    return f"Until {format_pause_deadline(state.until, include_date=False)}"


def format_pause_deadline(value: str | None, *, include_date: bool = True) -> str:
    timestamp = _parse_iso(value)
    if timestamp is None:
        return "resume"
    if include_date:
        return timestamp.astimezone().strftime("%b %d, %Y %I:%M %p")
    return timestamp.astimezone().strftime("%I:%M %p").lstrip("0")


def _optional_string(value: object) -> str | None:
    if value in {None, ""}:
        return None
    return str(value)


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        timestamp = datetime.fromisoformat(value)
    except ValueError:
        return None
    if timestamp.tzinfo is None:
        return timestamp.replace(tzinfo=UTC)
    return timestamp.astimezone(UTC)


def _coerce_now(now: datetime | None) -> datetime:
    if now is None:
        return datetime.now(UTC)
    if now.tzinfo is None:
        return now.replace(tzinfo=UTC)
    return now.astimezone(UTC)


def _coerce_local_now(now: datetime | None) -> datetime:
    if now is None:
        return datetime.now().astimezone()
    if now.tzinfo is None:
        return now.replace(tzinfo=UTC).astimezone()
    return now
