from __future__ import annotations

from .api import ImageRelayApiError
from .sync_pause import SyncPausedError


def user_message_for_error(error: Exception) -> str:
    if isinstance(error, SyncPausedError):
        return str(error)
    if isinstance(error, ImageRelayApiError):
        return _api_error_message(error)
    return str(error)


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
