'use server';

import { createHash } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import type { TransactionSql } from 'postgres';
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

// Blank is treated as "unset" and becomes NULL. If tampered FormData sends an invalid string,
// the ::uuid cast causes a DB error, so the format is rejected here (added in 0061).
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const optionalUuid = (form: FormData, key: string): string | null => {
  const value = String(form.get(key) ?? '').trim();
  if (!value) return null;
  if (!UUID_RE.test(value)) throw new Error(`${key} の形式が不正です`);
  return value;
};

// Blank is treated as an explicit clear (NULL). Values exceeding the DB numeric(p,s) precision,
// negative numbers, and non-numeric values are rejected clearly here instead of being left to DB CHECK/precision errors
// (added 2026-09-02; Codex review finding: fixing an insufficient input parser).
const optionalDecimal = (form: FormData, key: string, pattern: RegExp, label: string): number | null => {
  const raw = String(form.get(key) ?? '').trim();
  if (!raw) return null;
  if (!pattern.test(raw)) throw new Error(`${label} は0以上の数値で、桁数の上限内で入力してください`);
  return Number(raw);
};

const keys = (form: FormData): string[] =>
  [...new Set(form.getAll('framework_keys').map(String).map((value) => value.trim()).filter(Boolean))];

const requiredManagementKeys = (value: string[]): string[] =>
  [...new Set(['RISK-MANAGEMENT', ...value])];

const id = (form: FormData): string => text(form, 'id', 80);

const appMode = (form: FormData): 'isms' | 'risk' | undefined => {
  const mode = String(form.get('mode') ?? '');
  return mode === 'isms' || mode === 'risk' ? mode : undefined;
};

const jstTimestamp = (value: string): string => {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(value)) throw new Error('invalid datetime');
  return `${value.length === 16 ? `${value}:00` : value}+09:00`;
};

/** Prefer a client-generated intent ID; deterministic fallback preserves retries from legacy forms. */
const managementIntent = (form: FormData, action: string, input: Record<string, string>): { operationId: string; requestHash: string } => {
  const requestHash = createHash('sha256').update(JSON.stringify({ action, ...input })).digest('hex');
  const supplied = optionalText(form, 'operation_id', 64);
  if (supplied && !/^[a-f0-9]{12,64}$/.test(supplied)) throw new Error('invalid operation_id');
  return { operationId: supplied ?? requestHash, requestHash };
};

const managementEntityPath = (form: FormData): string => {
  const entityType = optionalText(form, 'entity_type', 30);
  const entityId = optionalText(form, 'entity_id', 80);
  if (!entityId) return '/risk-management';
  if (entityType === 'asset') return `/risk-management/assets?id=${encodeURIComponent(entityId)}`;
  if (entityType === 'measure') return `/risk-management/measures?id=${encodeURIComponent(entityId)}`;
  return `/risk-management/risks/${entityId}`;
};

async function tagAsset(sql: TransactionSql, assetId: string, frameworkKeys: string[]) {
  await sql`SELECT app.set_management_frameworks_for_work('asset',${assetId}::uuid,${frameworkKeys}::text[])`;
}

async function tagMeasure(sql: TransactionSql, measureId: string, frameworkKeys: string[]) {
  await sql`SELECT app.set_management_frameworks_for_work('measure',${measureId}::uuid,${frameworkKeys}::text[])`;
}

async function finish(
  result: Awaited<ReturnType<typeof withTenantWrite<unknown>>>,
  path = '/risk-management',
  mode?: 'isms' | 'risk',
) {
  const query = new URLSearchParams(mode ? { mode } : undefined);
  const separator = path.includes('?') ? '&' : '?';
  if (!result.ok) {
    query.set('error', result.reason);
    redirect(`${path}${separator}${query.toString()}`);
  }
  revalidatePath('/risk-management');
  revalidatePath('/iso27001');
  revalidatePath('/risk-management/assets');
  revalidatePath('/risk-management/measures');
  revalidatePath('/risk-management/risks');
  query.set('saved', '1');
  redirect(`${path}${separator}${query.toString()}`);
}

