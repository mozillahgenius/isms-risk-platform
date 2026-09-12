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

/** Adds a new draft version. The version number is the current max + 1 (the DB unique constraint rejects duplicates). */
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

/** Approves a draft version. app.approve_policy_version sets the approval info and records it in app.approvals together. */
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
 * Activates an approved version. app.activate_policy_version performs
 * "set effective_from on the target" and "set superseded_at on the previous current version of the same policy"
 * in the same transaction (the partial unique index policy_versions_current is
 * the last line of defense that rejects double activation itself).
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
