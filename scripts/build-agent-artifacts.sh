#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/agent-artifacts}"
mkdir -p "$OUT"
chmod 700 "$OUT"

ARTIFACT_NAMES=(
  isms-agent-darwin-arm64
  isms-agent-darwin-amd64
  isms-agent-linux-amd64
  isms-agent-windows-amd64.exe
)

if [ -n "${AGENT_ARTIFACT_SOURCE:-}" ]; then
  if [ ! -d "$AGENT_ARTIFACT_SOURCE" ]; then
    echo "[agent-artifact] prebuilt source directory is missing: $AGENT_ARTIFACT_SOURCE" >&2
    exit 1
  fi
  if [ -f "$AGENT_ARTIFACT_SOURCE/SHA256SUMS" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      (cd "$AGENT_ARTIFACT_SOURCE" && sha256sum -c SHA256SUMS)
    else
      (cd "$AGENT_ARTIFACT_SOURCE" && shasum -a 256 -c SHA256SUMS)
    fi
  fi
  for name in "${ARTIFACT_NAMES[@]}"; do
    source_file="$AGENT_ARTIFACT_SOURCE/$name"
    if [ ! -f "$source_file" ]; then
      echo "[agent-artifact] prebuilt artifact is missing: $source_file" >&2
      exit 1
    fi
    install -m 700 "$source_file" "$OUT/$name"
  done
  printf '[agent-artifact] copied %s prebuilt artifacts\n' "${#ARTIFACT_NAMES[@]}"
  exit 0
fi

GO_BIN="${GO_BIN:-}"
if [ -z "$GO_BIN" ]; then
  GO_BIN="$("$ROOT/scripts/ensure_go_toolchain.sh" --print-path)"
fi
if [ ! -x "$GO_BIN" ]; then
  echo "[agent-artifact] Go 1.26以上の実行ファイルが見つかりません: $GO_BIN" >&2
  exit 1
fi
echo "[agent-artifact] using $($GO_BIN version)" >&2

build_one() {
  local goos="$1"
  local goarch="$2"
  local name="$3"
  local target="$OUT/$name"
  echo "[agent-artifact] building $name"
  GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 \
    "$GO_BIN" -C "$ROOT/agent" build -trimpath -ldflags='-s -w' -o "$target" ./cmd/isms-agent
  chmod 700 "$target"
}

build_one darwin arm64 "${ARTIFACT_NAMES[0]}"
build_one darwin amd64 "${ARTIFACT_NAMES[1]}"
build_one linux amd64 "${ARTIFACT_NAMES[2]}"
build_one windows amd64 "${ARTIFACT_NAMES[3]}"

printf '[agent-artifact] built %s\n' "$(find "$OUT" -maxdepth 1 -type f | wc -l | tr -d ' ')"
