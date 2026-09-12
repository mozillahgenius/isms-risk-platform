#!/usr/bin/env python3
"""Static validation of connector manifests (connectors/**/v*.yaml).

Design doc 3.1 / 3.4 / 3.7. Does not touch the DB (pure validation).

**Why checking scopes alone is not enough.**
A manifest is an execution policy: "this is exactly what will be run in the future".
Even if the credential's scopes are read-only, if the manifest can declare POST or arbitrary URLs,
writes and external exfiltration become possible at run time. So here we validate three things separately:

  - the permissions the credential holds (auth.scopes)
  - the requests that can be issued at run time (http.methods / http.allowed_hosts / endpoint shape)
  - where fetched data goes (map_to and fields)

If any one of them is loose, the other two being strict is meaningless.

Usage:
    python3 scripts/validate_manifests.py [path...]
    Without paths, checks every *.yaml under connectors/.
    Exit code 1 if even one fails.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - CI checks separately for missing dependencies
    sys.stderr.write(
        "PyYAML が要ります。`python3 -m pip install -r requirements.txt` を実行してください。\n"
    )
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parent.parent

# --- vocabulary (fixed) -----------------------------------------------------
# Loosening these loosens validation. When adding, add together with the landing place (DB table/column).

KINDS = {"reader", "elevated_reader", "writer"}
AUTH_TYPES = {"oauth2", "service_account_dwd", "api_key"}
PAGING_TYPES = {"page_token", "offset", "cursor", "none"}
INCREMENTAL_TYPES = {"changes_api", "time_window", "updated_since"}
ON_ERROR_ACTIONS = {
    "retry",
    "skip",
    "fail_run",
    "record_as_unreadable",
    "record_as_gone",
}
BACKOFF = {"exponential_jitter", "exponential", "fixed"}
RATE_STRATEGY = {"token_bucket", "leaky_bucket", "fixed_window"}
SYNC_CADENCE = {"hourly", "daily", "weekly", "monthly", "manual"}

# Read-only methods. reader / elevated_reader cannot declare anything else.
READ_METHODS = {"GET", "HEAD"}
ALL_METHODS = READ_METHODS | {"POST", "PUT", "PATCH", "DELETE"}

# Derivations that can be written as `$derive.<name>`. Only implemented ones are allowed.
DERIVATIONS = {"permission_subject_kind"}

# map_to → logical field names accepted by the normalizer.
#
# **These are not column names themselves.** For edges (memberships_graph / app_grants),
# what the manifest passes is "an external ID for looking up the other side", not a column.
# The normalizer resolves it to an internal ID. This is the contract for that input.
#
# `db_table` is "the table where that map_to finally lands". It exists so that a map_to with
# no landing place cannot be written (the design doc's manifest had 2 mappings with no
# landing place; they were added in 0024).
MAP_TO: dict[str, dict[str, object]] = {
    "accounts": {
        "db_table": "app.accounts",
        "required": {"external_id"},
        "optional": {"email", "is_admin", "mfa_enrolled", "suspended", "last_login_at"},
    },
    "groups": {
        "db_table": "app.groups",
        "required": {"external_id"},
        "optional": {"name", "email", "parent_group_external_id"},
    },
    "memberships_graph": {
        "db_table": "app.memberships_graph",
        "required": {"account_external_id"},
        "optional": {"member_type", "group_external_id"},
    },
    "oauth_apps": {
        "db_table": "app.oauth_apps",
        "required": {"external_id"},
        "optional": {"name", "publisher", "scopes", "last_used_at"},
    },
    "app_grants": {
        "db_table": "app.app_grants",
        "required": {"oauth_app_external_id"},
        "optional": {"account_external_id", "scopes", "display_name", "granted_at"},
    },
    "resources": {
        "db_table": "app.resources",
        "required": {"external_id"},
        "optional": {
            "name",
            "kind",
            "parent_external_id",
            "drive_id",
            "owner_account_email",
            "last_modified_at",
            "inherit_permissions",
        },
    },
    "grants": {
        "db_table": "app.grants",
        "required": {"subject_kind"},
        "optional": {
            "subject_domain",
            "subject_account_email",
            "subject_group_email",
            "subject_oauth_app_external_id",
            "role",
            "discoverable",
            "expires_at",
        },
    },
    "raw_events": {
        "db_table": "app.raw_events",
        "required": {"external_id", "occurred_at", "event_type"},
        "optional": {"actor_email"},
    },
}

# Columns the normalizer fills itself. They cannot be mapped from a manifest
# (no crossing tenants, no audit timestamps from external input).
FORBIDDEN_TARGETS = {
    "id",
    "tenant_id",
    "connector",
    "identity_id",
    "created_at",
    "created_by",
    "updated_at",
    "updated_by",
    "collected_at",
    "first_seen_at",
    "last_seen_at",
    "collection_state",
}

TOP_LEVEL_REQUIRED = {"connector", "kind", "version", "auth", "resources", "rate_limit", "sync"}
TOP_LEVEL_OPTIONAL = {"http"}
RESOURCE_REQUIRED = {"name", "endpoint", "paging", "map_to", "fields"}
RESOURCE_OPTIONAL = {"params", "iterate_over", "incremental", "depends_on", "on_error"}

CONNECTOR_RE = re.compile(r"^[a-z][a-z0-9_]*$")
RESOURCE_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")
# endpoint may not contain a host (the host is decided by http.allowed_hosts).
# A relative path that only allows `{var}` bindings.
ENDPOINT_RE = re.compile(r"^[A-Za-z0-9._~\-/]+(\{[a-z_][a-z0-9_]*\}[A-Za-z0-9._~\-/]*)*$")

# Shape of Google read-only scopes: ending in .readonly, or an explicit allowlist.
READONLY_SCOPE_SUFFIXES = (".readonly", ".read_only")
READONLY_SCOPE_ALLOWLIST = {
    "https://www.googleapis.com/auth/admin.reports.audit.readonly",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "openid",
}


class Problem(Exception):
    pass


class UniqueKeyLoader(yaml.SafeLoader):
    """Do not silently let the later value win for duplicate YAML keys.

    The default SafeLoader overwrites with the later value when a key appears twice.
    In a manifest, "scopes written twice and only one takes effect" can happen, so fail.
    """


def _no_duplicates(loader: yaml.Loader, node: yaml.MappingNode, deep: bool = False):
    seen: set = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise Problem(f"YAML に重複したキーがあります: {key!r}")
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicates
)


def _need(d: dict, key: str, where: str):
    if key not in d:
        raise Problem(f"{where}: 必須の {key} がありません")
    return d[key]


def _check_keys(d: dict, required: set, optional: set, where: str):
    keys = set(d)
    missing = required - keys
    if missing:
        raise Problem(f"{where}: 必須のキーがありません: {sorted(missing)}")
    unknown = keys - required - optional
    if unknown:
        # Unknown keys produce "written but has no effect". Do not silently ignore them.
        raise Problem(f"{where}: 知らないキーがあります: {sorted(unknown)}")


def _is_readonly_scope(scope: str) -> bool:
    if scope in READONLY_SCOPE_ALLOWLIST:
        return True
    return scope.endswith(READONLY_SCOPE_SUFFIXES)


def validate_auth(auth: dict, kind: str):
    _check_keys(auth, {"type", "scopes"}, set(), "auth")
    if auth["type"] not in AUTH_TYPES:
        raise Problem(f"auth.type が語彙外です: {auth['type']}")
    scopes = auth["scopes"]
    if not isinstance(scopes, list) or not scopes:
        raise Problem("auth.scopes は 1 つ以上の配列である必要があります")
    if len(set(scopes)) != len(scopes):
        raise Problem("auth.scopes に重複があります")
    if kind == "reader":
        bad = [s for s in scopes if not _is_readonly_scope(s)]
        if bad:
            raise Problem(
                "kind=reader に read-only でないスコープがあります: "
                + ", ".join(bad)
                + "（読み取り専用版が無いなら kind=elevated_reader にして承認を要求する）"
            )


def validate_http(http: dict | None, kind: str):
    if http is None:
        raise Problem("http（methods / allowed_hosts）がありません。実行時に出せる要求を宣言する")
    _check_keys(http, {"methods", "allowed_hosts"}, set(), "http")
    methods = http["methods"]
    if not isinstance(methods, list) or not methods:
        raise Problem("http.methods は 1 つ以上の配列である必要があります")
    unknown = [m for m in methods if m not in ALL_METHODS]
    if unknown:
        raise Problem(f"http.methods が語彙外です: {unknown}")
    if kind in ("reader", "elevated_reader"):
        writable = [m for m in methods if m not in READ_METHODS]
        if writable:
            raise Problem(
                f"kind={kind} は GET / HEAD しか出せません。書き込めるメソッドがあります: {writable}"
                "（スコープが read-only でも、POST が書ければ実行時には書ける）"
            )
    hosts = http["allowed_hosts"]
    if not isinstance(hosts, list) or not hosts:
        raise Problem("http.allowed_hosts は 1 つ以上の配列である必要があります")
    for h in hosts:
        if not isinstance(h, str) or "/" in h or ":" in h or h.strip() != h:
            raise Problem(f"http.allowed_hosts はホスト名だけを書きます: {h!r}")
        if h in ("*", "") or h.startswith("*"):
            raise Problem(f"http.allowed_hosts にワイルドカードは書けません: {h!r}")


def validate_paging(paging: dict, where: str):
    if not isinstance(paging, dict):
        raise Problem(f"{where}: paging は表である必要があります")
    ptype = _need(paging, "type", f"{where}.paging")
    if ptype not in PAGING_TYPES:
        raise Problem(f"{where}.paging.type が語彙外です: {ptype}")
    # Required per scheme. Writing only type and forgetting param fetches just 1 page at run time.
    if ptype == "page_token":
        _check_keys(paging, {"type", "param"}, {"size"}, f"{where}.paging")
    elif ptype == "offset":
        _check_keys(paging, {"type", "param", "size"}, set(), f"{where}.paging")
    elif ptype == "cursor":
        _check_keys(paging, {"type", "param"}, {"size"}, f"{where}.paging")
    else:  # none
        _check_keys(paging, {"type"}, set(), f"{where}.paging")


def validate_on_error(on_error, where: str):
    if on_error is None:
        return
    if not isinstance(on_error, dict):
        raise Problem(f"{where}.on_error は HTTP ステータス → 動作の表です")
    for status, action in on_error.items():
        if not isinstance(status, int) or not (400 <= status <= 599):
            raise Problem(f"{where}.on_error のキーは 400-599 の整数です: {status!r}")
        if action not in ON_ERROR_ACTIONS:
            raise Problem(f"{where}.on_error[{status}] が語彙外です: {action}")


def validate_fields(fields, map_to: str, where: str):
    if not isinstance(fields, dict) or not fields:
        raise Problem(f"{where}: fields は 1 つ以上の写像である必要があります")
    spec = MAP_TO[map_to]
    allowed = set(spec["required"]) | set(spec["optional"])  # type: ignore[arg-type]
    targets = set(fields)

    forbidden = targets & FORBIDDEN_TARGETS
    if forbidden:
        raise Problem(
            f"{where}: 正規化側が埋める列へは写像できません: {sorted(forbidden)}"
        )
    unknown = targets - allowed
    if unknown:
        raise Problem(
            f"{where}: map_to={map_to} が受け取らないフィールドです: {sorted(unknown)}"
            f"（受け取るのは {sorted(allowed)}）"
        )
    missing = set(spec["required"]) - targets  # type: ignore[arg-type]
    if missing:
        raise Problem(f"{where}: map_to={map_to} に必須のフィールドがありません: {sorted(missing)}")

    sources: dict[str, str] = {}
    for target, source in fields.items():
        if not isinstance(source, str) or not source:
            raise Problem(f"{where}.fields.{target}: 取得元は空でない文字列です")
        if source.startswith("$derive."):
            name = source[len("$derive.") :]
            if name not in DERIVATIONS:
                raise Problem(
                    f"{where}.fields.{target}: 実装の無い導出です: {source}"
                    f"（在るのは {sorted(DERIVATIONS)}）"
                )
            continue
        if source in sources:
            # Mapping the same source to two destinations is usually a mistake.
            raise Problem(
                f"{where}.fields: 取得元 {source} が {sources[source]} と {target} に二重写像されています"
            )
        sources[source] = target


def validate_resource(res: dict, index: int, names: set[str]) -> dict:
    where = f"resources[{index}]"
    if not isinstance(res, dict):
        raise Problem(f"{where}: 表である必要があります")
    _check_keys(res, RESOURCE_REQUIRED, RESOURCE_OPTIONAL, where)

    name = res["name"]
    if not isinstance(name, str) or not RESOURCE_NAME_RE.match(name):
        raise Problem(f"{where}.name は小文字と数字と _ だけです: {name!r}")
    if name in names:
        raise Problem(f"resource 名が重複しています: {name}")
    names.add(name)
    where = f"resources[{name}]"

    endpoint = res["endpoint"]
    if not isinstance(endpoint, str) or not ENDPOINT_RE.match(endpoint):
        raise Problem(
            f"{where}.endpoint は相対パスだけです（スキーム・ホスト・クエリは書けません）: {endpoint!r}"
        )

    map_to = res["map_to"]
    if map_to not in MAP_TO:
        raise Problem(
            f"{where}.map_to に着地先がありません: {map_to}"
            f"（在るのは {sorted(MAP_TO)}）"
        )

    validate_paging(res["paging"], where)
    validate_on_error(res.get("on_error"), where)
    validate_fields(res["fields"], map_to, where)

    inc = res.get("incremental")
    if inc is not None:
        if not isinstance(inc, dict):
            raise Problem(f"{where}.incremental は表です")
        itype = _need(inc, "type", f"{where}.incremental")
        if itype not in INCREMENTAL_TYPES:
            raise Problem(f"{where}.incremental.type が語彙外です: {itype}")
        _need(inc, "cursor", f"{where}.incremental")

    params = res.get("params")
    if params is not None and not isinstance(params, dict):
        raise Problem(f"{where}.params は表です")

    # Every {var} in endpoint must be filled by iterate_over.bind.
    bound = set()
    it = res.get("iterate_over")
    if it is not None:
        if not isinstance(it, dict):
            raise Problem(f"{where}.iterate_over は表です")
        _check_keys(it, {"resource", "bind"}, set(), f"{where}.iterate_over")
        if it["resource"] == name:
            raise Problem(f"{where}.iterate_over が自分自身を指しています")
        bind = it["bind"]
        if not isinstance(bind, dict) or not bind:
            raise Problem(f"{where}.iterate_over.bind は 1 つ以上の束縛です")
        bound = set(bind)

    placeholders = set(re.findall(r"\{([a-z_][a-z0-9_]*)\}", endpoint))
    unbound = placeholders - bound
    if unbound:
        raise Problem(f"{where}.endpoint の {sorted(unbound)} を束縛する iterate_over がありません")
    unused = bound - placeholders
    if unused:
        raise Problem(f"{where}.iterate_over.bind の {sorted(unused)} が endpoint に出てきません")

    return res


def validate_graph(resources: list[dict]):
    """Inspect the dependency graph combining iterate_over and depends_on.

    Checks for references to nonexistent resources and for cycles.
    A cycle means execution never terminates.
    """
    names = {r["name"] for r in resources}
    edges: dict[str, set[str]] = {n: set() for n in names}
    for r in resources:
        name = r["name"]
        it = r.get("iterate_over")
        if it is not None:
            target = it["resource"]
            if target not in names:
                raise Problem(
                    f"resources[{name}].iterate_over.resource が実在しません: {target}"
                )
            edges[name].add(target)
        dep = r.get("depends_on")
        if dep is not None:
            deps = dep if isinstance(dep, list) else [dep]
            for d in deps:
                if d not in names:
                    raise Problem(f"resources[{name}].depends_on が実在しません: {d}")
                if d == name:
                    raise Problem(f"resources[{name}].depends_on が自分自身を指しています")
                edges[name].add(d)

    state: dict[str, int] = {}  # 0=unvisited 1=visiting 2=done

    def visit(n: str, path: list[str]):
        if state.get(n) == 2:
            return
        if state.get(n) == 1:
            cycle = path[path.index(n) :] + [n]
            raise Problem("resource の依存が循環しています: " + " → ".join(cycle))
        state[n] = 1
        for m in sorted(edges[n]):
            visit(m, path + [n])
        state[n] = 2

    for n in sorted(names):
        visit(n, [])


def validate_manifest(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    try:
        doc = yaml.load(text, Loader=UniqueKeyLoader)
    except Problem:
        raise
    except yaml.YAMLError as e:
        raise Problem(f"YAML として読めません: {e}")
    if not isinstance(doc, dict):
        raise Problem("最上位は表である必要があります")

    _check_keys(doc, TOP_LEVEL_REQUIRED, TOP_LEVEL_OPTIONAL, "最上位")

    connector = doc["connector"]
    if not isinstance(connector, str) or not CONNECTOR_RE.match(connector):
        raise Problem(f"connector は小文字と数字と _ だけです: {connector!r}")

    kind = doc["kind"]
    if kind not in KINDS:
        raise Problem(f"kind が語彙外です: {kind}")

    version = doc["version"]
    if not isinstance(version, int) or isinstance(version, bool) or version < 1:
        raise Problem(f"version は 1 以上の整数です: {version!r}")

    # The file's location and its content must agree.
    # connectors/<connector>/v<version>.yaml
    expected = ROOT / "connectors" / connector / f"v{version}.yaml"
    if path.resolve() != expected.resolve():
        raise Problem(
            f"置き場所が中身と合いません。{expected.relative_to(ROOT)} にしてください"
        )

    validate_auth(doc["auth"], kind)
    validate_http(doc.get("http"), kind)

    resources = doc["resources"]
    if not isinstance(resources, list) or not resources:
        raise Problem("resources は 1 つ以上の配列である必要があります")
    names: set[str] = set()
    for i, res in enumerate(resources):
        validate_resource(res, i, names)
    validate_graph(resources)

    rl = doc["rate_limit"]
    _check_keys(
        rl,
        {"strategy", "qps", "backoff", "max_retries"},
        {"concurrency", "respect_headers"},
        "rate_limit",
    )
    if rl["strategy"] not in RATE_STRATEGY:
        raise Problem(f"rate_limit.strategy が語彙外です: {rl['strategy']}")
    if rl["backoff"] not in BACKOFF:
        raise Problem(f"rate_limit.backoff が語彙外です: {rl['backoff']}")
    for key in ("qps", "max_retries"):
        if not isinstance(rl[key], int) or isinstance(rl[key], bool) or rl[key] < 1:
            raise Problem(f"rate_limit.{key} は 1 以上の整数です: {rl[key]!r}")

    sync = doc["sync"]
    _check_keys(sync, {"full"}, {"incremental"}, "sync")
    for key, val in sync.items():
        if val not in SYNC_CADENCE:
            raise Problem(f"sync.{key} が語彙外です: {val}")

    return doc


def find_manifests(paths: list[str]) -> list[Path]:
    if paths:
        return [Path(p) for p in paths]
    return sorted((ROOT / "connectors").rglob("*.yaml"))


def main(argv: list[str]) -> int:
    files = find_manifests(argv)
    if not files:
        sys.stderr.write("マニフェストが 1 つもありません（connectors/ 配下）\n")
        return 1
    ok = 0
    bad = 0
    seen: dict[tuple[str, int], Path] = {}
    for path in files:
        try:
            doc = validate_manifest(path)
        except Problem as e:
            sys.stderr.write(f"  NG {path}: {e}\n")
            bad += 1
            continue
        key = (doc["connector"], doc["version"])
        if key in seen:
            sys.stderr.write(f"  NG {path}: {key} が {seen[key]} と重複しています\n")
            bad += 1
            continue
        seen[key] = path
        print(f"  OK {path.relative_to(ROOT) if path.is_absolute() else path}"
              f" — {doc['connector']} v{doc['version']} ({doc['kind']}, "
              f"resource {len(doc['resources'])} 件)")
        ok += 1
    if bad:
        sys.stderr.write(f"マニフェスト検証: {ok} 件 OK / {bad} 件 NG\n")
        return 1
    print(f"マニフェスト検証: {ok} 件すべて OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
