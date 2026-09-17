#!/usr/bin/env bash
# 既存資産（設計書 Part XIII）を「無改変で流用」していることを機械で担保する。
#
# ハッシュ突合が証明するのは「ファイルが同一であること」だけで、
# DB への意味変換が正しいことは別（それは phase0/run_acceptance.sh の
# 写像テストと差分 0 件が見る）。ここは上流が黙って変わったことに気づくための番人。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIST="$ROOT/scripts/ci/reused_assets.sha256"
DIR="${RISK_MAP_SCRIPTS_DIR:-}"
CDIR="${CONTROL_SCRIPTS_DIR:-}"

if [ -z "$DIR" ] && [ -z "$CDIR" ]; then
  printf '  \033[33mSKIP\033[0m 外部の再利用資産が未設定（RISK_MAP_SCRIPTS_DIR / CONTROL_SCRIPTS_DIR）\n'
  exit 0
fi

if [ -z "$DIR" ] || [ -z "$CDIR" ]; then
  printf '  \033[31mFAIL\033[0m RISK_MAP_SCRIPTS_DIR と CONTROL_SCRIPTS_DIR は両方指定してください\n'
  exit 1
fi

files=(
  "$DIR/build_risk_map.py"
  "$DIR/risk_map_master.csv"
  "$CDIR/build_control_karte.py"
  "$CDIR/control_requirements_master.csv"
)

for f in "${files[@]}"; do
  [ -f "$f" ] || { printf '  \033[31mFAIL\033[0m 既存資産が見つからない: %s\n' "$f"; exit 1; }
done

if [ ! -f "$LIST" ]; then
  : > "$LIST"
  for f in "${files[@]}"; do
    printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$(basename "$f")" >> "$LIST"
  done
  printf '  \033[33mNEW\033[0m 基準ハッシュを作成した: %s\n' "$LIST"
  cat "$LIST" | sed 's/^/        /'
  exit 0
fi

fail=0
while read -r want name; do
  [ -z "${want:-}" ] && continue
  path=""
  for f in "${files[@]}"; do
    [ "$(basename "$f")" = "$name" ] && path="$f"
  done
  [ -n "$path" ] || { printf '  \033[31mFAIL\033[0m 基準に無いファイル名: %s\n' "$name"; fail=1; continue; }
  got=$(shasum -a 256 "$path" | awk '{print $1}')
  if [ "$got" != "$want" ]; then
    printf '  \033[31mFAIL\033[0m 上流が変わった: %s\n        期待 %s\n        実測 %s\n' "$name" "$want" "$got"
    printf '        中身を確認し、意図した変更なら %s を更新すること。\n' "$LIST"
    fail=1
  fi
done < "$LIST"

[ "$fail" -eq 0 ] || exit 1
printf '  \033[32mPASS\033[0m 再利用資産 %d 件が基準どおり（無改変）\n' "${#files[@]}"
