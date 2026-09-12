#!/usr/bin/env bash
# Page shape checks. We verify **that it actually fails when broken**.
#
# What it checks:
#   1. Against the seeded DB, main pages return 200 and counts match DB measurements
#   2. Broken IDs and nonexistent IDs return 404 (not 500 or 200)
#   3. Against an **unseeded isolated DB**, shows 0 items and "not loaded" (does not hide the 0)
#   4. With an **unreachable connection target**, returns 500 (does not disguise it as 0 items)
#
# For 3 and 4 we neither break isms_dev nor stop PostgreSQL.
# We use an isolated DB and an unreachable connection target.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB="$ROOT/web"
DB="${ISMS_DB:-isms_dev}"
EMPTY_DB="${ISMS_WEB_EMPTY_DB:-isms_web_empty}"
# catalog.controls.theme is nullable. Build a DB where uncategorized controls actually exist and verify.
NULL_DB="${ISMS_WEB_NULLTHEME_DB:-isms_web_nulltheme}"
# DB for checking that step (ISMS process) statuses really change when real data changes.
STEP_DB="${ISMS_WEB_STEPS_DB:-isms_web_steps}"
PORT="${ISMS_WEB_CHECK_PORT:-3199}"
PORT_EMPTY=$((PORT + 1))
PORT_DOWN=$((PORT + 2))

# Step keys. This also verifies that they match ISO_STEPS in lib/isoSteps.ts.
STEP_KEYS="scope policy assets risk-assessment soa documents training operate monitor audit management-review improve"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
die() { red "[check_web] $*"; exit 1; }

# Throwaway DBs are dropdb'd unconditionally. If env vars are mixed up and one has the same name as
# the DB under test, the check would delete the real one. Stop name collisions before deleting.
for _tmp in "$EMPTY_DB" "$NULL_DB" "$STEP_DB"; do
  [ "$_tmp" != "$DB" ] \
    || die "使い捨て DB の名前が検査対象の DB（${DB}）と同じです。消してしまうので止めます"
done
[ "$EMPTY_DB" != "$NULL_DB" ] && [ "$EMPTY_DB" != "$STEP_DB" ] && [ "$NULL_DB" != "$STEP_DB" ] \
  || die "使い捨て DB の名前が重複しています（${EMPTY_DB} / ${NULL_DB} / ${STEP_DB}）"

# The default bash on macOS is 3.2, which lacks negative array indices (${a[-1]}).
# Keep PIDs as a space-separated string.
PIDS=""
LAST_PID=""
# Before dropping a DB, **wait for the servers connected to it to exit**.
# Running dropdb right after kill fails because connections remain, leaving the throwaway DB behind.
drop_db_or_warn() { # $1 = dbname
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if dropdb --if-exists "$1" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  red "[check_web] 使い捨て DB $1 を消せませんでした。手動で dropdb してください"
  return 1
}
cleanup() {
  local rc=$?
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  # Wait until they exit (they are our own child processes, so we can wait).
  for p in $PIDS; do wait "$p" 2>/dev/null || true; done
  drop_db_or_warn "$EMPTY_DB" || { [ "$rc" -eq 0 ] && rc=1; }
  drop_db_or_warn "$NULL_DB"  || { [ "$rc" -eq 0 ] && rc=1; }
  drop_db_or_warn "$STEP_DB"  || { [ "$rc" -eq 0 ] && rc=1; }
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_app() { # $1=port $2=dsn [$3=tenant token] -> global LAST_PID
  local port="$1" dsn="$2" token="${3-}"
  # Environment variables take precedence over the file (.env.local). Passing an empty string
  # lets us exercise the "no token" path.
  ISMS_WEB_DATABASE_URL="$dsn" ISMS_WEB_TENANT_TOKEN="$token" \
    sh -c "cd '$WEB' && exec npx next start -H 127.0.0.1 -p $port" \
    >"${TMPDIR:-/tmp}/isms_web_${port}.log" 2>&1 &
  LAST_PID=$!
  PIDS="$PIDS $LAST_PID"
  for _ in $(seq 1 60); do
    # Treat even a 500 as "responded" (500 is the expected value in the DB-down check).
    if curl -s -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  die "起動しませんでした（port ${port}）。ログ: ${TMPDIR:-/tmp}/isms_web_${port}.log"
}

code_of() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
# Extract only the "missing items" line of a step page.
# Grepping the whole page picks up the same names shown in the tool list, making it
# impossible to distinguish "missing" from "in place".
#
# **An empty string may be read as "nothing missing" only after confirming the page is a step page.**
# Otherwise, when the wording changes or a 500 is returned, it silently becomes empty and
# every negative check looking for "missing" passes vacuously.
# The marker ("what to do in this step") is assumed to appear exactly once per page, so its count is checked too.
missing_of() {
  local body n
  body=$(text_of "$1")
  n=$(printf '%s' "$body" | grep -o 'この段階で行うこと' | wc -l | tr -d ' ')
  [ "$n" = "1" ] \
    || die "$1 が段階のページとして読めません（目印『この段階で行うこと』が ${n} 個。500 か文言変更）"
  printf '%s' "$body" | sed -n 's/.*そろっていないもの: \(.*\)この段階で行うこと.*/\1/p'
}

# Extract the page's h1. Used to confirm that all 12 step pages are distinct.
h1_of() {
  curl -s "$1" | python3 -c 'import sys,re
h=sys.stdin.read()
m=re.search(r"<h1[^>]*>(.*?)</h1>", h, re.S)
print(re.sub(r"\s+"," ",re.sub(r"<[^>]+>","",m.group(1))).strip() if m else "")'
}
text_of() { curl -s "$1" | python3 -c 'import sys,re; h=sys.stdin.read(); h=re.sub(r"<script.*?</script>"," ",h,flags=re.S); print(re.sub(r"\s+"," ",re.sub(r"<[^>]+>","",h)))'; }

[ -d "$WEB/node_modules" ] || die "web/node_modules がありません。make web-install を先に実行してください"
[ -d "$WEB/.next" ] || die "web/.next がありません。make web-build を先に実行してください"

# --- 1. Seeded DB ------------------------------------------------------------
start_app "$PORT" "postgres:///${DB}?user=app_ro"
BASE="http://127.0.0.1:${PORT}"

for p in / /dashboard /graph /catalog /catalog/controls /catalog/risks /catalog/policies /catalog/criteria \
         /catalog/org /catalog/calendar /catalog/frameworks /catalog/checks /operations \
         /settings \
         /risk-management /iso27001 /risk-management/assets /risk-management/measures /risk-management/risks; do
  c=$(code_of "${BASE}${p}")
  [ "$c" = "200" ] || die "$p が ${c}（200 のはず）"
done
for k in $STEP_KEYS; do
  c=$(code_of "${BASE}/steps/${k}")
  [ "$c" = "200" ] || die "/steps/${k} が ${c}（200 のはず）"
done
dashboard_text=$(text_of "${BASE}/dashboard")
case "$dashboard_text" in
  *"今日の管理状況"*) : ;;
  *) die "/dashboard にリスク管理全体の見出しがありません" ;;
