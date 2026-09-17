import { agentWebOrigin } from '@/lib/agentDistribution';
import { lookupAgentInstallation } from '@/lib/agentDistributionServer';

export const dynamic = 'force-dynamic';

function sh(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function ps(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

export async function GET(request: Request) {
  const params = new URL(request.url).searchParams;
  const token = params.get('token')?.trim() ?? '';
  const platform = params.get('platform')?.trim() ?? '';
  const manifest = token ? await lookupAgentInstallation(token) : null;
  if (!manifest || (platform !== 'sh' && platform !== 'ps1')) {
    return new Response('invalid_or_expired\n', { status: 404, headers: { 'Cache-Control': 'no-store' } });
  }
  const base = agentWebOrigin();
  if (!base) {
    return new Response('agent_distribution_origin_not_configured\n', {
      status: 503,
      headers: { 'Cache-Control': 'no-store' },
    });
  }
  const auth = manifest.auth_method;
  const script = platform === 'sh'
    ? `#!/bin/sh
set -eu
BASE=${sh(base)}
TOKEN=${sh(token)}
AUTH=${sh(auth)}
ARCH="$(uname -m)"
OS="$(uname -s)"
case "$OS:$ARCH" in Darwin:arm64|Darwin:aarch64) TARGET=macos-arm64 ;; Darwin:x86_64|Darwin:amd64) TARGET=macos-amd64 ;; Linux:x86_64|Linux:amd64) TARGET=linux-amd64 ;; *) echo "対応していないOS/アーキテクチャです: $OS/$ARCH" >&2; exit 1 ;; esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/isms-agent"
curl --fail --silent --show-error --proto '=https' --tlsv1.2 "$BASE/api/agent/v1/distribution/binary?token=$TOKEN&platform=$TARGET" -o "$BIN"
chmod 700 "$BIN"
INSTALL_DIR="$HOME/.local/libexec/example-org"
mkdir -p "$INSTALL_DIR"
install -m 700 "$BIN" "$INSTALL_DIR/isms-agent"
BIN="$INSTALL_DIR/isms-agent"
HOST="$(hostname)"
MODEL="$(sysctl -n hw.model 2>/dev/null || uname -m)"
HARDWARE="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4; exit}')"
[ -n "$HARDWARE" ] || HARDWARE="$HOST-$(uname -m)"
curl --fail --silent --show-error -X POST "$BASE/api/agent/v1/distribution/stage" -H 'content-type: application/json' --data "{\\"token\\":\\"$TOKEN\\",\\"stage\\":\\"installed\\",\\"hardware_id\\":\\"$HARDWARE\\"}" >/dev/null
if [ "$AUTH" = code ]; then
  "$BIN" enroll --url "$BASE" --enrollment-token "$TOKEN" --external-id "$HARDWARE" --hostname "$HOST" --model "$MODEL" --os-family "$( [ "$OS" = Darwin ] && echo macos || echo linux )"
else
  "$BIN" enroll --url "$BASE" --external-id "$HARDWARE" --hostname "$HOST" --model "$MODEL" --os-family "$( [ "$OS" = Darwin ] && echo macos || echo linux )" --delivery-token "$TOKEN"
fi
if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$HOME/Library/LaunchAgents/rocks.example-org.isms-agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>rocks.example-org.isms-agent</string><key>ProgramArguments</key><array><string>$BIN</string><string>run</string></array><key>StartInterval</key><integer>900</integer><key>RunAtLoad</key><true/></dict></plist>
PLIST
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/rocks.example-org.isms-agent.plist" 2>/dev/null || launchctl kickstart -k "gui/$(id -u)/rocks.example-org.isms-agent" 2>/dev/null || true
else
  (crontab -l 2>/dev/null; echo "*/15 * * * * $BIN run >/dev/null 2>&1") | sort -u | crontab -
fi
echo 'エージェントの導入と登録が完了しました。'
`
    : `#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$Base = ${ps(base)}
$Token = ${ps(token)}
$Auth = ${ps(auth)}
$Target = 'windows-amd64'
$Tmp = Join-Path $env:TEMP ('isms-agent-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
try {
  $Bin = Join-Path $Tmp 'isms-agent.exe'
  Invoke-WebRequest -UseBasicParsing -Uri "$Base/api/agent/v1/distribution/binary?token=$Token&platform=$Target" -OutFile $Bin
  $cs = Get-CimInstance Win32_ComputerSystemProduct
  $hardware = if ($cs.UUID) { [string]$cs.UUID } else { [string]$env:COMPUTERNAME }
  $model = if ($cs.Name) { [string]$cs.Name } else { 'Windows device' }
  $args = @('enroll','--url',$Base,'--external-id',$hardware,'--hostname',$env:COMPUTERNAME,'--model',$model,'--os-family','windows')
  if ($Auth -eq 'code') { $args += @('--enrollment-token',$Token) } else { $args += @('--delivery-token',$Token) }
  & $Bin @args
  if ($LASTEXITCODE -ne 0) { throw "isms-agent enroll failed: $LASTEXITCODE" }
  $InstallDir = Join-Path $env:ProgramData 'Example Organization'
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $InstalledBin = Join-Path $InstallDir 'isms-agent.exe'
  Copy-Item -LiteralPath $Bin -Destination $InstalledBin -Force
  $payload = @{ token=$Token; stage='installed'; hardware_id=$hardware } | ConvertTo-Json -Compress
  Invoke-RestMethod -Method Post -Uri "$Base/api/agent/v1/distribution/stage" -ContentType 'application/json' -Body $payload | Out-Null
  $TaskAction = New-ScheduledTaskAction -Execute $InstalledBin -Argument 'run'
  $TaskTrigger = New-ScheduledTaskTrigger -AtStartup
  Register-ScheduledTask -TaskName 'Example Organization Agent' -Action $TaskAction -Trigger $TaskTrigger -Force | Out-Null
  Write-Output 'エージェントの導入と登録が完了しました。'
} finally { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
`;
  return new Response(script, {
    headers: {
      'Content-Type': platform === 'sh' ? 'text/x-sh; charset=utf-8' : 'text/plain; charset=utf-8',
      'Content-Disposition': `attachment; filename="isms-agent-install.${platform}"`,
      'Cache-Control': 'no-store',
    },
  });
}
