#!/usr/bin/env bash
set -euo pipefail

# The agent module requires Go 1.26 or newer.  Keep the bootstrap pinned and
# verify the official archive before it is installed on an RUNTIME host.
GO_VERSION="${GO_VERSION:-1.26.8}"
GO_SHA256="${GO_SHA256:-d0f743b33e8d8945e6b1f432edd15785c70507121d6e2a723b21285eddf8b57b}"
GO_ROOT="${GO_ROOT:-/opt/go/$GO_VERSION}"

die() {
  echo "[go-toolchain] $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: ensure_go_toolchain.sh [--check|--print-path]

--check       verify an existing suitable Go installation; do not install
--print-path  verify or install, then print the selected Go executable path
EOF
  exit 2
}

version_at_least() {
  local current="$1"
  local required_major=1
  local required_minor=26
  local current_major current_minor
  IFS=. read -r current_major current_minor _ <<< "$current"
  [[ "$current_major" =~ ^[0-9]+$ ]] || return 1
  [[ "$current_minor" =~ ^[0-9]+$ ]] || return 1
  (( current_major > required_major )) && return 0
  (( current_major == required_major && current_minor >= required_minor ))
}

go_version() {
  local candidate="$1"
  "$candidate" version 2>/dev/null | awk '{print $3}' | sed 's/^go//'
}

valid_go() {
  local candidate="$1"
  [ -x "$candidate" ] || return 1
  version_at_least "$(go_version "$candidate")"
}

find_go() {
  local candidate
  if [ -n "${GO_BIN:-}" ] && valid_go "$GO_BIN"; then
    printf '%s\n' "$GO_BIN"
    return 0
  fi
  candidate="$GO_ROOT/bin/go"
  if valid_go "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$(command -v go 2>/dev/null || true)"
  if [ -n "$candidate" ] && valid_go "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

install_go() {
  [ "$(uname -s)" = "Linux" ] || die "Go $GO_VERSION が必要です。Linux以外ではGoを手動で導入してください"
  [ "$(uname -m)" = "x86_64" ] || die "Go bootstrapはlinux/amd64だけを対象にしています"
  command -v curl >/dev/null 2>&1 || die "curl がありません"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum がありません"
  sudo -n true 2>/dev/null || die "Goの導入にはパスワードなしsudoが必要です"

  local archive_dir archive url backup
  archive_dir="$(mktemp -d)"
  trap 'rm -rf "$archive_dir"' RETURN
  archive="$archive_dir/go${GO_VERSION}.linux-amd64.tar.gz"
  url="https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  echo "[go-toolchain] downloading Go $GO_VERSION" >&2
  curl --fail --location --silent --show-error "$url" -o "$archive"
  printf '%s  %s\n' "$GO_SHA256" "$archive" | sha256sum -c -

  if [ -e "$GO_ROOT" ]; then
    backup="${GO_ROOT}.invalid-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "[go-toolchain] preserving invalid installation at $backup" >&2
    sudo mv "$GO_ROOT" "$backup"
  fi
  sudo install -d -m 755 "$GO_ROOT"
  sudo tar -xzf "$archive" -C "$GO_ROOT" --strip-components=1
  trap - RETURN
}

MODE="${1:---print-path}"
case "$MODE" in
  --check|--print-path) ;;
  *) usage ;;
esac

GO_SELECTED="$(find_go || true)"
if [ -z "$GO_SELECTED" ] && [ "$MODE" = "--check" ]; then
  die "Go 1.26以上が見つかりません"
fi
if [ -z "$GO_SELECTED" ]; then
  install_go
  GO_SELECTED="$(find_go || true)"
fi
[ -n "$GO_SELECTED" ] || die "Go $GO_VERSION の導入後も実行ファイルを確認できません"

if [ "$MODE" = "--check" ]; then
  echo "[go-toolchain] $("$GO_SELECTED" version)" >&2
else
  printf '%s\n' "$GO_SELECTED"
fi
