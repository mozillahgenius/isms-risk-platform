#!/usr/bin/env bash
# 配備の関門(scripts/deploy_runtime.sh の DOWN_GUARD_MESSAGES)が、db/migrations/*.down.sql にある
# データ保護の拒否文(`NNNN rollback refused|blocked ...`)をすべて知っていることを確かめる。DB は使わない。
#
# 関門は本番の複製で down を流し、既知の保護の文言で拒否されたときだけ合格にする。一覧から漏れた拒否文が
# 先に効くと「予期しない理由」と判定して配備が止まる(2026-09-13 に 14 本の漏れが見つかった)。
# 番号を付け直したときや、保護付きの down を新しく足したときも、ここで漏れが分かる。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/scripts/deploy_runtime.sh"

LIST="$(sed -n '/^DOWN_GUARD_MESSAGES=(/,/^)/p' "$DEPLOY")"
[ -n "$LIST" ] || { echo "down_guard_messages: DOWN_GUARD_MESSAGES を読めない" >&2; exit 1; }

# down.sql の拒否文を、書式の引数(% など)より前の固定部分だけ取り出す。
MESSAGES="$(grep -ohE "RAISE EXCEPTION '[0-9]{4} rollback (refused|blocked)[^'%]*" "$ROOT"/db/migrations/*.down.sql \
  | sed -E "s/^RAISE EXCEPTION '//; s/[[:space:]]*\($//; s/[[:space:]]+$//" | sort -u)"
[ -n "$MESSAGES" ] || { echo "down_guard_messages: down.sql から拒否文を1つも読めない" >&2; exit 1; }

rc=0
count=0
while IFS= read -r msg; do
  count=$((count + 1))
  if ! printf '%s\n' "$LIST" | grep -Fq "'$msg'"; then
    echo "down_guard_messages: MISSING $msg" >&2
    rc=1
  fi
done <<< "$MESSAGES"

# 拒否文の番号は、その down.sql のファイル名の番号と一致すること。番号を付け直すときに文言だけ古い番号の
# まま残ると、配備の記録に誤った番号の拒否が出て、どの移行が止めたのか分からなくなる(Codex 2026-09-13)。
for f in "$ROOT"/db/migrations/*.down.sql; do
  file_no="$(basename "$f" | cut -d_ -f1)"
  while IFS= read -r msg_no; do
    [ -z "$msg_no" ] && continue
    if [ "$msg_no" != "$file_no" ]; then
      echo "down_guard_messages: NUMBER MISMATCH $(basename "$f") has a '$msg_no rollback' message" >&2
      rc=1
    fi
  done <<< "$(grep -ohE "RAISE EXCEPTION '[0-9]{4} rollback (refused|blocked)" "$f" | grep -oE "[0-9]{4}" || true)"
done

# 逆向き: 一覧にあるのに、どの down.sql にも無い文言(古い番号のまま残ったもの)も落とす。
while IFS= read -r entry; do
  if ! printf '%s\n' "$MESSAGES" | grep -Fxq "$entry"; then
    echo "down_guard_messages: STALE $entry" >&2
    rc=1
  fi
done <<< "$(printf '%s\n' "$LIST" | grep -oE "^[[:space:]]*'[0-9]{4} rollback [^']+'" | sed -E "s/^[[:space:]]*'//; s/'$//")"

[ "$rc" -eq 0 ] && echo "down_guard_messages: OK ($count messages known to the deploy gate)"
exit "$rc"
