#!/usr/bin/env python3
"""Local append-only NDJSON WAL + seal + optional remote ship for vibed persist-logs."""
from __future__ import annotations

import gzip
import json
import os
import shutil
import time
from pathlib import Path
from typing import Any, Callable, Iterator


DEFAULT_ROTATE_BYTES = 8 * 1024 * 1024
DEFAULT_ROTATE_SEC = 60


def stream_dir(base: Path, stream: str) -> Path:
    d = base / stream
    d.mkdir(parents=True, exist_ok=True)
    return d


def append(
    base: Path | str,
    stream: str,
    event_type: str,
    payload: dict[str, Any] | None = None,
    *,
    event_id: str | None = None,
    fsync: bool = True,
) -> dict[str, Any]:
    """Append one domain event to the active WAL. Fast local hot path."""
    base_p = Path(base)
    d = stream_dir(base_p, stream)
    wal = d / "wal.ndjson"
    evt: dict[str, Any] = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "stream": stream,
        "type": event_type,
        "id": event_id or f"{int(time.time() * 1000)}-{os.getpid()}",
        "payload": payload or {},
    }
    line = json.dumps(evt, separators=(",", ":")) + "\n"
    with wal.open("a", encoding="utf-8") as f:
        f.write(line)
        if fsync:
            f.flush()
            os.fsync(f.fileno())
    maybe_seal(d, rotate_bytes=DEFAULT_ROTATE_BYTES, rotate_sec=DEFAULT_ROTATE_SEC)
    return evt


def maybe_seal(
    stream_path: Path,
    *,
    rotate_bytes: int = DEFAULT_ROTATE_BYTES,
    rotate_sec: int = DEFAULT_ROTATE_SEC,
) -> Path | None:
    wal = stream_path / "wal.ndjson"
    if not wal.is_file():
        return None
    st = wal.stat()
    age = time.time() - st.st_mtime
    if st.st_size < rotate_bytes and age < rotate_sec:
        return None
    return seal(stream_path)


def seal(stream_path: Path) -> Path | None:
    """Rotate wal.ndjson → immutable seg-NNNN.ndjson.gz."""
    wal = stream_path / "wal.ndjson"
    if not wal.is_file() or wal.stat().st_size == 0:
        return None
    n = 0
    for p in stream_path.glob("seg-*.ndjson.gz"):
        try:
            n = max(n, int(p.name.split("-")[1].split(".")[0]))
        except (IndexError, ValueError):
            pass
    dest = stream_path / f"seg-{n + 1:06d}.ndjson.gz"
    tmp = stream_path / "wal.rotating"
    wal.rename(tmp)
    with tmp.open("rb") as src, gzip.open(dest, "wb") as out:
        shutil.copyfileobj(src, out)
    tmp.unlink(missing_ok=True)
    (stream_path / "wal.ndjson").touch()
    return dest


def iter_events(base: Path | str, stream: str) -> Iterator[dict[str, Any]]:
    """Replay sealed segments then active WAL in order."""
    d = stream_dir(Path(base), stream)
    for seg in sorted(d.glob("seg-*.ndjson.gz")):
        with gzip.open(seg, "rt", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    yield json.loads(line)
    wal = d / "wal.ndjson"
    if wal.is_file():
        with wal.open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    yield json.loads(line)


def replay(
    base: Path | str,
    stream: str,
    apply: Callable[[dict[str, Any], Any], Any],
    initial: Any = None,
) -> Any:
    state = initial
    for evt in iter_events(base, stream):
        state = apply(evt, state)
    return state


def list_sealed(base: Path | str, stream: str) -> list[Path]:
    d = stream_dir(Path(base), stream)
    return sorted(d.glob("seg-*.ndjson.gz"))
