#!/usr/bin/env bash
# 画面の外形検査。**壊した状態で実際に落ちること**まで見る。
#
# 見るもの:
#   1. 投入済み DB に対して主要ページが 200 で、件数が DB の実測と一致する
#   2. 壊れた ID・存在しない ID が 404 になる（500 や 200 にならない）
#   3. **seed していない隔離 DB** に対して 0 件と「未投入」を出す（0 を隠さない）
#   4. **繋がらない接続先**で 500 になる（0 件の顔で誤魔化さない）
#
# 3 と 4 のために isms_dev を壊したり PostgreSQL を止めたりはしない。
# 隔離した DB と、届かない接続先を使う。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB="$ROOT/web"
DB="${ISMS_DB:-isms_dev}"
EMPTY_DB="${ISMS_WEB_EMPTY_DB:-isms_web_empty}"
# catalog.controls.theme は NULL 可。分類の無い統制が実在する DB を作って確かめる。
NULL_DB="${ISMS_WEB_NULLTHEME_DB:-isms_web_nulltheme}"
# 段階（ISMS の進め方）の状態が、実データを変えると本当に変わることを見るための DB。
STEP_DB="${ISMS_WEB_STEPS_DB:-isms_web_steps}"
PORT="${ISMS_WEB_CHECK_PORT:-3199}"
PORT_EMPTY=$((PORT + 1))
PORT_DOWN=$((PORT + 2))

# 段階のキー。lib/isoSteps.ts の ISO_STEPS と一致していること自体をここで確かめる。
STEP_KEYS="scope policy assets risk-assessment soa documents training operate monitor audit management-review improve"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
die() { red "[check_web] $*"; exit 1; }

# 使い捨て DB は無条件に dropdb する。環境変数を取り違えて検査対象の DB と同じ名前に
# なっていると、検査が本体を消してしまう。消す前に名前の衝突を止める。
for _tmp in "$EMPTY_DB" "$NULL_DB" "$STEP_DB"; do
  [ "$_tmp" != "$DB" ] \
    || die "使い捨て DB の名前が検査対象の DB（${DB}）と同じです。消してしまうので止めます"
done
[ "$EMPTY_DB" != "$NULL_DB" ] && [ "$EMPTY_DB" != "$STEP_DB" ] && [ "$NULL_DB" != "$STEP_DB" ] \
  || die "使い捨て DB の名前が重複しています（${EMPTY_DB} / ${NULL_DB} / ${STEP_DB}）"

# macOS 既定の bash は 3.2 で、配列の負インデックス（${a[-1]}）が使えない。
# PID は空白区切りの文字列で持つ。
PIDS=""
LAST_PID=""
# DB を消す前に、その DB へ繋いでいたサーバの**終了を待つ**。
# kill した直後に dropdb すると接続が残っていて失敗し、使い捨て DB が残る。
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
  # 終了するまで待つ（自分の子プロセスなので wait できる）。
  for p in $PIDS; do wait "$p" 2>/dev/null || true; done
  drop_db_or_warn "$EMPTY_DB" || { [ "$rc" -eq 0 ] && rc=1; }
  drop_db_or_warn "$NULL_DB"  || { [ "$rc" -eq 0 ] && rc=1; }
  drop_db_or_warn "$STEP_DB"  || { [ "$rc" -eq 0 ] && rc=1; }
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_app() { # $1=port $2=dsn [$3=テナントトークン] -> グローバル LAST_PID
  local port="$1" dsn="$2" token="${3-}"
  # 環境変数はファイル（.env.local）より優先される。空文字を渡せば
  # 「トークン無し」の経路を確かめられる。
  ISMS_WEB_DATABASE_URL="$dsn" ISMS_WEB_TENANT_TOKEN="$token" \
    sh -c "cd '$WEB' && exec npx next start -H 127.0.0.1 -p $port" \
    >"${TMPDIR:-/tmp}/isms_web_${port}.log" 2>&1 &
  LAST_PID=$!
  PIDS="$PIDS $LAST_PID"
  for _ in $(seq 1 60); do
    # 500 でも「応答した」とみなす（DB 断の検査では 500 が期待値のため）。
    if curl -s -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  die "起動しませんでした（port ${port}）。ログ: ${TMPDIR:-/tmp}/isms_web_${port}.log"
}

