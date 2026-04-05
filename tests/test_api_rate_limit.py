from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import bootstrap
from imagerelay_client.api import ApiRateLimiter, ImageRelayApiClient, SharedApiRateLimiter
from imagerelay_client.config import Settings
from imagerelay_client.models import QuickLink


class DummyLogger:
    def __init__(self) -> None:
        self.warnings: list[tuple[object, ...]] = []
        self.debugs: list[tuple[object, ...]] = []

    def warning(self, *args: object) -> None:
        self.warnings.append(args)

    def debug(self, *args: object) -> None:
        self.debugs.append(args)


class FakeRateLimiter:
    def __init__(self) -> None:
        self.calls = 0

    def wait(self) -> None:
        self.calls += 1


class FakeResponse:
    def __init__(
        self,
        status_code: int,
        headers: dict[str, str] | None = None,
        text: str = "",
        content: bytes | None = None,
    ) -> None:
        self.status_code = status_code
        self.headers = headers or {}
        self.text = text
        self.content = content if content is not None else text.encode()
        self.closed = False

    def iter_content(self, chunk_size: int = 1024):
        for offset in range(0, len(self.content), chunk_size):
            yield self.content[offset : offset + chunk_size]

    def close(self) -> None:
        self.closed = True


class FakeSession:
    def __init__(self, responses: list[FakeResponse]) -> None:
        self.responses = responses
        self.requests: list[dict[str, object]] = []

    def request(self, **kwargs):
        self.requests.append(kwargs)
        return self.responses.pop(0)


class ApiRateLimitTests(unittest.TestCase):
    def test_rate_limiter_blocks_after_limit(self) -> None:
        limiter = ApiRateLimiter(max_requests=2, period=0.2)
        start = time.monotonic()

        limiter.wait()
        limiter.wait()
        limiter.wait()

        elapsed = time.monotonic() - start
        self.assertGreaterEqual(elapsed, 0.18)

    def test_shared_rate_limiter_coordinates_instances(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "rate_limit.db"
            limiter_one = SharedApiRateLimiter(db_path, max_requests=1, period=0.2)
            limiter_two = SharedApiRateLimiter(db_path, max_requests=1, period=0.2)
            start = time.monotonic()

            limiter_one.wait()
            limiter_two.wait()

            elapsed = time.monotonic() - start
            self.assertGreaterEqual(elapsed, 0.18)

    def test_request_retries_after_429(self) -> None:
        logger = DummyLogger()
        settings = Settings(api_key="secret", remote_root_folder_id=1, default_file_type_id=1)
        client = ImageRelayApiClient(settings=settings, logger=logger)
        client.rate_limiter = FakeRateLimiter()
        client.session = FakeSession(
            [
                FakeResponse(429, headers={"Retry-After": "3"}, text="slow down"),
                FakeResponse(200, text="{}"),
            ]
        )

        with patch("imagerelay_client.api.time.sleep") as sleep_mock:
            response = client._request("GET", "folders.json")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(client.rate_limiter.calls, 2)
        self.assertEqual(sleep_mock.call_args_list[0].args[0], 3)
        self.assertTrue(logger.warnings)

    def test_download_asset_uses_retrying_request_path(self) -> None:
        logger = DummyLogger()
        settings = Settings(api_key="secret", remote_root_folder_id=1, default_file_type_id=1)
        client = ImageRelayApiClient(settings=settings, logger=logger)
        client.rate_limiter = FakeRateLimiter()
        client.session = FakeSession(
            [
                FakeResponse(429, headers={"Retry-After": "2"}, text="slow down"),
                FakeResponse(200, content=b"hello world"),
            ]
        )
        client.create_quick_link = lambda asset_id, purpose: QuickLink(quick_link_id=7, url="https://download.example.com/file")  # type: ignore[method-assign]
        deleted_links: list[int] = []
        client.delete_quick_link = deleted_links.append  # type: ignore[method-assign]

        with tempfile.TemporaryDirectory() as tmp, patch("imagerelay_client.api.time.sleep") as sleep_mock:
            destination = Path(tmp) / "asset.bin"
            client.download_asset(asset_id=5, destination=destination, purpose="sync")
            downloaded = destination.read_bytes()

        self.assertEqual(downloaded, b"hello world")
        self.assertEqual(client.rate_limiter.calls, 2)
        self.assertEqual(sleep_mock.call_args_list[0].args[0], 2)
        self.assertEqual(deleted_links, [7])


if __name__ == "__main__":
    unittest.main()
