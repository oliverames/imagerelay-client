from __future__ import annotations

import importlib.metadata
import json
import sys
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any, NoReturn

import click

from .appdirs import config_path, database_path
from .api import ImageRelayApiClient, ImageRelayApiError
from .autostart import AutoStart, AutoStartError
from .config import ConfigStore, SyncConfigurationError, mask_api_key
from .database import Database
from .daemon import (
    DaemonLockError,
    daemon_status,
    run_daemon,
    run_sync_once,
    start_daemon,
    stop_daemon,
)
from .gui import load_menu_status, run_menu_bar_app
from .logging_utils import configure_logging
from .simulator import MockImageRelayServer, MockImageRelayState, run_demo, seed_demo_state
from .sync_pause import (
    SyncPausedError,
    clear_pause_state,
    describe_pause_state,
    pause_deadline_for_choice,
    set_pause_state,
)
from .user_messages import user_message_for_error


def _get_version() -> str:
    try:
        return importlib.metadata.version("imagerelay-client")
    except importlib.metadata.PackageNotFoundError:
        return "0.1.0"


def _echo_success(message: str) -> None:
    click.echo(click.style(message, fg="green"))


def _echo_warning(message: str) -> None:
    click.echo(click.style(message, fg="yellow"))


def _echo_error(message: str) -> None:
    click.echo(click.style("Error: ", fg="red") + message)


def _fatal_error(exc: Exception) -> NoReturn:
    _echo_error(user_message_for_error(exc))
    sys.exit(1)


def _human_status_label(snapshot) -> str:
    if snapshot.paused:
        return "Paused"
    if snapshot.sync_state == "error":
        return "Error"
    if snapshot.running and snapshot.sync_state == "syncing":
        return "Syncing"
    if snapshot.running:
        return "Up to Date"
    return "Engine Not Running"


def _status_color(snapshot) -> str:
    if snapshot.sync_state == "error":
        return "red"
    if snapshot.paused:
        return "yellow"
    if snapshot.running:
        return "green"
    return "yellow"


def _human_sync_mode(snapshot) -> str:
    if snapshot.sync_upload and snapshot.sync_download:
        return "Two-Way"
    if snapshot.sync_download:
        return "Download Only"
    if snapshot.sync_upload:
        return "Upload Only"
    return "Disabled"


BOOLEAN_VALUES = {
    "1": True,
    "true": True,
    "yes": True,
    "on": True,
    "0": False,
    "false": False,
    "no": False,
    "off": False,
}
NULL_VALUES = {"", "clear", "none", "null", "unset"}


def _coerce_value(key: str, raw: str) -> Any:
    int_keys = {
        "remote_root_folder_id",
        "default_file_type_id",
        "poll_interval_seconds",
        "upload_chunk_size",
        "version_chunk_size",
        "request_timeout_seconds",
    }
    bool_keys = {"sync_download", "sync_upload"}
    nullable_keys = {"api_key", "subdomain", "api_base_url", "remote_root_folder_id", "default_file_type_id"}
    normalized = raw.strip()

    if key in nullable_keys and normalized.lower() in NULL_VALUES:
        return None
    if key in int_keys:
        try:
            value = int(normalized)
        except ValueError as exc:
            raise click.ClickException(f"`{key}` must be a whole number.") from exc
        if value < 1:
            raise click.ClickException(f"`{key}` must be 1 or greater.")
        return value
    if key in bool_keys:
        bool_value = BOOLEAN_VALUES.get(normalized.lower())
        if bool_value is None:
            raise click.ClickException(
                f"`{key}` must be one of: true, false, yes, no, on, off, 1, 0."
            )
        return bool_value
    if key == "local_root":
        if not normalized:
            raise click.ClickException("`local_root` cannot be empty.")
        return str(Path(raw).expanduser())
    if key == "selected_folder_ids":
        if normalized.lower() in NULL_VALUES:
            return []
        try:
            ids = sorted(int(v.strip()) for v in normalized.split(",") if v.strip())
        except ValueError as exc:
            raise click.ClickException(
                "`selected_folder_ids` must be a comma-separated list of folder IDs (e.g., '5,12,30')."
            ) from exc
        if any(i < 1 for i in ids):
            raise click.ClickException("`selected_folder_ids` values must be 1 or greater.")
        return ids
    if key in {"download_purpose", "user_agent"} and not normalized:
        raise click.ClickException(f"`{key}` cannot be empty.")
    return raw


