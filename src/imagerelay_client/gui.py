from __future__ import annotations

import platform
import subprocess
import sys
import threading
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .appdirs import APP_NAME, config_path, database_path, log_path
from .autostart import AutoStart, AutoStartError
from .api import ImageRelayApiClient
from .config import ConfigStore
from .daemon import daemon_status, run_sync_once, start_daemon, stop_daemon
from .database import Database
from .progress import SyncActivityEntry, SyncProgressState, sync_progress_from_dict
from .sync_pause import (
    SyncPauseState,
    clear_pause_state,
    describe_pause_state,
    format_pause_deadline,
    load_pause_state,
    pause_deadline_for_choice,
    pause_menu_label,
    set_pause_state,
)
from .user_messages import user_message_for_error


def _require_rumps():
    try:
        import rumps
    except ImportError as exc:
        raise RuntimeError(
            "The macOS menu bar app requires the optional 'rumps' dependency."
        ) from exc
    return rumps


def _open_path(path: Path) -> None:
    subprocess.run(["open", str(path)], check=False)


def _format_last_sync(value: str | None) -> str:
    if not value:
        return "Never"

    try:
        timestamp = datetime.fromisoformat(value)
    except ValueError:
        return value

    return timestamp.astimezone().strftime("%b %d, %Y %I:%M %p")


@dataclass(slots=True)
class MenuStatusSnapshot:
    running: bool
    pid: int | None
    missing_fields: list[str]
    local_root: Path
    tracked_items: int
    poll_interval_seconds: int
    last_sync: str
    sync_upload: bool
    sync_download: bool
    sync_state: str
    sync_phase: str
    completed_steps: int
    total_steps: int
    eta_seconds: int | None
    current_item: str | None
    last_error: str | None
    last_remote_poll_at: str | None
    next_remote_poll_at: str | None
    paused: bool
    paused_until: str | None
    recent_activity: list[SyncActivityEntry]


def _status_symbol_name(snapshot: MenuStatusSnapshot) -> str:
    if snapshot.missing_fields:
        return "gearshape.circle"
    if snapshot.paused:
        return "pause.circle"
    if snapshot.sync_state == "error":
        return "exclamationmark.triangle"
    if snapshot.running and snapshot.sync_state == "syncing":
        return "arrow.triangle.2.circlepath"
    if snapshot.running:
        return "checkmark.circle"
    return "xmark.circle"


def _set_status_icon(app, symbol_name: str) -> bool:
    """Set the status bar icon to an SF Symbol via AppKit.

    Uses NSStatusItem.button() which is the public NSStatusItem API.
    Returns True if the icon was set, False on any failure (graceful fallback).
    """
    try:
        from AppKit import NSImage
    except ImportError:
        return False

    image = NSImage.imageWithSystemSymbolName_accessibilityDescription_(
        symbol_name, APP_NAME
    )
    if image is None:
        return False

    image.setTemplate_(True)

    ns_app = getattr(app, "_nsapp", None)
    if ns_app is None:
        return False

    try:
        status_item = ns_app.nsstatusitem
        status_item.button().setImage_(image)
        status_item.button().setTitle_("")
        return True
    except AttributeError:
        return False


def _clear_status_icon(app) -> bool:
    """Remove the SF Symbol icon from the status bar, reverting to text title."""
    ns_app = getattr(app, "_nsapp", None)
    if ns_app is None:
        return False

    try:
        status_item = ns_app.nsstatusitem
        status_item.button().setImage_(None)
        return True
    except AttributeError:
        return False


def _set_key_equivalent(rumps_menu_item, key: str, modifier_mask: int | None = None) -> bool:
    """Set a keyboard shortcut on a rumps MenuItem via its underlying NSMenuItem.

    By default NSMenuItem key equivalents use Cmd as the modifier.
    Returns True if set, False on failure (rumps may not expose the NS object).
    """
    try:
        ns_menu_item = rumps_menu_item._menuitem
        ns_menu_item.setKeyEquivalent_(key)
        if modifier_mask is not None:
            ns_menu_item.setKeyEquivalentModifierMask_(modifier_mask)
        return True
    except (AttributeError, TypeError):
        return False


