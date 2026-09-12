#!/usr/bin/env python3
"""Acceptance test for manifest validation.

**Verify failure, not success.** Validation easily ends up "looking present while checking nothing".
Here we prepare one correct manifest, inject
"realistic ways of breaking it" into it one at a time, and check that each one fails.

The original (connectors/google_workspace/v3.yaml) is not modified. A copy is made in a temp directory
and broken there (breaking the original would leave it broken if the test aborted midway).
"""

from __future__ import annotations

import copy
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import validate_manifests as vm  # noqa: E402

SRC = ROOT / "connectors" / "google_workspace" / "v3.yaml"

GREEN = "\033[32m"
RED = "\033[31m"
OFF = "\033[0m"

passed = 0
failed = 0


def _report(ok: bool, label: str, detail: str = ""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  {GREEN}PASS{OFF} {label}")
    else:
        failed += 1
        print(f"  {RED}FAIL{OFF} {label}{(' -- ' + detail) if detail else ''}")


def run(doc: dict, tmp: Path, *, connector: str | None = None, version: int | None = None):
    """Write doc as connectors/<connector>/v<version>.yaml and validate it.

    Validation also checks that the location matches the contents, so ROOT is swapped to the temp directory.
    """
    c = connector or doc.get("connector", "x")
    v = version if version is not None else doc.get("version", 1)
    path = tmp / "connectors" / str(c) / f"v{v}.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(doc, allow_unicode=True, sort_keys=False), encoding="utf-8")
    saved = vm.ROOT
    vm.ROOT = tmp
    try:
        return vm.validate_manifest(path)
    finally:
        vm.ROOT = saved


def expect_ok(label: str, doc: dict, tmp: Path):
    try:
        run(doc, tmp)
        _report(True, label)
    except vm.Problem as e:
        _report(False, label, f"通るはずが落ちた: {e}")


def expect_ng(label: str, doc: dict, tmp: Path, want: str = ""):
    try:
        run(doc, tmp)
        _report(False, label, "落ちるはずが通った")
    except vm.Problem as e:
        if want and want not in str(e):
            _report(False, label, f"別の理由で落ちた: {e}")
        else:
            _report(True, label)


def main() -> int:
    base = yaml.safe_load(SRC.read_text(encoding="utf-8"))
    print("== マニフェスト検証の受入試験（壊して落ちることを見る） ==")

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        expect_ok("正しいマニフェストは通る", copy.deepcopy(base), tmp)

        # --- 1. Permissions held by credentials -----------------------------------
        d = copy.deepcopy(base)
        d["auth"]["scopes"].append("https://www.googleapis.com/auth/drive")
        expect_ng("reader に書き込みスコープを足すと落ちる", d, tmp, "read-only でない")

        d = copy.deepcopy(base)
        d["auth"]["scopes"].append("https://www.googleapis.com/auth/gmail.settings.basic")
        expect_ng("read-only 版の無いスコープも reader では落ちる", d, tmp, "read-only でない")

        d = copy.deepcopy(base)
        d["kind"] = "elevated_reader"
        d["auth"]["scopes"].append("https://www.googleapis.com/auth/gmail.settings.basic")
        expect_ok("elevated_reader なら書き込み可能スコープを持てる", d, tmp)

        d = copy.deepcopy(base)
        d["auth"]["scopes"] = d["auth"]["scopes"] + [d["auth"]["scopes"][0]]
        expect_ng("スコープの重複は落ちる", d, tmp, "重複")

        # --- 2. Requests that can be issued at runtime ----------------------------
        d = copy.deepcopy(base)
        d["http"]["methods"] = ["GET", "POST"]
        expect_ng("reader に POST を足すと落ちる", d, tmp, "GET / HEAD しか出せません")

        d = copy.deepcopy(base)
        d["kind"] = "elevated_reader"
        d["http"]["methods"] = ["GET", "POST"]
        expect_ng("elevated_reader でも POST は落ちる", d, tmp, "GET / HEAD しか出せません")

        d = copy.deepcopy(base)
        d["http"]["allowed_hosts"] = ["*"]
        expect_ng("到達先のワイルドカードは落ちる", d, tmp, "ワイルドカード")

        d = copy.deepcopy(base)
        del d["http"]
        expect_ng("http の宣言が無いと落ちる", d, tmp, "http")

        d = copy.deepcopy(base)
        d["resources"][0]["endpoint"] = "https://evil.example.com/steal"
        expect_ng("endpoint にホストを書くと落ちる", d, tmp, "相対パス")

        # --- 3. Destination of collected data -------------------------------------
        d = copy.deepcopy(base)
        del d["resources"][0]["map_to"]
        expect_ng("map_to が無いと落ちる", d, tmp, "必須のキー")

        d = copy.deepcopy(base)
        d["resources"][0]["map_to"] = "somewhere_else"
        expect_ng("着地先の無い map_to は落ちる", d, tmp, "着地先がありません")

        d = copy.deepcopy(base)
        d["resources"][0]["fields"]["nonexistent_column"] = "x"
        expect_ng("受け取らないフィールドへの写像は落ちる", d, tmp, "受け取らない")

        d = copy.deepcopy(base)
        d["resources"][0]["fields"]["tenant_id"] = "someField"
        expect_ng("tenant_id への写像は落ちる", d, tmp, "正規化側が埋める列")

        d = copy.deepcopy(base)
        del d["resources"][0]["fields"]["external_id"]
        expect_ng("必須フィールドが無いと落ちる", d, tmp, "必須のフィールド")

        d = copy.deepcopy(base)
        d["resources"][0]["fields"]["email"] = "id"     # same source as external_id
        expect_ng("同じ取得元の二重写像は落ちる", d, tmp, "二重写像")

        d = copy.deepcopy(base)
        d["resources"][5]["fields"]["subject_kind"] = "$derive.nonexistent"
        expect_ng("実装の無い導出は落ちる", d, tmp, "実装の無い導出")

        # --- 4. Execution shape ---------------------------------------------------
        d = copy.deepcopy(base)
        d["resources"][2]["iterate_over"]["resource"] = "not_a_resource"
        expect_ng("実在しない resource を反復すると落ちる", d, tmp, "実在しません")

        d = copy.deepcopy(base)
        d["resources"][2]["iterate_over"]["resource"] = "group_members"
        expect_ng("自分自身の反復は落ちる", d, tmp, "自分自身")

        d = copy.deepcopy(base)
        # Create a cycle groups -> drive_permissions -> drive_files -> groups
        d["resources"][1]["depends_on"] = "drive_permissions"
        d["resources"][4]["depends_on"] = "groups"
        expect_ng("依存が循環すると落ちる", d, tmp, "循環")

        d = copy.deepcopy(base)
        del d["resources"][2]["iterate_over"]
        expect_ng("endpoint の {var} を束縛しないと落ちる", d, tmp, "束縛する iterate_over")

        d = copy.deepcopy(base)
        d["resources"][0]["paging"] = {"type": "page_token"}
        expect_ng("paging の必須フィールド欠落は落ちる", d, tmp, "必須のキー")

        d = copy.deepcopy(base)
        d["resources"][0]["paging"]["type"] = "magic"
        expect_ng("語彙外の paging.type は落ちる", d, tmp, "語彙外")

        d = copy.deepcopy(base)
        d["resources"][0]["on_error"] = {403: "ignore_silently"}
        expect_ng("語彙外の on_error は落ちる", d, tmp, "語彙外")

        d = copy.deepcopy(base)
        d["resources"].append(copy.deepcopy(d["resources"][0]))
        expect_ng("resource 名の重複は落ちる", d, tmp, "重複")

        # --- 5. Overall shape -----------------------------------------------------
        d = copy.deepcopy(base)
        d["unknown_top_level"] = 1
        expect_ng("知らない最上位キーは落ちる", d, tmp, "知らないキー")

        d = copy.deepcopy(base)
        d["resources"][0]["unknown_key"] = 1
        expect_ng("知らない resource のキーは落ちる", d, tmp, "知らないキー")

        d = copy.deepcopy(base)
        d["sync"]["full"] = "sometimes"
        expect_ng("語彙外の sync は落ちる", d, tmp, "語彙外")

        d = copy.deepcopy(base)
        d["rate_limit"]["max_retries"] = 0
        expect_ng("rate_limit の値が範囲外だと落ちる", d, tmp, "1 以上")

        # Location/content mismatch (the case of bumping the version but forgetting to rename the file)
        d = copy.deepcopy(base)
        d["version"] = 4
        try:
            run(d, tmp, version=3)
            _report(False, "置き場所と版が食い違うと落ちる", "落ちるはずが通った")
        except vm.Problem as e:
            _report("置き場所が中身と合いません" in str(e), "置き場所と版が食い違うと落ちる", str(e))

        # Duplicate YAML keys (safe_dump cannot produce them, so write them directly)
        dup = tmp / "connectors" / "dup" / "v1.yaml"
        dup.parent.mkdir(parents=True, exist_ok=True)
        dup.write_text("connector: dup\nkind: reader\nkind: writer\n", encoding="utf-8")
        saved = vm.ROOT
        vm.ROOT = tmp
        try:
            vm.validate_manifest(dup)
            _report(False, "YAML の重複キーは落ちる", "落ちるはずが通った")
        except vm.Problem as e:
            _report("重複したキー" in str(e), "YAML の重複キーは落ちる", str(e))
        finally:
            vm.ROOT = saved

    print(f"\n  合計: {GREEN}{passed} PASS{OFF} / {RED}{failed} FAIL{OFF}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