def _update_pause_state(choice: str | None) -> str:
    db = Database(database_path())
    try:
        if choice is None:
            pause_state = clear_pause_state(db)
        else:
            pause_state = set_pause_state(db, pause_deadline_for_choice(choice))
    finally:
        db.close()
    return describe_pause_state(pause_state)


@click.group()
@click.version_option(version=_get_version(), prog_name="imagerelay-client")
@click.option("--verbose", is_flag=True, help="Enable verbose logging.")
@click.pass_context
def main(ctx: click.Context, verbose: bool) -> None:
    ctx.ensure_object(dict)
    ctx.obj["verbose"] = verbose


@main.command()
@click.option("--api-key", envvar="IMAGERELAY_API_KEY", help="Image Relay API key.")
@click.option("--subdomain", help="Optional Image Relay subdomain.")
@click.option("--api-base-url", help="Override API base URL.")
@click.option("--local-root", type=click.Path(path_type=Path), help="Local sync root.")
@click.option(
    "--remote-root-folder-id",
    type=click.IntRange(min=1),
    help="Remote folder ID to use as the sync root.",
)
@click.option(
    "--default-file-type-id",
    type=click.IntRange(min=1),
    help="File type / metadata template ID for uploads.",
)
@click.option("--user-agent", help="User-Agent header required by Image Relay.")
@click.option(
    "--poll-interval-seconds",
    type=click.IntRange(min=1),
    help="Remote polling interval in seconds.",
)
@click.pass_context
def init(
    ctx: click.Context,
    api_key: str | None,
    subdomain: str | None,
    api_base_url: str | None,
    local_root: Path | None,
    remote_root_folder_id: int | None,
    default_file_type_id: int | None,
    user_agent: str | None,
    poll_interval_seconds: int | None,
) -> None:
    logger = configure_logging(verbose=ctx.obj["verbose"])
    store = ConfigStore()
    settings = store.load()

    if api_key is not None:
        settings.api_key = api_key
    if subdomain is not None:
        settings.subdomain = subdomain
    if api_base_url is not None:
        settings.api_base_url = api_base_url
    if local_root is not None:
        settings.local_root = str(local_root.expanduser())
    if default_file_type_id is not None:
        settings.default_file_type_id = default_file_type_id
    if user_agent is not None:
        settings.user_agent = user_agent
    if poll_interval_seconds is not None:
        settings.poll_interval_seconds = poll_interval_seconds

    if remote_root_folder_id is not None:
        settings.remote_root_folder_id = remote_root_folder_id
    elif settings.remote_root_folder_id is None and settings.resolved_api_key():
        try:
            api = ImageRelayApiClient(settings=settings, logger=logger)
            folders = api.list_folders()
        except ImageRelayApiError as exc:
            click.echo(f"Could not fetch folders: {exc}")
            click.echo("You can set the folder ID manually with --remote-root-folder-id.")
            folders = []

        if folders:
            click.echo("Available top-level folders:")
            for idx, folder in enumerate(folders, start=1):
                click.echo(f"  {idx}. {folder.name} (ID {folder.folder_id})")
            raw = click.prompt(
                "Pick a folder number, or enter a folder ID directly",
                default="1",
            )
            try:
                choice = int(raw)
            except ValueError:
                raise click.ClickException(f"Invalid selection: {raw}")
            if 1 <= choice <= len(folders):
                settings.remote_root_folder_id = folders[choice - 1].folder_id
            else:
                settings.remote_root_folder_id = choice
            click.echo(f"Selected remote root folder ID: {settings.remote_root_folder_id}")

    is_new_config = not config_path().exists()
    if is_new_config:
        click.echo(f"Config will be stored at {config_path()}")

    store.save(settings)
    _echo_success(f"Saved config to {store.path}")
    click.echo(f"Local root: {settings.resolved_local_root()}")
    click.echo(f"Remote root folder ID: {settings.remote_root_folder_id}")
    click.echo(f"Default file type ID: {settings.default_file_type_id}")


@main.group()
def config() -> None:
    """Inspect or update saved configuration."""


@config.command("show")
def config_show() -> None:
    store = ConfigStore()
    settings = store.load()
    payload = asdict(settings)
    payload["api_key"] = mask_api_key(settings.api_key)
    click.echo(json.dumps(payload, indent=2, sort_keys=True))


