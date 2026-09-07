#!/usr/bin/env python3
"""Install/remove task-owned workspace hooks with identity and content receipts.

Usage: python3 fm-workspace-hooks.py <install|remove> <state> <id> <workspace> [relative-path]
Install reads bytes from stdin and refuses an existing unowned file.
Remove preserves files without a matching receipt, including edited/replaced hooks.
Receipts live in state/<id>.workspace-hooks.json; task lifecycle locks serialize callers.
"""

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile


def identity(path):
    info = path.stat(follow_symlinks=False)
    return [info.st_dev, info.st_ino, hashlib.sha256(path.read_bytes()).hexdigest()]


def main():
    action, state, task_id, workspace, *relative = sys.argv[1:]
    root = Path(workspace).resolve()
    receipt = Path(state) / f"{task_id}.workspace-hooks.json"
    records = json.loads(receipt.read_text()) if receipt.exists() else {}
    if action not in ("install", "remove") or (action == "install" and len(relative) != 1):
        raise ValueError("expected install with one path, or remove with optional path")
    paths = relative or [str(Path(path).relative_to(root)) for path in records if Path(path).is_relative_to(root)]
    for name in paths:
        part = Path(name)
        if part.is_absolute() or ".." in part.parts:
            raise ValueError(f"unsafe workspace hook path: {name}")
        path = root / part
        key = str(path)
        safe = all(not (root / parent).is_symlink() for parent in (part, *part.parents))
        owned = safe and path.is_file() and records.get(key) == identity(path)
        if action == "install":
            if not safe or ((path.exists() or path.is_symlink()) and not owned):
                raise ValueError(f"refusing to overwrite workspace hook without task ownership: {path}")
            if owned:
                path.unlink()
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as stream:
                stream.write(sys.stdin.buffer.read())
            records[key] = identity(path)
        else:
            if owned:
                path.unlink()
            records.pop(key, None)
    if records:
        fd, temporary = tempfile.mkstemp(prefix=f".{task_id}.workspace-hooks.", dir=state)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(records, stream)
                stream.write("\n")
            os.replace(temporary, receipt)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    else:
        receipt.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
