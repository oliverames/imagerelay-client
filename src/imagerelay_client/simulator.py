from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from contextlib import AbstractContextManager
from dataclasses import dataclass, field
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse


def _now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


@dataclass(slots=True)
class MockFolder:
    folder_id: int
    name: str
    parent_id: int | None
    updated_on: str


@dataclass(slots=True)
class MockFile:
    file_id: int
    name: str
    folder_ids: list[int]
    file_type_id: int
    content: bytes
    updated_on: str
    content_type: str = "application/octet-stream"


@dataclass(slots=True)
class MockUploadJob:
    upload_job_id: int
    upload_file_id: int
    folder_id: int
    file_type_id: int
    file_name: str
    chunks: dict[int, bytes] = field(default_factory=dict)
    asset_id: int | None = None


@dataclass(slots=True)
class MockVersionUpload:
    file_id: int
    upload_uuid: str
    chunks: dict[int, bytes] = field(default_factory=dict)


@dataclass(slots=True)
class DemoResult:
    api_base_url: str
    client_home: Path
    local_root: Path
    log_path: Path
    remote_files: dict[str, bytes]


class MockImageRelayState:
    def __init__(self, api_key: str = "test-key") -> None:
        self.api_key = api_key
        self.lock = threading.RLock()
        self.base_url = ""
        self.next_folder_id = 2
        self.next_file_id = 100
        self.next_quick_link_id = 1000
        self.next_upload_job_id = 2000
        self.next_upload_file_id = 3000
        self.folders: dict[int, MockFolder] = {
            1: MockFolder(folder_id=1, name="Root", parent_id=None, updated_on=_now_iso())
        }
        self.files: dict[int, MockFile] = {}
        self.upload_jobs: dict[int, MockUploadJob] = {}
        self.version_uploads: dict[tuple[int, str], MockVersionUpload] = {}
        self.quick_links: dict[int, int] = {}
        self.throttle_next_download = False
        self.download_throttle_count = 0
        self.fail_once_routes: dict[tuple[str, str], tuple[int, dict[str, Any]]] = {}

    def set_base_url(self, base_url: str) -> None:
        self.base_url = base_url.rstrip("/")

    def fail_next_route(
        self,
        method: str,
        route: str,
        *,
        status: int,
        payload: dict[str, Any] | None = None,
    ) -> None:
        with self.lock:
            self.fail_once_routes[(method.upper(), route)] = (
                status,
                payload or {"error": "Temporary simulator failure"},
            )

    def consume_route_failure(
        self,
        method: str,
        route: str,
    ) -> tuple[int, dict[str, Any]] | None:
        with self.lock:
            return self.fail_once_routes.pop((method.upper(), route), None)

    def add_folder(self, parent_id: int, name: str) -> MockFolder:
        with self.lock:
            folder = MockFolder(
                folder_id=self.next_folder_id,
                name=name,
                parent_id=parent_id,
                updated_on=_now_iso(),
            )
            self.next_folder_id += 1
            self.folders[folder.folder_id] = folder
            return folder

    def update_folder(self, folder_id: int, name: str) -> MockFolder:
        with self.lock:
            folder = self.folders[folder_id]
            folder.name = name
            folder.updated_on = _now_iso()
            return folder

    def delete_folder(self, folder_id: int) -> None:
        with self.lock:
            descendants = self.descendant_folder_ids(folder_id)
            file_ids = [
                file_id
                for file_id, remote_file in self.files.items()
                if any(folder in descendants for folder in remote_file.folder_ids)
            ]
            for file_id in file_ids:
                self.files.pop(file_id, None)
            for descendant in descendants:
                if descendant != 1:
                    self.folders.pop(descendant, None)

    def add_file(
        self,
        folder_id: int,
        name: str,
        content: bytes,
        file_type_id: int = 7,
        folder_ids: list[int] | None = None,
    ) -> MockFile:
        with self.lock:
            effective_folder_ids = folder_ids or [folder_id]
            remote_file = MockFile(
                file_id=self.next_file_id,
                name=name,
                folder_ids=effective_folder_ids,
                file_type_id=file_type_id,
                content=content,
                updated_on=_now_iso(),
            )
            self.next_file_id += 1
            self.files[remote_file.file_id] = remote_file
            return remote_file

    def update_file_content(
        self, file_id: int, content: bytes, file_name: str | None = None
    ) -> MockFile:
        with self.lock:
            remote_file = self.files[file_id]
            remote_file.content = content
            if file_name:
                remote_file.name = file_name
            remote_file.updated_on = _now_iso()
            return remote_file

    def delete_file(self, file_id: int) -> None:
        with self.lock:
            self.files.pop(file_id, None)

    def move_file(self, file_id: int, folder_ids: list[int]) -> MockFile:
        with self.lock:
            remote_file = self.files[file_id]
            remote_file.folder_ids = folder_ids
            remote_file.updated_on = _now_iso()
            return remote_file

    def create_upload_job(
        self, folder_id: int, file_type_id: int, file_name: str
    ) -> MockUploadJob:
        with self.lock:
            job = MockUploadJob(
                upload_job_id=self.next_upload_job_id,
                upload_file_id=self.next_upload_file_id,
                folder_id=folder_id,
                file_type_id=file_type_id,
                file_name=file_name,
            )
            self.next_upload_job_id += 1
            self.next_upload_file_id += 1
            self.upload_jobs[job.upload_job_id] = job
            return job

    def append_upload_chunk(self, upload_job_id: int, chunk_number: int, data: bytes) -> None:
        with self.lock:
            self.upload_jobs[upload_job_id].chunks[chunk_number] = data

    def upload_job_status(self, upload_job_id: int) -> dict[str, Any]:
        with self.lock:
            job = self.upload_jobs[upload_job_id]
            if job.asset_id is None and job.chunks:
                content = b"".join(job.chunks[index] for index in sorted(job.chunks))
                remote_file = self.add_file(
                    folder_id=job.folder_id,
                    name=job.file_name,
                    content=content,
                    file_type_id=job.file_type_id,
                )
                job.asset_id = remote_file.file_id

            return {
                "id": job.upload_job_id,
                "finished": True if job.asset_id is not None else None,
                "asset_id": job.asset_id,
            }

    def start_version_upload(self, file_id: int) -> str:
        with self.lock:
            upload_uuid = str(uuid.uuid4())
            self.version_uploads[(file_id, upload_uuid)] = MockVersionUpload(
                file_id=file_id,
                upload_uuid=upload_uuid,
            )
            return upload_uuid

    def append_version_chunk(
        self, file_id: int, upload_uuid: str, chunk_number: int, data: bytes
    ) -> None:
        with self.lock:
            self.version_uploads[(file_id, upload_uuid)].chunks[chunk_number] = data

    def complete_version_upload(
        self, file_id: int, upload_uuid: str, file_name: str, chunk_count: int
    ) -> MockFile:
        with self.lock:
            upload = self.version_uploads[(file_id, upload_uuid)]
            content = b"".join(upload.chunks[index] for index in range(1, chunk_count + 1))
            remote_file = self.update_file_content(file_id, content, file_name=file_name)
            self.version_uploads.pop((file_id, upload_uuid), None)
            return remote_file

    def create_quick_link(self, asset_id: int) -> dict[str, Any]:
        with self.lock:
            quick_link_id = self.next_quick_link_id
            self.next_quick_link_id += 1
            self.quick_links[quick_link_id] = asset_id
            return {
                "id": quick_link_id,
                "url": f"{self.base_url}/download/{quick_link_id}",
            }

    def delete_quick_link(self, quick_link_id: int) -> None:
        with self.lock:
            self.quick_links.pop(quick_link_id, None)

    def quick_link_content(self, quick_link_id: int) -> bytes:
        with self.lock:
            asset_id = self.quick_links[quick_link_id]
            return self.files[asset_id].content

    def descendant_folder_ids(self, folder_id: int) -> set[int]:
        descendants: set[int] = set()
        stack = [folder_id]
        while stack:
            current = stack.pop()
            if current in descendants:
                continue
            descendants.add(current)
            stack.extend(
                child.folder_id for child in self.folders.values() if child.parent_id == current
            )
        return descendants

    def folder_full_path(self, folder_id: int) -> str:
        parts: list[str] = []
        current = self.folders[folder_id]
        while current.parent_id is not None:
            parts.append(current.name)
            current = self.folders[current.parent_id]
        return "/".join(reversed(parts))

    def folder_payload(self, folder: MockFolder) -> dict[str, Any]:
        return {
            "id": folder.folder_id,
            "name": folder.name,
            "parent_id": folder.parent_id,
            "full_path": self.folder_full_path(folder.folder_id),
            "updated_on": folder.updated_on,
        }

    def file_payload(self, remote_file: MockFile) -> dict[str, Any]:
        return {
            "id": remote_file.file_id,
            "name": remote_file.name,
            "size": len(remote_file.content),
            "updated_on": remote_file.updated_on,
            "content_type": remote_file.content_type,
            "file_type_id": remote_file.file_type_id,
            "folder_ids": remote_file.folder_ids,
            "deleted": False,
        }

    def list_folders(self) -> list[dict[str, Any]]:
        with self.lock:
            return [self.folder_payload(folder) for folder in self.folders.values()]

    def list_files(self, folder_id: int, recursive: bool) -> list[dict[str, Any]]:
        with self.lock:
            allowed = self.descendant_folder_ids(folder_id) if recursive else {folder_id}
            return [
                self.file_payload(remote_file)
                for remote_file in self.files.values()
                if any(folder in allowed for folder in remote_file.folder_ids)
            ]

    def canonical_rel_paths(self) -> dict[str, bytes]:
        with self.lock:
            results: dict[str, bytes] = {}
            for remote_file in self.files.values():
                rel_paths = sorted(
                    str(PurePosixPath(self.folder_full_path(folder_id)) / remote_file.name)
                    if folder_id != 1
                    else remote_file.name
                    for folder_id in remote_file.folder_ids
                )
                if rel_paths:
                    results[rel_paths[0]] = remote_file.content
            return results

    def find_folder_by_rel_path(self, rel_path: str) -> MockFolder | None:
        target = str(PurePosixPath(rel_path))
        with self.lock:
            for folder in self.folders.values():
                if folder.folder_id == 1:
                    continue
                if self.folder_full_path(folder.folder_id) == target:
                    return folder
        return None

    def find_file_by_rel_path(self, rel_path: str) -> MockFile | None:
        target = str(PurePosixPath(rel_path))
        with self.lock:
            for remote_file in self.files.values():
                rel_paths = sorted(
                    str(PurePosixPath(self.folder_full_path(folder_id)) / remote_file.name)
                    if folder_id != 1
                    else remote_file.name
                    for folder_id in remote_file.folder_ids
                )
                if rel_paths and rel_paths[0] == target:
                    return remote_file
        return None


