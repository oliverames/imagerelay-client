from __future__ import annotations

import sqlite3
import time
from collections import deque
from contextlib import suppress
from email.utils import parsedate_to_datetime
from pathlib import Path
from threading import Lock
from typing import Any

import requests

from .appdirs import rate_limit_path
from .config import Settings
from .models import QuickLink, RemoteFile, RemoteFolder


MAX_REQUESTS_PER_SECOND = 5
MAX_RETRIES = 3
MAX_RETRY_DELAY_SECONDS = 30
RETRYABLE_STATUS_CODES = {429, 502, 503}


class ImageRelayApiError(RuntimeError):
    def __init__(self, message: str, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


class ApiRateLimiter:
    def __init__(self, max_requests: int = MAX_REQUESTS_PER_SECOND, period: float = 1.0) -> None:
        self.max_requests = max_requests
        self.period = period
        self._timestamps: deque[float] = deque()
        self._lock = Lock()

    def wait(self) -> None:
        while True:
            with self._lock:
                now = time.monotonic()

                while self._timestamps and now - self._timestamps[0] >= self.period:
                    self._timestamps.popleft()

                if len(self._timestamps) < self.max_requests:
                    self._timestamps.append(now)
                    return

                sleep_for = self.period - (now - self._timestamps[0]) + 0.01

            time.sleep(max(sleep_for, 0.01))


class SharedApiRateLimiter:
    def __init__(
        self,
        state_path: Path,
        max_requests: int = MAX_REQUESTS_PER_SECOND,
        period: float = 1.0,
    ) -> None:
        self.state_path = Path(state_path)
        self.max_requests = max_requests
        self.period = period
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize_db()

    def wait(self) -> None:
        while True:
            now = time.time()
            cutoff = now - self.period

            with self._connect() as connection:
                connection.execute("BEGIN IMMEDIATE")
                connection.execute("DELETE FROM request_timestamps WHERE ts <= ?", (cutoff,))
                count, oldest = connection.execute(
                    "SELECT COUNT(*), MIN(ts) FROM request_timestamps"
                ).fetchone()

                if count < self.max_requests:
                    connection.execute("INSERT INTO request_timestamps (ts) VALUES (?)", (now,))
                    connection.commit()
                    return

                connection.commit()

            oldest_ts = float(oldest) if oldest is not None else now
            sleep_for = self.period - (now - oldest_ts) + 0.01
            time.sleep(max(sleep_for, 0.01))

    def _initialize_db(self) -> None:
        with self._connect() as connection:
            connection.execute(
                "CREATE TABLE IF NOT EXISTS request_timestamps (ts REAL NOT NULL)"
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_request_timestamps_ts ON request_timestamps (ts)"
            )

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.state_path, timeout=30.0, isolation_level=None)
        connection.execute("PRAGMA busy_timeout = 30000")
        return connection