code_of() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
# 段階のページの「そろっていないもの」の行だけを取り出す。
# ページ全体を grep すると、道具の一覧に出ている同じ名前を拾って
# 「そろっていない」と「そろっている」が区別できなくなる。
#
# **空文字を「不足なし」と読んでよいのは、ページが段階のページだと確かめた後だけ。**
# 文言を変えたときや 500 を返したときに黙って空になり、
# 「そろっていない」を見る否定判定がすべて素通りするのを防ぐ。
# 目印（この段階で行うこと）はページに 1 つしか無い前提なので、その数も確かめる。
missing_of() {
  local body n
  body=$(text_of "$1")
  n=$(printf '%s' "$body" | grep -o 'この段階で行うこと' | wc -l | tr -d ' ')
  [ "$n" = "1" ] \
    || die "$1 が段階のページとして読めません（目印『この段階で行うこと』が ${n} 個。500 か文言変更）"
  printf '%s' "$body" | sed -n 's/.*そろっていないもの: \(.*\)この段階で行うこと.*/\1/p'
}

# ページの h1 を取り出す。段階のページが 12 枚とも別物であることの確認に使う。
h1_of() {
  curl -s "$1" | python3 -c 'import sys,re
h=sys.stdin.read()
m=re.search(r"<h1[^>]*>(.*?)</h1>", h, re.S)
print(re.sub(r"\s+"," ",re.sub(r"<[^>]+>","",m.group(1))).strip() if m else "")'
}
text_of() { curl -s "$1" | python3 -c 'import sys,re; h=sys.stdin.read(); h=re.sub(r"<script.*?</script>"," ",h,flags=re.S); print(re.sub(r"\s+"," ",re.sub(r"<[^>]+>","",h)))'; }

[ -d "$WEB/node_modules" ] || die "web/node_modules がありません。make web-install を先に実行してください"
[ -d "$WEB/.next" ] || die "web/.next がありません。make web-build を先に実行してください"

# --- 1. 投入済み DB -----------------------------------------------------------
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

# 検査の側でキーを直書きすると、定義の側でキーを増減・改名しても気づけない。
# **画面が出しているリンクから引き出して**、直書きの一覧と突き合わせる。
app_keys=$(curl -s "${BASE}/" \
  | python3 -c 'import sys,re; print(" ".join(sorted(set(re.findall(r"/steps/([A-Za-z0-9_-]+)", sys.stdin.read())))))')
want_keys=$(printf '%s\n' $STEP_KEYS | sort | tr '\n' ' ' | sed 's/ $//')
[ "$app_keys" = "$want_keys" ] \
  || die "画面の段階キーが検査の一覧と食い違います（画面: ${app_keys} / 検査: ${want_keys}）"

# 段階のページが 12 枚とも別物であること。200 だけ見ていると、
# 12 キーが同じ内容を返していても通ってしまう。
# 本文の指紋だけだと「同じ雛形で番号だけ違う」でも通るので、**見出し（h1）の一意性**も見る。
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

# 未知の段階キーは 404。500 でも 200 でもない。
for bad in /steps/nope /steps/SCOPE /steps/scope2; do
  c=$(code_of "${BASE}${bad}")
  [ "$c" = "404" ] || die "$bad が ${c}（404 のはず）"
done
grn "[check_web] 1/4c 未知の段階キーは 404"

# カタログの副ナビから 8 ページすべてへ行けること。
# 第一階層のナビから消えた分、ここが唯一の導線になる。
# ページのどこかに href があるだけでは導線の証明にならない。**副ナビの中**を見る。
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
# 詳細ページにも副ナビが出ること（親タブと現在地が消えると迷子になる）。
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

# --- 段階の状態が実測から出ていること ------------------------------------------
# 焼き込んだ進捗を置くと DB を空にしても緑のままになる。DB の実測と突き合わせる。