esac
dashboard_html=$(curl -s "${BASE}/dashboard")
case "$dashboard_html" in
  *"/risk-management?framework=RISK-MANAGEMENT"*"/operations/passwords"*) : ;;
  *) die "/dashboard に共通台帳とパスワード管理の導線がありません" ;;
esac
grn "[check_web] 1/4 主要ページ 200（段階 12 件とリスク台帳 5 ルートを含む）"

# If the check hard-codes the keys, adding/removing/renaming keys on the definition side goes unnoticed.
# **Derive them from the links the UI renders** and compare against the hard-coded list.
app_keys=$(curl -s "${BASE}/" \
  | python3 -c 'import sys,re; print(" ".join(sorted(set(re.findall(r"/steps/([A-Za-z0-9_-]+)", sys.stdin.read())))))')
want_keys=$(printf '%s\n' $STEP_KEYS | sort | tr '\n' ' ' | sed 's/ $//')
[ "$app_keys" = "$want_keys" ] \
  || die "画面の段階キーが検査の一覧と食い違います（画面: ${app_keys} / 検査: ${want_keys}）"

# All 12 step pages must be distinct. Looking only at 200 would pass even if
# all 12 keys returned the same content.
# A body fingerprint alone passes "same template, only the number differs", so also check **h1 uniqueness**.
step_i=0
seen_bodies=""
seen_h1=""
for k in $STEP_KEYS; do
  step_i=$((step_i + 1))
  t=$(text_of "${BASE}/steps/${k}")
  case "$t" in
    *"段階 ${step_i} / 12"*) : ;;
    *) die "/steps/${k} に「段階 ${step_i} / 12」が出ていません（並び順が定義とずれています）" ;;
  esac
  fp=$(printf '%s' "$t" | shasum | cut -d' ' -f1)
  case " $seen_bodies " in
    *" $fp "*) die "/steps/${k} が他の段階と同じ内容を返しています" ;;
    *) seen_bodies="$seen_bodies $fp" ;;
  esac
  h=$(h1_of "${BASE}/steps/${k}")
  [ -n "$h" ] || die "/steps/${k} に見出し（h1）がありません"
  hfp=$(printf '%s' "$h" | shasum | cut -d' ' -f1)
  case " $seen_h1 " in
    *" $hfp "*) die "/steps/${k} の見出しが他の段階と同じです（雛形の使い回し）" ;;
    *) seen_h1="$seen_h1 $hfp" ;;
  esac
done
grn "[check_web] 1/4b 段階 12 枚がそれぞれ別の内容・別の見出し（キーは画面から導出して突合）"

# Unknown step keys are 404. Neither 500 nor 200.
for bad in /steps/nope /steps/SCOPE /steps/scope2; do
  c=$(code_of "${BASE}${bad}")
  [ "$c" = "404" ] || die "$bad が ${c}（404 のはず）"
done
grn "[check_web] 1/4c 未知の段階キーは 404"

# All 8 pages must be reachable from the catalog sub-nav.
# Since they were removed from the top-level nav, this is the only path to them.
# An href somewhere on the page does not prove a path exists. Look **inside the sub-nav**.
ct=$(curl -s "${BASE}/catalog" \
  | python3 -c 'import sys,re
h=sys.stdin.read()
m=re.search(r"<nav[^>]*aria-label=\"カタログの下位ページ\".*?</nav>", h, re.S)
print(m.group(0) if m else "")')
[ -n "$ct" ] || die "/catalog に副ナビ（aria-label=カタログの下位ページ）がありません"
for sub in controls risks policies criteria org calendar frameworks checks; do
  case "$ct" in
    *"/catalog/${sub}\""*) : ;;
    *) die "/catalog の副ナビから /catalog/${sub} へ行けません" ;;
  esac
done
for shell_page in /catalog /operations; do
  mode_nav=$(curl -s "${BASE}${shell_page}" | python3 -c 'import sys,re; h=sys.stdin.read(); m=re.search(r"<nav[^>]*aria-label=\"表示モード\".*?</nav>", h, re.S); print(m.group(0) if m else "")')
  [ -n "$mode_nav" ] || die "${shell_page} に共通の表示モード切替がありません"
  case "$mode_nav" in
    *"mode=risk"*"mode=isms"*) : ;;
    *) die "${shell_page} の表示モード切替からリスク管理全体 / ISMS専用へ移動できません" ;;
  esac
done
# The sub-nav must also appear on detail pages (without the parent tab and current location, users get lost).
for deep in /catalog/policies/p01_basic; do
  case "$(curl -s "${BASE}${deep}")" in
    *'aria-label="カタログの下位ページ"'*) : ;;
    *) die "${deep} に副ナビが出ていません" ;;
  esac
done
grn "[check_web] 1/4d カタログ副ナビから 8 ページへ到達できる"

db_controls=$(psql -At -d "$DB" -c "SELECT count(*) FROM catalog.controls WHERE retired_at IS NULL")
db_risks=$(psql -At -d "$DB" -c "SELECT count(*) FROM catalog.risk_scenario_templates WHERE retired_at IS NULL")
page_controls=$(text_of "${BASE}/catalog/controls" | sed -n 's/.*該当 \([0-9]*\) 件.*/\1/p')
page_risks=$(text_of "${BASE}/catalog/risks" | sed -n 's/.*該当 \([0-9]*\) 件.*/\1/p')
[ "$page_controls" = "$db_controls" ] || die "統制の件数がずれています（画面 ${page_controls} / DB ${db_controls}）"
[ "$page_risks" = "$db_risks" ] || die "リスク雛形の件数がずれています（画面 ${page_risks} / DB ${db_risks}）"
grn "[check_web] 2/4 件数一致（統制 ${db_controls} / リスク雛形 ${db_risks}）"

