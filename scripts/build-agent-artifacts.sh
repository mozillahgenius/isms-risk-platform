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
  if [ "$goos" = darwin ]; then
    # macOS の収集（プロセスの実行ファイルのパス）は cgo が要る（collector/procpath_darwin.go）。
    # CGO_ENABLED=0 で作ると `kernel process path lookup is unsupported ... rebuild with cgo enabled` で
    # 収集が毎回失敗し、状態の報告が一度も届かない（2026-09-25 に実機で発生）。macOS の上でだけ作る。
    if [ "$(uname -s)" != Darwin ]; then
      echo "[agent-artifact] macOS 用は cgo が要るため macOS の上で作ってください（$name）" >&2
      exit 1
    fi
    local clang_arch="$goarch"
    [ "$goarch" = amd64 ] && clang_arch=x86_64
    GOOS=darwin GOARCH="$goarch" CGO_ENABLED=1 CC="clang -arch $clang_arch" \
      "$GO_BIN" -C "$ROOT/agent" build -trimpath -ldflags='-s -w' -o "$target" ./cmd/isms-agent
  else
    GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 \
      "$GO_BIN" -C "$ROOT/agent" build -trimpath -ldflags='-s -w' -o "$target" ./cmd/isms-agent
  fi
  chmod 700 "$target"
}

build_one darwin arm64 "${ARTIFACT_NAMES[0]}"
build_one darwin amd64 "${ARTIFACT_NAMES[1]}"
build_one linux amd64 "${ARTIFACT_NAMES[2]}"
build_one windows amd64 "${ARTIFACT_NAMES[3]}"

printf '[agent-artifact] built %s\n' "$(find "$OUT" -maxdepth 1 -type f | wc -l | tr -d ' ')"