# 規程・年間行事が、どれも段階に割り当たっていること（双方向の差集合が 0）。
db_pol=$(psql -At -d "$DB" -c "SELECT count(*) FROM catalog.policies_default")
db_cal=$(psql -At -d "$DB" -c "SELECT count(*) FROM catalog.calendar_events_default")
db_role=$(psql -At -d "$DB" -c "SELECT count(*) FROM catalog.roles_default")
home=$(text_of "${BASE}/")
# 3 種すべての件数を成功条件に含める。前方一致で切ると、
# 末尾に足した種別（ロール）が検証されないまま通ってしまう。
case "$home" in
  *"食い違いなし（規程 ${db_pol} 件・年間行事 ${db_cal} 件・ロール ${db_role} 件が、すべてどこかの段階に 割り当たっている）"*) : ;;
  *) die "段階への割り当てに食い違いがあります（または件数が DB と一致していません: 規程 ${db_pol} / 行事 ${db_cal} / ロール ${db_role}）" ;;
esac

# 附属書 A の統制。件数が 0 なら、適用宣言書の段階はそれを理由に落ちていること。
db_annex=$(psql -At -d "$DB" -c \
  "SELECT count(*) FROM catalog.controls WHERE framework_key = 'ISO27001:2022' AND retired_at IS NULL")
# 件数だけでなく**形の合う件数**も測る。形の違う統制しか無い DB では、
# 件数 0 の分岐を抜けたうえで「入っている」ことにされかねない。
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
  # 統制の合計 304 件を根拠に「統制がある」と読ませないこと。
  # ただし期待する言葉は、この段階のもう 1 つの下敷き（規程 p05_rt_soa）の状態で変わる。
  #   本文が仮置き → 下敷きも記録も無い＝「まだ何も無い」
  #   本文が入った → 下敷きの片方だけ在る＝「一部だけそろっている」
  # どちらの場合も「記録まで残せる」にはならない。そこを固定する。
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

# 規程の本文。全件が仮置きなら、規程を整える段階の下敷きはそろっていないこと。
db_subst=$(psql -At -d "$DB" -c \
  "SELECT count(*) FROM catalog.policies_default WHERE body_md !~ '（標準本文'")
if [ "$db_subst" = "0" ]; then
  doc_missing=$(missing_of "${BASE}/steps/documents")
  case "$doc_missing" in
    *"個別規程の雛形"*) : ;;
    *) die "規程の本文が全件仮置きなのに、規程を整える段階が整備済みとして扱っています（${db_pol} 本あることを根拠にしていないか。そろっていないもの: ${doc_missing:-なし}）" ;;
  esac
elif [ "$db_subst" = "$db_pol" ]; then
  # 逆側も見る。全部そろっているのに「雛形が足りない」と言い続けるなら、
  # 画面は DB を読んでおらず固定の文字列を出している。
  doc_missing=$(missing_of "${BASE}/steps/documents")
  case "$doc_missing" in
    *"個別規程の雛形"*)
      die "規程 ${db_pol} 本すべてに本文があるのに、規程を整える段階がまだ雛形不足と出しています" ;;
    *) : ;;
  esac
fi

# トークン無しではチェック結果を読めない。読めないことを 0 件と言わないこと。
mon=$(text_of "${BASE}/steps/monitor")
case "$mon" in
  *"読めない項目あり"*) : ;;
  *) die "テナント文脈が無いのに、監視・測定の段階が『読めない』と出していません" ;;
esac
# 記録の行そのものを見る。ページ全体に「0 件」を探すと、
# 別の道具の未投入表示や「0 件とは違う」という説明文を拾ってしまう。
case "$mon" in
  *"落ちることを確かめたチェック結果"*"読める状態にない（0 件と決まったわけではない）読めない"*) : ;;
  *) die "読めないチェック結果が「読める状態にない」と出ていません（0 件や未投入に化けていないか）" ;;
esac
grn "[check_web] 2/4b 段階の状態が DB の実測から出ている（附属書A ${db_annex} 件 / 実本文の規程 ${db_subst} 本）"