def _show_about_dialog(snapshot: "MenuStatusSnapshot") -> None:
    """Show a rich About dialog using NSAlert with a Copy Debug Info button.

    Falls back to returning False if AppKit is unavailable so the caller
    can use rumps.alert instead.
    """
    try:
        from AppKit import (
            NSAlert,
            NSInformationalAlertStyle,
            NSPasteboard,
            NSStringPboardType,
        )
    except ImportError:
        return False

    version = "0.1.0"
    python_version = sys.version.split()[0]
    status_label = _primary_status_label(snapshot)
    sync_mode = _sync_mode_label(snapshot)
    pause_label = pause_menu_label(
        SyncPauseState(paused=snapshot.paused, until=snapshot.paused_until)
    )

    info_lines = [
        f"Version: {version}",
        f"Python: {python_version}",
        f"Platform: {platform.platform()}",
        "",
        f"Status: {status_label}",
        f"Sync Mode: {sync_mode}",
        f"Pause: {pause_label}",
        f"Phase: {snapshot.sync_phase}",
        f"Progress: {_progress_label(snapshot)}",
        f"Time Remaining: {_format_eta(snapshot.eta_seconds) if snapshot.sync_state == 'syncing' else '--'}",
        f"Current Item: {_shorten_path(snapshot.current_item, limit=52)}",
        f"Last Sync: {snapshot.last_sync}",
        f"Last Pull: {_format_last_sync(snapshot.last_remote_poll_at)}",
        f"Next Pull: {_next_pull_label(snapshot)}",
        f"Tracked Items: {snapshot.tracked_items}",
        f"Upload Changes: {'On' if snapshot.sync_upload else 'Off'}",
        f"Download Changes: {'On' if snapshot.sync_download else 'Off'}",
        f"Menu Bar App at Login: {'On' if _autostart_enabled('gui') else 'Off'}",
        f"Sync Engine at Login: {'On' if _autostart_enabled('daemon') else 'Off'}",
    ]
    if snapshot.last_error:
        info_lines.append(f"Last Error: {snapshot.last_error}")

    message_text = "\n".join(info_lines)

    alert = NSAlert.alloc().init()
    alert.setAlertStyle_(NSInformationalAlertStyle)
    alert.setMessageText_(APP_NAME)
    alert.setInformativeText_(message_text)
    alert.addButtonWithTitle_("OK")
    alert.addButtonWithTitle_("Copy Debug Info")

    response = alert.runModal()
    # NSAlertSecondButtonReturn = 1001
    if response == 1001:
        pasteboard = NSPasteboard.generalPasteboard()
        pasteboard.clearContents()
        pasteboard.setString_forType_(
            f"{APP_NAME} {version}\n{message_text}", NSStringPboardType
        )

    return True


def _build_folder_tree(folders, root_id):
    """Return folders in tree-walk order as (folder, depth) pairs.

    Walks descendants of *root_id*.  When no descendants exist (e.g. the
    configured root is a leaf folder), falls back to showing siblings of
    the root (all children of the same parent) so the user can still see
    and select folders.
    """
    folders_by_id = {f.folder_id: f for f in folders}
    children_by_parent: dict[int | None, list] = {}
    for f in folders:
        children_by_parent.setdefault(f.parent_id, []).append(f)

    result: list[tuple] = []

    def walk(parent_id, depth):
        for f in sorted(children_by_parent.get(parent_id, []), key=lambda x: x.name.lower()):
            result.append((f, depth))
            walk(f.folder_id, depth + 1)

    walk(root_id, 0)

    # Fallback: if root has no children, show all folders under the same
    # parent (siblings) so the user has something to work with.
    if not result:
        root_folder = folders_by_id.get(root_id)
        if root_folder and root_folder.parent_id is not None:
            walk(root_folder.parent_id, 0)

    # Last resort: show all folders as a flat tree from the top-level roots.
    if not result:
        top_level_parents = {
            f.parent_id
            for f in folders
            if f.parent_id not in folders_by_id
        }
        for parent_id in sorted(top_level_parents):
            walk(parent_id, 0)

    return result