# --- Step statuses come from actual measurements ---------------------------
# Baked-in progress would stay green even with an emptied DB. Compare against DB measurements.

# Every policy and annual event must be assigned to a step (set difference is 0 in both directions).
db_pol=$(psql -At -d "$DB" -c "SELECT count(*) FROM catalog.policies_default")
db_cal=$(psql -At -d "$DB" -c "SELECT count(*) FROM catalog.calendar_events_default")
db_role=$(psql -At -d "$DB" -c "SELECT count(*) FROM catalog.roles_default")
home=$(text_of "${BASE}/")
# Include the counts of all 3 kinds in the success condition. A prefix match would
# let the kind appended at the end (roles) pass unverified.
case "$home" in
  *"食い違いなし（規程 ${db_pol} 件・年間行事 ${db_cal} 件・ロール ${db_role} 件が、すべてどこかの段階に 割り当たっている）"*) : ;;
  *) die "段階への割り当てに食い違いがあります（または件数が DB と一致していません: 規程 ${db_pol} / 行事 ${db_cal} / ロール ${db_role}）" ;;
esac

# Annex A controls. If the count is 0, the Statement of Applicability step must fail for that reason.
db_annex=$(psql -At -d "$DB" -c \
  "SELECT count(*) FROM catalog.controls WHERE framework_key = 'ISO27001:2022' AND retired_at IS NULL")
# Measure not just the count but also **the count with the right shape**. In a DB holding only wrongly shaped
# controls, it could get past the count-0 branch and still be treated as "present".
db_annex_ok=$(psql -At -d "$DB" -c \
  "SELECT count(*) FROM catalog.controls
    WHERE framework_key = 'ISO27001:2022' AND retired_at IS NULL
      AND code ~ '^A\\.[5-8]\\.[0-9]{1,2}$'")
soa_missing=$(missing_of "${BASE}/steps/soa")
if [ "$db_annex" != "$db_annex_ok" ]; then
  case "$soa_missing" in
    *"附属書 A の統制"*) : ;;
    *) die "附属書 A の形が合わない統制が $((db_annex - db_annex_ok)) 件あるのに、そろっている扱いです" ;;
  esac
fi
if [ "$db_annex" = "0" ]; then
  case "$soa_missing" in
    *"附属書 A の統制"*) : ;;
    *) die "附属書 A が 0 件なのに、適用宣言書の段階がそれを理由に落ちていません（そろっていないもの: ${soa_missing:-なし}）" ;;
  esac
  case "$(text_of "${BASE}/catalog")" in
    *"附属書 A はまだ 1 件も入っていない"*) : ;;
    *) die "附属書 A が 0 件なのに、カタログがそれを出していません" ;;
  esac
  # Do not let the total control count be read as "controls exist".
  # The expected wording, however, depends on the state of this step's other basis (policy p05_rt_soa).
  #   body is a placeholder -> neither basis nor records exist = "nothing yet"
  #   body is filled in     -> only one basis exists = "partially in place"
  # In neither case does it become "can keep records". Pin that down.
  soa_policy_written=$(psql -At -d "$DB" -c \
    "SELECT count(*) FROM catalog.policies_default
      WHERE key = 'p05_rt_soa' AND body_md !~ '（標準本文'")
  soa_text=$(text_of "${BASE}/steps/soa")
  case "$soa_text" in
    *"記録まで残せる"*)
      die "附属書 A が 0 件なのに、適用宣言書の段階が『記録まで残せる』です（統制 ${db_controls} 件を根拠にしていないか）" ;;
    *) : ;;
  esac
  if [ "$soa_policy_written" = "0" ]; then
    case "$soa_text" in
      *"まだ何も無い"*) : ;;
      *) die "附属書 A が 0 件・規程も仮置きなのに、適用宣言書の段階が『まだ何も無い』になっていません" ;;
    esac
  else
    case "$soa_text" in
      *"一部だけそろっている"*) : ;;
      *) die "附属書 A が 0 件・規程は本文ありなのに、適用宣言書の段階が『一部だけそろっている』になっていません" ;;
    esac
  fi
fi

# Policy bodies. If all are placeholders, the basis of the policy-writing step must not be in place.
db_subst=$(psql -At -d "$DB" -c \
  "SELECT count(*) FROM catalog.policies_default WHERE body_md !~ '（標準本文'")
if [ "$db_subst" = "0" ]; then
  doc_missing=$(missing_of "${BASE}/steps/documents")
  case "$doc_missing" in
    *"個別規程の雛形"*) : ;;
    *) die "規程の本文が全件仮置きなのに、規程を整える段階が整備済みとして扱っています（${db_pol} 本あることを根拠にしていないか。そろっていないもの: ${doc_missing:-なし}）" ;;
  esac
elif [ "$db_subst" = "$db_pol" ]; then
  # Check the reverse too. If it keeps saying "templates missing" when everything is in place,
  # the UI is not reading the DB but printing a fixed string.
  doc_missing=$(missing_of "${BASE}/steps/documents")
  case "$doc_missing" in
    *"個別規程の雛形"*)
      die "規程 ${db_pol} 本すべてに本文があるのに、規程を整える段階がまだ雛形不足と出しています" ;;
    *) : ;;
  esac
fi

# Without a token, check results cannot be read. Do not call the unreadable state 0 items.
mon=$(text_of "${BASE}/steps/monitor")
case "$mon" in
  *"読めない項目あり"*) : ;;
  *) die "テナント文脈が無いのに、監視・測定の段階が『読めない』と出していません" ;;
esac
# Look at the record's own row. Searching the whole page for "0 items" would
# pick up another tool's not-loaded notice or the explanatory text "not the same as 0 items".
case "$mon" in
  *"落ちることを確かめたチェック結果"*"読める状態にない（0 件と決まったわけではない）読めない"*) : ;;
  *) die "読めないチェック結果が「読める状態にない」と出ていません（0 件や未投入に化けていないか）" ;;
esac
grn "[check_web] 2/4b 段階の状態が DB の実測から出ている（附属書A ${db_annex} 件 / 実本文の規程 ${db_subst} 本）"

