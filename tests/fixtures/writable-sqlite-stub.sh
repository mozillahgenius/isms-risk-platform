#!/usr/bin/env bash
set -euo pipefail

args=()
for arg in "$@"; do
  [ "$arg" = "-readonly" ] || args+=("$arg")
done
exec sqlite3 "${args[@]}"