def _show_folder_picker_dialog(folders, root_id, current_selection):
    """Show a native macOS dialog for selecting which folders to sync.

    Returns a list of selected folder IDs, an empty list to sync all,
    or None if the user cancelled.
    """
    try:
        from AppKit import (
            NSAlert,
            NSButton,
            NSFont,
            NSInformationalAlertStyle,
            NSMakeRect,
            NSScrollView,
            NSView,
        )
    except ImportError:
        return None

    tree_items = _build_folder_tree(folders, root_id)
    if not tree_items:
        alert = NSAlert.alloc().init()
        alert.setAlertStyle_(NSInformationalAlertStyle)
        alert.setMessageText_("No Folders Available")
        alert.setInformativeText_("No folders were found in your Image Relay account.")
        alert.addButtonWithTitle_("OK")
        alert.runModal()
        return None

    selected_set = set(current_selection)
    row_height = 24
    indent_width = 20
    view_width = 380

    # Layout checkboxes inside a container view.
    # NSView y=0 is bottom, so we lay out rows from the top downward.
    view_height = len(tree_items) * row_height
    container = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, view_width, view_height))

    checkboxes: dict[int, NSButton] = {}
    for i, (folder, depth) in enumerate(tree_items):
        x = 8 + depth * indent_width
        y = view_height - (i + 1) * row_height
        btn = NSButton.alloc().initWithFrame_(
            NSMakeRect(x, y, view_width - x - 8, row_height)
        )
        btn.setButtonType_(3)  # NSSwitchButton
        btn.setTitle_(folder.name)
        btn.setFont_(NSFont.systemFontOfSize_(13))
        btn.setState_(1 if folder.folder_id in selected_set else 0)
        container.addSubview_(btn)
        checkboxes[folder.folder_id] = btn

    scroll_height = min(view_height + 4, 340)
    scroll_view = NSScrollView.alloc().initWithFrame_(
        NSMakeRect(0, 0, view_width + 24, scroll_height)
    )
    scroll_view.setHasVerticalScroller_(True)
    scroll_view.setBorderType_(2)  # NSBezelBorder
    scroll_view.setDocumentView_(container)

    alert = NSAlert.alloc().init()
    alert.setAlertStyle_(NSInformationalAlertStyle)
    alert.setMessageText_("Select Folders to Sync")
    alert.setInformativeText_(
        "Only checked folders and their subfolders will sync.\n"
        "Use Sync All to go back to syncing everything."
    )
    alert.addButtonWithTitle_("Save")
    alert.addButtonWithTitle_("Sync All")
    alert.addButtonWithTitle_("Cancel")
    alert.setAccessoryView_(scroll_view)

    # Scroll to top so the first folder is visible.
    container.scrollPoint_(NSMakeRect(0, view_height, 0, 0).origin)

    response = alert.runModal()

    if response == 1002:  # Cancel
        return None
    if response == 1001:  # Sync All
        return []

    # Save: collect checked folder IDs
    return sorted(
        folder_id
        for folder_id, btn in checkboxes.items()
        if btn.state() == 1
    )


def _make_section_header(rumps_module, label: str):
    """Create a disabled menu item that acts as a section header."""
    item = rumps_module.MenuItem(f"-- {label} --")
    item.set_callback(None)
    return item


def _sync_mode_label(snapshot: MenuStatusSnapshot) -> str:
    if snapshot.sync_upload and snapshot.sync_download:
        return "Two-Way"
    if snapshot.sync_download:
        return "Download Only"
    if snapshot.sync_upload:
        return "Upload Only"
    return "Paused"


def _primary_status_label(snapshot: MenuStatusSnapshot) -> str:
    if snapshot.missing_fields:
        return "Set Up Syncing"
    if snapshot.paused:
        if snapshot.paused_until:
            return f"Syncing Paused Until {format_pause_deadline(snapshot.paused_until, include_date=False)}"
        return "Syncing Paused"
    if snapshot.sync_state == "error":
        return "Sync Failed"
    if snapshot.running and snapshot.sync_state == "syncing":
        return "Syncing Now"
    if snapshot.running:
        return "Files Are Up to Date"
    return "Sync Engine Not Running"


def _parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _format_eta(seconds: int | None) -> str:
    if seconds is None:
        return "--"
    if seconds < 60:
        return f"about {seconds}s"
    minutes, remaining_seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"about {minutes}m {remaining_seconds:02d}s"
    hours, remaining_minutes = divmod(minutes, 60)
    return f"about {hours}h {remaining_minutes:02d}m"


def _format_future(value: str | None) -> str:
    timestamp = _parse_iso(value)
    if timestamp is None:
        return "--"

    delta_seconds = int(round((timestamp - datetime.now(timestamp.tzinfo)).total_seconds()))
    if delta_seconds <= 1:
        return "now"
    if delta_seconds < 60:
        return f"in {delta_seconds}s"
    minutes, seconds = divmod(delta_seconds, 60)
    if minutes < 60:
        return f"in {minutes}m {seconds:02d}s"
    hours, remaining_minutes = divmod(minutes, 60)
    return f"in {hours}h {remaining_minutes:02d}m"


