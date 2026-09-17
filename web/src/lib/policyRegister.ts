import 'server-only';

import { withTenant, type TenantReadResult } from './tenant';
import { isPlaceholderBody } from './policyBody';

export type PolicySummary = {
  id: string;
  catalog_key: string | null;
  title: string;
  current_version: number | null;
  current_version_id: string | null;
  current_approved_at: string | Date | null;
  // date型。::textで明示的に文字列化する(下のSELECT参照)。Date化すると
  // 実行環境のtimezoneでtoLocaleDateString()等の表示日がずれうる
  // (Codexレビュー2026-09-02、画面⑤コスト機能のレビューで同種の問題を指摘)。
  current_effective_from: string | null;
  current_is_placeholder: boolean;
  draft_count: number;
  version_count: number;
};

export type PolicyVersionRow = {
  id: string;
  version: number;
  body_md: string;
  diff_clause_count: number;
  approved_by: string | null;
  approved_at: string | Date | null;
  effective_from: string | null;
  superseded_at: string | Date | null;
  created_at: string | Date;
  is_current: boolean;
  is_placeholder: boolean;
};

export type PolicyDetail = {
  policy: { id: string; catalog_key: string | null; title: string };
  versions: PolicyVersionRow[];
  catalogBody: string | null;
};

export async function listPolicies(): Promise<TenantReadResult<PolicySummary[]>> {
  return withTenant(async (sql) => {
    const rows = await sql<
      {
        id: string;
        catalog_key: string | null;
        title: string;
        current_version: number | null;
        current_version_id: string | null;
        current_approved_at: string | Date | null;
        current_effective_from: string | null;
        current_body_md: string | null;
        draft_count: number;
        version_count: number;
      }[]
    >`
      SELECT p.id, p.catalog_key, p.title,
             cur.version AS current_version, cur.id AS current_version_id,
             cur.approved_at AS current_approved_at, cur.effective_from::text AS current_effective_from,
             cur.body_md AS current_body_md,
             (SELECT count(*)::int FROM app.policy_versions v
               WHERE v.tenant_id = p.tenant_id AND v.policy_id = p.id AND v.approved_at IS NULL) AS draft_count,
             (SELECT count(*)::int FROM app.policy_versions v
               WHERE v.tenant_id = p.tenant_id AND v.policy_id = p.id) AS version_count
        FROM app.policies p
        LEFT JOIN app.policy_versions cur
          ON cur.tenant_id = p.tenant_id AND cur.policy_id = p.id
         AND cur.approved_at IS NOT NULL
         AND cur.effective_from<=(now() AT TIME ZONE 'Asia/Tokyo')::date
         AND (cur.superseded_at IS NULL OR cur.superseded_at>now())
       ORDER BY p.title`;
    return rows.map((row) => ({
      id: row.id,
      catalog_key: row.catalog_key,
      title: row.title,
      current_version: row.current_version,
      current_version_id: row.current_version_id,
      current_approved_at: row.current_approved_at,
      current_effective_from: row.current_effective_from,
      current_is_placeholder: isPlaceholderBody(row.current_body_md ?? ''),
      draft_count: row.draft_count,
      version_count: row.version_count,
    }));
  });
}

export async function getPolicyDetail(id: string): Promise<TenantReadResult<PolicyDetail>> {
  return withTenant(async (sql) => {
    const policies = await sql<{ id: string; catalog_key: string | null; title: string }[]>`
      SELECT id, catalog_key, title FROM app.policies
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid`;
    const policy = policies[0];
    if (!policy) throw new Error('policy not found');

    const versions = await sql<
      {
        id: string;
        version: number;
        body_md: string;
        diff_clause_count: number;
        approved_by: string | null;
        approved_at: string | Date | null;
        effective_from: string | null;
        superseded_at: string | Date | null;
        created_at: string | Date;
        is_current: boolean;
      }[]
    >`
      SELECT id, version, body_md, diff_clause_count, approved_by, approved_at,
             effective_from::text, superseded_at, created_at,
             approved_at IS NOT NULL
               AND effective_from<=(now() AT TIME ZONE 'Asia/Tokyo')::date
               AND (superseded_at IS NULL OR superseded_at>now()) AS is_current
        FROM app.policy_versions
       WHERE tenant_id = app.current_tenant() AND policy_id = ${id}::uuid
       ORDER BY version DESC`;

    let catalogBody: string | null = null;
    if (policy.catalog_key) {
      const catalogRows = await sql<{ body_md: string }[]>`
        SELECT body_md FROM catalog.policies_default WHERE key = ${policy.catalog_key}`;
      catalogBody = catalogRows[0]?.body_md ?? null;
    }

    return {
      policy,
      versions: versions.map((v) => ({
        ...v,
        is_current: v.is_current,
        is_placeholder: isPlaceholderBody(v.body_md),
      })),
      catalogBody,
    };
  });
}