@config.command("set")
@click.argument("key")
@click.argument("value")
def config_set(key: str, value: str) -> None:
    store = ConfigStore()
    settings = store.load()

    if not hasattr(settings, key):
        raise click.ClickException(f"Unknown config key: {key}")

    setattr(settings, key, _coerce_value(key, value))
    store.save(settings)
    saved_value = getattr(settings, key)
    if key == "api_key":
        saved_value = mask_api_key(saved_value)
    elif isinstance(saved_value, bool):
        saved_value = str(saved_value).lower()
    elif saved_value is None:
        saved_value = "(cleared)"
    _echo_success(f"Updated {key}: {saved_value}")


@main.group()
def folders() -> None:
    """List and select which remote folders to sync."""


@folders.command("list")
@click.pass_context
def folders_list(ctx: click.Context) -> None:
    """List available remote folders."""
    logger = configure_logging(verbose=ctx.obj["verbose"])
    store = ConfigStore()
    settings = store.load()

    if not settings.resolved_api_key():
        raise click.ClickException("No API key configured. Run `imagerelay-client init` first.")
    if settings.remote_root_folder_id is None:
        raise click.ClickException("No remote root folder configured. Run `imagerelay-client init` first.")

    try:
        api = ImageRelayApiClient(settings=settings, logger=logger)
        all_folders = api.list_folders()
    except ImageRelayApiError as exc:
        _fatal_error(exc)
        return  # _fatal_error is NoReturn; satisfies type checker

    root_id = settings.remote_root_folder_id
    folders_by_id = {f.folder_id: f for f in all_folders}

    # Build parent-children map and find descendants of root
    children_by_parent: dict[int | None, list] = {}
    for f in all_folders:
        children_by_parent.setdefault(f.parent_id, []).append(f)

    selected = set(settings.selected_folder_ids)

    def print_tree(parent_id: int, indent: int = 0) -> None:
        children = children_by_parent.get(parent_id, [])
        for f in sorted(children, key=lambda x: x.name.lower()):
            marker = click.style("*", fg="green") if f.folder_id in selected else " "
            prefix = "  " * indent
            click.echo(f"  {marker} {prefix}{f.name} (ID {f.folder_id})")
            print_tree(f.folder_id, indent + 1)

    click.echo()
    click.echo(click.style("Remote Folders", bold=True))
    if selected:
        click.echo(f"  (* = selected for sync)")

    has_children = root_id in children_by_parent
    if has_children:
        print_tree(root_id)
    else:
        click.echo("  No subfolders found under the configured root folder.")

    if not selected:
        click.echo()
        click.echo("  All folders are synced. Use `folders select` to choose specific folders.")
    click.echo()


@folders.command("select")
@click.argument("folder_ids", nargs=-1, type=int, required=True)
@click.pass_context
def folders_select(ctx: click.Context, folder_ids: tuple[int, ...]) -> None:
    """Select specific folder IDs to sync. Only these folders (and their subfolders) will be synced."""
    store = ConfigStore()
    settings = store.load()
    settings.selected_folder_ids = sorted(set(folder_ids))
    store.save(settings)
    _echo_success(f"Selected {len(settings.selected_folder_ids)} folder(s) for sync: {settings.selected_folder_ids}")
    click.echo("Only these folders and their subfolders will be synced.")
    click.echo("Restart the sync engine for changes to take effect.")


@folders.command("show")
def folders_show() -> None:
    """Show currently selected folders."""
    store = ConfigStore()
    settings = store.load()

    if not settings.selected_folder_ids:
        click.echo("No folder selection active. All folders are synced.")
    else:
        click.echo(f"Selected folder IDs: {settings.selected_folder_ids}")
        click.echo(f"Only these folders and their subfolders will be synced.")


@folders.command("clear")
def folders_clear() -> None:
    """Clear folder selection and sync all folders."""
    store = ConfigStore()
    settings = store.load()
    settings.selected_folder_ids = []
    store.save(settings)
    _echo_success("Folder selection cleared. All folders will be synced.")


@main.group()
def sync() -> None:
    """Run sync commands."""


@sync.command("once")
@click.option("--verbose", "-v", is_flag=True, help="Show per-file operations (DEBUG logging).")
@click.pass_context
def sync_once(ctx: click.Context, verbose: bool) -> None:
    effective_verbose = verbose or ctx.obj["verbose"]
    try:
        run_sync_once(verbose=effective_verbose)
    except (SyncConfigurationError, SyncPausedError, ImageRelayApiError) as exc:
        _fatal_error(exc)
    _echo_success("Sync completed.")


