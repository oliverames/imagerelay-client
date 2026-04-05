from __future__ import annotations

import fcntl
import os
import signal
import subprocess
import sys
import time
from contextlib import contextmanager

from .api import ImageRelayApiClient
from .appdirs import database_path, ensure_app_dirs, lock_path, log_path, pid_path
from .config import ConfigStore, ensure_sync_ready
from .database import Database
from .logging_utils import configure_logging
from .sync_engine import SyncEngine


class DaemonLockError(RuntimeError):
    """Raised when another daemon process already holds the runtime lock."""


_daemon_lock_handle = None


def build_runtime(verbose: bool = False) -> tuple[Database, SyncEngine]:
    logger = configure_logging(verbose=verbose)
    settings = ConfigStore().load()
    ensure_sync_ready(settings)

    database = Database(database_path())
    api = ImageRelayApiClient(settings=settings, logger=logger)
    engine = SyncEngine(settings=settings, api=api, db=database, logger=logger)
    return database, engine


def run_daemon(verbose: bool = False) -> None:
    with daemon_lock():
        database, engine = build_runtime(verbose=verbose)
        try:
            engine.run_forever()
        finally:
            database.close()


def run_sync_once(verbose: bool = False) -> None:
    database, engine = build_runtime(verbose=verbose)
    try:
        engine.sync_once()
        engine.progress.update_next_remote_poll(None)
    finally:
        database.close()


def daemon_status() -> tuple[bool, int | None]:
    pid = read_pid()
    if pid is None:
        return False, None
    running = is_running(pid)
    if not running:
        pid_path().unlink(missing_ok=True)
    return running, pid if running else None


def start_daemon(timeout: float = 30.0) -> int:
    running, pid = daemon_status()
    if running and pid is not None:
        return pid

    ensure_sync_ready(ConfigStore().load())
    ensure_app_dirs()
    with log_path().open("a") as log_handle:
        process = subprocess.Popen(
            [sys.executable, "-m", "imagerelay_client", "daemon", "run"],
            stdout=log_handle,
            stderr=log_handle,
            start_new_session=True,
        )

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        running, daemon_pid = daemon_status()
        if running and daemon_pid is not None:
            return daemon_pid
        if process.poll() is not None:
            break
        time.sleep(0.1)

    failure_detail = _daemon_start_failure_detail(process.returncode)
    raise RuntimeError(failure_detail)


def stop_daemon(timeout: float = 10.0) -> bool:
    pid = read_pid()
    if pid is None:
        return False

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pid_path().unlink(missing_ok=True)
        return False

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not is_running(pid):
            pid_path().unlink(missing_ok=True)
            return True
        time.sleep(0.2)

    return False


def read_pid() -> int | None:
    try:
        value = pid_path().read_text().strip()
    except FileNotFoundError:
        return None

    if not value:
        return None

    try:
        return int(value)
    except ValueError:
        return None


def is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


@contextmanager
def daemon_lock():
    acquire_daemon_lock()
    try:
        pid_path().write_text(f"{os.getpid()}\n")
        yield
    finally:
        pid_path().unlink(missing_ok=True)
        release_daemon_lock()


def acquire_daemon_lock() -> None:
    global _daemon_lock_handle

    if _daemon_lock_handle is not None:
        return

    ensure_app_dirs()
    handle = lock_path().open("a+")

    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        handle.close()
        raise DaemonLockError("Another ImageRelay daemon is already running.") from exc

    handle.seek(0)
    handle.truncate()
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    _daemon_lock_handle = handle


def release_daemon_lock() -> None:
    global _daemon_lock_handle

    if _daemon_lock_handle is None:
        return

    fcntl.flock(_daemon_lock_handle.fileno(), fcntl.LOCK_UN)
    _daemon_lock_handle.close()
    _daemon_lock_handle = None


def _daemon_start_failure_detail(return_code: int | None) -> str:
    headline = "The daemon did not become ready before the timeout expired."
    if return_code is not None:
        headline = f"The daemon exited before it became ready (exit code {return_code})."

    tail = _read_log_tail()
    if not tail:
        return headline
    return f"{headline}\nRecent log output:\n{tail}"


def _read_log_tail(max_lines: int = 20) -> str:
    try:
        lines = log_path().read_text(errors="replace").splitlines()
    except FileNotFoundError:
        return ""
    return "\n".join(lines[-max_lines:])