# 壊れた入力。500 でも 200 でもなく 404 になること。
cid=$(psql -At -d "$DB" -c "SELECT id FROM catalog.controls ORDER BY code LIMIT 1")
[ "$(code_of "${BASE}/catalog/controls/${cid}")" = "200" ] || die "実在する統制の詳細が 200 になりません"
for bad in "/catalog/controls/not-a-uuid" \
           "/catalog/controls/00000000-0000-0000-0000-000000000000" \
           "/catalog/policies/NOPE" "/n/bogus" "/n/unknown.YWJj" "/n/control.YWJj"; do
  c=$(code_of "${BASE}${bad}")
  [ "$c" = "404" ] || die "$bad が ${c}（404 のはず）"
done
grn "[check_web] 3/4 壊れた ID は 404"

# 分類まわりの件数が、画面と DB で一致すること。**重複のある分類を全部見る**（先頭 1 件だけにしない）。
#
# 画面同士（詳細 N と一覧 M）を直接比べると、親子関係のある分類
# （'A / B' と 'A / B / C' が両方在る）では一覧が子孫も含むため、正しくても食い違う。
# そこで**それぞれを DB の実測と突き合わせる**。
#   - 詳細の「同じ分類の統制を見る（N 件）」 … 同じ theme の**完全一致**の件数
#   - 一覧の「該当 M 件」                    … 完全一致 ＋ 子孫（theme LIKE ? || ' / %'）の件数
# 1 行 1 分類で読む。theme に改行が入ると行の切れ目が壊れるので、
# **黙って誤読せず、読めないことを明示して落とす**（0023 の CHECK は改行を禁じていない）。
nl_themes=$(psql -At -d "$DB" -c \
  "SELECT count(*) FROM catalog.controls WHERE theme ~ E'[\\n\\r]'")
[ "$nl_themes" = "0" ] \
  || die "分類に改行を含む統制が ${nl_themes} 件あります。この検査は 1 行 1 分類で読むため判定できません"

# 件数を先に、theme を最後に置く。theme に '|' が入っても
# `read -r a b rest` の rest 側へ全部入るので、区切りの取り違えが起きない。
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
    # 空行はヒアドキュメントの端。件数は読めたのに分類が空なら、それは空文字の theme
    # （0023 未適用の DB）なので、黙って飛ばさず落とす。
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

# 運用ページ: トークンが無いときは「0 件」ではなく「読める状態にない」と出ること。
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

# 収集設定も、テナント文脈が無いときはカタログとテナント設定を混同しない。
st=$(text_of "${BASE}/settings")
# 2 つの言葉が**両方**出ていることを見る。並び順は画面の都合で変わるので条件にしない
# （実際、警告が先・カタログの見出しが後の並びで、この検査だけが落ちていた）。
case "$st" in
  *"ISMS側の収集定義"*) : ;;
  *) die "トークン無しの収集設定ページに、カタログ側（ISMS側の収集定義）が表示されていません" ;;
esac
case "$st" in
  *"読める状態にありません"*) : ;;
  *) die "トークン無しの収集設定ページが、テナント設定を『読める状態にない』と言っていません" ;;
esac
# 「未設定 0 件ではありません」という**否定文**が同じ語を含む。
# 否定文を取り除いてから探す。取り除かないと、正しく否定している画面を落としてしまう。
st_claim=${st//未設定 0 件ではありません/}
case "$st_claim" in
  *"未設定 0 件"*) die "読めていないのに収集設定を『未設定 0 件』と表示しています" ;;
  *) : ;;
esac
# 否定文そのものは出ていること（黙って何も言わない画面を通さない）。
case "$st" in
  *"未設定 0 件ではありません"*) : ;;
  *) die "トークン無しの収集設定ページが『未設定 0 件ではありません』と断っていません" ;;
esac
grn "[check_web] 3/4e トークン無しの収集設定はカタログを表示し、テナント設定を未読と表示"

kill "$LAST_PID" 2>/dev/null || true

# トークンを渡した場合。呼び出し側が用意していれば確かめる（無ければその旨を出す）。
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

