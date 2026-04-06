# Worklog

## 2026-04-06 -- Selective folder sync, recursive file fix, GUI folder picker

**What changed**: Added selective folder sync feature across all layers (config, sync engine, CLI, GUI). Users can now choose which folders to sync via `folders list/select/show/clear` CLI commands or a native macOS dialog in the menu bar app (Settings > Select Folders to Sync...). The sync engine filters both downloads and uploads to only include selected folders and their descendants.

Fixed a critical bug where `recursive=True` on `list_files()` never actually worked. Python's `bool` serialized as `"True"` (capital T) but the Image Relay API expects lowercase `"true"`. This meant the sync client was never fetching files from subfolders.

Added subfolder discovery: `list_folders()` only returns top-level folders, so subfolders are now discovered from file `folder_ids` and their metadata fetched individually via `get_folder()`. Changed the sync root from 1923998 (Brand Documents and Resources) to 1909821 (account root) to enable cross-folder selection.

When folders are selected, files are fetched from each selected folder directly instead of scanning the entire account root, which is much faster.

**Decisions made**:
- Include-list approach (not exclude-list) for folder selection. Empty list = sync all (backwards compatible).
- Ancestor folders are included in the allowed set for directory structure creation but NOT in upload prefixes, preventing accidental uploads to ancestor-only directories.
- The `.pth` editable install is broken with Python 3.14 (spaces in iCloud path). Using `PYTHONPATH` as workaround for now.
- Folder picker uses NSAlert with accessory scroll view (checkboxes) rather than a standalone NSWindow, matching the existing About dialog pattern.

**Left off at**:
- Sync is actively downloading Photography folder content (~35 files downloaded, hundreds more to go). First sync is slow due to 411+ subfolder metadata fetches; subsequent syncs will be fast.
- The folder picker loads slowly for large accounts because it fetches all files to discover subfolders. Could optimize by caching folder metadata in the database.
- Duplicate log lines appear (each log entry is doubled). Likely a dual-handler issue in logging_utils.py.
- The Python dock icon appears when running the GUI. Needs `LSUIElement` in an app bundle or `LSBackgroundOnly` to suppress.

**Open questions**:
- Should subfolder metadata be cached in the database to avoid re-fetching on every sync pass?
- Should the file fetching strategy change to fetch from each top-level subfolder individually (parallel) rather than from root?
- The editable install (.pth file) doesn't work with Python 3.14 on an iCloud path with spaces. Is this a Python bug or setuptools issue?

---
