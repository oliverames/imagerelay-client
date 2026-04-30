#!/usr/bin/env python3

from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

try:
    import jwt
except ImportError as exc:  # pragma: no cover - preflight only
    raise SystemExit(
        "PyJWT is required for App Store Connect API access. "
        "Run `python3 -m pip install PyJWT` and retry."
    ) from exc


API_BASE = "https://api.appstoreconnect.apple.com/v1"
CERTIFICATE_TYPES = {"DEVELOPER_ID_APPLICATION", "DEVELOPER_ID_APPLICATION_G2"}


@dataclass(frozen=True)
class BundleProfileSpec:
    bundle_identifier: str
    bundle_name: str
    profile_name: str


SPECS = (
    BundleProfileSpec(
        bundle_identifier="com.oliverames.imagerelay-client",
        bundle_name="ImageRelayClient",
        profile_name="ImageRelayClient Developer ID",
    ),
    BundleProfileSpec(
        bundle_identifier="com.oliverames.imagerelay-client.fileprovider",
        bundle_name="ImageRelayClient FileProviderExtension",
        profile_name="ImageRelayClient FileProviderExtension Developer ID",
    ),
)


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


class ASCClient:
    def __init__(self, key_path: Path, key_id: str, issuer_id: str) -> None:
        private_key = key_path.read_bytes()
        now = int(time.time())
        token = jwt.encode(
            {
                "iss": issuer_id,
                "iat": now,
                "exp": now + 1200,
                "aud": "appstoreconnect-v1",
            },
            private_key,
            algorithm="ES256",
            headers={"kid": key_id, "typ": "JWT"},
        )
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }

    def request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, str] | None = None,
        body: dict[str, object] | None = None,
    ) -> dict[str, object]:
        url = f"{API_BASE}{path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        data = None
        if body is not None:
            data = json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(request) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode()
            raise RuntimeError(f"{method} {path} failed: {detail}") from error


def latest(items: list[dict[str, object]]) -> dict[str, object] | None:
    if not items:
        return None
    return sorted(
        items,
        key=lambda item: item.get("attributes", {}).get("createdDate", ""),
        reverse=True,
    )[0]


def ensure_bundle_id(client: ASCClient, spec: BundleProfileSpec) -> dict[str, object]:
    payload = client.request(
        "GET",
        "/bundleIds",
        params={"filter[identifier]": spec.bundle_identifier, "limit": "200"},
    )
    bundle = latest(payload.get("data", []))
    if bundle is not None:
        print(f"Using existing bundle ID {spec.bundle_identifier}")
        return bundle

    created = client.request(
        "POST",
        "/bundleIds",
        body={
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": spec.bundle_identifier,
                    "name": spec.bundle_name,
                    "platform": "MAC_OS",
                },
            }
        },
    )
    bundle = created["data"]
    print(f"Created bundle ID {spec.bundle_identifier}")
    return bundle


def find_developer_id_certificate(client: ASCClient) -> dict[str, object]:
    payload = client.request("GET", "/certificates", params={"limit": "200"})
    certificates = payload.get("data", [])
    candidates = [
        certificate
        for certificate in certificates
        if certificate.get("attributes", {}).get("certificateType") in CERTIFICATE_TYPES
    ]
    if not candidates:
        raise RuntimeError("No Developer ID Application certificate found in App Store Connect.")
    certificate = latest(candidates)
    name = certificate.get("attributes", {}).get("name", certificate.get("id"))
    print(f"Using Developer ID certificate {name}")
    return certificate


def ensure_profile(
    client: ASCClient,
    spec: BundleProfileSpec,
    bundle_id: dict[str, object],
    certificate: dict[str, object],
) -> dict[str, object]:
    payload = client.request(
        "GET",
        "/profiles",
        params={
            "filter[name]": spec.profile_name,
            "filter[profileState]": "ACTIVE",
            "limit": "200",
        },
    )
    profiles = [
        profile
        for profile in payload.get("data", [])
        if profile.get("attributes", {}).get("profileType") == "MAC_APP_DIRECT"
    ]
    profile = latest(profiles)
    if profile is not None:
        print(f"Using existing profile {spec.profile_name}")
        return profile

    created = client.request(
        "POST",
        "/profiles",
        body={
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": spec.profile_name,
                    "profileType": "MAC_APP_DIRECT",
                },
                "relationships": {
                    "bundleId": {
                        "data": {"type": "bundleIds", "id": bundle_id["id"]},
                    },
                    "certificates": {
                        "data": [{"type": "certificates", "id": certificate["id"]}],
                    },
                },
            }
        },
    )
    profile = created["data"]
    print(f"Created profile {spec.profile_name}")
    return profile


def install_profile(client: ASCClient, profile_id: str, install_dir: Path) -> Path:
    payload = client.request("GET", f"/profiles/{profile_id}")
    attributes = payload["data"]["attributes"]
    profile_bytes = base64.b64decode(attributes["profileContent"])
    profile_path = install_dir / f"{attributes['uuid']}.provisionprofile"
    install_dir.mkdir(parents=True, exist_ok=True)
    existing = profile_path.read_bytes() if profile_path.exists() else None
    if existing != profile_bytes:
        profile_path.write_bytes(profile_bytes)
    return profile_path


def main() -> int:
    key_path = Path(required_env("ASC_KEY_PATH"))
    key_id = required_env("ASC_KEY_ID")
    issuer_id = required_env("ASC_ISSUER_ID")
    install_dir = Path(required_env("ASC_PROFILE_INSTALL_DIR")).expanduser()

    client = ASCClient(key_path, key_id, issuer_id)
    certificate = find_developer_id_certificate(client)

    for spec in SPECS:
        bundle_id = ensure_bundle_id(client, spec)
        profile = ensure_profile(client, spec, bundle_id, certificate)
        installed = install_profile(client, profile["id"], install_dir)
        print(f"Installed {spec.profile_name} -> {installed}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
