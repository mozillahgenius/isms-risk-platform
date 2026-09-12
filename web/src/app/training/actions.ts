'use server';

import { createHash } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';
import { invalidationTarget } from '@/lib/trainingSync';

type Completion = {
  external_training_id: string;
  course_title: string;
  course_tags: string[];
  external_user_id: string;
  email: string;
  display_name: string;
  completion_status: 'completed' | 'incomplete';
  completed_at: string | null;
  score: number | null;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EVALUATIONS = ['有効', '要確認', '対象外'] as const;

function modeRoute(form: FormData, path: string): string {
  return form.get('mode') === 'isms' ? `${path}${path.includes('?') ? '&' : '?'}mode=isms` : path;
}

function normalizedTags(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error('invalid tags');
  const tags = [...new Set(value.map(String).map((tag) => tag.trim().toLowerCase()).filter(Boolean))].sort();
  if (tags.length > 30 || tags.some((tag) => tag.length > 80)) throw new Error('invalid tags');
  return tags;
}

function completion(value: unknown): Completion {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid completion');
  const row = value as Record<string, unknown>;
  const completionStatus = String(row.completion_status ?? '');
  const completedAt = row.completed_at === null ? null : String(row.completed_at ?? '');
  const score = row.score === null ? null : Number(row.score);
  if (!UUID.test(String(row.external_training_id)) || !UUID.test(String(row.external_user_id))
      || typeof row.course_title !== 'string' || !row.course_title.trim() || row.course_title.length > 500
      || typeof row.email !== 'string' || !row.email.includes('@') || row.email.length > 320
      || typeof row.display_name !== 'string' || row.display_name.length > 500
      || !['completed', 'incomplete'].includes(completionStatus)
      || (completionStatus === 'completed' && (completedAt === null || !Number.isFinite(Date.parse(completedAt))))
      || (completionStatus === 'incomplete' && completedAt !== null)
      || (score !== null && (!Number.isFinite(score) || score < 0 || score > 100))) {
    throw new Error('invalid completion');
  }
  return {
    external_training_id: String(row.external_training_id),
    course_title: row.course_title.trim(),
    course_tags: normalizedTags(row.course_tags),
    external_user_id: String(row.external_user_id),
    email: row.email.trim().toLowerCase(),
    display_name: row.display_name.trim(),
    completion_status: completionStatus as Completion['completion_status'],
    completed_at: completedAt,
    score,
  };
}

function fiscalYear(completedAt: string): number {
  const parts = new Intl.DateTimeFormat('en', {
    timeZone: 'Asia/Tokyo', year: 'numeric', month: 'numeric',
  }).formatToParts(new Date(completedAt));
  const year = Number(parts.find((part) => part.type === 'year')?.value);
  const month = Number(parts.find((part) => part.type === 'month')?.value);
  if (!Number.isInteger(year) || !Number.isInteger(month)) throw new Error('invalid completion date');
  return month < 4 ? year - 1 : year;
}

export async function syncElearningCompletions(form: FormData) {
  const endpoint = process.env.ELEARNING_COMPLETIONS_URL ?? '';
  const token = process.env.ELEARNING_MANAGEMENT_SYNC_TOKEN ?? '';
  if (!endpoint.startsWith('https://') || token.length < 32) {
    redirect(modeRoute(form, '/training?error=integration_not_configured'));
  }

  let rows: Completion[];
  try {
    const response = await fetch(endpoint, {
      headers: { authorization: `Bearer ${token}` },
      cache: 'no-store',
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new Error('upstream rejected');
    const body = await response.json() as { items?: unknown; truncated?: unknown };
    if (body.truncated === true) throw new Error('truncated response');
    if (!Array.isArray(body.items) || body.items.length > 1000) throw new Error('invalid response');
    rows = body.items.map(completion).filter((row) =>
      row.course_tags.includes('isms') || row.course_tags.includes('risk-management'));
  } catch (error) {
    const reason = error instanceof Error && error.message === 'truncated response'
      ? 'integration_truncated'
      : 'integration_unavailable';
    redirect(modeRoute(form, `/training?error=${reason}`));
  }

  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_training_manager()`;
    let imported = 0;
    let unmatched = 0;
    let deferred = 0;
    for (const row of rows) {
      if (row.completion_status === 'incomplete') {
        // The response cannot tell which year's revocation this is, so hold it without applying it to records.
        // The decision rule and rationale live in invalidationTarget in lib/trainingSync.ts
        // and are tested in isolation. **Evaluated records are never touched here** (no UPDATE is written).
        // Only check whether the course exists. The year cannot be used for the decision, so it is not fetched either.
        const known = await sql<{ one: number }[]>`
          SELECT 1 AS one FROM app.trainings
           WHERE tenant_id=app.current_tenant()
             AND source_system='elearning'
             AND external_training_id=${row.external_training_id}
           LIMIT 1`;
        if (invalidationTarget(known.length > 0).kind === 'deferred') deferred += 1;
        continue;
      }
      // There is only one import-source endpoint and token per deployment, and the response has no tenant identifier,
      // so code cannot determine "whether this response covers only this tenant".
      // Instead, only rows that could be matched to users in the current tenant pass. app.users is
      // narrowed by tenant context, and training_records has a composite FK on (tenant_id,user_id),
      // so records for other tenants' learners cannot be created (pinned by tests/management_workflows.sh).
      // Course rows are also only created after this matching.
      const users = await sql<{ id: string }[]>`
        SELECT id FROM app.users
         WHERE status = 'active' AND lower(email::text) = ${row.email}
         LIMIT 2`;
      if (users.length !== 1) {
        unmatched += 1;
        continue;
      }
      const completedAt = row.completed_at;
      if (!completedAt) throw new Error('completed training has no completion date');
      const trainingFiscalYear = fiscalYear(completedAt);
      const trainings = await sql<{ id: string }[]>`
        INSERT INTO app.trainings
          (tenant_id, title, fiscal_year, tags, source_system, external_training_id, description)
        VALUES
          (app.current_tenant(), ${row.course_title}, ${trainingFiscalYear}, ${row.course_tags},
           'elearning', ${row.external_training_id}, 'eLearningシステムから同期')
        ON CONFLICT (tenant_id, source_system, external_training_id, fiscal_year)
          WHERE external_training_id IS NOT NULL
        DO UPDATE SET title = EXCLUDED.title, tags = EXCLUDED.tags, updated_at = now()
        RETURNING id`;
      const trainingId = trainings[0].id;
      const evidence = `elearning://course/${row.external_training_id}/year/${trainingFiscalYear}/user/${row.external_user_id}`;
      const sourcePayload = {
        external_training_id: row.external_training_id,
        course_title: row.course_title,
        course_tags: row.course_tags,
        external_user_id: row.external_user_id,
        email: row.email,
        display_name: row.display_name,
        completion_status: row.completion_status,
        completed_at: completedAt,
        score: row.score,
      };
      const sourceSha256 = createHash('sha256')
        .update(JSON.stringify(sourcePayload))
        .digest('hex');
      await sql`
        INSERT INTO app.training_records AS current_record
          (tenant_id, training_id, user_id, completed_at, score, evidence_ref,
           source_payload, source_sha256, imported_at)
        VALUES
          (app.current_tenant(), ${trainingId}::uuid, ${users[0].id}::uuid,
           ${completedAt}::timestamptz, ${row.score}, ${evidence},
           ${sql.json(sourcePayload)}, ${sourceSha256}, now())
        ON CONFLICT (tenant_id, training_id, user_id) DO UPDATE
          SET completed_at = EXCLUDED.completed_at, score = EXCLUDED.score,
              evidence_ref = EXCLUDED.evidence_ref,
              source_payload = EXCLUDED.source_payload,
              source_sha256 = EXCLUDED.source_sha256,
              imported_at = now(),
              evaluation_status = CASE
                WHEN current_record.source_sha256 IS NOT DISTINCT FROM EXCLUDED.source_sha256
                  THEN current_record.evaluation_status ELSE '未評価' END,
              evaluated_at = CASE
                WHEN current_record.source_sha256 IS NOT DISTINCT FROM EXCLUDED.source_sha256
                  THEN current_record.evaluated_at ELSE NULL END,
              evaluated_by = CASE
                WHEN current_record.source_sha256 IS NOT DISTINCT FROM EXCLUDED.source_sha256
                  THEN current_record.evaluated_by ELSE NULL END`;
      imported += 1;
    }
    return { imported, unmatched, deferred };
  });
  if (!result.ok) redirect(modeRoute(form, `/training?error=${result.reason}`));
  revalidatePath('/training');
  revalidatePath('/competency');
  revalidatePath('/steps/training');
  redirect(modeRoute(form, `/training?synced=${result.data.imported}&unmatched=${result.data.unmatched}&deferred=${result.data.deferred}`));
}

export async function evaluateTrainingRecord(form: FormData) {
  const trainingId = String(form.get('training_id') ?? '');
  const userId = String(form.get('user_id') ?? '');
  const evaluation = String(form.get('evaluation_status') ?? '');
  if (!UUID.test(trainingId) || !UUID.test(userId)
      || !EVALUATIONS.includes(evaluation as (typeof EVALUATIONS)[number])) {
    throw new Error('invalid evaluation');
  }
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_work_permission('training', ${trainingId}::uuid, 'write')`;
    const updated = await sql`
      UPDATE app.training_records
         SET evaluation_status = ${evaluation}, evaluated_at = now(),
             evaluated_by = app.current_session_user()
       WHERE training_id = ${trainingId}::uuid AND user_id = ${userId}::uuid
       RETURNING training_id`;
    if (updated.length !== 1) throw new Error('training record not found');
  });
  if (!result.ok) redirect(modeRoute(form, `/training?error=${result.reason}`));
  revalidatePath('/training');
  revalidatePath('/competency');
  revalidatePath('/steps/training');
  redirect(modeRoute(form, '/training?evaluated=1'));
}