export async function saveAsset(form: FormData) {
  const assetKey = text(form, 'asset_key', 80);
  const name = text(form, 'name', 200);
  const assetType = text(form, 'asset_type', 80);
  const description = optionalText(form, 'description', 4000) ?? '';
  const classification = text(form, 'classification', 80);
  const sourceNote = optionalText(form, 'source_note', 4000) ?? '';
  // Owning department and location (0061). The owner_department_id column has existed since 0027
  // but was not used by the UI. Location has two parts: a system (FK), and
  // free text for locations a system can't represent (paper, storage, devices).
  const ownerDepartmentId = optionalUuid(form, 'owner_department_id');
  const locationSystemId = optionalUuid(form, 'location_system_id');
  const locationNote = optionalText(form, 'location_note', 500) ?? '';
  const frameworkKeys = requiredManagementKeys(keys(form));
  const assetId = optionalText(form, 'id', 80);
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_work_permission('asset', ${assetId ? assetId : null}::uuid, ${assetId ? 'write' : 'create'})`;
    const rows = assetId
      ? await sql<{ id: string }[]>`
          UPDATE app.assets
             SET asset_key = ${assetKey}, name = ${name}, asset_type = ${assetType},
                 description = ${description}, classification = ${classification},
                 source_note = ${sourceNote},
                 owner_department_id = ${ownerDepartmentId}::uuid,
                 location_system_id = ${locationSystemId}::uuid,
                 location_note = ${locationNote}, updated_at = now()
           WHERE tenant_id = app.current_tenant() AND id = ${assetId}::uuid
           RETURNING id`
      : await sql<{ id: string }[]>`
          INSERT INTO app.assets
            (tenant_id, asset_key, name, asset_type, description, classification, source_note,
             owner_department_id, location_system_id, location_note)
          VALUES
            (app.current_tenant(), ${assetKey}, ${name}, ${assetType}, ${description}, ${classification}, ${sourceNote},
             ${ownerDepartmentId}::uuid, ${locationSystemId}::uuid, ${locationNote})
          ON CONFLICT (tenant_id, asset_key) DO UPDATE
            SET name = EXCLUDED.name, asset_type = EXCLUDED.asset_type,
                description = EXCLUDED.description, classification = EXCLUDED.classification,
                source_note = EXCLUDED.source_note,
                owner_department_id = EXCLUDED.owner_department_id,
                location_system_id = EXCLUDED.location_system_id,
                location_note = EXCLUDED.location_note,
                status = 'active', updated_at = now()
          RETURNING id`;
    const asset = rows[0];
    if (!asset) throw new Error('asset not found');
    await tagAsset(sql, asset.id, frameworkKeys);
    return asset.id;
  });
  await finish(result, '/risk-management', appMode(form));
}

export async function saveMeasure(form: FormData) {
  const measureKey = text(form, 'measure_key', 80);
  const name = text(form, 'name', 200);
  const summary = text(form, 'summary', 4000);
  const strategy = text(form, 'strategy', 30);
  if (!['mitigate', 'transfer', 'avoid', 'accept'].includes(strategy)) throw new Error('invalid strategy');
  const sourceNote = optionalText(form, 'source_note', 4000) ?? '';
  // Match the precision of numeric(12,2) / numeric(4,2) (added 2026-09-02).
  const budgetAmount = optionalDecimal(form, 'budget_amount', /^\d{1,10}(\.\d{1,2})?$/, '予算');
  const resourceFte = optionalDecimal(form, 'resource_fte', /^\d{1,2}(\.\d{1,2})?$/, '人的リソース（FTE）');
  const frameworkKeys = requiredManagementKeys(keys(form));
  const measureId = optionalText(form, 'id', 80);
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_work_permission('measure', ${measureId ? measureId : null}::uuid, ${measureId ? 'write' : 'create'})`;
    const rows = measureId
      ? await sql<{ id: string }[]>`
          UPDATE app.measures
             SET measure_key = ${measureKey}, name = ${name}, summary = ${summary},
                 strategy = ${strategy}, source_note = ${sourceNote},
                 budget_amount = ${budgetAmount}, resource_fte = ${resourceFte},
                 updated_at = now()
           WHERE tenant_id = app.current_tenant() AND id = ${measureId}::uuid
           RETURNING id`
      : await sql<{ id: string }[]>`
          INSERT INTO app.measures
            (tenant_id, measure_key, name, summary, strategy, source_note, budget_amount, resource_fte)
          VALUES
            (app.current_tenant(), ${measureKey}, ${name}, ${summary}, ${strategy}, ${sourceNote}, ${budgetAmount}, ${resourceFte})
          ON CONFLICT (tenant_id, measure_key) DO UPDATE
            SET name = EXCLUDED.name, summary = EXCLUDED.summary,
                strategy = EXCLUDED.strategy, source_note = EXCLUDED.source_note,
                budget_amount = EXCLUDED.budget_amount, resource_fte = EXCLUDED.resource_fte,
                status = 'planned', updated_at = now()
          RETURNING id`;
    const measure = rows[0];
    if (!measure) throw new Error('measure not found');
    await tagMeasure(sql, measure.id, frameworkKeys);
    return measure.id;
  });
  await finish(result, '/risk-management', appMode(form));
}

