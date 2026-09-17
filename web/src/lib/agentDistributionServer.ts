import 'server-only';

import { createHash } from 'node:crypto';
import { getAgentDb } from './agent-db';

export type AgentInstallationManifest = {
  id: string;
  os_family: 'macos' | 'windows' | 'linux';
  auth_method: 'code' | 'gws';
  expires_at: string;
  installer_version: string;
  status: string;
};

export function hashDeliveryToken(token: string): Buffer {
  return createHash('sha256').update(token, 'utf8').digest();
}

export async function lookupAgentInstallation(token: string): Promise<AgentInstallationManifest | null> {
  const db = getAgentDb();
  const rows = await db<{ result: AgentInstallationManifest & { ok?: boolean } }[]>`
    SELECT app.lookup_agent_installation(${hashDeliveryToken(token)}) AS result
  `;
  const result = rows[0]?.result;
  if (!result || result.ok !== true) return null;
  return result;
}

export async function markAgentInstallation(
  token: string,
  stage: string,
  hardwareId?: string,
  deviceId?: string,
  failureCode?: string,
): Promise<Record<string, unknown>> {
  const db = getAgentDb();
  const rows = await db<{ result: Record<string, unknown> }[]>`
    SELECT app.mark_agent_installation(
      ${hashDeliveryToken(token)}, ${stage}, ${hardwareId ?? null},
      ${deviceId ?? null}::uuid, ${failureCode ?? null}
    ) AS result
  `;
  return rows[0]?.result ?? { ok: false, reason: 'unavailable' };
}

export function binaryArtifactPath(platform: string): string | null {
  const names: Record<string, string> = {
    'macos-arm64': 'isms-agent-darwin-arm64',
    'macos-amd64': 'isms-agent-darwin-amd64',
    'windows-amd64': 'isms-agent-windows-amd64.exe',
    'linux-amd64': 'isms-agent-linux-amd64',
  };
  return names[platform] ?? null;
}

export function artifactDirectory(): string {
  return process.env.ISMS_AGENT_ARTIFACT_DIR?.trim() || `${process.cwd()}/agent-artifacts`;
}
