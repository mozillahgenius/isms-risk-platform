import 'server-only';

import { createHash, randomBytes } from 'node:crypto';

export const AGENT_INSTALLER_VERSION = '0.3.0-distribution-1';
export const AGENT_OS_FAMILIES = ['macos', 'windows', 'linux'] as const;
export const AGENT_AUTH_METHODS = ['code', 'gws'] as const;

export type AgentOsFamily = (typeof AGENT_OS_FAMILIES)[number];
export type AgentAuthMethod = (typeof AGENT_AUTH_METHODS)[number];

export function createDeliveryToken(): string {
  return randomBytes(48).toString('base64url');
}

export function hashDeliveryToken(token: string): Buffer {
  return createHash('sha256').update(token, 'utf8').digest();
}

export function agentWebOrigin(env: NodeJS.ProcessEnv = process.env): string | null {
  const raw = env.ISMS_WEB_BASE_URL?.trim();
  if (!raw) return null;
  try {
    const url = new URL(raw);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) return null;
    // Keep the configured path. When the app is served under a basePath (e.g. /risk),
    // returning only the origin would send install links, installer scripts and the
    // agent's server URL to the parent app (404). Callers append '/...' themselves.
    return `${url.origin}${url.pathname.replace(/\/+$/, '')}`;
  } catch {
    return null;
  }
}

export function installUrl(token: string, env: NodeJS.ProcessEnv = process.env): string | null {
  const origin = agentWebOrigin(env);
  return origin ? `${origin}/agent/install/${encodeURIComponent(token)}` : null;
}

export function installerScriptUrl(token: string, platform: 'sh' | 'ps1', env: NodeJS.ProcessEnv = process.env): string | null {
  const origin = agentWebOrigin(env);
  return origin
    ? `${origin}/api/agent/v1/distribution/installer?token=${encodeURIComponent(token)}&platform=${platform}`
    : null;
}

export function agentDistributionMailBody(input: {
  targetName: string;
  installUrl: string;
  osFamily: AgentOsFamily;
  authMethod: AgentAuthMethod;
  expiresAt: string;
  activationUrl?: string;
}): string {
  const authText = input.authMethod === 'gws'
    ? '導入後、対象機器上でGWS/Gmailにログインし、対象機器用の認証リンクでアクティベートします。'
    : '導入後、管理画面で発行された登録コードを対象機器上で使って登録します。';
  const lines = [
    `${input.targetName || 'ご担当者'} 様`,
    '',
    'Example Organization の端末エージェント導入リンクです。',
    '',
    `対象OS: ${input.osFamily}`,
    authText,
    '',
    `対象機器上のブラウザで次のリンクを開いてください。`,
    input.installUrl,
    '',
  ];
  if (input.authMethod === 'gws' && input.activationUrl) {
    lines.push('導入後、同じ機器でGWS/Gmailにログインして次のリンクを開き、アクティベートを押してください。', input.activationUrl, '');
  }
  lines.push(
    `有効期限: ${new Date(input.expiresAt).toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' })}`,
    'このリンクは一回限りです。転送せず、登録する機器自身で開いてください。',
  );
  return lines.join('\n');
}