def _progress_label(snapshot: MenuStatusSnapshot) -> str:
    if snapshot.sync_state == "syncing" and snapshot.total_steps > 0:
        return f"{snapshot.completed_steps} of {snapshot.total_steps}"
    if snapshot.total_steps > 0:
        return f"Last pass completed {snapshot.total_steps} step(s)"
    return "No pending transfers"


def _shorten_path(value: str | None, limit: int = 42) -> str:
    if not value:
        return "--"
    if len(value) <= limit:
        return value
    return "..." + value[-(limit - 3):]


def _next_pull_label(snapshot: MenuStatusSnapshot) -> str:
    if snapshot.paused and snapshot.paused_until:
        return f"Resumes {_format_future(snapshot.paused_until)}"
    if snapshot.paused:
        return "Resume Syncing to Continue"
    if snapshot.running and snapshot.sync_download:
        return _format_future(snapshot.next_remote_poll_at)
    return "Start Sync Engine to Auto-Pull"


def _format_activity(entry: SyncActivityEntry) -> str:
    timestamp = _parse_iso(entry.when)
    time_label = timestamp.astimezone().strftime("%I:%M %p").lstrip("0") if timestamp else "--"
    path_label = _shorten_path(entry.rel_path, limit=34)
    return f"{time_label} {entry.action} {path_label}"


def _autostart_enabled(target: str) -> bool:
    try:
        return AutoStart(target=target).enabled
    except (AutoStartError, RuntimeError):
        return False


def load_menu_status() -> MenuStatusSnapshot:
    settings = ConfigStore().load()
    running, pid = daemon_status()
    tracked_items = 0
    last_sync = "Never"
    sync_progress = SyncProgressState()
    pause_state = SyncPauseState()

    db_file = database_path()
    if db_file.exists():
        db = Database(db_file)
        try:
            tracked_items = db.count_entries(include_aliases=False)
            last_sync = _format_last_sync(db.get_state("last_sync_at"))
            sync_progress = sync_progress_from_dict(db.get_state_json("sync_progress", None))
            pause_state = load_pause_state(db)
        finally:
            db.close()

    if not running:
        sync_progress.next_remote_poll_at = None

    sync_state = sync_progress.state
    sync_phase = sync_progress.phase
    eta_seconds = sync_progress.eta_seconds
    current_item = sync_progress.current_item
    next_remote_poll_at = sync_progress.next_remote_poll_at

    if pause_state.paused:
        sync_state = "paused"
        sync_phase = "Syncing paused until resumed" if pause_state.until is None else "Syncing paused"
        eta_seconds = None
        current_item = None
        next_remote_poll_at = pause_state.until

    return MenuStatusSnapshot(
        running=running,
        pid=pid,
        missing_fields=settings.missing_sync_fields(),
        local_root=settings.resolved_local_root(),
        tracked_items=tracked_items,
        poll_interval_seconds=settings.poll_interval_seconds,
        last_sync=last_sync,
        sync_upload=settings.sync_upload,
        sync_download=settings.sync_download,
        sync_state=sync_state,
        sync_phase=sync_phase,
        completed_steps=sync_progress.completed_steps,
        total_steps=sync_progress.total_steps,
        eta_seconds=eta_seconds,
        current_item=current_item,
        last_error=sync_progress.last_error,
        last_remote_poll_at=sync_progress.last_remote_poll_at,
        next_remote_poll_at=next_remote_poll_at,
        paused=pause_state.paused,
        paused_until=pause_state.until,
        recent_activity=sync_progress.recent_activity,
    )