# --- 2. seed していない隔離 DB -------------------------------------------------
dropdb --if-exists "$EMPTY_DB"
createdb "$EMPTY_DB"
ISMS_DB="$EMPTY_DB" "$ROOT/scripts/migrate.sh" up >/dev/null
start_app "$PORT_EMPTY" "postgres:///${EMPTY_DB}?user=app_ro"
EB="http://127.0.0.1:${PORT_EMPTY}"
[ "$(code_of "${EB}/")" = "200" ] || die "空 DB で進め方のページが 200 になりません"
[ "$(code_of "${EB}/catalog")" = "200" ] || die "空 DB でカタログのページが 200 になりません"
[ "$(code_of "${EB}/settings")" = "200" ] || die "空 DB で収集設定ページが 200 になりません"
# 件数と出所の表示はカタログへ移した（トップは「進め方」になったため）。
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
# ここも並び順を条件にしない。**両方の言葉が出ていること**を見る。
case "$settings_empty" in
  *"カタログに収集定義が投入されていません"*) : ;;
  *) die "空 DB の収集設定に『カタログに収集定義が投入されていません』が出ていません" ;;
esac
case "$settings_empty" in
  *"読める状態にありません"*) : ;;
  *) die "空 DB の収集設定が、テナント設定を『読める状態にない』と言っていません" ;;
esac
# 空の DB では、どの段階も「使える」側に立たないこと。
# ここが緑のままなら、状態が実測ではなく焼き込みになっている。
t=$(text_of "${EB}/")
n_usable=$(printf '%s' "$t" | sed -n 's/.*12 段階のいまの状態\([0-9][0-9]*\)記録まで残せる.*/\1/p')
n_none=$(printf '%s' "$t" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)まだ何も無い.*/\1/p')
[ -n "$n_usable" ] && [ -n "$n_none" ] \
  || die "段階の集計が読めません（画面の構造が変わったか、集計を出していません）"
[ "$n_usable" = "0" ] \
  || die "空 DB なのに『記録まで残せる』段階が ${n_usable} 件あります"
[ "$n_none" = "12" ] \
  || die "空 DB なのに『まだ何も無い』が 12 件になりません（${n_none}）"
# 集計だけでなく、12 枚それぞれが落ちていること。
# 集計を固定文字列にしても通る、という抜けを塞ぐ。
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

# --- 2b. 分類の無い統制（theme が NULL）が実在する DB ---------------------------
# catalog.controls.theme は nullable。図と統制詳細は theme を段に割るので、
# NULL を string と決め打ちすると 500 になる（実際に mac mini で起きた）。
# 行を消して回避してもいけない。件数が DB と食い違う。
PORT_NULL=$((PORT + 4))
dropdb --if-exists "$NULL_DB"
createdb "$NULL_DB"
ISMS_DB="$NULL_DB" "$ROOT/scripts/migrate.sh" up >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$NULL_DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null
ISMS_DB="$NULL_DB" python3 "$ROOT/db/seeds/load_csv.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$NULL_DB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null
# 分類なし（NULL）1 件と、同じ分類を共有する 2 件。
# 空白のみ・前後空白の分類は migration 0023 の CHECK が拒否するので**入れられない**。
# 「入れられないこと」自体は下で確かめる。
psql -v ON_ERROR_STOP=1 -q -d "$NULL_DB" >/dev/null <<'SQL'
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
SELECT key, 'ZZ-NULL-THEME', '分類の無い統制', NULL FROM catalog.frameworks ORDER BY key LIMIT 1;
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
SELECT key, 'ZZ-SAME-1', '同じ分類1', 'ZZ分類 / 甲' FROM catalog.frameworks ORDER BY key LIMIT 1;
INSERT INTO catalog.controls (framework_key, code, title_ja, theme)
SELECT key, 'ZZ-SAME-2', '同じ分類2', 'ZZ分類 / 甲' FROM catalog.frameworks ORDER BY key LIMIT 1;
SQL

# 非正規形が DB に入らないこと。ここが通ると、画面側の「素の等値でよい」という
# 前提が崩れ、詳細と一覧の件数が食い違う経路が復活する。
# code は 1 件ずつ変える。使い回すと、制約が無いときに 1 件目だけ入り、
# 2 件目以降が一意制約違反で落ちて「拒否された」ように見える。
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

