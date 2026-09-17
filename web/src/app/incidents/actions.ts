'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';

const text = (form: FormData, key: string, max = 1000): string => {
  const value = String(form.get(key) ?? '').trim();
  if (!value || value.length > max) throw new Error(`${key} is required`);
  return value;
};

const optionalText = (form: FormData, key: string, max = 4000): string | null => {
  const value = String(form.get(key) ?? '').trim();
  return value ? value.slice(0, max) : null;
};

const optionalTimestamp = (form: FormData, key: string): string | null => {
  const value = String(form.get(key) ?? '').trim();
  return value || null;
};

const SEVERITIES = ['critical', 'high', 'medium', 'low'] as const;
const STATUSES = ['open', 'contained', 'closed'] as const;

function route(form: FormData, value: string): string {
  const mode = form.get('mode');
  if (mode !== 'isms' && mode !== 'risk') return value;
  return `${value}${value.includes('?') ? '&' : '?'}mode=${mode}`;
}

async function finish(result: Awaited<ReturnType<typeof withTenantWrite<unknown>>>, form: FormData) {
  if (!result.ok) redirect(route(form, `/incidents?error=${result.reason}`));
  revalidatePath('/incidents');
  redirect(route(form, '/incidents?saved=1'));
}

export async function saveIncident(form: FormData) {
  const title = text(form, 'title', 200);
  const summary = optionalText(form, 'summary', 4000) ?? '';
  const severity = optionalText(form, 'severity', 20);
  if (severity && !SEVERITIES.includes(severity as (typeof SEVERITIES)[number])) {
    throw new Error('invalid severity');
  }
  const status = text(form, 'status', 20);
  if (!STATUSES.includes(status as (typeof STATUSES)[number])) throw new Error('invalid status');
  const occurredAt = optionalTimestamp(form, 'occurred_at');
  const detectedAt = optionalTimestamp(form, 'detected_at');
  const relatedRiskId = optionalText(form, 'related_risk_id', 80);
  const relatedMeasureId = optionalText(form, 'related_measure_id', 80);
  const assigneeUserId = optionalText(form, 'assignee_user_id', 80);
  const incidentId = optionalText(form, 'id', 80);
  // closedへ遷移した瞬間だけ resolved_at を打つ。closed以外に戻した場合はクリアする
  // (再オープン時に古い解決日時が残らないように)。
  const resolvedAtExpr = status === 'closed';

  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_work_permission('incident', ${incidentId ? incidentId : null}::uuid, ${incidentId ? 'write' : 'create'})`;
    // assignee_user_id はUIではrisk_ownerだけを選択肢に出すが、フォームは
    // 改ざん可能なのでサーバー側でも role_key='risk_owner' を持つ有効な
    // メンバーシップであることを検証する(Codexレビュー2026-09-02指摘: 未検証だと
    // 一般ユーザーもアサイン可能だった)。ただし「変更していない既存の値」まで
    // 拒否すると、退職済みユーザーへの既存アサインが編集のたびに保存できなくなる
    // (これも別のCodexレビュー指摘)。既存値と同じ場合はこの検証をスキップする。
    if (assigneeUserId) {
      let unchanged = false;
      if (incidentId) {
        // FOR UPDATE で行ロックしてからUPDATEまで同一トランザクションで保持する。
        // ロックしないと、この確認とUPDATEの間に別リクエストが割り込み、
        // 「変更していない」の判定がすり抜けうる(Codexレビュー2026-09-02指摘、TOCTOU)。
        const current = await sql<{ assignee_user_id: string | null }[]>`
          SELECT assignee_user_id FROM app.incidents
           WHERE tenant_id = app.current_tenant() AND id = ${incidentId}::uuid
           FOR UPDATE`;
        unchanged = current[0]?.assignee_user_id === assigneeUserId;
      }
      if (!unchanged) {
        // FOR UPDATE OF mem, u でメンバーシップ・ユーザー行もロックする。ロック
        // しないと、この確認からUPDATEまでの間に別トランザクションがrevoke/status
        // 変更でき、退職・ロール解除済みへの新規アサインが確定しうる
        // (Codexレビュー2026-09-02指摘、TOCTOU)。
        const owners = await sql<{ id: string }[]>`
          SELECT 1 AS id FROM app.memberships mem
            JOIN app.users u ON u.tenant_id = mem.tenant_id AND u.id = mem.user_id
           WHERE mem.tenant_id = app.current_tenant() AND mem.user_id = ${assigneeUserId}::uuid
             AND mem.role_key = 'risk_owner' AND mem.revoked_at IS NULL AND u.status = 'active'
           FOR UPDATE OF mem, u`;
        if (owners.length === 0) throw new Error('assignee must be an active risk_owner');
      }
    }
    if (incidentId) {
      await sql`
        UPDATE app.incidents
           SET title = ${title}, summary = ${summary}, severity = ${severity},
               status = ${status}, occurred_at = ${occurredAt}, detected_at = ${detectedAt},
               related_risk_id = ${relatedRiskId ? relatedRiskId : null}::uuid,
               related_measure_id = ${relatedMeasureId ? relatedMeasureId : null}::uuid,
               assignee_user_id = ${assigneeUserId ? assigneeUserId : null}::uuid,
               resolved_at = CASE WHEN ${resolvedAtExpr} THEN coalesce(resolved_at, now()) ELSE NULL END,
               updated_at = now()
         WHERE tenant_id = app.current_tenant() AND id = ${incidentId}::uuid`;
      return incidentId;
    }
    const rows = await sql<{ id: string }[]>`
      INSERT INTO app.incidents
        (tenant_id, title, summary, severity, status, occurred_at, detected_at,
         related_risk_id, related_measure_id, assignee_user_id, resolved_at)
      VALUES
        (app.current_tenant(), ${title}, ${summary}, ${severity}, ${status},
         ${occurredAt}, ${detectedAt},
         ${relatedRiskId ? relatedRiskId : null}::uuid,
         ${relatedMeasureId ? relatedMeasureId : null}::uuid,
         ${assigneeUserId ? assigneeUserId : null}::uuid,
         CASE WHEN ${resolvedAtExpr} THEN now() ELSE NULL END)
      RETURNING id`;
    const incident = rows[0];
    if (!incident) throw new Error('incident not found');
    return incident.id;
  });
  await finish(result, form);
}
