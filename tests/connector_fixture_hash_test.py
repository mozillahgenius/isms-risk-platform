#!/usr/bin/env python3
"""記録済み応答の改変を SHA-256 ゲートが拒否することを確認する。"""

from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from connector_sync import ReplayError, verify_fixture  # noqa: E402


def main() -> int:
    source = ROOT / "fixtures/google_workspace/replay-basic.json"
    sidecar = Path(str(source) + ".sha256")
    with tempfile.TemporaryDirectory() as td:
        target = Path(td) / source.name
        target_sidecar = Path(str(target) + ".sha256")
        shutil.copyfile(source, target)
        shutil.copyfile(sidecar, target_sidecar)
        verify_fixture(target)
        content = target.read_text(encoding="utf-8")
        content = content.replace("公開前提ではない資料", "改変された資料", 1)
        target.write_text(content, encoding="utf-8")
        try:
            verify_fixture(target)
        except ReplayError as exc:
            print(f"PASS 記録済み応答の改変を拒否: {exc}")
            return 0
        print("FAIL 改変された記録済み応答が通りました")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
