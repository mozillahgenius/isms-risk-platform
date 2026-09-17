export type ManifestResource = {
  name: string;
  mapTo: string | null;
};

export type ManifestSummary = {
  authType: string | null;
  scopes: number;
  resources: ManifestResource[];
  fullSchedule: string | null;
  incrementalSchedule: string | null;
};

function objectValue(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function stringValue(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value : null;
}

/** UI向けにマニフェストの構造だけを取り出す。生のJSONは画面へ出さない。 */
export function summarizeManifest(manifest: unknown): ManifestSummary {
  const root = objectValue(manifest);
  const auth = objectValue(root.auth);
  const sync = objectValue(root.sync);
  const resources = Array.isArray(root.resources)
    ? root.resources.flatMap((resource): ManifestResource[] => {
        const item = objectValue(resource);
        const name = stringValue(item.name);
        if (!name) return [];
        return [{ name, mapTo: stringValue(item.map_to) }];
      })
    : [];

  const scopes = Array.isArray(auth.scopes) ? auth.scopes.filter((scope) => typeof scope === 'string').length : 0;
  return {
    authType: stringValue(auth.type),
    scopes,
    resources,
    fullSchedule: stringValue(sync.full),
    incrementalSchedule: stringValue(sync.incremental),
  };
}

/** 外部応答の生文を出さず、運用上必要な失敗分類だけを表示する。 */
export function summarizeRunError(detail: string | null): string | null {
  if (!detail) return null;
  const value = detail.toLowerCase();
  if (value.includes('403') || value.includes('permission') || value.includes('forbidden') || value.includes('scope')) {
    return '権限不足またはスコープ不足';
  }
  if (value.includes('429') || value.includes('rate')) return 'レート制限';
  if (value.includes('404') || value.includes('not found')) return '対象が見つからない';
  if (value.includes('timeout') || value.includes('network')) return '通信またはタイムアウト';
  return '外部サービス側のエラー（詳細はサーバログ）';
}