class MockImageRelayServer(AbstractContextManager["MockImageRelayServer"]):
    def __init__(
        self,
        state: MockImageRelayState,
        host: str = "127.0.0.1",
        port: int = 0,
    ) -> None:
        self.state = state
        self.host = host
        self.port = port
        self.httpd: ThreadingHTTPServer | None = None
        self.thread: threading.Thread | None = None

    @property
    def api_base_url(self) -> str:
        if self.httpd is None:
            raise RuntimeError("Server is not running.")
        host, port = self.httpd.server_address
        return f"http://{host}:{port}/api/v2"

    @property
    def download_base_url(self) -> str:
        if self.httpd is None:
            raise RuntimeError("Server is not running.")
        host, port = self.httpd.server_address
        return f"http://{host}:{port}"

    def start(self) -> MockImageRelayServer:
        if self.httpd is not None:
            return self

        state = self.state

        class Handler(BaseHTTPRequestHandler):
            server_version = "MockImageRelay/1.0"

            def log_message(self, format: str, *args) -> None:
                return

            def do_GET(self) -> None:
                self._dispatch("GET")

            def do_POST(self) -> None:
                self._dispatch("POST")

            def do_PUT(self) -> None:
                self._dispatch("PUT")

            def do_DELETE(self) -> None:
                self._dispatch("DELETE")

            def _dispatch(self, method: str) -> None:
                parsed = urlparse(self.path)
                path = parsed.path

                if path.startswith("/download/"):
                    self._handle_download(path)
                    return

                if not self.headers.get("User-Agent"):
                    self._send_json(403, {"error": "Missing User-Agent"})
                    return

                if self.headers.get("Authorization") != f"Bearer {state.api_key}":
                    self._send_json(401, {"error": "Unauthorized"})
                    return

                if not path.startswith("/api/v2/"):
                    self._send_json(404, {"error": "Not found"})
                    return

                route = path[len("/api/v2/") :]
                parts = [part for part in route.split("/") if part]
                query = parse_qs(parsed.query)
                forced_failure = state.consume_route_failure(method, route)
                if forced_failure is not None:
                    status, payload = forced_failure
                    self._send_json(status, payload)
                    return

                try:
                    if method == "GET" and route == "folders.json":
                        self._send_json(200, state.list_folders())
                    elif method == "GET" and route == "folders/root.json":
                        self._send_json(200, state.folder_payload(state.folders[1]))
                    elif method == "POST" and route == "folders.json":
                        body = self._read_json()
                        folder = state.add_folder(int(body["parent_id"]), str(body["name"]))
                        self._send_json(201, state.folder_payload(folder))
                    elif (
                        method == "PUT"
                        and len(parts) == 2
                        and parts[0] == "folders"
                        and parts[1].endswith(".json")
                    ):
                        body = self._read_json()
                        folder_id = int(parts[1].removesuffix(".json"))
                        folder = state.update_folder(folder_id, str(body["name"]))
                        self._send_json(200, state.folder_payload(folder))
                    elif (
                        method == "DELETE"
                        and len(parts) == 2
                        and parts[0] == "folders"
                        and parts[1].endswith(".json")
                    ):
                        folder_id = int(parts[1].removesuffix(".json"))
                        state.delete_folder(folder_id)
                        self._send_empty(204)
                    elif (
                        method == "GET"
                        and len(parts) == 3
                        and parts[0] == "folders"
                        and parts[1].isdigit()
                        and parts[2] == "files.json"
                    ):
                        folder_id = int(parts[1])
                        recursive = query.get("recursive", ["true"])[0].lower() != "false"
                        self._send_json(200, state.list_files(folder_id, recursive))
                    elif (
                        method == "DELETE"
                        and len(parts) == 2
                        and parts[0] == "files"
                        and parts[1].endswith(".json")
                    ):
                        file_id = int(parts[1].removesuffix(".json"))
                        state.delete_file(file_id)
                        self._send_empty(204)
                    elif (
                        method == "POST"
                        and len(parts) == 3
                        and parts[0] == "files"
                        and parts[1].isdigit()
                        and parts[2] == "move.json"
                    ):
                        body = self._read_json()
                        file_id = int(parts[1])
                        moved = state.move_file(
                            file_id, [int(folder_id) for folder_id in body["folder_ids"]]
                        )
                        self._send_json(200, state.file_payload(moved))
                    elif method == "POST" and route == "upload_jobs.json":
                        body = self._read_json()
                        file_info = body["files"][0]
                        job = state.create_upload_job(
                            folder_id=int(body["folder_id"]),
                            file_type_id=int(body["file_type_id"]),
                            file_name=str(file_info["file_name"]),
                        )
                        self._send_json(
                            201, {"id": job.upload_job_id, "files": [{"id": job.upload_file_id}]}
                        )
                    elif (
                        method == "POST"
                        and len(parts) == 6
                        and parts[0] == "upload_jobs"
                        and parts[1].isdigit()
                        and parts[2] == "files"
                        and parts[3].isdigit()
                        and parts[4] == "chunks"
                    ):
                        upload_job_id = int(parts[1])
                        chunk_number = int(parts[5])
                        state.append_upload_chunk(upload_job_id, chunk_number, self._read_bytes())
                        self._send_empty(204)
                    elif (
                        method == "GET"
                        and len(parts) == 2
                        and parts[0] == "upload_jobs"
                        and parts[1].endswith(".json")
                    ):
                        upload_job_id = int(parts[1].removesuffix(".json"))
                        self._send_json(200, state.upload_job_status(upload_job_id))
                    elif (
                        method == "POST"
                        and len(parts) == 3
                        and parts[0] == "files"
                        and parts[1].isdigit()
                        and parts[2] == "versions.json"
                    ):
                        file_id = int(parts[1])
                        self._send_json(201, {"uuid": state.start_version_upload(file_id)})
                    elif (
                        method == "POST"
                        and len(parts) == 6
                        and parts[0] == "files"
                        and parts[1].isdigit()
                        and parts[2] == "versions"
                        and parts[4] == "chunk"
                    ):
                        file_id = int(parts[1])
                        upload_uuid = parts[3]
                        chunk_number = int(parts[5])
                        state.append_version_chunk(
                            file_id, upload_uuid, chunk_number, self._read_bytes()
                        )
                        self._send_empty(204)
                    elif (
                        method == "POST"
                        and len(parts) == 5
                        and parts[0] == "files"
                        and parts[1].isdigit()
                        and parts[2] == "versions"
                        and parts[4] == "complete.json"
                    ):
                        body = self._read_json()
                        file_id = int(parts[1])
                        upload_uuid = parts[3]
                        updated = state.complete_version_upload(
                            file_id=file_id,
                            upload_uuid=upload_uuid,
                            file_name=str(body["file_name"]),
                            chunk_count=int(body["chunk_count"]),
                        )
                        self._send_json(202, state.file_payload(updated))
                    elif method == "POST" and route == "quick_links.json":
                        body = self._read_json()
                        self._send_json(201, state.create_quick_link(int(body["asset_id"])))
                    elif (
                        method == "DELETE"
                        and len(parts) == 2
                        and parts[0] == "quick_links"
                        and parts[1].endswith(".json")
                    ):
                        quick_link_id = int(parts[1].removesuffix(".json"))
                        state.delete_quick_link(quick_link_id)
                        self._send_empty(204)
                    else:
                        self._send_json(404, {"error": f"Unhandled route: {method} {route}"})
                except KeyError as exc:
                    self._send_json(404, {"error": f"Missing resource: {exc.args[0]}"})

            def _handle_download(self, path: str) -> None:
                quick_link_id = int(path.rsplit("/", 1)[1])

                if state.throttle_next_download:
                    state.throttle_next_download = False
                    state.download_throttle_count += 1
                    self.send_response(429)
                    self.send_header("Retry-After", "1")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return

                try:
                    content = state.quick_link_content(quick_link_id)
                except KeyError:
                    self._send_json(404, {"error": "Unknown quick link"})
                    return

                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)

            def _read_json(self) -> dict[str, Any]:
                raw = self._read_bytes()
                if not raw:
                    return {}
                return json.loads(raw.decode("utf-8"))

            def _read_bytes(self) -> bytes:
                length = int(self.headers.get("Content-Length", "0"))
                return self.rfile.read(length) if length > 0 else b""

            def _send_json(self, status: int, payload: Any) -> None:
                data = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _send_empty(self, status: int) -> None:
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.httpd = ThreadingHTTPServer((self.host, self.port), Handler)
        host, port = self.httpd.server_address
        self.state.set_base_url(f"http://{host}:{port}")
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        return self

    def stop(self) -> None:
        if self.httpd is not None:
            self.httpd.shutdown()
            self.httpd.server_close()
            self.httpd = None
        if self.thread is not None:
            self.thread.join(timeout=5)
            self.thread = None

    def __enter__(self) -> MockImageRelayServer:
        return self.start()

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()


