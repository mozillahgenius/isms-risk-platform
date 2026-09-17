'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';

const text = (form: FormData, key: string, max = 1000): string => {
  const value = String(form.get(key) ?? '').trim();
  if (!value || value.length > max) throw new Error(`${key} is required`);
  return value;
};

const optionalText = (form: FormData, key: string, max = 1000): string | null => {
  const value = String(form.get(key) ?? '').trim();
  return value ? value.slice(0, max) : null;
};

const route = (form: FormData, value: string): string => {
  const mode = form.get('mode');
  return mode === 'isms' || mode === 'risk'
    ? `${value}${value.includes('?') ? '&' : '?'}mode=${mode}`
    : value;
};

async function finish(
  result: Awaited<ReturnType<typeof withTenantWrite<unknown>>>,
  policyId: string,
  form: FormData,
) {
  if (!result.ok) redirect(route(form, `/policies/${policyId}?error=${result.reason}`));
  revalidatePath('/policies');
  revalidatePath(`/policies/${policyId}`);
  revalidatePath('/operations');
  redirect(route(form, `/policies/${policyId}?saved=1`));
}

/** 新しい下書き版を追加する。version 番号は既存の最大値+1（DB の一意制約が重複を弾く）。 */
export async function createPolicyDraft(form: FormData) {
  const policyId = text(form, 'policy_id', 80);
  const bodyMd = text(form, 'body_md', 200000);
  const result = await withTenantWrite(async (sql) => {
    await sql`
      INSERT INTO app.policy_versions (tenant_id, policy_id, version, body_md, diff_clause_count)
      SELECT app.current_tenant(), ${policyId}::uuid, coalesce(max(version), 0) + 1, ${bodyMd}, 0
        FROM app.policy_versions
       WHERE tenant_id = app.current_tenant() AND policy_id = ${policyId}::uuid`;
    return policyId;
  });
  await finish(result, policyId, form);
}

/** 下書き版を承認する。app.approve_policy_version が承認情報と app.approvals への記録をまとめて行う。 */
export async function approvePolicyVersion(form: FormData) {
  const policyId = text(form, 'policy_id', 80);
  const versionId = text(form, 'version_id', 80);
  const comment = optionalText(form, 'comment', 4000);
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.approve_policy_version(${versionId}::uuid, ${comment})`;
    return policyId;
  });
  await finish(result, policyId, form);
}

/**
 * 承認済みの版を有効化する。app.activate_policy_version が
 * 「対象の effective_from をセット」「同一規程の旧現行版へ superseded_at をセット」を
 * 同一トランザクションで行う（部分ユニークインデックス policy_versions_current が
 * 二重有効化そのものを弾く最後の砦）。
 */
export async function activatePolicyVersion(form: FormData) {
  const policyId = text(form, 'policy_id', 80);
  const versionId = text(form, 'version_id', 80);
  const effectiveFrom = optionalText(form, 'effective_from', 20);
  const result = await withTenantWrite(async (sql) => {
    if (effectiveFrom) {
      await sql`SELECT app.activate_policy_version(${versionId}::uuid, ${effectiveFrom}::date)`;
    } else {
      await sql`SELECT app.activate_policy_version(${versionId}::uuid)`;
    }
    return policyId;
  });
  await finish(result, policyId, form);
}