class ImageRelayMenuBarApp:
    def __init__(self) -> None:
        if platform.system() != "Darwin":
            raise RuntimeError("The menu bar app is only available on macOS.")

        self.rumps = _require_rumps()
        self.app = self.rumps.App(APP_NAME, title="IR", quit_button=None)
        self._using_symbol_icon = False

        self.overview_item = self.rumps.MenuItem("ImageRelay Client")
        self.status_item = self.rumps.MenuItem("Checking Sync Status...")
        self.status_detail_item = self.rumps.MenuItem("Status: Checking...")
        self.mode_item = self.rumps.MenuItem("Sync Mode: Checking...")
        self.pause_item = self.rumps.MenuItem("Pause: Not Paused")
        self.phase_item = self.rumps.MenuItem("Phase: Idle")
        self.progress_item = self.rumps.MenuItem("Progress: --")
        self.eta_item = self.rumps.MenuItem("Time Remaining: --")
        self.current_item_item = self.rumps.MenuItem("Current Item: --")
        self.pull_schedule_item = self.rumps.MenuItem("Automatic Pull: --")
        self.last_pull_item = self.rumps.MenuItem("Last Pull: Never")
        self.next_pull_item = self.rumps.MenuItem("Next Pull: --")
        self.last_sync_item = self.rumps.MenuItem("Last Sync: Never")
        self.tracked_items_item = self.rumps.MenuItem("Tracked Items: 0")
        self.root_item = self.rumps.MenuItem("Sync Folder: --")
        self.error_item = self.rumps.MenuItem("Last Error: None")
        self.recent_activity_items = [
            self.rumps.MenuItem("No recent activity yet") for _ in range(4)
        ]

        self.start_item = self.rumps.MenuItem("Start Sync Engine", callback=self.start_daemon)
        self.restart_item = self.rumps.MenuItem("Restart Sync Engine", callback=self.restart_daemon)
        self.stop_item = self.rumps.MenuItem("Stop Sync Engine", callback=self.stop_daemon)
        self.sync_item = self.rumps.MenuItem("Sync Now", callback=self.sync_now)
        self.pause_30m_item = self.rumps.MenuItem("Pause Syncing 30 Minutes", callback=self.pause_30_minutes)
        self.pause_1h_item = self.rumps.MenuItem("Pause Syncing 1 Hour", callback=self.pause_1_hour)
        self.pause_tomorrow_item = self.rumps.MenuItem(
            "Pause Until Tomorrow at 9 AM", callback=self.pause_until_tomorrow
        )
        self.pause_indefinite_item = self.rumps.MenuItem(
            "Pause Indefinitely", callback=self.pause_indefinitely
        )
        self.resume_item = self.rumps.MenuItem("Resume Syncing", callback=self.resume_sync)
        self.pause_menu_item = self.rumps.MenuItem("Pause Syncing")
        self.pause_menu_item.update(
            [
                self.pause_30m_item,
                self.pause_1h_item,
                self.pause_tomorrow_item,
                self.pause_indefinite_item,
            ]
        )

        self.uploads_item = self.rumps.MenuItem("Upload Changes", callback=self.toggle_uploads)
        self.downloads_item = self.rumps.MenuItem(
            "Download Changes", callback=self.toggle_downloads
        )
        self.menu_bar_autostart_item = self.rumps.MenuItem(
            "Open Menu Bar App at Login", callback=self.toggle_menu_bar_autostart
        )
        self.daemon_autostart_item = self.rumps.MenuItem(
            "Start Sync Engine at Login", callback=self.toggle_daemon_autostart
        )
        self.select_folders_item = self.rumps.MenuItem(
            "Select Folders to Sync...", callback=self.select_folders
        )
        self.settings_menu_item = self.rumps.MenuItem("Settings")
        self.settings_menu_item.update(
            [
                self.select_folders_item,
                None,
                self.uploads_item,
                self.downloads_item,
                None,
                self.menu_bar_autostart_item,
                self.daemon_autostart_item,
            ]
        )

        self.open_folder_item = self.rumps.MenuItem(
            "Open Sync Folder", callback=self.open_sync_folder
        )
        self.open_logs_item = self.rumps.MenuItem("Open Log Folder", callback=self.open_logs)
        self.reveal_config_item = self.rumps.MenuItem(
            "Reveal Config File", callback=self.reveal_config
        )
        self.reveal_db_item = self.rumps.MenuItem(
            "Reveal Sync Database", callback=self.reveal_database
        )
        self.details_menu_item = self.rumps.MenuItem("Details")
        self.details_menu_item.update(
            [
                self.status_detail_item,
                self.mode_item,
                self.pause_item,
                self.phase_item,
                self.progress_item,
                self.eta_item,
                self.current_item_item,
                None,
                self.pull_schedule_item,
                self.last_pull_item,
                self.next_pull_item,
                self.last_sync_item,
                self.tracked_items_item,
                self.root_item,
                self.error_item,
            ]
        )
        self.recent_activity_menu_item = self.rumps.MenuItem("Recent Activity")
        self.recent_activity_menu_item.update(self.recent_activity_items)
        self.about_item = self.rumps.MenuItem("About ImageRelay Client", callback=self.show_about)
        self.advanced_menu_item = self.rumps.MenuItem("Advanced")
        self.advanced_menu_item.update(
            [
                self.open_logs_item,
                self.reveal_config_item,
                self.reveal_db_item,
                None,
                self.about_item,
            ]
        )
        self.quit_item = self.rumps.MenuItem("Quit", callback=self.quit_app)

        self.sync_section_header = _make_section_header(self.rumps, "Sync")
        self.settings_section_header = _make_section_header(self.rumps, "Settings")

        self.app.menu = [
            self.overview_item,
            self.status_item,
            None,
            self.sync_section_header,
            self.open_folder_item,
            self.sync_item,
            self.pause_menu_item,
            self.resume_item,
            self.start_item,
            self.restart_item,
            self.stop_item,
            None,
            self.settings_section_header,
            self.settings_menu_item,
            self.details_menu_item,
            self.recent_activity_menu_item,
            self.advanced_menu_item,
            None,
            self.quit_item,
        ]

        # Set keyboard shortcuts via AppKit (best-effort; no-op if unavailable)
        _set_key_equivalent(self.sync_item, "s")
        _set_key_equivalent(self.quit_item, "q")

        self.timer = self.rumps.Timer(self.refresh_status, 3)
        self.timer.start()
        self.refresh_status(None)

    def run(self) -> None:
        self.app.run()

    def notify(self, title: str, message: str) -> None:
        self.rumps.notification(APP_NAME, title, message)

    def run_in_background(self, target) -> None:
        thread = threading.Thread(target=target, daemon=True)
        thread.start()

    def refresh_status(self, _sender) -> None:
        snapshot = load_menu_status()
        self._apply_status_icon(snapshot)
        primary_status = _primary_status_label(snapshot)

        if snapshot.missing_fields:
            if not self._using_symbol_icon:
                self.app.title = "IR!"
            self.status_item.title = "Set Up Syncing"
        elif snapshot.paused:
            if not self._using_symbol_icon:
                self.app.title = "IR||"
            self.status_item.title = primary_status
        elif snapshot.sync_state == "error":
            if not self._using_symbol_icon:
                self.app.title = "IR!"
            self.status_item.title = primary_status
        elif snapshot.running:
            if not self._using_symbol_icon:
                self.app.title = "IR"
            self.status_item.title = primary_status
        else:
            if not self._using_symbol_icon:
                self.app.title = "IR-"
            self.status_item.title = primary_status

        self.status_detail_item.title = f"Status: {primary_status}"
        self.last_sync_item.title = f"Last Sync: {snapshot.last_sync}"
        self.mode_item.title = f"Sync Mode: {_sync_mode_label(snapshot)}"
        self.pause_item.title = (
            f"Pause: {pause_menu_label(SyncPauseState(paused=snapshot.paused, until=snapshot.paused_until))}"
        )
        self.phase_item.title = f"Phase: {snapshot.sync_phase}"
        self.progress_item.title = f"Progress: {_progress_label(snapshot)}"
        self.eta_item.title = (
            f"Time Remaining: {_format_eta(snapshot.eta_seconds)}"
            if snapshot.sync_state == "syncing"
            else "Time Remaining: --"
        )
        self.current_item_item.title = f"Current Item: {_shorten_path(snapshot.current_item)}"
        self.pull_schedule_item.title = (
            "Automatic Pull: Paused"
            if snapshot.paused
            else f"Automatic Pull: Every {max(snapshot.poll_interval_seconds, 1)}s"
        )
        self.last_pull_item.title = f"Last Pull: {_format_last_sync(snapshot.last_remote_poll_at)}"
        self.next_pull_item.title = f"Next Pull: {_next_pull_label(snapshot)}"
        self.tracked_items_item.title = f"Tracked Items: {snapshot.tracked_items}"
        self.root_item.title = f"Sync Folder: {snapshot.local_root.name or snapshot.local_root}"
        self.error_item.title = (
            f"Last Error: {_shorten_path(snapshot.last_error, limit=70)}"
            if snapshot.last_error
            else "Last Error: None"
        )

        for index, item in enumerate(self.recent_activity_items):
            if index < len(snapshot.recent_activity):
                item.title = _format_activity(snapshot.recent_activity[index])
            elif index == 0:
                item.title = "No recent file activity yet"
            else:
                item.title = "--"

        self.start_item.set_callback(None if snapshot.running else self.start_daemon)
        self.restart_item.set_callback(self.restart_daemon if snapshot.running else None)
        self.stop_item.set_callback(self.stop_daemon if snapshot.running else None)
        can_change_pause = not snapshot.missing_fields
        self.sync_item.set_callback(
            self.sync_now if not snapshot.missing_fields and not snapshot.paused else None
        )
        self.pause_30m_item.set_callback(self.pause_30_minutes if can_change_pause else None)
        self.pause_1h_item.set_callback(self.pause_1_hour if can_change_pause else None)
        self.pause_tomorrow_item.set_callback(
            self.pause_until_tomorrow if can_change_pause else None
        )
        self.pause_indefinite_item.set_callback(
            self.pause_indefinitely if can_change_pause else None
        )
        self.resume_item.set_callback(self.resume_sync if snapshot.paused and can_change_pause else None)
        self.open_folder_item.set_callback(
            self.open_sync_folder if not snapshot.missing_fields else None
        )
        self.select_folders_item.set_callback(
            self.select_folders if not snapshot.missing_fields else None
        )
        selected_count = len(ConfigStore().load().selected_folder_ids)
        self.select_folders_item.title = (
            f"Select Folders to Sync ({selected_count} selected)..."
            if selected_count
            else "Select Folders to Sync..."
        )
        self.uploads_item.state = 1 if snapshot.sync_upload else 0
        self.downloads_item.state = 1 if snapshot.sync_download else 0
        self.menu_bar_autostart_item.state = 1 if _autostart_enabled("gui") else 0
        self.daemon_autostart_item.state = 1 if _autostart_enabled("daemon") else 0

    def _apply_status_icon(self, snapshot: MenuStatusSnapshot) -> None:
        symbol_name = _status_symbol_name(snapshot)
        if _set_status_icon(self.app, symbol_name):
            self._using_symbol_icon = True
            self.app.title = None
        else:
            self._using_symbol_icon = False
            _clear_status_icon(self.app)

    def _toggle_direction(self, key: str, title: str) -> None:
        store = ConfigStore()
        settings = store.load()
        current = bool(getattr(settings, key))
        setattr(settings, key, not current)
        store.save(settings)

        if daemon_status()[0]:
            stopped = stop_daemon()
            if stopped:
                start_daemon()

        self.notify(
            title,
            "Enabled." if not current else "Disabled.",
        )
        self.refresh_status(None)

    def toggle_uploads(self, _sender) -> None:
        self._toggle_direction("sync_upload", "Upload Changes")

    def toggle_downloads(self, _sender) -> None:
        self._toggle_direction("sync_download", "Download Changes")

    def select_folders(self, _sender) -> None:
        from .logging_utils import configure_logging

        store = ConfigStore()
        settings = store.load()
        logger = configure_logging(verbose=False)

        try:
            api = ImageRelayApiClient(settings=settings, logger=logger)
            all_folders = api.list_folders()

            # Discover subfolders by fetching metadata for folders with children.
            to_fetch = [f.folder_id for f in all_folders if getattr(f, "child_count", 0) or 0 > 0]
            # Simpler: fetch child folders for any folder that reports child_count > 0.
            # Since the API doesn't have a children endpoint, we fetch each folder
            # individually by ID when we discover them from file folder_ids.
            # For the picker, do a lightweight discovery: fetch files to find subfolder IDs.
            root_id = settings.remote_root_folder_id
            if root_id is not None:
                files = api.list_files(root_id, recursive=True)
                folders_by_id = {f.folder_id: f for f in all_folders}
                unknown_ids: set[int] = set()
                for rf in files:
                    for fid in rf.folder_ids:
                        if fid not in folders_by_id:
                            unknown_ids.add(fid)
                fetched: set[int] = set()
                fetch_queue = list(unknown_ids)
                while fetch_queue:
                    fid = fetch_queue.pop()
                    if fid in fetched or fid in folders_by_id:
                        continue
                    fetched.add(fid)
                    try:
                        folder = api.get_folder(fid)
                        folders_by_id[folder.folder_id] = folder
                        all_folders.append(folder)
                        if folder.parent_id and folder.parent_id not in folders_by_id:
                            fetch_queue.append(folder.parent_id)
                    except Exception:
                        pass
        except Exception as exc:
            self.notify("Could Not Load Folders", user_message_for_error(exc))
            return

        root_id = settings.remote_root_folder_id
        if root_id is None:
            self.notify("No Root Folder", "Run `imagerelay-client init` to set up the sync root.")
            return

        result = _show_folder_picker_dialog(all_folders, root_id, settings.selected_folder_ids)
        if result is None:
            return  # Cancelled

        settings.selected_folder_ids = result
        store.save(settings)

        if result:
            self.notify("Folder Selection Saved", f"Syncing {len(result)} selected folder(s).")
        else:
            self.notify("Folder Selection Cleared", "All folders will be synced.")

        if daemon_status()[0]:
            stop_daemon()
            start_daemon()

        self.refresh_status(None)

    def start_daemon(self, _sender) -> None:
        def work() -> None:
            try:
                pid = start_daemon()
            except Exception as exc:
                self.notify("Failed to Start Sync Engine", user_message_for_error(exc))
            else:
                self.notify("Sync Engine Started", f"ImageRelay sync is running as PID {pid}.")
            finally:
                self.refresh_status(None)

        self.run_in_background(work)

    def restart_daemon(self, _sender) -> None:
        def work() -> None:
            try:
                stop_daemon()
                pid = start_daemon()
            except Exception as exc:
                self.notify("Failed to Restart Sync Engine", user_message_for_error(exc))
            else:
                self.notify("Sync Engine Restarted", f"ImageRelay sync restarted as PID {pid}.")
            finally:
                self.refresh_status(None)

        self.run_in_background(work)

    def stop_daemon(self, _sender) -> None:
        def work() -> None:
            stopped = stop_daemon()
            self.notify("Sync Engine Stopped" if stopped else "Sync Engine Not Running", "")
            self.refresh_status(None)

        self.run_in_background(work)

    def sync_now(self, _sender) -> None:
        def work() -> None:
            try:
                run_sync_once()
            except Exception as exc:
                self.notify("Sync failed", user_message_for_error(exc))
            else:
                self.notify("Sync complete", "ImageRelay sync finished successfully.")
            finally:
                self.refresh_status(None)

        self.run_in_background(work)

    def _set_pause(self, choice: str | None, title: str) -> None:
        def work() -> None:
            db = Database(database_path())
            try:
                if choice is None:
                    pause_state = clear_pause_state(db)
                else:
                    pause_state = set_pause_state(db, pause_deadline_for_choice(choice))
            except Exception as exc:
                self.notify(title, user_message_for_error(exc))
            else:
                self.notify(title, describe_pause_state(pause_state))
            finally:
                db.close()
                self.refresh_status(None)

        self.run_in_background(work)

    def pause_30_minutes(self, _sender) -> None:
        self._set_pause("30m", "Sync paused for 30 minutes")

    def pause_1_hour(self, _sender) -> None:
        self._set_pause("1h", "Sync paused for 1 hour")

    def pause_until_tomorrow(self, _sender) -> None:
        self._set_pause("tomorrow", "Sync paused until tomorrow 9 AM")

    def pause_indefinitely(self, _sender) -> None:
        self._set_pause("indefinite", "Sync paused")

    def resume_sync(self, _sender) -> None:
        self._set_pause(None, "Sync resumed")

    def open_sync_folder(self, _sender) -> None:
        _open_path(load_menu_status().local_root)

    def open_logs(self, _sender) -> None:
        _open_path(log_path().parent)

    def reveal_config(self, _sender) -> None:
        _open_path(config_path())

    def reveal_database(self, _sender) -> None:
        _open_path(database_path())

    def _toggle_autostart_target(self, target: str, enabled_title: str, disabled_title: str) -> None:
        try:
            autostart = AutoStart(target=target)
        except Exception as exc:
            self.notify("Autostart unavailable", str(exc))
            return

        if autostart.enabled:
            autostart.disable()
            self.notify(disabled_title, "Disabled.")
        else:
            path = autostart.enable()
            self.notify(enabled_title, f"Launch agent saved to {path}.")

        self.refresh_status(None)

    def toggle_menu_bar_autostart(self, _sender) -> None:
        self._toggle_autostart_target(
            "gui",
            "Menu Bar App Opens at Login",
            "Menu Bar App Won't Open at Login",
        )

    def toggle_daemon_autostart(self, _sender) -> None:
        self._toggle_autostart_target(
            "daemon",
            "Sync Engine Starts at Login",
            "Sync Engine Won't Start at Login",
        )

    def show_about(self, _sender) -> None:
        snapshot = load_menu_status()
        if _show_about_dialog(snapshot):
            return
        # Fallback to rumps.alert if AppKit is unavailable
        self.rumps.alert(
            title=APP_NAME,
            message=(
                f"Version: 0.1.0 / Python {sys.version.split()[0]}\n\n"
                f"Status: {_primary_status_label(snapshot)}\n"
                f"Sync Mode: {_sync_mode_label(snapshot)}\n"
                f"Tracked Items: {snapshot.tracked_items}\n"
                f"Last Sync: {snapshot.last_sync}"
            ),
        )

    def quit_app(self, _sender) -> None:
        self.timer.stop()
        self.rumps.quit_application()


def run_menu_bar_app() -> None:
    ImageRelayMenuBarApp().run()


def main() -> None:
    run_menu_bar_app()
