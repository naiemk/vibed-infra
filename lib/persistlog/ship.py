#!/usr/bin/env python3
"""Ship sealed persist-log segments to R2/S3-compatible storage (batched PUTs)."""
from __future__ import annotations

import hashlib
import hmac
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlsplit


def _sigv4_put(
    local: Path,
    key: str,
    endpoint: str,
    bucket: str,
    access: str,
    secret: str,
    region: str = "auto",
) -> None:
    """Minimal SigV4 PUT for S3/R2-compatible endpoints (stdlib only)."""
    body = local.read_bytes()
    payload_hash = hashlib.sha256(body).hexdigest()
    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")

    parts = urlsplit(endpoint.rstrip("/"))
    host = parts.netloc
    # Virtual-hosted style preferred for R2: https://bucket.account.r2.cloudflarestorage.com/key
    # Path style: https://endpoint/bucket/key
    if host.startswith(f"{bucket}."):
        url_path = "/" + quote(key, safe="/")
        canonical_uri = url_path
        host_header = host
    else:
        url_path = f"/{bucket}/{quote(key, safe='/')}"
        canonical_uri = f"/{bucket}/{quote(key, safe='/')}"
        host_header = host

    service = "s3"
    credential_scope = f"{date_stamp}/{region}/{service}/aws4_request"
    canonical_headers = (
        f"host:{host_header}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = "\n".join(
        [
            "PUT",
            canonical_uri,
            "",
            canonical_headers,
            signed_headers,
            payload_hash,
        ]
    )
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )

    def _sign(key: bytes, msg: str) -> bytes:
        return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

    k_date = _sign(("AWS4" + secret).encode("utf-8"), date_stamp)
    k_region = _sign(k_date, region)
    k_service = _sign(k_region, service)
    k_signing = _sign(k_service, "aws4_request")
    signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    authorization = (
        f"AWS4-HMAC-SHA256 Credential={access}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    url = f"{parts.scheme}://{host_header}{url_path}"
    req = urllib.request.Request(url, data=body, method="PUT")
    req.add_header("Host", host_header)
    req.add_header("x-amz-content-sha256", payload_hash)
    req.add_header("x-amz-date", amz_date)
    req.add_header("Authorization", authorization)
    req.add_header("Content-Length", str(len(body)))
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            if resp.status not in (200, 201, 204):
                raise RuntimeError(f"PUT {url} returned {resp.status}")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"PUT {url} failed: {exc.code} {detail}") from exc


def ship_file(local: Path, key: str, endpoint: str, bucket: str, access: str, secret: str) -> None:
    if shutil.which("aws"):
        env = os.environ.copy()
        env["AWS_ACCESS_KEY_ID"] = access
        env["AWS_SECRET_ACCESS_KEY"] = secret
        endpoint_url = endpoint.rstrip("/")
        cmd = [
            "aws",
            "s3",
            "cp",
            str(local),
            f"s3://{bucket}/{key}",
            "--endpoint-url",
            endpoint_url,
        ]
        subprocess.run(cmd, check=True, env=env)
        return
    region = os.environ.get("R2_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "auto"
    _sigv4_put(local, key, endpoint, bucket, access, secret, region=region)


def main() -> int:
    base = Path(os.environ.get("PERSIST_LOG_ROOT", Path.home() / "services/vibed-infra/persist-logs"))
    if os.environ.get("PERSIST_SHIP", "0") in ("0", "false", "off", ""):
        print("PERSIST_SHIP disabled — local only")
        return 0
    endpoint = os.environ.get("R2_ENDPOINT") or os.environ.get("S3_ENDPOINT") or ""
    bucket = os.environ.get("R2_BUCKET") or os.environ.get("S3_BUCKET") or ""
    access = os.environ.get("R2_ACCESS_KEY_ID") or os.environ.get("AWS_ACCESS_KEY_ID") or ""
    secret = os.environ.get("R2_SECRET_ACCESS_KEY") or os.environ.get("AWS_SECRET_ACCESS_KEY") or ""
    machine = os.environ.get("PERSIST_MACHINE_ID") or os.uname().nodename
    prefix = (os.environ.get("PERSIST_SHIP_PREFIX") or "").strip().strip("/")
    if not endpoint or not bucket or not access or not secret:
        print("missing R2/S3 credentials — skip ship", file=sys.stderr)
        return 0

    shipped = 0
    for seg in base.rglob("seg-*.ndjson.gz"):
        marker = seg.with_suffix(seg.suffix + ".shipped")
        if marker.is_file():
            continue
        rel = seg.relative_to(base).as_posix()
        if prefix:
            key = f"{machine}/{prefix}/{rel}"
        else:
            key = f"{machine}/{rel}"
        try:
            ship_file(seg, key, endpoint, bucket, access, secret)
            marker.write_text("ok\n", encoding="utf-8")
            shipped += 1
            print(f"shipped {key}")
        except Exception as exc:  # noqa: BLE001
            print(f"ship failed {seg}: {exc}", file=sys.stderr)
    print(f"shipped={shipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