# Broken input. Must be 404, neither 500 nor 200.
cid=$(psql -At -d "$DB" -c "SELECT id FROM catalog.controls ORDER BY code LIMIT 1")
[ "$(code_of "${BASE}/catalog/controls/${cid}")" = "200" ] || die "実在する統制の詳細が 200 になりません"
for bad in "/catalog/controls/not-a-uuid" \
           "/catalog/controls/00000000-0000-0000-0000-000000000000" \
           "/catalog/policies/NOPE" "/n/bogus" "/n/unknown.YWJj" "/n/control.YWJj"; do
  c=$(code_of "${BASE}${bad}")
  [ "$c" = "404" ] || die "$bad が ${c}（404 のはず）"
done
grn "[check_web] 3/4 壊れた ID は 404"

# Category-related counts must match between UI and DB. **Check every category with duplicates** (not just the first).
#
# Comparing UI to UI (detail N vs list M) directly mismatches even when correct for categories with
# parent/child relations (both 'A / B' and 'A / B / C' exist), because the list includes descendants.
# So **compare each against DB measurements**.
#   - detail "view controls in the same category (N)" ... count of **exact matches** on the same theme
#   - list "M matching"                               ... exact matches + descendants (theme LIKE ? || ' / %')
# Read one category per line. A newline in theme breaks the line boundaries, so
# **instead of silently misreading, fail explicitly as unreadable** (the CHECK in 0023 does not forbid newlines).
nl_themes=$(psql -At -d "$DB" -c \
  "SELECT count(*) FROM catalog.controls WHERE theme ~ E'[\\n\\r]'")
[ "$nl_themes" = "0" ] \
  || die "分類に改行を含む統制が ${nl_themes} 件あります。この検査は 1 行 1 分類で読むため判定できません"

# Put counts first and theme last. Even if theme contains '|',
# it all goes into rest of `read -r a b rest`, so delimiters cannot be confused.
dup_rows=$(psql -At -F '|' -d "$DB" -c "
  SELECT (SELECT count(*) FROM catalog.controls e
           WHERE e.retired_at IS NULL AND e.theme = t.theme),
         (SELECT count(*) FROM catalog.controls l
           WHERE l.retired_at IS NULL
             AND (l.theme = t.theme OR l.theme LIKE t.theme || ' / %')),
         t.theme
    FROM (SELECT theme FROM catalog.controls
           WHERE retired_at IS NULL AND theme IS NOT NULL
           GROUP BY theme HAVING count(*) > 1) t
   ORDER BY t.theme")
dup_checked=0
if [ -z "$dup_rows" ]; then
  printf '[check_web] 3/4d 同じ分類を共有する統制が無いので飛ばしました\n'
else
  while IFS='|' read -r exact_n list_n th; do
    # An empty line is the edge of the here-doc. If counts were read but the category is empty, it is an empty-string theme
    # (a DB without 0023 applied), so fail instead of silently skipping.
    [ -n "$exact_n$list_n$th" ] || continue
    [ -n "$th" ] \
      || die "分類が空文字の統制があります（0023 の CHECK が未適用の DB です）"
    cid=$(psql -At -d "$DB" -c "
      SELECT id FROM catalog.controls
       WHERE retired_at IS NULL AND theme = '$(printf '%s' "$th" | sed "s/'/''/g")'
       ORDER BY code LIMIT 1")
    n=$(text_of "${BASE}/catalog/controls/${cid}" | sed -n 's/.*同じ分類の統制を見る（\([0-9]*\) 件）.*/\1/p')
    [ "$n" = "$exact_n" ] \
      || die "詳細の「同じ分類」件数が DB と食い違います（分類 ${th}: 画面 ${n:-なし} / DB ${exact_n}）"
    q=$(printf '%s' "$th" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')
    m=$(text_of "${BASE}/catalog/controls?theme=${q}" | sed -n 's/.*該当 \([0-9]*\) 件.*/\1/p')
    [ "$m" = "$list_n" ] \
      || die "一覧の絞り込み件数が DB と食い違います（分類 ${th}: 画面 ${m:-なし} / DB ${list_n}）"
    dup_checked=$((dup_checked + 1))
  done <<EOF
$dup_rows
EOF
  grn "[check_web] 3/4d 分類の件数が画面と DB で一致（重複のある分類 ${dup_checked} 種すべて）"
fi

# Operations page: without a token it must say "not in a readable state", not "0 items".
t=$(text_of "${BASE}/operations")
case "$t" in
  *"読める状態にない"*) : ;;
  *) die "トークン無しの運用ページに『読める状態にない』が出ていません" ;;
esac
case "$t" in
  *"運用データ 0 件"*) die "読めていないのに『0 件』と書いています" ;;
  *) : ;;
esac
grn "[check_web] 3/4b トークン無しでは『0 件』と言わない"

# Collection settings, too, must not confuse catalog and tenant settings without tenant context.
st=$(text_of "${BASE}/settings")
# Check that **both** phrases appear. Order depends on the UI, so it is not a condition
# (in fact, with the warning first and the catalog heading after, only this check was failing).
case "$st" in
  *"ISMS側の収集定義"*) : ;;
  *) die "トークン無しの収集設定ページに、カタログ側（ISMS側の収集定義）が表示されていません" ;;
esac
case "$st" in
  *"読める状態にありません"*) : ;;
  *) die "トークン無しの収集設定ページが、テナント設定を『読める状態にない』と言っていません" ;;
esac
# The **negative sentence** "not 0 unset" contains the same words.
# Remove the negative sentence before searching. Otherwise a UI that correctly negates would fail.
st_claim=${st//未設定 0 件ではありません/}
case "$st_claim" in
  *"未設定 0 件"*) die "読めていないのに収集設定を『未設定 0 件』と表示しています" ;;
  *) : ;;
esac
# The negative sentence itself must appear (do not pass a UI that silently says nothing).
case "$st" in
  *"未設定 0 件ではありません"*) : ;;
  *) die "トークン無しの収集設定ページが『未設定 0 件ではありません』と断っていません" ;;
esac
grn "[check_web] 3/4e トークン無しの収集設定はカタログを表示し、テナント設定を未読と表示"

kill "$LAST_PID" 2>/dev/null || true