@sync.command("status")
@click.option("--json-output", "json_output", is_flag=True, help="Print raw status as JSON.")
def sync_status(json_output: bool) -> None:
    try:
        snapshot = load_menu_status()
    except Exception as exc:
        _fatal_error(exc)
        return  # unreachable, but helps type checkers

    recent_activity = [
        {"action": item.action, "rel_path": item.rel_path, "when": item.when}
        for item in snapshot.recent_activity
    ]

    if json_output:
        payload = {
            "running": snapshot.running,
            "pid": snapshot.pid,
            "sync_state": snapshot.sync_state,
            "sync_phase": snapshot.sync_phase,
            "progress": {
                "completed_steps": snapshot.completed_steps,
                "total_steps": snapshot.total_steps,
                "eta_seconds": snapshot.eta_seconds,
                "current_item": snapshot.current_item,
            },
            "remote_pull": {
                "last_remote_pull_at": snapshot.last_remote_poll_at,
                "next_remote_pull_at": snapshot.next_remote_poll_at,
                "poll_interval_seconds": snapshot.poll_interval_seconds,
            },
            "recent_activity": recent_activity,
            "last_error": snapshot.last_error,
            "paused": snapshot.paused,
            "paused_until": snapshot.paused_until,
        }
        click.echo(json.dumps(payload, indent=2, sort_keys=True))
        return

    # Human-readable summary
    click.echo()
    click.echo(click.style("Image Relay Sync", bold=True))

    # Status line with color
    status_label = _human_status_label(snapshot)
    status_color = _status_color(snapshot)
    click.echo(f"  Status:    {click.style(status_label, fg=status_color)}")

    click.echo(f"  Last sync: {snapshot.last_sync}")
    click.echo(f"  Tracked:   {snapshot.tracked_items} files")

    sync_mode = _human_sync_mode(snapshot)
    click.echo(f"  Mode:      {sync_mode}")

    if snapshot.running:
        engine_label = click.style(f"Running (PID {snapshot.pid})", fg="green")
    else:
        engine_label = click.style("Not Running", fg="yellow")
    click.echo(f"  Engine:    {engine_label}")

    if snapshot.paused and snapshot.paused_until:
        click.echo(f"  Paused:    Until {snapshot.paused_until}")
    elif snapshot.paused:
        click.echo(f"  Paused:    Indefinitely")

    if snapshot.sync_state == "syncing" and snapshot.total_steps > 0:
        click.echo(f"  Progress:  {snapshot.completed_steps}/{snapshot.total_steps}")
        if snapshot.current_item:
            click.echo(f"  Current:   {snapshot.current_item}")

    if snapshot.last_error:
        click.echo(f"  Last error: {click.style(snapshot.last_error, fg='red')}")

    if recent_activity:
        click.echo()
        click.echo(click.style("Recent Activity", bold=True))
        for item in recent_activity:
            click.echo(f"  {item['action']:>10}  {item['rel_path']}")

    click.echo()


@sync.command("pause")
@click.option(
    "--for",
    "pause_for",
    type=click.Choice(["30m", "1h", "tomorrow", "indefinite"], case_sensitive=False),
    default="1h",
    show_default=True,
    help="How long to pause syncing. `tomorrow` resumes at 9:00 AM local time.",
)
def sync_pause_command(pause_for: str) -> None:
    message = _update_pause_state(pause_for.lower())
    click.echo(message)


@sync.command("resume")
def sync_resume_command() -> None:
    message = _update_pause_state(None)
    click.echo(message)


@main.group()
def daemon() -> None:
    """Run or manage the background daemon."""


@daemon.command("run")
@click.pass_context
def daemon_run(ctx: click.Context) -> None:
    try:
        run_daemon(verbose=ctx.obj["verbose"])
    except (DaemonLockError, SyncConfigurationError, SyncPausedError, ImageRelayApiError) as exc:
        _fatal_error(exc)


@daemon.command("start")
def daemon_start() -> None:
    try:
        pid = start_daemon()
    except (SyncConfigurationError, RuntimeError) as exc:
        _fatal_error(exc)
    _echo_success(f"Daemon started with PID {pid}")


@daemon.command("stop")
def daemon_stop() -> None:
    stopped = stop_daemon()
    if stopped:
        _echo_success("Daemon stopped.")
    else:
        _echo_warning("Daemon was not running.")


@daemon.command("status")
def daemon_status_command() -> None:
    running, pid = daemon_status()
    if running:
        _echo_success(f"Daemon is running (PID {pid})")
    else:
        _echo_warning("Daemon is not running.")


