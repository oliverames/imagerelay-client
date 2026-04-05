from __future__ import annotations

import errno

import requests

from .api import ImageRelayApiError
from .config import SyncConfigurationError
from .daemon import DaemonLockError
from .sync_pause import SyncPausedError


def user_message_for_error(error: Exception) -> str:
    if isinstance(error, SyncPausedError):
        return str(error)
    if isinstance(error, ImageRelayApiError):
        return _api_error_message(error)
    if isinstance(error, SyncConfigurationError):
        return (
            "Sync is not configured yet. Run `imagerelay-client init` to set up "
            "your API key, root folder, and file type."
        )
    if isinstance(error, DaemonLockError):
        return (
            "Another sync instance is already running. "
            "Stop it first with `imagerelay-client daemon stop`."
        )
    if isinstance(error, requests.ConnectionError):
        return "Cannot reach Image Relay. Check your internet connection and try again."
    if isinstance(error, requests.Timeout):
        return (
            "The request to Image Relay timed out. "
            "The server may be slow or your connection interrupted."
        )
    if isinstance(error, PermissionError):
        return f"Permission denied: {error.filename or 'a file'}. Check that the sync folder is writable."
    if isinstance(error, OSError) and error.errno == errno.ENOSPC:
        return "Not enough disk space to complete this sync operation."
    if isinstance(error, OSError):
        return f"File system error: {error.strerror}"
    return str(error)


def cross_parent_move_message(src_path: str, dst_path: str) -> str:
    return (
        "Folder move not supported: Moving folders between different parent directories "
        "isn't supported by Image Relay. The folder has been moved back to its original "
        "location. To reorganize, move individual files or delete and re-create the folder."
    )


def _api_error_message(error: ImageRelayApiError) -> str:
    base = str(error)
    status_code = error.status_code

    if status_code == 401:
        return (
            "Image Relay rejected the API key or account permissions. "
            "Check `api_key`, account access, and whether the token is still valid.\n"
            f"Details: {base}"
        )

    if status_code == 403:
        return (
            "Image Relay refused the request. "
            "Check that `user_agent` identifies the app with a URL or email, "
            "and confirm the account has permission for this action.\n"
            f"Details: {base}"
        )

    if status_code == 404:
        return (
            "Image Relay could not find the requested resource. "
            "Check `remote_root_folder_id` and whether the remote folder or file still exists.\n"
            f"Details: {base}"
        )

    if status_code == 429:
        return (
            "Image Relay is throttling requests right now. "
            "The client backs off automatically, but another app or machine may also be using the same IP.\n"
            f"Details: {base}"
        )

    if status_code in {502, 503, 504}:
        return (
            "Image Relay is temporarily unavailable. "
            "The daemon will retry automatically.\n"
            f"Details: {base}"
        )

    return base