export async function saveRisk(form: FormData) {
  const existingRiskId = optionalText(form, 'risk_id', 80);
  const riskKey = text(form, 'risk_key', 80);
  const area = text(form, 'area', 200);
  const phase = Number(text(form, 'phase', 2));
  if (!Number.isInteger(phase) || phase < 1 || phase > 5) throw new Error('invalid phase');
  const theme = text(form, 'theme', 400);
  const riskMeasure = text(form, 'measure', 400);
  const frame = text(form, 'frame', 30);
  if (!['管理可能性', '精度', 'スピード'].includes(frame)) throw new Error('invalid frame');
  const summary = text(form, 'summary', 4000);
  const frameworkKeys = requiredManagementKeys(keys(form));
  const assetIds = [...new Set(form.getAll('asset_ids').map(String).filter(Boolean))];
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_work_permission('risk', ${existingRiskId ? existingRiskId : null}::uuid, ${existingRiskId ? 'write' : 'create'})`;
    const rows = existingRiskId
      ? await sql<{ id: string }[]>`
          UPDATE app.risk_scenarios
             SET risk_key=${riskKey},domain=${area},area=${area},phase=${phase},theme=${theme},
                 measure=${riskMeasure},frame=${frame},summary=${summary},updated_at=now()
           WHERE tenant_id=app.current_tenant() AND id=${existingRiskId}::uuid AND status='active'
           RETURNING id`
      : await sql<{ id: string }[]>`
          INSERT INTO app.risk_scenarios
            (tenant_id, risk_key, domain, area, phase, theme, measure, frame, summary, status)
          VALUES
            (app.current_tenant(), ${riskKey}, ${area}, ${area}, ${phase}, ${theme}, ${riskMeasure}, ${frame}, ${summary}, 'active')
          ON CONFLICT (tenant_id, risk_key) DO UPDATE
            SET domain = EXCLUDED.domain, area = EXCLUDED.area, phase = EXCLUDED.phase,
                theme = EXCLUDED.theme, measure = EXCLUDED.measure, frame = EXCLUDED.frame,
                summary = EXCLUDED.summary, status = 'active', updated_at = now()
          RETURNING id`;
    const risk = rows[0];
    if (!risk) throw new Error('risk not found');
    await sql`SELECT app.set_management_frameworks_for_work('risk_scenario',${risk.id}::uuid,${frameworkKeys}::text[])`;
    await sql`DELETE FROM app.risk_scenario_assets
                WHERE tenant_id = app.current_tenant() AND risk_scenario_id = ${risk.id}::uuid`;
    for (const assetId of assetIds) {
      await sql`
        INSERT INTO app.risk_scenario_assets (tenant_id, risk_scenario_id, asset_id, relation)
        VALUES (app.current_tenant(), ${risk.id}::uuid, ${assetId}::uuid, 'primary')
        ON CONFLICT DO NOTHING`;
    }
    return risk.id;
  });
  await finish(result, '/risk-management', appMode(form));
}

export async function addRiskSnapshot(form: FormData) {
  const riskId = id(form);
  const stage = text(form, 'stage', 30) as 'inherent' | 'before_measure' | 'after_measure';
  if (!['inherent', 'before_measure', 'after_measure'].includes(stage)) throw new Error('invalid stage');
  const assessedOn = text(form, 'assessed_on', 20);
  const probability = Number(text(form, 'probability', 2));
  const impact = Number(text(form, 'impact', 2));
  if (![probability, impact].every((value) => Number.isInteger(value) && value >= 1 && value <= 5)) {
    throw new Error('invalid score');
  }
  const selectedMeasureId = optionalText(form, 'measure_id', 80);
  const measureId = stage === 'after_measure' ? selectedMeasureId : null;
  if (stage === 'after_measure' && !measureId) throw new Error('measure is required');
  const rationale = text(form, 'rationale', 4000);
  const sourceNote = optionalText(form, 'source_note', 4000) ?? '';
  const result = await withTenantWrite(async (sql) => {
    if (stage === 'after_measure') {
      const inherent = await sql<{ risk_level: number }[]>`
        SELECT risk_level FROM app.risk_evaluation_snapshots
         WHERE tenant_id=app.current_tenant() AND risk_scenario_id=${riskId}::uuid AND stage='inherent'
         ORDER BY assessed_on DESC, created_at DESC, id DESC LIMIT 1`;
      if (!inherent[0] || probability * impact > inherent[0].risk_level) throw new Error('residual risk must not exceed inherent risk');
    }
    await sql`
      INSERT INTO app.risk_evaluation_snapshots
        (tenant_id, risk_scenario_id, measure_id, stage, assessed_on,
         probability, impact, rationale, source_note)
      VALUES
        (app.current_tenant(), ${riskId}::uuid, ${measureId ? measureId : null}::uuid,
         ${stage}, ${assessedOn}::date, ${probability}, ${impact}, ${rationale}, ${sourceNote})`;
    return riskId;
  });
  await finish(result, `/risk-management/risks/${riskId}`, appMode(form));
}

/** Acceptance is bound to immutable inherent and residual evaluation snapshots. */
export async function acceptRisk(form: FormData) {
  const riskId = id(form);
  const evaluationSnapshotId = text(form, 'evaluation_snapshot_id', 80);
  const evaluationSnapshotSha256 = text(form, 'evaluation_snapshot_sha256', 64);
  const inherentSnapshotId = text(form, 'inherent_snapshot_id', 80);
  const inherentSnapshotSha256 = text(form, 'inherent_snapshot_sha256', 64);
  const reason = text(form, 'reason', 4000);
  const expiresAtLocal = text(form, 'expires_at', 32);
  const expiresAt = jstTimestamp(expiresAtLocal);
  const policyVersionId = text(form, 'policy_version_id', 80);
  const result = await withTenantWrite(async (sql) => {
    const policies = await sql<{ sha256: string }[]>`
      SELECT encode(digest(convert_to(body_md,'UTF8'),'sha256'),'hex') AS sha256
        FROM app.policy_versions
       WHERE tenant_id=app.current_tenant() AND id=${policyVersionId}::uuid
         AND approved_at IS NOT NULL
         AND effective_from<=(now() AT TIME ZONE 'Asia/Tokyo')::date
         AND (superseded_at IS NULL OR superseded_at>now())`;
    const policyVersionSha256 = policies[0]?.sha256;
    if (!policyVersionSha256) throw new Error('approved policy evidence is required');
    const { operationId, requestHash } = managementIntent(form, 'accept_risk', {
      riskId, evaluationSnapshotId, evaluationSnapshotSha256, inherentSnapshotId,
      inherentSnapshotSha256, reason, expiresAt, policyVersionId, policyVersionSha256,
    });
    const rows = await sql<{ receipt: Record<string, unknown> }[]>`
      SELECT app.accept_risk_snapshot_human_evidenced(
        ${operationId},${requestHash},${riskId}::uuid,
        ${evaluationSnapshotId}::uuid,
        ${evaluationSnapshotSha256},
        ${inherentSnapshotId}::uuid,
        ${inherentSnapshotSha256},
        ${reason},
        ${expiresAt}::timestamptz,
        ${policyVersionId}::uuid,
        ${policyVersionSha256}
      ) AS receipt`;
    return rows[0]?.receipt;
  });
  await finish(result, `/risk-management/risks/${riskId}`, appMode(form));
}

export async function requestIsoRemoval(form: FormData) {
  const entityType = text(form, 'entity_type', 30); const entityId = text(form, 'entity_id', 80); const generation = text(form, 'generation_id', 80);
  const reason = text(form, 'reason', 4000); const alternate = text(form, 'alternate_control', 4000); const expires = text(form, 'expires_at', 40);
  const result = await withTenantWrite(async (sql) => {
    const hash = await sql<{ beforeHash: Buffer; afterHash: Buffer }[]>`
      SELECT digest(convert_to(${entityType}||':'||${entityId}||':ISO27001:2022:'||${generation},'UTF8'),'sha256') AS "beforeHash",
             digest(convert_to(${entityType}||':'||${entityId}||':WITHOUT:ISO27001:2022:'||${generation},'UTF8'),'sha256') AS "afterHash"`;
    await sql`SELECT app.request_iso_framework_removal(${entityType},${entityId}::uuid,${generation}::uuid,${hash[0].beforeHash}::bytea,${hash[0].afterHash}::bytea,${reason},${alternate},${expires}::timestamptz)`;
    return entityId;
  });
  const detailPath = managementEntityPath(form);
  await finish(result, detailPath, appMode(form));
}
export async function approveIsoRemoval(form: FormData) { const requestId=id(form); const result=await withTenantWrite(async sql=>{await sql`SELECT app.approve_iso_framework_removal(${requestId}::uuid)`;return requestId;}); await finish(result,managementEntityPath(form),appMode(form)); }
export async function executeIsoRemoval(form: FormData) { const requestId=id(form); const result=await withTenantWrite(async sql=>{await sql`SELECT app.execute_iso_framework_removal_v2(${requestId}::uuid)`;return requestId;}); await finish(result,managementEntityPath(form),appMode(form)); }

export async function requestManagementDeviation(form: FormData) {
  const riskId = id(form);
  const title = text(form, 'title', 200);
  const description = text(form, 'description', 4000);
  const correctiveAction = text(form, 'corrective_action', 4000);
  const ownerId = text(form, 'owner_user_id', 80);
  const dueAt = jstTimestamp(text(form, 'due_at', 40));
  const expiresAt = jstTimestamp(text(form, 'expires_at', 40));
  const { operationId, requestHash } = managementIntent(form, 'request_deviation', {
    riskId, title, description, correctiveAction, ownerId, dueAt, expiresAt,
  });
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.request_management_deviation(
      ${operationId},${requestHash},${title},${description},${correctiveAction},
      ${ownerId}::uuid,${dueAt}::timestamptz,${expiresAt}::timestamptz,
      ARRAY[${riskId}::uuid]::uuid[]
    )`;
    return riskId;
  });
  await finish(result, `/risk-management/risks/${riskId}`, appMode(form));
}

export async function approveManagementDeviation(form: FormData) {
  const riskId = text(form, 'risk_id', 80);
  const deviationId = id(form);
  const { operationId, requestHash } = managementIntent(form, 'approve_deviation', { deviationId });
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.approve_management_deviation(${deviationId}::uuid,${operationId},${requestHash})`;
    return deviationId;
  });
  await finish(result, `/risk-management/risks/${riskId}`, appMode(form));
}

export async function closeManagementDeviation(form: FormData) {
  const riskId = text(form, 'risk_id', 80);
  const deviationId = id(form);
  const closeNote = text(form, 'close_note', 4000);
  const { operationId, requestHash } = managementIntent(form, 'close_deviation', { deviationId, closeNote });
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.close_management_deviation(${deviationId}::uuid,${closeNote},${operationId},${requestHash})`;
    return deviationId;
  });
  await finish(result, `/risk-management/risks/${riskId}`, appMode(form));
}
