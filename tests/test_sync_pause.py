from __future__ import annotations

import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import bootstrap
from imagerelay_client.database import Database
from imagerelay_client.sync_pause import (
    SyncPauseState,
    clear_pause_state,
    describe_pause_state,
    load_pause_state,
    pause_deadline_for_choice,
    set_pause_state,
)


class SyncPauseTests(unittest.TestCase):
    def test_pause_deadline_for_tomorrow_uses_9am_local_time(self) -> None:
        now = datetime(2026, 4, 2, 17, 45, tzinfo=ZoneInfo("America/New_York"))

        deadline = pause_deadline_for_choice("tomorrow", now=now)

        self.assertEqual(deadline, datetime(2026, 4, 3, 9, 0, tzinfo=ZoneInfo("America/New_York")))

    def test_load_pause_state_clears_expired_pause(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Database(Path(tmp) / "state.db")
            try:
                set_pause_state(db, datetime(2026, 4, 2, 12, 0, tzinfo=UTC), now=datetime(2026, 4, 2, 11, 0, tzinfo=UTC))

                state = load_pause_state(db, now=datetime(2026, 4, 2, 12, 1, tzinfo=UTC))

                self.assertFalse(state.paused)
                self.assertIsNone(state.until)
            finally:
                db.close()

    def test_describe_pause_state_handles_indefinite_and_active_states(self) -> None:
        self.assertEqual(
            describe_pause_state(SyncPauseState(paused=True, until=None)),
            "Syncing is paused until you resume it.",
        )
        self.assertEqual(
            describe_pause_state(SyncPauseState(paused=False, until=None)),
            "Syncing is active.",
        )

    def test_clear_pause_state_unpauses_sync(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Database(Path(tmp) / "state.db")
            try:
                set_pause_state(db, None)

                state = clear_pause_state(db)

                self.assertFalse(state.paused)
                self.assertIsNone(state.until)
            finally:
                db.close()


if __name__ == "__main__":
    unittest.main()
