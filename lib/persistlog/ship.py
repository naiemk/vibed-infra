#!/usr/bin/env python3
"""Ship sealed persist-log segments to R2/S3-compatible storage (batched PUTs)."""
from __future__ import annotations

import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Optional: use aws CLI if present (works with R2 endpoint)
def ship_file(local: Path, key: str, endpoint: str, bucket: str, access: str, secret: str) -> None:
    # Prefer aws CLI for SigV4
    import shutil
    import subprocess

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
    raise RuntimeError("aws CLI required for persist-log ship (or set PERSIST_SHIP=0)")


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
    if not endpoint or not bucket or not access or not secret:
        print("missing R2/S3 credentials — skip ship", file=sys.stderr)
        return 0

    shipped = 0
    for seg in base.rglob("seg-*.ndjson.gz"):
        marker = seg.with_suffix(seg.suffix + ".shipped")
        if marker.is_file():
            continue
        rel = seg.relative_to(base).as_posix()
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