# 分類なしの統制に「同じ分類の統制を見る」を出さない（分類なしの寄せ集めを指すため）。
case "$(text_of "${NB}/catalog/controls/${nid}")" in
  *同じ分類の統制を見る*) die "分類なしの統制に「同じ分類の統制を見る」が出ています" ;;
  *) : ;;
esac

# 詳細の「同じ分類（N 件）」と、その遷移先一覧の「該当 M 件」が一致すること。
# 片方だけ分類文字列を正規化すると、ここが食い違う。
sid=$(psql -At -d "$NULL_DB" -c "SELECT id FROM catalog.controls WHERE code = 'ZZ-SAME-1'")
sn=$(text_of "${NB}/catalog/controls/${sid}" | sed -n 's/.*同じ分類の統制を見る（\([0-9]*\) 件）.*/\1/p')
[ -n "$sn" ] || die "同じ分類を共有する統制の詳細に「同じ分類の統制を見る」が出ていません"
sq=$(python3 -c 'import urllib.parse; print(urllib.parse.quote("ZZ分類 / 甲", safe=""))')
sm=$(text_of "${NB}/catalog/controls?theme=${sq}" | sed -n 's/.*該当 \([0-9]*\) 件.*/\1/p')
[ "$sn" = "2" ] || die "同じ分類の件数が 2 になりません（${sn}）"
[ "$sn" = "$sm" ] || die "詳細と一覧で「同じ分類」の件数が食い違います（詳細 ${sn} / 一覧 ${sm}）"

grn "[check_web] 4/4c 分類なし（NULL）で 200・件数一致・『分類なし』と明示。非正規形は DB が拒否"
kill "$LAST_PID" 2>/dev/null || true

# --- 2c. 実データを変えると段階の状態が変わること -------------------------------
# 「壊すと落ちる」の裏返し。**直すと変わる**ことも見ないと、
# 画面が固定文字列を出しているだけでも 2/4b が通ってしまう。
#
# 変異は 1 つずつ当て、**当てる前の状態をその場で測ってから**当てる。
# 変異後の値だけを見ると、初期 seed が変わったときに「変わった」ことを実証できない。
PORT_STEP=$((PORT + 5))
drop_db_or_warn "$STEP_DB"
createdb "$STEP_DB"
ISMS_DB="$STEP_DB" "$ROOT/scripts/migrate.sh" up >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$STEP_DB" -f "$ROOT/db/seeds/0001_dom_2026_1.sql" >/dev/null
ISMS_DB="$STEP_DB" python3 "$ROOT/db/seeds/load_csv.py" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$STEP_DB" -f "$ROOT/db/seeds/0002_checks_core.sql" >/dev/null
# 0008（追加した 16 本）だけを入れる。**0007 は入れない**。
# 変異 2 は「仮置き → 実本文で段階の表示が変わる」ことを見るので、
# 当初の 12 本は仮置きのまま残す必要がある。一方 0008 を入れないと、
# 段階への割り当て（isoSteps）だけが 28 本を指して食い違いになる。
psql -v ON_ERROR_STOP=1 -q -d "$STEP_DB" -f "$ROOT/db/seeds/0008_policies_extended.sql" >/dev/null
start_app "$PORT_STEP" "postgres:///${STEP_DB}?user=app_ro"
SB="http://127.0.0.1:${PORT_STEP}"

# 変異 1: 附属書 A の形をした統制を 1 件入れる。前後で「そろっていない」が消えること。
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
# 状態そのものが上がること。行を隠すだけの実装では通さない。
case "$(text_of "${SB}/steps/soa")" in
  *"まだ何も無い"*) die "附属書 A を入れても段階の状態が『まだ何も無い』のままです" ;;
  *) : ;;
esac
case "$(text_of "${SB}/catalog")" in
  *"附属書 A はまだ 1 件も入っていない"*)
    die "附属書 A を 1 件入れたのに、カタログがまだ 0 件と言っています" ;;
  *) : ;;
esac

# 変異 2: 規程 1 本を実本文にする。前後で下敷きがそろうこと。
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

# 変異 3: コードの形が違う統制を足すと、附属書 A としては数えられなくなること。
# ここが落ちないなら、件数しか見ていない。
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