@main.group()
def autostart() -> None:
    """Manage launchd autostart on macOS."""


@autostart.command("enable")
@click.option(
    "--target",
    type=click.Choice(["daemon", "gui"], case_sensitive=False),
    default="daemon",
    show_default=True,
    help="What to start on login.",
)
def autostart_enable(target: str) -> None:
    try:
        path = AutoStart(target=target.lower()).enable()
    except AutoStartError as exc:
        _fatal_error(exc)
    _echo_success(f"Autostart enabled: {path}")


@autostart.command("disable")
@click.option(
    "--target",
    type=click.Choice(["daemon", "gui"], case_sensitive=False),
    default="daemon",
    show_default=True,
    help="Which launch agent to remove.",
)
def autostart_disable(target: str) -> None:
    try:
        autostart = AutoStart(target=target.lower())
        autostart.disable()
    except AutoStartError as exc:
        _fatal_error(exc)
    _echo_success("Autostart disabled.")


@autostart.command("status")
@click.option(
    "--target",
    type=click.Choice(["daemon", "gui"], case_sensitive=False),
    default="daemon",
    show_default=True,
    help="Which launch agent to inspect.",
)
def autostart_status(target: str) -> None:
    try:
        autostart = AutoStart(target=target.lower())
    except AutoStartError as exc:
        _fatal_error(exc)

    if autostart.enabled:
        _echo_success(f"Autostart is enabled: {autostart.path}")
    else:
        _echo_warning("Autostart is disabled.")


@main.command("gui")
def gui() -> None:
    """Run the native macOS menu bar app."""
    try:
        run_menu_bar_app()
    except RuntimeError as exc:
        _fatal_error(exc)


@main.group()
def simulate() -> None:
    """Run a local Image Relay simulator for end-to-end testing."""


@simulate.command("server")
@click.option("--host", default="127.0.0.1", show_default=True, help="Host to bind.")
@click.option("--port", default=8765, show_default=True, type=int, help="Port to bind.")
@click.option("--api-key", default="test-key", show_default=True, help="Mock API key.")
@click.option(
    "--seed-demo/--empty",
    default=True,
    show_default=True,
    help="Seed sample folders and files into the simulator.",
)
@click.option(
    "--throttle-first-download",
    is_flag=True,
    help="Return one 429 on the first quick-link download to exercise retry logic.",
)
def simulate_server(
    host: str,
    port: int,
    api_key: str,
    seed_demo: bool,
    throttle_first_download: bool,
) -> None:
    state = MockImageRelayState(api_key=api_key)
    if seed_demo:
        seed_demo_state(state, throttle_first_download=throttle_first_download)
    elif throttle_first_download:
        state.throttle_next_download = True

    click.echo("Starting local Image Relay simulator.")
    with MockImageRelayServer(state, host=host, port=port) as server:
        click.echo(f"API base URL: {server.api_base_url}")
        click.echo(f"API key: {api_key}")
        click.echo("Sample init command:")
        click.echo(
            "  imagerelay-client init "
            f"--api-key {api_key!r} "
            f"--api-base-url {server.api_base_url!r} "
            "--local-root ~/Image\\ Relay\\ Simulator "
            "--remote-root-folder-id 1 "
            "--default-file-type-id 7"
        )
        click.echo("Press Ctrl+C to stop the simulator.")
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            click.echo("\nSimulator stopped.")


@simulate.command("demo")
@click.option(
    "--cleanup/--keep-temp",
    default=False,
    show_default=True,
    help="Remove or preserve the temporary client home and sync root after the demo completes.",
)
@click.option("--api-key", default="test-key", show_default=True, help="Mock API key.")
def simulate_demo(cleanup: bool, api_key: str) -> None:
    try:
        result = run_demo(
            keep_temp=not cleanup,
            api_key=api_key,
            output=click.echo,
        )
    except RuntimeError as exc:
        _fatal_error(exc)

    _echo_success("Simulation complete.")
    click.echo(f"API base URL: {result.api_base_url}")
    if cleanup:
        click.echo("Temporary files were cleaned up.")
    else:
        click.echo(f"Client home: {result.client_home}")
        click.echo(f"Local root: {result.local_root}")
        click.echo(f"Log path: {result.log_path}")
    click.echo("Remote files:")
    for rel_path in sorted(result.remote_files):
        click.echo(f"  {rel_path}")
