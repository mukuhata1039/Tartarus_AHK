from __future__ import annotations

import os
import time
from pathlib import Path

MAX_BYTES = 1 * 1024 * 1024
BACKUP_COUNT = 2


def _rotate(path: Path, max_bytes: int = MAX_BYTES, backups: int = BACKUP_COUNT) -> None:
    try:
        if not path.exists() or path.stat().st_size < max_bytes:
            return
        # Keep a fixed-size history: .1 newest, .2 older.
        oldest = Path(str(path) + f".{backups}")
        if oldest.exists():
            oldest.unlink()
        for i in range(backups - 1, 0, -1):
            src = Path(str(path) + f".{i}")
            dst = Path(str(path) + f".{i + 1}")
            if src.exists():
                os.replace(src, dst)
        os.replace(path, Path(str(path) + ".1"))
    except Exception:
        # Logging must never break the device runtime.
        pass


def append_log(path: Path, message: str, *, max_bytes: int = MAX_BYTES, backups: int = BACKUP_COUNT) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        _rotate(path, max_bytes=max_bytes, backups=backups)
        with path.open("a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + message + "\n")
    except Exception:
        pass