# 変異 4: どの段階にも割り当てていない規程を足すと、差集合に出ること。
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

# --- 2d. 台帳の件数が ISMS の枠組みで絞られていること -------------------------
# 段階の画面は ISMS のレンズ（resolveAppMode で /steps は必ず isms モード）。
# 台帳は全枠組みで 1 本なので、**枠組みで絞らないと上場準備だけの資産まで数に混ざる**。
# 絞り込みは catalog.ts の SQL の中にしか無く、単体試験からは触れない。
# ここで実データを使い、**条件を外すと数が変わる**ことを前後に測って確かめる。
PORT_REG=$((PORT + 6))
# テナントは provision_tenant を通さず必要な行だけ直接置く（この検査の関心は
# 台帳の件数の絞り込みだけで、provisioning 経路の事情に左右されたくない）。
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

# ここから先は台帳。**テナント文脈を張ってから入れる**
# （枠組みの整合を見るトリガが app.current_tenant() を要求する）。
# set_tenant_context は SET LOCAL 相当なので、1 トランザクションに閉じる。
psql -q -v ON_ERROR_STOP=1 -v tok="$REG_TOKEN" -d "$STEP_DB" >/dev/null <<'SQL'
BEGIN;
SELECT app.set_tenant_context(:'tok');
-- 資産・リスク・施策のそれぞれに「ISO 対象」と「上場準備だけ」を 1 件ずつ置く。
-- 片方しか置かないと、その台帳の枠組み条件を外しても数が動かない。
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

# 台帳の件数だけを取り出す。**ページ全文で件数の文字列を探さない。**
# 同じ段階の規程の行も「N 件」を出すので、全文一致だと台帳の数が変わっても
# 規程の行に当たって素通りする（実際に素通りした）。
# 道具の説明文（台帳の行にしか無い）を目印にして、その直後の件数を読む。
register_count_of() { # $1=URL $2=説明文の目印
  text_of "$1" | tr '\n' ' ' | grep -o "$2.\{0,60\}" | grep -oE '[0-9]+ 件' | head -1
}

# 3 台帳とも ISO 対象の 1 件だけを数えること。2 件なら絞りが効いていない。
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

# **直すと変わる**ことも見る。片方向だけでは固定文字列と区別できない。
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

# 登録されていれば「そろっていないもの」から消えること。
# 承認や管理責任者の有無を数の条件にしない（2026-09-07 のユーザー判断）。
for step in assets risk-assessment operate; do
  case "$(missing_of "${RB}/steps/${step}")" in
    *"自社の情報資産目録"*|*"自社のリスク台帳"*|*"選んだ統制の実施記録"*)
      die "/steps/${step} は台帳に行があるのに『そろっていない』のままです" ;;
    *) : ;;
  esac
done

grn "[check_web] 2/4d 台帳の件数が ISMS の枠組みで絞られる（外すと数が変わることを両方向で確認）"
kill "$LAST_PID" 2>/dev/null || true

# --- 3. 繋がらない接続先 -------------------------------------------------------
# 届かないポートを指す。稼働中の PostgreSQL は止めない。
start_app "$PORT_DOWN" "postgres://app_ro@127.0.0.1:59999/${DB}"
DOWN="http://127.0.0.1:${PORT_DOWN}"
for p in / /catalog /steps/scope; do
  c=$(code_of "${DOWN}${p}")
  [ "$c" = "500" ] || die "DB へ繋がらないのに ${p} が ${c}（500 のはず。0 件の顔で誤魔化してはいけない）"
done
# 未知の段階キーは、DB が落ちていても 404 のまま。
# キーの検証を DB アクセスより後ろに置くと、ここが 500 になって
# 「そんなページは無い」と「いま読めない」が区別できなくなる。
for bad in /steps/nope /steps/SCOPE /steps/scope2; do
  c=$(code_of "${DOWN}${bad}")
  [ "$c" = "404" ] || die "DB 断でも ${bad} は 404 のはずですが ${c} でした"
done
grn "[check_web] 4/4b DB 断は 500（0 件と区別できる）。未知キーは DB 断でも 404"

grn "[check_web] すべて緑"