# When a token is passed. Verify if the caller provided one (otherwise say so).
if [ -n "${ISMS_WEB_CHECK_TENANT_TOKEN:-}" ]; then
  start_app "$((PORT + 3))" "postgres:///${DB}?user=app_ro" "$ISMS_WEB_CHECK_TENANT_TOKEN"
  tb="http://127.0.0.1:$((PORT + 3))"
  [ "$(code_of "${tb}/operations")" = "200" ] || die "トークンありで運用ページが 200 になりません"
  t=$(text_of "${tb}/operations")
  case "$t" in
    *"チェックの最新結果"*) : ;;
    *) die "トークンありなのにチェックの結果が出ていません" ;;
  esac
  [ "$(code_of "${tb}/settings")" = "200" ] || die "トークンありで収集設定ページが 200 になりません"
  t=$(text_of "${tb}/settings")
  case "$t" in
    *"ISMS側の収集定義"*) : ;;
    *) die "トークンありなのに収集定義の画面が出ていません" ;;
  esac
  grn "[check_web] 3/4c トークンありでチェックの結果が出る"
  kill "$LAST_PID" 2>/dev/null || true
else
  printf '[check_web] 3/4c トークンありの確認は飛ばしました（ISMS_WEB_CHECK_TENANT_TOKEN 未設定）\n'
fi

# --- 2. Unseeded isolated DB -------------------------------------------------
dropdb --if-exists "$EMPTY_DB"
createdb "$EMPTY_DB"
ISMS_DB="$EMPTY_DB" "$ROOT/scripts/migrate.sh" up >/dev/null
start_app "$PORT_EMPTY" "postgres:///${EMPTY_DB}?user=app_ro"
EB="http://127.0.0.1:${PORT_EMPTY}"
[ "$(code_of "${EB}/")" = "200" ] || die "空 DB で進め方のページが 200 になりません"
[ "$(code_of "${EB}/catalog")" = "200" ] || die "空 DB でカタログのページが 200 になりません"
[ "$(code_of "${EB}/settings")" = "200" ] || die "空 DB で収集設定ページが 200 になりません"
# Counts and provenance display moved to the catalog (the top page became "how to proceed").
t=$(text_of "${EB}/catalog")
case "$t" in
  *未投入*) : ;;
  *) die "空 DB なのにカタログに『未投入』が出ていません" ;;
esac
case "$t" in
  *"出所が記録されていません"*) : ;;
  *) die "空 DB なのに出所が記録済みのように見えています" ;;
esac
settings_empty=$(text_of "${EB}/settings")
# Here too, order is not a condition. Check that **both phrases appear**.
case "$settings_empty" in
  *"カタログに収集定義が投入されていません"*) : ;;
  *) die "空 DB の収集設定に『カタログに収集定義が投入されていません』が出ていません" ;;
esac
case "$settings_empty" in
  *"読める状態にありません"*) : ;;
  *) die "空 DB の収集設定が、テナント設定を『読める状態にない』と言っていません" ;;
esac
# In an empty DB, no step may be on the "usable" side.
# If this stays green, the status is baked in rather than measured.
t=$(text_of "${EB}/")
n_usable=$(printf '%s' "$t" | sed -n 's/.*12 段階のいまの状態\([0-9][0-9]*\)記録まで残せる.*/\1/p')
n_none=$(printf '%s' "$t" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)まだ何も無い.*/\1/p')
[ -n "$n_usable" ] && [ -n "$n_none" ] \
  || die "段階の集計が読めません（画面の構造が変わったか、集計を出していません）"
[ "$n_usable" = "0" ] \
  || die "空 DB なのに『記録まで残せる』段階が ${n_usable} 件あります"
[ "$n_none" = "12" ] \
  || die "空 DB なのに『まだ何も無い』が 12 件になりません（${n_none}）"
# Not just the summary: each of the 12 pages must fail too.
# Closes the gap where a fixed-string summary would pass.
for k in $STEP_KEYS; do
  [ "$(code_of "${EB}/steps/${k}")" = "200" ] || die "空 DB で /steps/${k} が 200 になりません"
  case "$(text_of "${EB}/steps/${k}")" in
    *"まだ何も無い"*) : ;;
    *) die "空 DB なのに /steps/${k} が『まだ何も無い』になっていません" ;;
  esac
done
[ "$(code_of "${EB}/graph")" = "200" ] || die "空 DB で図が 200 になりません"
grn "[check_web] 4/4a 空 DB で 0 件・未投入を出し、全 12 段階が『まだ何も無い』に落ちる"
kill "$LAST_PID" 2>/dev/null || true

# --- 2b. DB with uncategorized controls (theme is NULL) ------------------------
# catalog.controls.theme is nullable. The graph and control detail split by theme, so
# assuming NULL is a string yields a 500 (this actually happened on a dev machine).
# Working around it by deleting rows is not acceptable either: counts would disagree with the DB.
PORT_NULL=$((PORT + 4))
dropdb --if-exists "$NULL_DB"
createdb "$NULL_DB"
ISMS_DB="$NULL_DB" "$ROOT/scripts/migrate.sh" up >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$NULL_DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null
ISMS_DB="$NULL_DB" python3 "$ROOT/db/seeds/load_csv.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$NULL_DB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null
# One uncategorized (NULL) control and two sharing the same category.
# Whitespace-only and leading/trailing-space categories are rejected by migration 0023's CHECK, so they **cannot be inserted**.
# That they "cannot be inserted" is itself verified below.
psql -v ON_ERROR_STOP=1 -q -d "$NULL_DB" >/dev/null <<'SQL'
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
SELECT key, 'ZZ-NULL-THEME', '分類の無い統制', NULL FROM catalog.frameworks ORDER BY key LIMIT 1;
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
SELECT key, 'ZZ-SAME-1', '同じ分類1', 'ZZ分類 / 甲' FROM catalog.frameworks ORDER BY key LIMIT 1;
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
SELECT key, 'ZZ-SAME-2', '同じ分類2', 'ZZ分類 / 甲' FROM catalog.frameworks ORDER BY key LIMIT 1;
SQL