class ImageRelayApiClient:
    def __init__(self, settings: Settings, logger) -> None:
        self.settings = settings
        self.logger = logger
        self.rate_limiter = SharedApiRateLimiter(rate_limit_path())
        self.session = requests.Session()
        self.base_url = settings.resolved_base_url()

    def list_folders(self) -> list[RemoteFolder]:
        items = self._paged_get("folders.json")
        return [self._parse_folder(item) for item in items]

    def get_folder(self, folder_id: int) -> RemoteFolder:
        data = self._json_request("GET", f"folders/{folder_id}.json")
        return self._parse_folder(data)

    def get_root_folder(self) -> RemoteFolder:
        data = self._json_request("GET", "folders/root.json")
        return self._parse_folder(data)

    def create_folder(self, parent_id: int, name: str) -> RemoteFolder:
        data = self._json_request("POST", "folders.json", json={"parent_id": parent_id, "name": name})
        return self._parse_folder(data)

    def update_folder(self, folder_id: int, name: str) -> RemoteFolder:
        data = self._json_request("PUT", f"folders/{folder_id}.json", json={"name": name})
        return self._parse_folder(data)

    def delete_folder(self, folder_id: int) -> None:
        self._request("DELETE", f"folders/{folder_id}.json", expected_status=(200, 202, 204))

    def list_files(
        self,
        folder_id: int,
        recursive: bool = True,
        query: str | None = None,
        uploaded_after: str | None = None,
    ) -> list[RemoteFile]:
        params: dict[str, Any] = {"recursive": str(recursive).lower()}
        if query:
            params["query"] = query
        if uploaded_after:
            params["uploaded_after"] = uploaded_after

        items = self._paged_get(f"folders/{folder_id}/files.json", params=params)
        return [self._parse_file(item) for item in items]

    def delete_file(self, file_id: int) -> None:
        self._request("DELETE", f"files/{file_id}.json", expected_status=(200, 202, 204))

    def move_file(self, file_id: int, folder_ids: list[int]) -> RemoteFile:
        data = self._json_request(
            "POST",
            f"files/{file_id}/move.json",
            json={"folder_ids": [str(folder_id) for folder_id in folder_ids]},
        )
        return self._parse_file(data)

    def upload_new_asset(self, local_path: Path, folder_id: int, file_type_id: int) -> int:
        payload = {
            "folder_id": folder_id,
            "file_type_id": file_type_id,
            "files": [{"file_name": local_path.name, "file_size": local_path.stat().st_size}],
        }
        data = self._json_request("POST", "upload_jobs.json", json=payload)

        upload_job_id = int(data["id"])
        files = data.get("files") or []
        if not files:
            raise ImageRelayApiError("Upload job response did not include an upload file ID.")
        upload_file_id = int(files[0]["id"])

        self._upload_binary_chunks(
            local_path,
            lambda chunk_number: f"upload_jobs/{upload_job_id}/files/{upload_file_id}/chunks/{chunk_number}",
            chunk_size=min(self.settings.upload_chunk_size, 5 * 1024 * 1024),
        )

        return self._wait_for_upload_job(upload_job_id)

    def upload_new_version(self, file_id: int, local_path: Path) -> str:
        data = self._json_request("POST", f"files/{file_id}/versions.json")
        upload_uuid = data.get("uuid")
        if not upload_uuid:
            raise ImageRelayApiError("Version upload did not return a UUID.")

        chunk_count = self._upload_binary_chunks(
            local_path,
            lambda chunk_number: f"files/{file_id}/versions/{upload_uuid}/chunk/{chunk_number}",
            chunk_size=min(self.settings.version_chunk_size, 5 * 1024 * 1024),
        )

        self._json_request(
            "POST",
            f"files/{file_id}/versions/{upload_uuid}/complete.json",
            json={"file_name": local_path.name, "chunk_count": chunk_count},
            expected_status=(200, 201, 202),
        )

        return str(upload_uuid)

    def create_quick_link(self, asset_id: int, purpose: str, disposition: str = "attachment") -> QuickLink:
        data = self._json_request(
            "POST",
            "quick_links.json",
            json={
                "asset_id": asset_id,
                "purpose": purpose,
                "disposition": disposition,
            },
        )
        return QuickLink(quick_link_id=int(data["id"]), url=str(data["url"]))

    def delete_quick_link(self, quick_link_id: int) -> None:
        self._request("DELETE", f"quick_links/{quick_link_id}.json", expected_status=(200, 202, 204))

    def download_asset(self, asset_id: int, destination: Path, purpose: str) -> None:
        quick_link = self.create_quick_link(asset_id=asset_id, purpose=purpose)
        destination.parent.mkdir(parents=True, exist_ok=True)

        try:
            response = self._request(
                "GET",
                quick_link.url,
                headers={"Accept": "*/*"},
                expected_status=(200,),
                include_auth=False,
                accept_json=False,
                stream=True,
            )
            try:
                with destination.open("wb") as file_handle:
                    for chunk in response.iter_content(chunk_size=1024 * 1024):
                        if chunk:
                            file_handle.write(chunk)
            finally:
                response.close()
        finally:
            with suppress(Exception):
                self.delete_quick_link(quick_link.quick_link_id)

    def _upload_binary_chunks(
        self,
        local_path: Path,
        endpoint_builder,
        chunk_size: int,
    ) -> int:
        chunk_number = 0

        with local_path.open("rb") as file_handle:
            while True:
                chunk = file_handle.read(chunk_size)
                if not chunk:
                    break

                chunk_number += 1
                self._request(
                    "POST",
                    endpoint_builder(chunk_number),
                    data=chunk,
                    headers={"Content-Type": "application/octet-stream"},
                    expected_status=(200, 201, 202, 204),
                )

        return chunk_number

    def _wait_for_upload_job(self, upload_job_id: int, timeout: int = 300) -> int:
        deadline = time.monotonic() + timeout

        while time.monotonic() < deadline:
            data = self._json_request("GET", f"upload_jobs/{upload_job_id}.json")
            finished = data.get("finished")
            asset_id = data.get("asset_id")
            if finished and asset_id is not None:
                return int(asset_id)
            time.sleep(2.0)

        raise ImageRelayApiError(f"Upload job {upload_job_id} did not finish within {timeout} seconds.")

    def _paged_get(self, path: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        page = 1
        per_page = 100
        results: list[dict[str, Any]] = []

        while True:
            query = {"page": page, "per_page": per_page}
            if params:
                query.update(params)

            response = self._request("GET", path, params=query)
            body = response.json() if response.content else []

            if isinstance(body, dict) and "pagination" in body:
                items = []
                for key, value in body.items():
                    if key != "pagination" and isinstance(value, list):
                        items = value
                        break
                pagination = body.get("pagination") or {}
                results.extend(items)
                has_next = pagination.get("next") is not None or pagination.get("has_next") is True
            elif isinstance(body, list):
                results.extend(body)
                link_header = response.headers.get("Link", "")
                has_next = 'rel="next"' in link_header or len(body) >= per_page
            else:
                raise ImageRelayApiError(f"Unexpected paginated response format from {path}.")

            if not has_next:
                break

            page += 1

        return results

    def _json_request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json: dict[str, Any] | None = None,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
        expected_status: tuple[int, ...] = (200, 201),
    ) -> dict[str, Any]:
        response = self._request(
            method,
            path,
            params=params,
            json=json,
            data=data,
            headers=headers,
            expected_status=expected_status,
        )
        if not response.content:
            return {}
        payload = response.json()
        if not isinstance(payload, dict):
            raise ImageRelayApiError(f"Expected a JSON object from {path}.")
        return payload

    def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json: dict[str, Any] | None = None,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
        expected_status: tuple[int, ...] = (200, 201),
        include_auth: bool = True,
        accept_json: bool = True,
        stream: bool = False,
    ) -> requests.Response:
        url = path if path.startswith("http://") or path.startswith("https://") else f"{self.base_url.rstrip('/')}/{path.lstrip('/')}"
        request_headers = {"User-Agent": self.settings.user_agent}
        if accept_json:
            request_headers["Accept"] = "application/json"
        if include_auth:
            api_key = self.settings.resolved_api_key()
            if not api_key:
                raise ImageRelayApiError(
                    "No Image Relay API key is configured. Run `imagerelay-client init --api-key ...` first."
                )
            request_headers["Authorization"] = f"Bearer {api_key}"
        if json is not None:
            request_headers["Content-Type"] = "application/json"
        if headers:
            request_headers.update(headers)

        last_error: Exception | None = None

        for attempt in range(MAX_RETRIES):
            self.rate_limiter.wait()

            try:
                response = self.session.request(
                    method=method,
                    url=url,
                    params=params,
                    json=json,
                    data=data,
                    headers=request_headers,
                    timeout=self.settings.request_timeout_seconds,
                    stream=stream,
                )
            except requests.RequestException as error:
                last_error = error
                self.logger.warning("Request failed for %s %s: %s", method, path, error)
                if attempt < MAX_RETRIES - 1:
                    time.sleep((attempt + 1) * 0.5)
                    continue
                raise ImageRelayApiError(f"{method} {url} failed: {error}") from error

            if response.status_code in expected_status:
                self.logger.debug("%s %s -> %s", method, path, response.status_code)
                return response

            if response.status_code in RETRYABLE_STATUS_CODES and attempt < MAX_RETRIES - 1:
                backoff = self._retry_delay_seconds(response.headers.get("Retry-After"), attempt)
                self.logger.warning(
                    "Retrying %s %s after %s (%s)",
                    method,
                    path,
                    response.status_code,
                    backoff,
                )
                response.close()
                time.sleep(backoff)
                continue

            body = response.text.strip()
            raise ImageRelayApiError(
                self._format_error_message(method, path, response.status_code, body),
                status_code=response.status_code,
            )

        if last_error:
            raise ImageRelayApiError(f"{method} {path} failed: {last_error}") from last_error
        raise ImageRelayApiError(f"{method} {path} failed for an unknown reason.")

    @staticmethod
    def _retry_delay_seconds(retry_after: str | None, attempt: int) -> float:
        if retry_after:
            if retry_after.isdigit():
                return min(int(retry_after), MAX_RETRY_DELAY_SECONDS)

            with suppress(ValueError, OverflowError, TypeError):
                retry_at = parsedate_to_datetime(retry_after)
                delay = retry_at.timestamp() - time.time()
                if delay > 0:
                    return min(delay, MAX_RETRY_DELAY_SECONDS)

        return min((attempt + 1) * 1.0, MAX_RETRY_DELAY_SECONDS)

    @staticmethod
    def _format_error_message(method: str, path: str, status_code: int, body: str) -> str:
        details = body or "No response body."
        if status_code == 401:
            guidance = "Unauthorized. Check the configured API key and account permissions."
        elif status_code == 403:
            guidance = (
                "Forbidden. Check that the User-Agent identifies the app with a URL or email, "
                "and confirm this account can perform the requested action."
            )
        elif status_code == 404:
            guidance = "Not found. The remote folder, file, or endpoint may no longer exist."
        elif status_code == 429:
            guidance = "Too many requests. The client will retry where possible."
        else:
            guidance = "Request failed."
        return f"{method} {path} returned {status_code}. {guidance} Response: {details}"

    @staticmethod
    def _parse_folder(payload: dict[str, Any]) -> RemoteFolder:
        parent_id = payload.get("parent_id")
        return RemoteFolder(
            folder_id=int(payload["id"]),
            name=str(payload["name"]),
            parent_id=int(parent_id) if parent_id is not None else None,
            full_path=str(payload.get("full_path") or payload.get("full_catalog_path") or ""),
            updated_on=str(payload.get("updated_on")) if payload.get("updated_on") else None,
            child_count=int(payload.get("child_count") or 0),
        )

    @staticmethod
    def _parse_file(payload: dict[str, Any]) -> RemoteFile:
        folder_ids = [int(folder_id) for folder_id in payload.get("folder_ids") or []]
        file_type_id = payload.get("file_type_id")
        return RemoteFile(
            file_id=int(payload["id"]),
            name=str(payload.get("filename") or payload.get("name") or ""),
            size=int(payload.get("size") or 0),
            updated_on=str(payload.get("updated_on")) if payload.get("updated_on") else None,
            content_type=str(payload.get("content_type")) if payload.get("content_type") else None,
            file_type_id=int(file_type_id) if file_type_id is not None else None,
            folder_ids=folder_ids,
            deleted=bool(payload.get("deleted", False)),
        )