def seed_demo_state(
    state: MockImageRelayState,
    *,
    throttle_first_download: bool = False,
) -> MockImageRelayState:
    remote_only = state.add_folder(1, "RemoteOnly")
    state.add_file(remote_only.folder_id, "hello.txt", b"hello remote", file_type_id=7)

    marketing = state.add_folder(1, "Marketing")
    state.add_file(marketing.folder_id, "brand-guide.pdf", b"brand guide", file_type_id=7)
    state.add_file(
        marketing.folder_id,
        "shared-creative.txt",
        b"shared creative",
        file_type_id=7,
        folder_ids=[marketing.folder_id, remote_only.folder_id],
    )

    state.throttle_next_download = throttle_first_download
    return state


def wait_for(
    predicate: Callable[[], bool],
    description: str,
    *,
    timeout: float = 15.0,
    interval: float = 0.2,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(interval)
    raise RuntimeError(f"Timed out while waiting for {description}.")


def run_demo(
    *,
    python_executable: str | None = None,
    keep_temp: bool = False,
    api_key: str = "test-key",
    user_agent: str = "ImageRelay Client Demo (demo@example.com)",
    output: Callable[[str], None] | None = None,
) -> DemoResult:
    emit = output or (lambda _message: None)
    base_temp_dir = Path(tempfile.mkdtemp(prefix="imagerelay-demo-"))
    client_home = base_temp_dir / "client-home"
    local_root = base_temp_dir / "local-root"
    local_root.mkdir(parents=True, exist_ok=True)

    state = seed_demo_state(MockImageRelayState(api_key=api_key), throttle_first_download=True)
    interpreter = python_executable or sys.executable
    env = os.environ.copy()
    env["IMAGERELAY_CLIENT_HOME"] = str(client_home)

    def run_cli(*args: str, check: bool = True, timeout: float = 30.0) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [interpreter, "-m", "imagerelay_client", *args],
            env=env,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        if check and result.returncode != 0:
            raise RuntimeError(
                f"Command failed: {' '.join(args)}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        return result

    with MockImageRelayServer(state) as server:
        emit(f"Mock API running at {server.api_base_url}")
        run_cli(
            "init",
            "--api-key",
            api_key,
            "--api-base-url",
            server.api_base_url,
            "--local-root",
            str(local_root),
            "--remote-root-folder-id",
            "1",
            "--default-file-type-id",
            "7",
            "--user-agent",
            user_agent,
            "--poll-interval-seconds",
            "1",
        )

        run_cli("sync", "once")
        if (local_root / "RemoteOnly" / "hello.txt").read_text() != "hello remote":
            raise RuntimeError("Initial remote download did not produce the expected file.")
        if not (local_root / "RemoteOnly" / "shared-creative.txt").is_symlink():
            raise RuntimeError("Synced multi-folder asset did not create the expected alias.")
        if (local_root / "Marketing" / "shared-creative.txt").read_text() != "shared creative":
            raise RuntimeError("Synced multi-folder asset is missing its canonical download.")

        emit("Initial remote download succeeded.")
        emit("Synced file alias succeeded.")
        run_cli("daemon", "start")
        emit("Daemon started.")

        try:
            uploads_dir = local_root / "Uploads"
            uploads_dir.mkdir()
            local_file = uploads_dir / "from-local.txt"
            local_file.write_text("version one")
            wait_for(
                lambda: state.find_file_by_rel_path("Uploads/from-local.txt") is not None,
                "local upload",
            )

            remote_file = state.find_file_by_rel_path("Uploads/from-local.txt")
            if remote_file is None or remote_file.content != b"version one":
                raise RuntimeError("Local upload did not reach the simulated API.")

            emit("Local file upload succeeded.")

            local_file.write_text("version two")
            wait_for(
                lambda: (
                    state.find_file_by_rel_path("Uploads/from-local.txt") is not None
                    and state.find_file_by_rel_path("Uploads/from-local.txt").content == b"version two"
                ),
                "version upload",
            )
            emit("Version upload succeeded.")

            remote_later = state.add_folder(1, "RemoteLater")
            state.add_file(remote_later.folder_id, "fresh.txt", b"from remote", file_type_id=7)
            wait_for(
                lambda: (local_root / "RemoteLater" / "fresh.txt").exists(),
                "remote download through daemon poll",
            )
            emit("Remote download through daemon poll succeeded.")

            state.delete_folder(remote_later.folder_id)
            wait_for(
                lambda: not (local_root / "RemoteLater").exists(),
                "remote deletion",
            )
            emit("Remote deletion mirrored locally.")

            local_file.unlink()
            wait_for(
                lambda: state.find_file_by_rel_path("Uploads/from-local.txt") is None,
                "local delete mirrored upstream",
            )
            emit("Local deletion mirrored upstream.")
        finally:
            run_cli("daemon", "stop", check=False)

        status = run_cli("daemon", "status")
        if "not running" not in status.stdout.lower():
            raise RuntimeError("The daemon did not stop cleanly.")

        emit("Daemon stopped cleanly.")

    result = DemoResult(
        api_base_url=server.api_base_url if server.httpd is not None else state.base_url + "/api/v2",
        client_home=client_home,
        local_root=local_root,
        log_path=client_home / "logs" / "client.log",
        remote_files=state.canonical_rel_paths(),
    )

    if not keep_temp:
        shutil.rmtree(base_temp_dir, ignore_errors=True)

    return result