# Non-normalized forms must not get into the DB. If they do, the UI's assumption that
# "plain equality suffices" breaks, and the path where detail and list counts disagree returns.
# Change code for each one. Reusing it would, without the constraint, let only the first insert succeed
# and later ones fail on the unique constraint, looking as if they were "rejected".
bad_i=0
for bad in "' ZZ分類 / 甲 '" "'   '" "' / '" "''" "'甲 /  / 乙'" ; do
  bad_i=$((bad_i + 1))
  if psql -q -v ON_ERROR_STOP=1 -d "$NULL_DB" >/dev/null 2>&1 <<SQL
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
SELECT key, 'ZZ-BAD-${bad_i}', '非正規形', ${bad} FROM catalog.frameworks ORDER BY key LIMIT 1;
SQL
  then die "非正規形の分類 ${bad} が保存できてしまいました（0023 の CHECK が効いていない）"; fi
done
start_app "$PORT_NULL" "postgres:///${NULL_DB}?user=app_ro"
NB="http://127.0.0.1:${PORT_NULL}"
[ "$(code_of "${NB}/graph")" = "200" ] \
  || die "分類の無い統制が在ると図が 200 になりません（theme の NULL で落ちている）"
nid=$(psql -At -d "$NULL_DB" -c "SELECT id FROM catalog.controls WHERE code = 'ZZ-NULL-THEME'")
[ "$(code_of "${NB}/catalog/controls/${nid}")" = "200" ] \
  || die "分類の無い統制の詳細が 200 になりません"
db_n=$(psql -At -d "$NULL_DB" -c "SELECT count(*) FROM catalog.controls WHERE retired_at IS NULL")
page_n=$(text_of "${NB}/catalog/controls" | sed -n 's/.*該当 \([0-9]*\) 件.*/\1/p')
[ "$page_n" = "$db_n" ] || die "分類の無い統制を数え落としています（画面 ${page_n} / DB ${db_n}）"
case "$(text_of "${NB}/catalog/controls/${nid}")" in
  *分類なし*) : ;;
  *) die "分類が無いことを画面に出していません（空欄では取得漏れと区別が付かない）" ;;
esac

# Do not show "view controls in the same category" on an uncategorized control (it would point to the uncategorized grab bag).
case "$(text_of "${NB}/catalog/controls/${nid}")" in
  *同じ分類の統制を見る*) die "分類なしの統制に「同じ分類の統制を見る」が出ています" ;;
  *) : ;;
esac

# The detail's "same category (N)" must match the "M matching" of the list it links to.
# If only one side normalizes the category string, they disagree here.
sid=$(psql -At -d "$NULL_DB" -c "SELECT id FROM catalog.controls WHERE code = 'ZZ-SAME-1'")
sn=$(text_of "${NB}/catalog/controls/${sid}" | sed -n 's/.*同じ分類の統制を見る（\([0-9]*\) 件）.*/\1/p')
[ -n "$sn" ] || die "同じ分類を共有する統制の詳細に「同じ分類の統制を見る」が出ていません"
sq=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("ZZ分類 / 甲", safe=""))')
sm=$(text_of "${NB}/catalog/controls?theme=${sq}" | sed -n 's/.*該当 \([0-9]*\) 件.*/\1/p')
[ "$sn" = "2" ] || die "同じ分類の件数が 2 になりません（${sn}）"
[ "$sn" = "$sm" ] || die "詳細と一覧で「同じ分類」の件数が食い違います（詳細 ${sn} / 一覧 ${sm}）"

grn "[check_web] 4/4c 分類なし（NULL）で 200・件数一致・『分類なし』と明示。非正規形は DB が拒否"
kill "$LAST_PID" 2>/dev/null || true

# --- 2c. Changing real data changes step statuses ----------------------------
# The flip side of "fails when broken". Unless we also check that **fixing changes it**,
# 2/4b would pass even if the UI just printed a fixed string.
#
# Apply mutations one at a time, **measuring the state right before applying each**.
# Looking only at post-mutation values cannot prove a "change" when the initial seed changes.
PORT_STEP=$((PORT + 5))
drop_db_or_warn "$STEP_DB"
createdb "$STEP_DB"
ISMS_DB="$STEP_DB" "$ROOT/scripts/migrate.sh" up >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$STEP_DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null
ISMS_DB="$STEP_DB" python3 "$ROOT/db/seeds/load_csv.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$STEP_DB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null
# Load only 0008 (the 16 added policies). **Do not load 0007.**
# Mutation 2 checks that "placeholder -> real body changes the step display", so
# the original 12 must stay placeholders. On the other hand, without 0008,
# only the step assignment (isoSteps) would point to 28 policies and disagree.
psql -v ON_ERROR_STOP=1 -q -d "$STEP_DB" -f "$ROOT/db/seeds/0008_policies_extended.sql" >/dev/null
start_app "$PORT_STEP" "postgres:///${STEP_DB}?user=app_ro"
SB="http://127.0.0.1:${PORT_STEP}"

# Mutation 1: insert one Annex A-shaped control. "Missing" must disappear between before and after.
before=$(missing_of "${SB}/steps/soa")
case "$before" in
  *"附属書 A の統制"*) : ;;
  *) die "変異前の STEP_DB で附属書 A がそろっている扱いです（seed が変わっています）" ;;
esac
psql -v ON_ERROR_STOP=1 -q -d "$STEP_DB" >/dev/null <<'SQL'
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
VALUES ('ISO27001:2022', 'A.5.9', '情報及びその他の関連資産の目録', '組織的管理策');
SQL
after=$(missing_of "${SB}/steps/soa")
case "$after" in
  *"附属書 A の統制"*)
    die "附属書 A を 1 件入れたのに、まだ『そろっていない』ままです（固定文字列を出しています）" ;;
  *) : ;;
esac
# The status itself must rise. An implementation that just hides the row does not pass.
case "$(text_of "${SB}/steps/soa")" in
  *"まだ何も無い"*) die "附属書 A を入れても段階の状態が『まだ何も無い』のままです" ;;
  *) : ;;
esac
case "$(text_of "${SB}/catalog")" in
  *"附属書 A はまだ 1 件も入っていない"*)
    die "附属書 A を 1 件入れたのに、カタログがまだ 0 件と言っています" ;;
  *) : ;;
esac

# Mutation 2: give one policy a real body. The basis must become complete between before and after.
case "$(missing_of "${SB}/steps/scope")" in
  *"適用範囲の規程雛形"*) : ;;
  *) die "変異前の STEP_DB で適用範囲の規程が実本文扱いです（seed が変わっています）" ;;
esac
n_upd=$(psql -At -v ON_ERROR_STOP=1 -d "$STEP_DB" -c "
  WITH u AS (
    UPDATE catalog.policies_default
       SET body_md = E'# ISMS 適用範囲\n\n当社の全事業所と全従業員を対象とする。受託開発業務を含む。'
     WHERE key = 'p02_scope' RETURNING 1)
  SELECT count(*) FROM u")
[ "$n_upd" = "1" ] || die "p02_scope の本文を更新できませんでした（更新 ${n_upd} 行）"
case "$(missing_of "${SB}/steps/scope")" in
  *"適用範囲の規程雛形"*)
    die "p02_scope を実本文にしたのに、まだ仮置き扱いです" ;;
  *) : ;;
esac

# Mutation 3: adding a control with a differently shaped code must not be counted as Annex A.
# If this does not fail, only the count is being checked.
psql -v ON_ERROR_STOP=1 -q -d "$STEP_DB" >/dev/null <<'SQL'
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
VALUES ('ISO27001:2022', 'X-1', '形の合わない統制', '組織的管理策');
SQL
case "$(missing_of "${SB}/steps/soa")" in
  *"附属書 A の統制"*) : ;;
  *) die "形の合わない統制（X-1）を足しても附属書 A として数えられています（件数しか見ていません）" ;;
esac
case "$(text_of "${SB}/catalog/frameworks")" in
  *"形が合わないものが 1 件ある"*) : ;;
  *) die "フレームワークの画面が、形の合わない統制を出していません" ;;
esac

# Mutation 4: adding a policy not assigned to any step must appear in the set difference.
case "$(text_of "${SB}/")" in
  *食い違いなし*) : ;;
  *) die "変異前の STEP_DB で既に割り当ての食い違いがあります" ;;
esac
psql -v ON_ERROR_STOP=1 -q -d "$STEP_DB" >/dev/null <<'SQL'
INSERT INTO catalog.policies_default (key, dom_version_id, title_ja, body_md, clause_refs, sort_order)
VALUES ('zz_unassigned', '00000000-0000-0000-0000-000000002026', '割り当てていない規程',
        E'# 割り当てていない規程\n\n本文あり。', '{}', 99);
SQL
case "$(text_of "${SB}/")" in
  *"DB にあるのに割り当てていない規程: zz_unassigned"*) : ;;
  *) die "割り当てていない規程を足したのに、画面が食い違いを出していません" ;;
esac
case "$(text_of "${SB}/")" in
  *食い違いなし*) die "割り当ての食い違いがあるのに『食い違いなし』と出ています" ;;
  *) : ;;
esac
grn "[check_web] 2/4c 実データを変えると段階の状態が変わる（前後を測って確認）"
kill "$LAST_PID" 2>/dev/null || true

# --- 2d. Register counts are filtered by the ISMS framework ---------------------
# The step pages are the ISMS lens (resolveAppMode always forces isms mode for /steps).
# The register is one across all frameworks, so **without a framework filter, IPO-prep-only assets get counted too**.
# The filter exists only inside the SQL in catalog.ts and cannot be reached from unit tests.
# Here we use real data and verify, measuring before and after, that **removing the condition changes the count**.
PORT_REG=$((PORT + 6))
# Place only the needed tenant rows directly, bypassing provision_tenant (this check only cares about
# register count filtering and should not depend on provisioning-path details).
REG_TOKEN=$(python3 -c "import secrets;print(secrets.token_hex(32))")
psql -q -v ON_ERROR_STOP=1 -v tok="$REG_TOKEN" -d "$STEP_DB" >/dev/null <<'SQL'
INSERT INTO app.tenants (id, name, domain, dom_version_id)
SELECT '11111111-1111-4111-8111-111111111111', '枠組み検査', 'register-scope.invalid', d.id
  FROM catalog.dom_versions d WHERE d.is_current;
INSERT INTO app.users (id, tenant_id, email, display_name)
VALUES ('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111',
        'check@register-scope.invalid','検査');
INSERT INTO app.memberships (tenant_id, user_id, role_key)
VALUES ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222','ciso');
INSERT INTO app.sessions (tenant_id, user_id, token_hash, expires_at)
VALUES ('11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222',
        public.digest(convert_to(:'tok','UTF8'),'sha256'), now() + interval '1 hour');
SQL

# From here on, the registers. **Insert after establishing tenant context**
# (the framework-consistency trigger requires app.current_tenant()).
# set_tenant_context is equivalent to SET LOCAL, so keep it within one transaction.
psql -q -v ON_ERROR_STOP=1 -v tok="$REG_TOKEN" -d "$STEP_DB" >/dev/null <<'SQL'
BEGIN;
SELECT app.set_tenant_context(:'tok');
-- Put one "ISO in scope" and one "IPO prep only" row in each of assets, risks, and measures.
-- With only one of them, removing that register's framework condition would not move the count.
INSERT INTO app.assets (tenant_id, asset_key, name, asset_type, classification)
VALUES ('11111111-1111-4111-8111-111111111111','REG-ISO','ISO 対象の資産','system','internal'),
       ('11111111-1111-4111-8111-111111111111','REG-IPO','上場準備だけの資産','system','internal');
INSERT INTO app.asset_frameworks (tenant_id, asset_id, framework_key)
SELECT a.tenant_id, a.id, f FROM app.assets a,
       unnest(ARRAY['RISK-MANAGEMENT','ISO27001:2022']) f WHERE a.asset_key = 'REG-ISO';
INSERT INTO app.asset_frameworks (tenant_id, asset_id, framework_key)
SELECT a.tenant_id, a.id, f FROM app.assets a,
       unnest(ARRAY['RISK-MANAGEMENT','IPO-KARTE']) f WHERE a.asset_key = 'REG-IPO';

INSERT INTO app.risk_scenarios
  (tenant_id, risk_key, domain, area, phase, theme, measure, frame, summary, status)
VALUES ('11111111-1111-4111-8111-111111111111','REG-RISK','R','R',1,'R','R','管理可能性',
        'ISO 対象のリスク','active'),
       ('11111111-1111-4111-8111-111111111111','REG-RISK-IPO','R','R',1,'R','R','管理可能性',
        '上場準備だけのリスク','active');
INSERT INTO app.risk_scenario_frameworks (tenant_id, risk_scenario_id, framework_key)
SELECT r.tenant_id, r.id, f FROM app.risk_scenarios r,
       unnest(ARRAY['RISK-MANAGEMENT','ISO27001:2022']) f WHERE r.risk_key = 'REG-RISK';
INSERT INTO app.risk_scenario_frameworks (tenant_id, risk_scenario_id, framework_key)
SELECT r.tenant_id, r.id, f FROM app.risk_scenarios r,
       unnest(ARRAY['RISK-MANAGEMENT','IPO-KARTE']) f WHERE r.risk_key = 'REG-RISK-IPO';

INSERT INTO app.measures (tenant_id, measure_key, name, summary, strategy)
VALUES ('11111111-1111-4111-8111-111111111111','REG-M-ISO','ISO 対象の施策','s','mitigate'),
       ('11111111-1111-4111-8111-111111111111','REG-M-IPO','上場準備だけの施策','s','mitigate');
INSERT INTO app.measure_frameworks (tenant_id, measure_id, framework_key)
SELECT m.tenant_id, m.id, f FROM app.measures m,
       unnest(ARRAY['RISK-MANAGEMENT','ISO27001:2022']) f WHERE m.measure_key = 'REG-M-ISO';
INSERT INTO app.measure_frameworks (tenant_id, measure_id, framework_key)
SELECT m.tenant_id, m.id, f FROM app.measures m,
       unnest(ARRAY['RISK-MANAGEMENT','IPO-KARTE']) f WHERE m.measure_key = 'REG-M-IPO';
COMMIT;
SQL

start_app "$PORT_REG" "postgres:///${STEP_DB}?user=app_ro" "$REG_TOKEN"
RB="http://127.0.0.1:${PORT_REG}"

# Extract only the register count. **Do not search the whole page for the count string.**
# Policy rows on the same step also show "N items", so a full-text match would pass by hitting the
# policy row even if the register count changed (it actually did pass that way).
# Use the tool description (which appears only on the register row) as a marker and read the count right after it.
register_count_of() { # $1=URL $2=description marker text
  text_of "$1" | tr '\n' ' ' | grep -o "$2.\{0,60\}" | grep -oE '[0-9]+ 件' | head -1
}

# All 3 registers must count only the 1 ISO-in-scope row. 2 means the filter is not working.
for probe in \
  "assets|件数は ISO 対象として登録されている資産の数|資産" \
  "risk-assessment|件数は ISO 対象として登録されているリスクの数|リスク" \
  "operate|件数は ISO 対象として登録されている施策の数|施策"; do
  step="${probe%%|*}"; rest="${probe#*|}"; note="${rest%%|*}"; label="${rest##*|}"
  n=$(register_count_of "${RB}/steps/${step}" "$note")
  [ -n "$n" ] || die "${label}の段階に台帳の件数が出ていません"
  [ "$n" = "1 件" ] \
    || die "${label}の台帳の件数が枠組みで絞られていません（実測: ${n}）"
done

# Also check that **fixing changes it**. One direction alone cannot be distinguished from a fixed string.
psql -q -v ON_ERROR_STOP=1 -v tok="$REG_TOKEN" -d "$STEP_DB" >/dev/null <<'SQL'
BEGIN;
SELECT app.set_tenant_context(:'tok');
INSERT INTO app.asset_frameworks (tenant_id, asset_id, framework_key)
SELECT a.tenant_id, a.id, 'ISO27001:2022' FROM app.assets a WHERE a.asset_key = 'REG-IPO';
INSERT INTO app.risk_scenario_frameworks (tenant_id, risk_scenario_id, framework_key)
SELECT r.tenant_id, r.id, 'ISO27001:2022' FROM app.risk_scenarios r WHERE r.risk_key = 'REG-RISK-IPO';
INSERT INTO app.measure_frameworks (tenant_id, measure_id, framework_key)
SELECT m.tenant_id, m.id, 'ISO27001:2022' FROM app.measures m WHERE m.measure_key = 'REG-M-IPO';
COMMIT;
SQL

for probe in \
  "assets|件数は ISO 対象として登録されている資産の数|資産" \
  "risk-assessment|件数は ISO 対象として登録されているリスクの数|リスク" \
  "operate|件数は ISO 対象として登録されている施策の数|施策"; do
  step="${probe%%|*}"; rest="${probe#*|}"; note="${rest%%|*}"; label="${rest##*|}"
  n=$(register_count_of "${RB}/steps/${step}" "$note")
  [ "$n" = "2 件" ] \
    || die "ISO 対象のタグを足したのに${label}の件数が増えません（実測: ${n}）"
done

# Once registered, it must disappear from "missing items".
# Do not make approval or presence of a responsible manager a condition of the count (user decision on 2026-09-07).
for step in assets risk-assessment operate; do
  case "$(missing_of "${RB}/steps/${step}")" in
    *"自社の情報資産目録"*|*"自社のリスク台帳"*|*"選んだ統制の実施記録"*)
      die "/steps/${step} は台帳に行があるのに『そろっていない』のままです" ;;
    *) : ;;
  esac
done

grn "[check_web] 2/4d 台帳の件数が ISMS の枠組みで絞られる（外すと数が変わることを両方向で確認）"
kill "$LAST_PID" 2>/dev/null || true

# --- 3. Unreachable connection target -------------------------------------------
# Point at an unreachable port. Do not stop the running PostgreSQL.
start_app "$PORT_DOWN" "postgres://app_ro@127.0.0.1:59999/${DB}"
DOWN="http://127.0.0.1:${PORT_DOWN}"
for p in / /catalog /steps/scope; do
  c=$(code_of "${DOWN}${p}")
  [ "$c" = "500" ] || die "DB へ繋がらないのに ${p} が ${c}（500 のはず。0 件の顔で誤魔化してはいけない）"
done
# Unknown step keys stay 404 even when the DB is down.
# If key validation is placed after DB access, this becomes 500 and
# "no such page" becomes indistinguishable from "cannot read right now".
for bad in /steps/nope /steps/SCOPE /steps/scope2; do
  c=$(code_of "${DOWN}${bad}")
  [ "$c" = "404" ] || die "DB 断でも ${bad} は 404 のはずですが ${c} でした"
done
grn "[check_web] 4/4b DB 断は 500（0 件と区別できる）。未知キーは DB 断でも 404"

grn "[check_web] すべて緑"
