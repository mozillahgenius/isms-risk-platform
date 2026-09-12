'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import type { TransactionSql } from 'postgres';
import { FINDING_FROM, FINDING_STEPS, type FindingStep } from '@/lib/findingFlow';
import { withTenantWrite } from '@/lib/tenant';

// Write ISMS operational records from the UI (design doc 2026-09-11 §5; backed by migrations 0063 / 0064).
// The final say on roles belongs to the DB's app.require_records_role(kind) (supplier evaluations use app.require_work_permission).
// Here we read the same check first and return the rejection reason in words the user understands (a DB exception can only be shown as a generic "failure").

type RecordKind =
  | 'audit' | 'corrective' | 'effectiveness' | 'management_review'
  | 'objective' | 'evidence' | 'exception' | 'vendor' | 'context' | 'legal' | 'continuity' | 'vulnerability'
  | 'change';

const ROLES_FOR: Record<RecordKind, readonly string[]> = {
  audit: ['owner', 'admin', 'auditor'],
  corrective: ['owner', 'admin', 'manager'],
  effectiveness: ['owner', 'admin'],
  management_review: ['owner', 'admin'],
  objective: ['owner', 'admin'],
  evidence: ['owner', 'admin', 'manager'],
  exception: ['owner'],
  // Organizational issues (4.1) and interested parties (4.2) determine the context of the organization, so they sit at the same tier as objectives (0065).
  context: ['owner', 'admin'],
  // Legal and contractual requirements are records of business operations, so they sit at the same tier as corrective actions and evidence (0066).
  legal: ['owner', 'admin', 'manager'],
  // Business continuity plans and tests are also records of business operations (0068).
  continuity: ['owner', 'admin', 'manager'],
  // Vulnerability records are also records of business operations (0069).
  vulnerability: ['owner', 'admin', 'manager'],
  // Anyone can submit a change request (0070). Only top management can approve or reject (checked separately in decideChangeRequest, and the DB function also refuses).
  change: ['owner', 'admin', 'manager', 'member'],
  // Supplier evaluations follow work assignments (members assigned to the task can also write). The DB has the final say.
  vendor: ['owner', 'admin', 'manager', 'member'],
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

class InputError extends Error {}

const text = (form: FormData, key: string, max = 4000): string => {
  const value = String(form.get(key) ?? '').trim();
  if (!value || value.length > max) throw new InputError(key);
  return value;
};
const optionalText = (form: FormData, key: string, max = 4000): string | null => {
  const value = String(form.get(key) ?? '').trim();
  if (value.length > max) throw new InputError(key);
  return value || null;
};
const uuid = (form: FormData, key: string): string => {
  const value = String(form.get(key) ?? '').trim();
  if (!UUID_RE.test(value)) throw new InputError(key);
  return value;
};
const optionalUuid = (form: FormData, key: string): string | null => {
  const value = String(form.get(key) ?? '').trim();
  if (!value) return null;
  if (!UUID_RE.test(value)) throw new InputError(key);
  return value;
};
/** Not just the format: is it a date that exists on the calendar (so a day like 2026-02-31 doesn't become a DB exception)? */
const isCalendarDate = (value: string): boolean => {
  if (!DATE_RE.test(value)) return false;
  const [y, m, d] = value.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  return y >= 1900 && y <= 2100 && t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
};
const optionalDate = (form: FormData, key: string): string | null => {
  const value = String(form.get(key) ?? '').trim();
  if (!value) return null;
  if (!isCalendarDate(value)) throw new InputError(key);
  return value;
};
const requiredDate = (form: FormData, key: string): string => {
  const value = optionalDate(form, key);
  if (!value) throw new InputError(key);
  return value;
};
const oneOf = <T extends string>(form: FormData, key: string, allowed: readonly T[]): T => {
  const value = String(form.get(key) ?? '').trim();
  if (!(allowed as readonly string[]).includes(value)) throw new InputError(key);
  return value as T;
};
const intIn = (form: FormData, key: string, min: number, max: number): number => {
  const value = Number(String(form.get(key) ?? '').trim());
  if (!Number.isInteger(value) || value < min || value > max) throw new InputError(key);
  return value;
};
const fiscalYear = (form: FormData): number => intIn(form, 'fiscal_year', 2000, 2100);

/** Today (JST). Used for comparisons so a future date isn't recorded as "performed". */
function todayJst(): string {
  return new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10);
}
/** `days` days after today (JST). */
function daysFromTodayJst(days: number): string {
  return new Date(Date.now() + 9 * 3600_000 + days * 86_400_000).toISOString().slice(0, 10);
}

function back(form: FormData, anchor: string, query: Record<string, string>): string {
  const params = new URLSearchParams(query);
  const mode = form.get('mode');
  if (mode === 'isms' || mode === 'risk') params.set('mode', mode);
  return `/iso27001/records?${params.toString()}#${anchor}`;
}

/**
 * Validates input, checks the role, then runs fn in a single transaction.
 * If fn returns a string, it is returned as the user-facing rejection reason (error=...).
 */
async function run(
  form: FormData,
  anchor: string,
  kind: RecordKind,
  parse: () => void,
  fn: (sql: TransactionSql) => Promise<string | void>,
): Promise<never> {
  try {
    parse();
  } catch (e) {
    if (e instanceof InputError) redirect(back(form, anchor, { error: 'invalid_input', field: e.message }));
    throw e;
  }
  const result = await withTenantWrite(async (sql) => {
    const [{ role }] = await sql<{ role: string }[]>`SELECT app.current_management_role() AS role`;
    if (!ROLES_FOR[kind].includes(role)) return 'forbidden';
    // For supplier evaluations, app.require_work_permission checks inside fn (so members with an assignment are let through).
    if (kind !== 'vendor') await sql`SELECT app.require_records_role(${kind})`;
    // Only active users belonging to this tenant can be chosen as owner or chair (don't rely solely on the UI's candidate list).
    for (const key of PERSON_FIELDS) {
      const value = String(form.get(key) ?? '').trim();
      if (value && UUID_RE.test(value) && !(await isActiveMember(sql, value))) return 'inactive_user';
    }
    return (await fn(sql)) ?? 'ok';
  });
  if (!result.ok) redirect(back(form, anchor, { error: result.reason }));
  if (result.data !== 'ok') redirect(back(form, anchor, { error: String(result.data) }));
  revalidatePath('/iso27001/records');
  revalidatePath('/iso27001');
  revalidatePath('/steps');
  redirect(back(form, anchor, { saved: anchor }));
}

/**
 * Returns false on a unique-constraint violation (so concurrent submissions that slip past the duplicate check don't become unhandled exceptions).
 * Wrapped in a savepoint, so the transaction can continue even after a violation.
 */
async function unlessDuplicate(sql: TransactionSql, fn: (sp: TransactionSql) => Promise<void>): Promise<boolean> {
  try {
    await sql.savepoint(fn);
    return true;
  } catch (e) {
    if ((e as { code?: string }).code === '23505') return false;
    throw e;
  }
}

/** A field that points to a person as owner or chair (in every record, only active members are accepted). */
const PERSON_FIELDS = ['owner_user_id', 'assigned_to', 'chaired_by'] as const;

/** Is this an active user who belongs to this tenant (and has not been removed from it)? */
async function isActiveMember(sql: TransactionSql, userId: string): Promise<boolean> {
  const [r] = await sql<{ n: number }[]>`
    SELECT count(*)::int AS n FROM app.users u
     WHERE u.tenant_id = app.current_tenant() AND u.id = ${userId}::uuid AND u.status = 'active'
       AND EXISTS (SELECT 1 FROM app.memberships ms
                    WHERE ms.tenant_id = u.tenant_id AND ms.user_id = u.id AND ms.revoked_at IS NULL)`;
  return r.n > 0;
}

// ---- Internal audit (9.2) ----------------------------------------------------------
export async function saveAudit(form: FormData) {
  let id: string | null = null, year = 0, scope = '', criteria = '', auditor = '';
  let plannedOn: string | null = null, performedOn: string | null = null;
  await run(form, 'audits', 'audit', () => {
    id = optionalUuid(form, 'id');
    year = fiscalYear(form);
    scope = text(form, 'scope');
    criteria = text(form, 'criteria');
    auditor = uuid(form, 'auditor_user_id');
    plannedOn = optionalDate(form, 'planned_on');
    performedOn = optionalDate(form, 'performed_on');
  }, async (sql) => {
    // The performed date must be today or earlier. Don't mark a future date as performed (plans go in planned_on).
    if (performedOn && performedOn > todayJst()) return 'future_performed';
    // Auditors are limited to active users holding the auditor role (don't rely solely on the UI's candidate list).
    const [auditorOk] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n
        FROM app.users u
        JOIN app.memberships ms ON ms.tenant_id = u.tenant_id AND ms.user_id = u.id
       WHERE u.tenant_id = app.current_tenant() AND u.id = ${auditor}::uuid AND u.status = 'active'
         AND ms.role_key = 'auditor' AND ms.revoked_at IS NULL`;
    if (auditorOk.n === 0) return 'not_auditor';
    await sql`
      INSERT INTO app.audit_programs (tenant_id, fiscal_year, status, created_by, updated_by)
      VALUES (app.current_tenant(), ${year}, 'draft', app.current_session_user(), app.current_session_user())
      ON CONFLICT (tenant_id, fiscal_year) DO NOTHING`;
    const [program] = await sql<{ id: string }[]>`
      SELECT id FROM app.audit_programs WHERE tenant_id = app.current_tenant() AND fiscal_year = ${year}`;
    if (id) {
      const rows = await sql`
        UPDATE app.audits
           SET program_id = ${program.id}::uuid, scope = ${scope}, criteria = ${criteria},
               auditor_user_id = ${auditor}::uuid, planned_on = ${plannedOn}::date, performed_on = ${performedOn}::date,
               updated_at = now(), updated_by = app.current_session_user()
         WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid`;
      if (rows.count !== 1) return 'not_found';
    } else {
      await sql`
        INSERT INTO app.audits (tenant_id, program_id, auditor_user_id, scope, criteria, planned_on, performed_on, created_by, updated_by)
        VALUES (app.current_tenant(), ${program.id}::uuid, ${auditor}::uuid, ${scope}, ${criteria},
                ${plannedOn}::date, ${performedOn}::date, app.current_session_user(), app.current_session_user())`;
    }
  });
}

// ---- Findings and nonconformities (10.2) ------------------------------------------------------
const SEVERITIES = ['critical', 'high', 'medium', 'low'] as const;

export async function saveFinding(form: FormData) {
  const auditId = String(form.get('audit_id') ?? '').trim() || null;
  // Findings raised in an audit are audit records (auditors can also write them). Nonconformities outside audits are written by the corrective-action owner.
  const kind: RecordKind = auditId ? 'audit' : 'corrective';
  let title = '', detail: string | null = null, severity: (typeof SEVERITIES)[number] = 'medium';
  let dueDate: string | null = null, assignedTo: string | null = null, audit: string | null = null;
  await run(form, 'findings', kind, () => {
    audit = optionalUuid(form, 'audit_id');
    title = text(form, 'title', 500);
    detail = optionalText(form, 'detail');
    severity = oneOf(form, 'severity', SEVERITIES);
    dueDate = optionalDate(form, 'due_date');
    assignedTo = optionalUuid(form, 'assigned_to');
  }, async (sql) => {
    await sql`
      INSERT INTO app.findings (tenant_id, source, audit_id, title, detail, severity, assigned_to, due_date, created_by, updated_by)
      VALUES (app.current_tenant(), ${audit ? 'internal_audit' : 'manual'}, ${audit}::uuid, ${title}, ${detail},
              ${severity}, ${assignedTo}::uuid, ${dueDate}::date, app.current_session_user(), app.current_session_user())`;
  });
}

/** Advances a finding's status. Verification (verified) and completion (closed) are done by the evaluating role, not by the person who made the correction. */
export async function advanceFinding(form: FormData) {
  const to = String(form.get('status') ?? '');
  const kind: RecordKind = to === 'verified' || to === 'closed' ? 'effectiveness' : 'corrective';
  let id = '', status: FindingStep = 'in_remediation';
  await run(form, 'findings', kind, () => {
    id = uuid(form, 'id');
    status = oneOf(form, 'status', FINDING_STEPS);
  }, async (sql) => {
    // Read the current status under a row lock and confirm the transition order is allowed before writing (so concurrent updates don't skip steps).
    const [row] = await sql<{ status: string; verified_by: string | null }[]>`
      SELECT status, verified_by FROM app.findings
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid FOR UPDATE`;
    if (!row) return 'not_found';
    if (!FINDING_FROM[status].includes(row.status)) return 'invalid_transition';
    if (status === 'closed' && !row.verified_by) return 'not_verified';
    const rows = await sql`
      UPDATE app.findings
         SET status = ${status},
             verified_by = CASE WHEN ${status} = 'verified' THEN app.current_session_user() ELSE verified_by END,
             verified_at = CASE WHEN ${status} = 'verified' THEN now() ELSE verified_at END,
             closed_at   = CASE WHEN ${status} = 'closed'   THEN now() ELSE closed_at END,
             updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid`;
    if (rows.count !== 1) return 'not_found';
  });
}

// ---- Corrective actions (10.2) ----------------------------------------------------------
export async function saveCorrective(form: FormData) {
  let findingId = '', rootCause = '', action = '', owner: string | null = null, dueDate: string | null = null;
  await run(form, 'corrective', 'corrective', () => {
    findingId = uuid(form, 'finding_id');
    rootCause = text(form, 'root_cause');
    action = text(form, 'action');
    owner = optionalUuid(form, 'owner_user_id');
    dueDate = optionalDate(form, 'due_date');
  }, async (sql) => {
    await sql`
      INSERT INTO app.corrective_actions (tenant_id, finding_id, root_cause, action, owner_user_id, due_date, created_by, updated_by)
      VALUES (app.current_tenant(), ${findingId}::uuid, ${rootCause}, ${action}, ${owner}::uuid, ${dueDate}::date,
              app.current_session_user(), app.current_session_user())`;
  });
}

export async function completeCorrective(form: FormData) {
  let id = '';
  await run(form, 'corrective', 'corrective', () => { id = uuid(form, 'id'); }, async (sql) => {
    const rows = await sql`
      UPDATE app.corrective_actions SET completed_at = now(), updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND completed_at IS NULL`;
    if (rows.count !== 1) return 'not_found';
  });
}

/** Verifies that a corrective action was effective. Done after the action is completed, by someone other than the owner (the DB CHECK also refuses). */
export async function reviewCorrective(form: FormData) {
  let id = '', result: 'effective' | 'not_effective' = 'effective';
  await run(form, 'corrective', 'effectiveness', () => {
    id = uuid(form, 'id');
    result = oneOf(form, 'result', ['effective', 'not_effective'] as const);
  }, async (sql) => {
    const [row] = await sql<{ owner_user_id: string | null; completed_at: string | null; me: string }[]>`
      SELECT owner_user_id, completed_at, app.current_session_user() AS me
        FROM app.corrective_actions WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid`;
    if (!row) return 'not_found';
    if (!row.completed_at) return 'not_completed';
    if (row.owner_user_id && row.owner_user_id === row.me) return 'reviewer_is_owner';
    await sql`
      UPDATE app.corrective_actions
         SET effectiveness_reviewed_by = app.current_session_user(), effectiveness_reviewed_at = now(),
             effectiveness_result = ${result}, updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid`;
  });
}

// ---- Management review (9.3) ------------------------------------------------
export async function saveReview(form: FormData) {
  let id: string | null = null, year = 0, heldOn: string | null = null, chair: string | null = null, minutes = '';
  await run(form, 'reviews', 'management_review', () => {
    id = optionalUuid(form, 'id');
    year = fiscalYear(form);
    heldOn = optionalDate(form, 'held_on');
    chair = optionalUuid(form, 'chaired_by');
    minutes = optionalText(form, 'minutes_md', 100_000) ?? '';
  }, async (sql) => {
    // Duplicate fiscal years are detected by the DB unique constraint (tenant_id, fiscal_year). Merely counting first lets concurrent submissions slip through.
    if (id) {
      let count = 0;
      const unique = await unlessDuplicate(sql, async (sp) => {
        const rows = await sp`
          UPDATE app.management_reviews
             SET fiscal_year = ${year}, held_on = ${heldOn}::date, chaired_by = ${chair}::uuid, minutes_md = ${minutes},
                 updated_at = now(), updated_by = app.current_session_user()
           WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid`;
        count = rows.count;
      });
      if (!unique) return 'review_exists_for_year';
      if (count !== 1) return 'not_found';
      return;
    }
    const inserted = await unlessDuplicate(sql, async (sp) => {
      await sp`
        INSERT INTO app.management_reviews (tenant_id, fiscal_year, held_on, chaired_by, minutes_md, created_by, updated_by)
        VALUES (app.current_tenant(), ${year}, ${heldOn}::date, ${chair}::uuid, ${minutes},
                app.current_session_user(), app.current_session_user())`;
    });
    if (!inserted) return 'review_exists_for_year';
  });
}

export async function addReviewOutput(form: FormData) {
  let reviewId = '', decision = '', owner = '', dueDate = '';
  await run(form, 'reviews', 'management_review', () => {
    reviewId = uuid(form, 'review_id');
    decision = text(form, 'decision');
    owner = uuid(form, 'owner_user_id');
    dueDate = requiredDate(form, 'due_date');
  }, async (sql) => {
    await sql`
      INSERT INTO app.management_review_outputs (tenant_id, review_id, decision, owner_user_id, due_date, created_by, updated_by)
      VALUES (app.current_tenant(), ${reviewId}::uuid, ${decision}, ${owner}::uuid, ${dueDate}::date,
              app.current_session_user(), app.current_session_user())`;
  });
}

/** Approves the minutes. Only top management (ciso) can do this (checked by the DB's app.approve_management_review). */
export async function approveReview(form: FormData) {
  let reviewId = '', comment: string | null = null;
  await run(form, 'reviews', 'management_review', () => {
    reviewId = uuid(form, 'review_id');
    comment = optionalText(form, 'comment', 2000);
  }, async (sql) => {
    const [row] = await sql<{ held_on: string | null; minutes: string }[]>`
      SELECT held_on::text AS held_on, coalesce(minutes_md, '') AS minutes
        FROM app.management_reviews WHERE tenant_id = app.current_tenant() AND id = ${reviewId}::uuid`;
    if (!row) return 'not_found';
    if (!row.held_on || row.held_on > todayJst()) return 'not_held';
    if (!row.minutes.trim()) return 'minutes_empty';
    const [{ role }] = await sql<{ role: string }[]>`SELECT app.current_management_role() AS role`;
    if (role !== 'owner') return 'executive_required';
    const [dup] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM app.approvals
       WHERE tenant_id = app.current_tenant() AND target_type = 'management_review' AND target_id = ${reviewId}::uuid
         AND target_version_hash = public.digest(convert_to(${row.held_on} || E'\n' || ${row.minutes}, 'UTF8'), 'sha256')`;
    if (dup.n > 0) return 'already_approved';
    await sql`SELECT app.approve_management_review(${reviewId}::uuid, ${comment})`;
  });
}

// ---- Control effectiveness evaluation (9.1) ----------------------------------------------------
export async function saveEffectiveness(form: FormData) {
  let measureId = '', criteria = '', evaluatedOn = '', evidence = '';
  let result: 'effective' | 'partially_effective' | 'not_effective' = 'effective';
  await run(form, 'effectiveness', 'effectiveness', () => {
    measureId = uuid(form, 'measure_id');
    criteria = text(form, 'criteria');
    evaluatedOn = requiredDate(form, 'evaluated_on');
    result = oneOf(form, 'result', ['effective', 'partially_effective', 'not_effective'] as const);
    evidence = optionalText(form, 'evidence_note') ?? '';
  }, async (sql) => {
    if (evaluatedOn > todayJst()) return 'future_evaluated';
    await sql`
      INSERT INTO app.control_effectiveness
        (tenant_id, measure_id, criteria, evaluated_on, evaluator_user_id, result, evidence_note, created_by, updated_by)
      VALUES (app.current_tenant(), ${measureId}::uuid, ${criteria}, ${evaluatedOn}::date, app.current_session_user(),
              ${result}, ${evidence}, app.current_session_user(), app.current_session_user())`;
  });
}

// ---- Information security objectives (6.2) -------------------------------------------------
// The measurement method (measure_how) is required. An achievement evaluation is only valid once all three of "measured value, evaluation date, evaluator" are present (CHECK in 0055).
export async function saveObjective(form: FormData) {
  let year = 0, title = '', description = '', measureHow = '', target = '';
  let owner: string | null = null, dueDate: string | null = null;
  await run(form, 'objectives', 'objective', () => {
    year = fiscalYear(form);
    title = text(form, 'title', 300);
    description = optionalText(form, 'description') ?? '';
    measureHow = text(form, 'measure_how');
    target = optionalText(form, 'target_value', 500) ?? '';
    owner = optionalUuid(form, 'owner_user_id');
    dueDate = optionalDate(form, 'due_date');
  }, async (sql) => {
    // Duplicate titles within the same fiscal year are detected by the DB unique constraint (tenant_id, fiscal_year, title).
    const inserted = await unlessDuplicate(sql, async (sp) => {
      await sp`
        INSERT INTO app.security_objectives
          (tenant_id, fiscal_year, title, description, measure_how, target_value, owner_user_id, due_date, created_by, updated_by)
        VALUES (app.current_tenant(), ${year}, ${title}, ${description}, ${measureHow}, ${target}, ${owner}::uuid,
                ${dueDate}::date, app.current_session_user(), app.current_session_user())`;
    });
    if (!inserted) return 'objective_exists';
  });
}

export async function evaluateObjective(form: FormData) {
  let id = '', achieved = '', status: 'achieved' | 'not_achieved' = 'achieved';
  await run(form, 'objectives', 'objective', () => {
    id = uuid(form, 'id');
    achieved = text(form, 'achieved_value', 500);
    status = oneOf(form, 'status', ['achieved', 'not_achieved'] as const);
  }, async (sql) => {
    const rows = await sql`
      UPDATE app.security_objectives
         SET achieved_value = ${achieved}, evaluated_at = now(), evaluated_by = app.current_session_user(),
             status = ${status}, updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status <> 'cancelled'`;
    if (rows.count !== 1) return 'not_found';
  });
}

// ---- Supplier evaluation (A.5.19-5.22) --------------------------------------------------
const VENDOR_RESULTS = ['acceptable', 'conditional', 'unacceptable'] as const;

export async function saveVendorAssessment(form: FormData) {
  let vendorId = '', assessedOn = '', nextDue: string | null = null;
  let result: (typeof VENDOR_RESULTS)[number] = 'acceptable';
  await run(form, 'vendors', 'vendor', () => {
    vendorId = uuid(form, 'vendor_id');
    assessedOn = requiredDate(form, 'assessed_on');
    result = oneOf(form, 'result', VENDOR_RESULTS);
    nextDue = optionalDate(form, 'next_due_on');
  }, async (sql) => {
    if (assessedOn > todayJst()) return 'future_assessed';
    if (nextDue && nextDue <= assessedOn) return 'next_due_before_assessed';
    await sql`SELECT app.require_work_permission('vendor_assessment', ${vendorId}::uuid, 'write')`;
    await sql`
      INSERT INTO app.vendor_assessments (tenant_id, vendor_id, assessed_on, result, next_due_on, created_by, updated_by)
      VALUES (app.current_tenant(), ${vendorId}::uuid, ${assessedOn}::date, ${result}, ${nextDue}::date,
              app.current_session_user(), app.current_session_user())`;
  });
}

// ---- Evidence (manual) -----------------------------------------------------------
// Automatic (auto) evidence is created by check runs. Only manual evidence is entered from the UI.
// The file itself is not stored. We record where it is (its location).
export async function saveEvidence(form: FormData) {
  let title = '', location = '', collectedOn = '', freshness = 365;
  await run(form, 'evidences', 'evidence', () => {
    title = text(form, 'title', 300);
    location = text(form, 'object_key', 1000);
    collectedOn = requiredDate(form, 'collected_on');
    freshness = intIn(form, 'freshness_days', 1, 3650);
  }, async (sql) => {
    if (collectedOn > todayJst()) return 'future_collected';
    await sql`
      INSERT INTO app.evidences (tenant_id, kind, title, object_key, collected_at, freshness_days, state, created_by, updated_by)
      VALUES (app.current_tenant(), 'manual', ${title}, ${location},
              (${collectedOn}::date::timestamp AT TIME ZONE 'Asia/Tokyo'), ${freshness}, 'valid',
              app.current_session_user(), app.current_session_user())`;
  });
}

// ---- Finding exceptions (accepted as a risk instead of corrected) ----------------------------------
// Only top management can approve. To avoid open-ended acceptance, the expiry must be after today and within 1 year.
export async function approveException(form: FormData) {
  let findingId = '', reason = '', compensating = '', expiresOn = '';
  await run(form, 'exceptions', 'exception', () => {
    findingId = uuid(form, 'finding_id');
    reason = text(form, 'reason');
    compensating = text(form, 'compensating_control');
    expiresOn = requiredDate(form, 'expires_on');
  }, async (sql) => {
    if (expiresOn <= todayJst()) return 'expiry_not_future';
    if (expiresOn > daysFromTodayJst(366)) return 'expiry_too_far';
    // Read the finding under a row lock, so concurrent approvals don't create 2 exceptions and a finding closed after the check isn't turned back into an exception.
    const [finding] = await sql<{ status: string }[]>`
      SELECT status FROM app.findings WHERE tenant_id = app.current_tenant() AND id = ${findingId}::uuid FOR UPDATE`;
    if (!finding) return 'not_found';
    if (finding.status === 'closed') return 'finding_closed';
    // Verified means the correction is done. Turning it into an exception would mark it "accepted" while the verification record remains.
    if (finding.status === 'verified') return 'finding_verified';
    if (finding.status === 'risk_accepted') return 'already_exception';
    // Renewing an expired exception is allowed. If an unexpired exception still exists, don't stack another.
    if (finding.status === 'exception') {
      const [live] = await sql<{ n: number }[]>`
        SELECT count(*)::int AS n FROM app.exceptions
         WHERE tenant_id = app.current_tenant() AND finding_id = ${findingId}::uuid AND expires_at > now()`;
      if (live.n > 0) return 'already_exception';
    }
    await sql`
      INSERT INTO app.exceptions
        (tenant_id, finding_id, reason, compensating_control, approved_by, approved_at, expires_at, created_by, updated_by)
      VALUES (app.current_tenant(), ${findingId}::uuid, ${reason}, ${compensating}, app.current_session_user(), now(),
              ((${expiresOn}::date + 1)::timestamp AT TIME ZONE 'Asia/Tokyo'),
              app.current_session_user(), app.current_session_user())`;
    await sql`
      UPDATE app.findings SET status = 'exception', updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${findingId}::uuid`;
  });
}

// ---- Organizational issues (4.1) and interested parties (4.2) ------------------------------------------
// The standard requires that these be "determined". Record what was decided and the date it was last reviewed. No approval is attached (the standard does not require one).
// Withdraw instead of deleting (what was treated as an issue, and until when, is part of the history behind scope and risk decisions).
const CONTEXT_KINDS = ['internal', 'external'] as const;
const PARTY_CATEGORIES = ['customer', 'regulator', 'employee', 'shareholder', 'supplier', 'partner', 'other'] as const;

export async function saveContextIssue(form: FormData) {
  let kind: (typeof CONTEXT_KINDS)[number] = 'external';
  let title = '', description = '', impact = '', owner: string | null = null;
  await run(form, 'context', 'context', () => {
    kind = oneOf(form, 'kind', CONTEXT_KINDS);
    title = text(form, 'title', 300);
    description = optionalText(form, 'description') ?? '';
    impact = text(form, 'isms_impact');
    owner = optionalUuid(form, 'owner_user_id');
  }, async (sql) => {
    // Duplicates of the same kind and title are detected by the DB unique constraint (tenant_id, kind, title).
    const inserted = await unlessDuplicate(sql, async (sp) => {
      await sp`
        INSERT INTO app.context_issues (tenant_id, kind, title, description, isms_impact, owner_user_id, created_by, updated_by)
        VALUES (app.current_tenant(), ${kind}, ${title}, ${description}, ${impact}, ${owner}::uuid,
                app.current_session_user(), app.current_session_user())`;
    });
    if (!inserted) return 'context_exists';
  });
}

export async function saveInterestedParty(form: FormData) {
  let category: (typeof PARTY_CATEGORIES)[number] = 'customer';
  let name = '', requirements = '', addressed = '', owner: string | null = null;
  await run(form, 'parties', 'context', () => {
    name = text(form, 'name', 300);
    category = oneOf(form, 'category', PARTY_CATEGORIES);
    requirements = text(form, 'requirements');
    addressed = optionalText(form, 'addressed_in_isms') ?? '';
    owner = optionalUuid(form, 'owner_user_id');
  }, async (sql) => {
    // Duplicate names are detected by the DB unique constraint (tenant_id, name).
    const inserted = await unlessDuplicate(sql, async (sp) => {
      await sp`
        INSERT INTO app.interested_parties
          (tenant_id, name, category, requirements, addressed_in_isms, owner_user_id, created_by, updated_by)
        VALUES (app.current_tenant(), ${name}, ${category}, ${requirements}, ${addressed}, ${owner}::uuid,
                app.current_session_user(), app.current_session_user())`;
    });
    if (!inserted) return 'party_exists';
  });
}

/** Records that issues/interested parties were reviewed (content confirmed as of today's date). Withdrawn ones are excluded. */
export async function reviewContext(form: FormData) {
  const anchor = form.get('target') === 'party' ? 'parties' : 'context';
  let target: 'issue' | 'party' = 'issue', id = '';
  await run(form, anchor, 'context', () => {
    target = oneOf(form, 'target', ['issue', 'party'] as const);
    id = uuid(form, 'id');
  }, async (sql) => {
    const rows = target === 'issue'
      ? await sql`
          UPDATE app.context_issues
             SET reviewed_on = ${todayJst()}::date, updated_at = now(), updated_by = app.current_session_user()
           WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`
      : await sql`
          UPDATE app.interested_parties
             SET reviewed_on = ${todayJst()}::date, updated_at = now(), updated_by = app.current_session_user()
           WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`;
    if (rows.count !== 1) return 'not_found';
  });
}

/** Withdraws an issue/interested party (does not delete it). */
export async function retireContext(form: FormData) {
  const anchor = form.get('target') === 'party' ? 'parties' : 'context';
  let target: 'issue' | 'party' = 'issue', id = '';
  await run(form, anchor, 'context', () => {
    target = oneOf(form, 'target', ['issue', 'party'] as const);
    id = uuid(form, 'id');
  }, async (sql) => {
    const rows = target === 'issue'
      ? await sql`
          UPDATE app.context_issues SET status = 'retired', updated_at = now(), updated_by = app.current_session_user()
           WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`
      : await sql`
          UPDATE app.interested_parties SET status = 'retired', updated_at = now(), updated_by = app.current_session_user()
           WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`;
    if (rows.count !== 1) return 'not_found';
  });
}

// ---- Legal, regulatory, and contractual requirements (A.5.31) ------------------------------------------
// Identify, link to the responding controls/evidence, evaluate compliance, and keep it current. Evaluations are recorded together with "when and by whom" (the DB CHECK also refuses otherwise).
const LEGAL_KINDS = ['law', 'regulation', 'contract', 'standard', 'other'] as const;
const COMPLIANCE_RESULTS = ['compliant', 'partially_compliant', 'non_compliant'] as const;

/**
 * Whether the new link targets (control/evidence) exist in this tenant and are usable (so FK violations don't become unhandled exceptions).
 * Don't create new links to withdrawn controls or deleted evidence (same conditions as the UI's candidates). Callers pass null for links that aren't changing.
 */
async function legalRefsExist(sql: TransactionSql, measure: string | null, evidence: string | null): Promise<boolean> {
  // Read the target rows with a share lock. Even if another process withdraws or deletes them right after the check, it has to wait until this one finishes
  // (prevents something slipping in between the check and the link, leaving a link to a withdrawn control or deleted evidence).
  if (measure) {
    const m = await sql`
      SELECT 1 FROM app.measures
       WHERE tenant_id = app.current_tenant() AND id = ${measure}::uuid AND status <> 'retired' FOR SHARE`;
    if (m.length === 0) return false;
  }
  if (evidence) {
    const e = await sql`
      SELECT 1 FROM app.evidences
       WHERE tenant_id = app.current_tenant() AND id = ${evidence}::uuid AND deleted_at IS NULL FOR SHARE`;
    if (e.length === 0) return false;
  }
  return true;
}

export async function saveLegalRequirement(form: FormData) {
  let kind: (typeof LEGAL_KINDS)[number] = 'law';
  let title = '', requirement = '', sourceRef = '';
  let owner: string | null = null, measure: string | null = null, evidence: string | null = null;
  await run(form, 'legal', 'legal', () => {
    kind = oneOf(form, 'kind', LEGAL_KINDS);
    title = text(form, 'title', 300);
    requirement = text(form, 'requirement');
    sourceRef = optionalText(form, 'source_ref', 500) ?? '';
    owner = optionalUuid(form, 'owner_user_id');
    measure = optionalUuid(form, 'measure_id');
    evidence = optionalUuid(form, 'evidence_id');
  }, async (sql) => {
    if (!(await legalRefsExist(sql, measure, evidence))) return 'ref_unavailable';
    // Duplicates of the same kind and title are detected by the DB unique constraint (tenant_id, kind, title).
    const inserted = await unlessDuplicate(sql, async (sp) => {
      await sp`
        INSERT INTO app.legal_requirements
          (tenant_id, kind, title, requirement, source_ref, owner_user_id, measure_id, evidence_id, created_by, updated_by)
        VALUES (app.current_tenant(), ${kind}, ${title}, ${requirement}, ${sourceRef}, ${owner}::uuid,
                ${measure}::uuid, ${evidence}::uuid, app.current_session_user(), app.current_session_user())`;
    });
    if (!inserted) return 'legal_exists';
  });
}

/** Evaluates compliance. Evaluation date is today (JST), the evaluator is the current user. The next review date must be after today. */
export async function assessLegalRequirement(form: FormData) {
  let id = '', result: (typeof COMPLIANCE_RESULTS)[number] = 'compliant', nextReview: string | null = null;
  await run(form, 'legal', 'legal', () => {
    id = uuid(form, 'id');
    result = oneOf(form, 'compliance_status', COMPLIANCE_RESULTS);
    nextReview = optionalDate(form, 'next_review_on');
  }, async (sql) => {
    const today = todayJst();
    if (nextReview && nextReview <= today) return 'next_review_not_after';
    const rows = await sql`
      UPDATE app.legal_requirements
         SET compliance_status = ${result}, assessed_on = ${today}::date, assessed_by = app.current_session_user(),
             next_review_on = ${nextReview}::date, updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`;
    if (rows.count !== 1) return 'not_found';
  });
}

/** Withdraws a requirement (does not delete it; what was treated as a requirement, and until when, is part of the history). */
export async function retireLegalRequirement(form: FormData) {
  let id = '';
  await run(form, 'legal', 'legal', () => { id = uuid(form, 'id'); }, async (sql) => {
    const rows = await sql`
      UPDATE app.legal_requirements SET status = 'retired', updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`;
    if (rows.count !== 1) return 'not_found';
  });
}

// ---- Edit / restore (issues, interested parties, requirements) ----------------------------------------
// Edit when a review changes the content. Withdrawn items can be restored (recreating one with the same name would hit the unique constraint).
// Only active items can be edited (withdrawn items must be restored first, then edited).

/** Edits the content of an issue. */
export async function updateContextIssue(form: FormData) {
  let id = '', kind: (typeof CONTEXT_KINDS)[number] = 'external';
  let title = '', description = '', impact = '', owner: string | null = null;
  await run(form, 'context', 'context', () => {
    id = uuid(form, 'id');
    kind = oneOf(form, 'kind', CONTEXT_KINDS);
    title = text(form, 'title', 300);
    description = optionalText(form, 'description') ?? '';
    impact = text(form, 'isms_impact');
    owner = optionalUuid(form, 'owner_user_id');
  }, async (sql) => {
    let count = 0;
    const unique = await unlessDuplicate(sql, async (sp) => {
      const rows = await sp`
        UPDATE app.context_issues
           -- 中身が変わったら、前の見直しは新しい中身に対するものではないので未見直しへ戻す（担当だけなら戻さない）。
           SET reviewed_on = CASE WHEN (kind, title, description, isms_impact)
                                       IS DISTINCT FROM (${kind}::text, ${title}::text, ${description}::text, ${impact}::text)
                                  THEN NULL ELSE reviewed_on END,
               kind = ${kind}, title = ${title}, description = ${description}, isms_impact = ${impact},
               owner_user_id = ${owner}::uuid, updated_at = now(), updated_by = app.current_session_user()
         WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`;
      count = rows.count;
    });
    if (!unique) return 'context_exists';
    if (count !== 1) return 'not_found';
  });
}

/** Edits the content of an interested party. */
export async function updateInterestedParty(form: FormData) {
  let id = '', category: (typeof PARTY_CATEGORIES)[number] = 'customer';
  let name = '', requirements = '', addressed = '', owner: string | null = null;
  await run(form, 'parties', 'context', () => {
    id = uuid(form, 'id');
    name = text(form, 'name', 300);
    category = oneOf(form, 'category', PARTY_CATEGORIES);
    requirements = text(form, 'requirements');
    addressed = optionalText(form, 'addressed_in_isms') ?? '';
    owner = optionalUuid(form, 'owner_user_id');
  }, async (sql) => {
    let count = 0;
    const unique = await unlessDuplicate(sql, async (sp) => {
      const rows = await sp`
        UPDATE app.interested_parties
           -- 中身が変わったら未見直しへ戻す（担当だけなら戻さない）。
           SET reviewed_on = CASE WHEN (name, category, requirements, addressed_in_isms)
                                       IS DISTINCT FROM (${name}::text, ${category}::text, ${requirements}::text, ${addressed}::text)
                                  THEN NULL ELSE reviewed_on END,
               name = ${name}, category = ${category}, requirements = ${requirements}, addressed_in_isms = ${addressed},
               owner_user_id = ${owner}::uuid, updated_at = now(), updated_by = app.current_session_user()
         WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`;
      count = rows.count;
    });
    if (!unique) return 'party_exists';
    if (count !== 1) return 'not_found';
  });
}

/** Restores a withdrawn issue/interested party. */
export async function reactivateContext(form: FormData) {
  const anchor = form.get('target') === 'party' ? 'parties' : 'context';
  let target: 'issue' | 'party' = 'issue', id = '';
  await run(form, anchor, 'context', () => {
    target = oneOf(form, 'target', ['issue', 'party'] as const);
    id = uuid(form, 'id');
  }, async (sql) => {
    const rows = target === 'issue'
      ? await sql`
          UPDATE app.context_issues SET status = 'active', updated_at = now(), updated_by = app.current_session_user()
           WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'retired'`
      : await sql`
          UPDATE app.interested_parties SET status = 'active', updated_at = now(), updated_by = app.current_session_user()
           WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'retired'`;
    if (rows.count !== 1) return 'not_found';
  });
}

/** Edits the content of a requirement (the compliance evaluation is kept as is; to re-evaluate, use the "evaluate" action). */
export async function updateLegalRequirement(form: FormData) {
  let id = '', kind: (typeof LEGAL_KINDS)[number] = 'law';
  let title = '', requirement = '', sourceRef = '';
  let owner: string | null = null, measure: string | null = null, evidence: string | null = null;
  await run(form, 'legal', 'legal', () => {
    id = uuid(form, 'id');
    kind = oneOf(form, 'kind', LEGAL_KINDS);
    title = text(form, 'title', 300);
    requirement = text(form, 'requirement');
    sourceRef = optionalText(form, 'source_ref', 500) ?? '';
    owner = optionalUuid(form, 'owner_user_id');
    measure = optionalUuid(form, 'measure_id');
    evidence = optionalUuid(form, 'evidence_id');
  }, async (sql) => {
    const [cur] = await sql<{ measure_id: string | null; evidence_id: string | null }[]>`
      SELECT measure_id, evidence_id FROM app.legal_requirements
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active' FOR UPDATE`;
    if (!cur) return 'not_found';
    // Links that aren't changing are not checked (so other fields can still be edited even if a linked control was withdrawn afterward).
    const newMeasure = measure === cur.measure_id ? null : measure;
    const newEvidence = evidence === cur.evidence_id ? null : evidence;
    if (!(await legalRefsExist(sql, newMeasure, newEvidence))) return 'ref_unavailable';
    let count = 0;
    const unique = await unlessDuplicate(sql, async (sp) => {
      // If the substance (what is required, link targets, etc.) changes, the previous compliance evaluation no longer applies to the new substance, so reset it to unevaluated.
      // A change of owner alone does not reset it. The right-hand side of SET sees the pre-update values.
      const rows = await sp`
        UPDATE app.legal_requirements
           SET compliance_status = CASE WHEN (kind, title, requirement, source_ref, measure_id, evidence_id)
                                             IS DISTINCT FROM (${kind}::text, ${title}::text, ${requirement}::text,
                                                               ${sourceRef}::text, ${measure}::uuid, ${evidence}::uuid)
                                        THEN 'not_assessed' ELSE compliance_status END,
               assessed_on = CASE WHEN (kind, title, requirement, source_ref, measure_id, evidence_id)
                                       IS DISTINCT FROM (${kind}::text, ${title}::text, ${requirement}::text,
                                                         ${sourceRef}::text, ${measure}::uuid, ${evidence}::uuid)
                                  THEN NULL ELSE assessed_on END,
               assessed_by = CASE WHEN (kind, title, requirement, source_ref, measure_id, evidence_id)
                                       IS DISTINCT FROM (${kind}::text, ${title}::text, ${requirement}::text,
                                                         ${sourceRef}::text, ${measure}::uuid, ${evidence}::uuid)
                                  THEN NULL ELSE assessed_by END,
               kind = ${kind}, title = ${title}, requirement = ${requirement}, source_ref = ${sourceRef},
               owner_user_id = ${owner}::uuid, measure_id = ${measure}::uuid, evidence_id = ${evidence}::uuid,
               updated_at = now(), updated_by = app.current_session_user()
         WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`;
      count = rows.count;
    });
    if (!unique) return 'legal_exists';
    if (count !== 1) return 'not_found';
  });
}

/** Restores a withdrawn requirement. */
export async function reactivateLegalRequirement(form: FormData) {
  let id = '';
  await run(form, 'legal', 'legal', () => { id = uuid(form, 'id'); }, async (sql) => {
    const rows = await sql`
      UPDATE app.legal_requirements SET status = 'active', updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'retired'`;
    if (rows.count !== 1) return 'not_found';
  });
}

// ---- Business continuity plans and tests (A.5.29 / A.5.30) ------------------------------------------
// Having written a plan and having tested that it works are different things. A test is accepted as a record only if its performed date is today or earlier
// (a future date is a plan, so it goes into the plan's "next test due date"). The tester is the person who records it.
const CONTINUITY_METHODS = ['tabletop', 'walkthrough', 'simulation', 'full_interruption'] as const;
const CONTINUITY_RESULTS = ['passed', 'partially_passed', 'failed'] as const;

/** Number of hours (optional). null if blank. Capped at 1 year (8760 hours). */
const optionalHours = (form: FormData, key: string, min: number): number | null => {
  const raw = String(form.get(key) ?? '').trim();
  if (!raw) return null;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > 8760) throw new InputError(key);
  return value;
};

type PlanFields = {
  title: string; scope: string; location: string; owner: string | null;
  nextDue: string | null; rto: number | null; rpo: number | null;
};
const planFields = (form: FormData): PlanFields => ({
  title: text(form, 'title', 300),
  scope: text(form, 'scope'),
  location: text(form, 'procedure_location', 1000),
  owner: optionalUuid(form, 'owner_user_id'),
  nextDue: optionalDate(form, 'next_test_due'),
  rto: optionalHours(form, 'rto_hours', 1),
  rpo: optionalHours(form, 'rpo_hours', 0),
});

export async function saveContinuityPlan(form: FormData) {
  let f: PlanFields | null = null;
  await run(form, 'continuity', 'continuity', () => { f = planFields(form); }, async (sql) => {
    const p = f!;
    // Duplicate titles are detected by the DB unique constraint (tenant_id, title).
    const inserted = await unlessDuplicate(sql, async (sp) => {
      await sp`
        INSERT INTO app.continuity_plans
          (tenant_id, title, scope, rto_hours, rpo_hours, procedure_location, owner_user_id, next_test_due, created_by, updated_by)
        VALUES (app.current_tenant(), ${p.title}, ${p.scope}, ${p.rto}, ${p.rpo}, ${p.location}, ${p.owner}::uuid,
                ${p.nextDue}::date, app.current_session_user(), app.current_session_user())`;
    });
    if (!inserted) return 'plan_exists';
  });
}

/** Edits the content of a plan (test records are facts as of that time, so they are not edited). */
export async function updateContinuityPlan(form: FormData) {
  let id = '', f: PlanFields | null = null;
  await run(form, 'continuity', 'continuity', () => { id = uuid(form, 'id'); f = planFields(form); }, async (sql) => {
    const p = f!;
    let count = 0;
    const unique = await unlessDuplicate(sql, async (sp) => {
      const rows = await sp`
        UPDATE app.continuity_plans
           SET title = ${p.title}, scope = ${p.scope}, rto_hours = ${p.rto}, rpo_hours = ${p.rpo},
               procedure_location = ${p.location}, owner_user_id = ${p.owner}::uuid, next_test_due = ${p.nextDue}::date,
               updated_at = now(), updated_by = app.current_session_user()
         WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`;
      count = rows.count;
    });
    if (!unique) return 'plan_exists';
    if (count !== 1) return 'not_found';
  });
}

/** Records a test. The tester is the person who records it. Not recorded against withdrawn plans. */
export async function recordContinuityTest(form: FormData) {
  let planId = '', testedOn = '', notes = '';
  let method: (typeof CONTINUITY_METHODS)[number] = 'tabletop';
  let result: (typeof CONTINUITY_RESULTS)[number] = 'passed';
  let rtoMet: boolean | null = null, evidence: string | null = null;
  await run(form, 'continuity', 'continuity', () => {
    planId = uuid(form, 'plan_id');
    testedOn = requiredDate(form, 'tested_on');
    method = oneOf(form, 'method', CONTINUITY_METHODS);
    result = oneOf(form, 'result', CONTINUITY_RESULTS);
    const met = oneOf(form, 'rto_met', ['', 'yes', 'no'] as const);
    rtoMet = met === '' ? null : met === 'yes';
    notes = optionalText(form, 'findings_note') ?? '';
    evidence = optionalUuid(form, 'evidence_id');
  }, async (sql) => {
    if (testedOn > todayJst()) return 'future_tested';
    // Read the plan with a share lock (prevents it being withdrawn right after the check and a test getting attached to a withdrawn plan).
    const plan = await sql`
      SELECT 1 FROM app.continuity_plans
       WHERE tenant_id = app.current_tenant() AND id = ${planId}::uuid AND status = 'active' FOR SHARE`;
    if (plan.length === 0) return 'not_found';
    // Evidence must exist and not be deleted (controls aren't linked, so pass null).
    if (!(await legalRefsExist(sql, null, evidence))) return 'ref_unavailable';
    await sql`
      INSERT INTO app.continuity_tests
        (tenant_id, plan_id, tested_on, method, result, rto_met, findings_note, performed_by, evidence_id, created_by, updated_by)
      VALUES (app.current_tenant(), ${planId}::uuid, ${testedOn}::date, ${method}, ${result}, ${rtoMet}, ${notes},
              app.current_session_user(), ${evidence}::uuid, app.current_session_user(), app.current_session_user())`;
  });
}

/** Withdraws a plan (does not delete it; test records are kept). */
export async function retireContinuityPlan(form: FormData) {
  let id = '';
  await run(form, 'continuity', 'continuity', () => { id = uuid(form, 'id'); }, async (sql) => {
    const rows = await sql`
      UPDATE app.continuity_plans SET status = 'retired', updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'active'`;
    if (rows.count !== 1) return 'not_found';
  });
}

/** Restores a withdrawn plan. */
export async function reactivateContinuityPlan(form: FormData) {
  let id = '';
  await run(form, 'continuity', 'continuity', () => { id = uuid(form, 'id'); }, async (sql) => {
    const rows = await sql`
      UPDATE app.continuity_plans SET status = 'active', updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'retired'`;
    if (rows.count !== 1) return 'not_found';
  });
}

// ---- Technical vulnerabilities (A.8.8) ----------------------------------------------------------
// Detected -> in progress -> resolved, or false positive. Closed records are not reopened (a recurrence is a new record).
// There is no "accepted without fixing" state (acceptance is handled in the risk register; design decision 2026-09-12).
const VULN_SOURCES = ['scan', 'advisory', 'report', 'pentest', 'other'] as const;
const VULN_SEVERITIES = ['critical', 'high', 'medium', 'low'] as const;

export async function saveVulnerability(form: FormData) {
  let title = '', identifier = '', detectedOn = '';
  let source: (typeof VULN_SOURCES)[number] = 'scan';
  let severity: (typeof VULN_SEVERITIES)[number] = 'medium';
  let asset: string | null = null, dueDate: string | null = null, owner: string | null = null;
  await run(form, 'vulnerabilities', 'vulnerability', () => {
    title = text(form, 'title', 300);
    identifier = optionalText(form, 'identifier', 100) ?? '';
    source = oneOf(form, 'source', VULN_SOURCES);
    severity = oneOf(form, 'severity', VULN_SEVERITIES);
    asset = optionalUuid(form, 'asset_id');
    detectedOn = requiredDate(form, 'detected_on');
    dueDate = optionalDate(form, 'due_date');
    owner = optionalUuid(form, 'owner_user_id');
  }, async (sql) => {
    if (detectedOn > todayJst()) return 'future_detected';
    if (dueDate && dueDate < detectedOn) return 'due_before_detected';
    if (asset) {
      // Read the asset with a share lock (prevents it being retired right after the check and a link to a retired asset).
      const a = await sql`
        SELECT 1 FROM app.assets
         WHERE tenant_id = app.current_tenant() AND id = ${asset}::uuid AND status = 'active' FOR SHARE`;
      if (a.length === 0) return 'ref_unavailable';
    }
    // Duplicate open records (same identifier, same asset) are detected by a DB unique index.
    const inserted = await unlessDuplicate(sql, async (sp) => {
      await sp`
        INSERT INTO app.vulnerabilities
          (tenant_id, title, identifier, source, asset_id, severity, detected_on, due_date, owner_user_id, created_by, updated_by)
        VALUES (app.current_tenant(), ${title}, ${identifier}, ${source}, ${asset}::uuid, ${severity}, ${detectedOn}::date,
                ${dueDate}::date, ${owner}::uuid, app.current_session_user(), app.current_session_user())`;
    });
    if (!inserted) return 'vuln_open_exists';
  });
}

/**
 * Advances the status: detected -> in progress, or close (from detected or in progress) as resolved or false positive.
 * The closed date is today (JST). A false positive requires a reason (the DB CHECK also refuses). Closed records cannot be advanced.
 */
export async function progressVulnerability(form: FormData) {
  let id = '', note = '';
  let to: 'in_progress' | 'mitigated' | 'false_positive' = 'in_progress';
  await run(form, 'vulnerabilities', 'vulnerability', () => {
    id = uuid(form, 'id');
    to = oneOf(form, 'status', ['in_progress', 'mitigated', 'false_positive'] as const);
    note = optionalText(form, 'resolution_note') ?? '';
  }, async (sql) => {
    if (to === 'false_positive' && !note) return 'false_positive_reason';
    const closing = to !== 'in_progress';
    const rows = await sql`
      UPDATE app.vulnerabilities
         SET status = ${to},
             resolved_on = ${closing ? todayJst() : null}::date,
             resolution_note = CASE WHEN ${note}::text = '' THEN resolution_note ELSE ${note}::text END,
             updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid
         AND (status = 'open' OR (${closing}::boolean AND status = 'in_progress'))`;
    if (rows.count !== 1) return 'invalid_transition';
  });
}

// ---- Change requests and approval (A.8.32) ------------------------------------------------------
// Request -> approve/reject (top management only, not the requester; written by app.decide_change_request) -> implement. Can be cancelled while requested or after approval.
// State transitions, decision fields, and post-approval content are guarded by DB triggers. We check first here only to return the rejection reason in words the user understands.
const RISK_LEVELS = ['low', 'medium', 'high'] as const;

type ChangeFields = {
  title: string; description: string; impact: string; risk: (typeof RISK_LEVELS)[number];
  rollback: string; asset: string | null; plannedOn: string | null;
};
const changeFields = (form: FormData): ChangeFields => ({
  title: text(form, 'title', 300),
  description: text(form, 'description'),
  impact: text(form, 'impact'),
  risk: oneOf(form, 'risk_level', RISK_LEVELS),
  rollback: optionalText(form, 'rollback_plan') ?? '',
  asset: optionalUuid(form, 'asset_id'),
  plannedOn: optionalDate(form, 'planned_on'),
});

/** Whether the asset is usable. Read with a share lock (prevents it being retired right after the check and a link to a retired asset). */
async function assetUsable(sql: TransactionSql, asset: string | null): Promise<boolean> {
  if (!asset) return true;
  const a = await sql`
    SELECT 1 FROM app.assets
     WHERE tenant_id = app.current_tenant() AND id = ${asset}::uuid AND status = 'active' FOR SHARE`;
  return a.length > 0;
}

export async function requestChange(form: FormData) {
  let f: ChangeFields | null = null;
  await run(form, 'changes', 'change', () => { f = changeFields(form); }, async (sql) => {
    const c = f!;
    if (!(await assetUsable(sql, c.asset))) return 'ref_unavailable';
    await sql`
      INSERT INTO app.change_requests
        (tenant_id, title, description, impact, risk_level, rollback_plan, asset_id, planned_on, requested_by, created_by, updated_by)
      VALUES (app.current_tenant(), ${c.title}, ${c.description}, ${c.impact}, ${c.risk}, ${c.rollback}, ${c.asset}::uuid,
              ${c.plannedOn}::date, app.current_session_user(), app.current_session_user(), app.current_session_user())`;
  });
}

/** Edits the request content. Only possible while requested (so it doesn't drift from what was approved/rejected; DB triggers also refuse). */
export async function updateChangeRequest(form: FormData) {
  let id = '', f: ChangeFields | null = null;
  await run(form, 'changes', 'change', () => { id = uuid(form, 'id'); f = changeFields(form); }, async (sql) => {
    const c = f!;
    const [cur] = await sql<{ status: string; asset_id: string | null }[]>`
      SELECT status, asset_id FROM app.change_requests
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid FOR UPDATE`;
    if (!cur) return 'not_found';
    if (cur.status !== 'requested') return 'change_not_editable';
    // Links that aren't changing are not checked (so other fields can still be edited even if a linked asset was retired afterward).
    if (c.asset !== cur.asset_id && !(await assetUsable(sql, c.asset))) return 'ref_unavailable';
    await sql`
      UPDATE app.change_requests
         SET title = ${c.title}, description = ${c.description}, impact = ${c.impact}, risk_level = ${c.risk},
             rollback_plan = ${c.rollback}, asset_id = ${c.asset}::uuid, planned_on = ${c.plannedOn}::date,
             updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid`;
  });
}

/** Approve/reject. Top management only, not the requester, only while requested. Rejection requires a reason. Written by the DB function (which also links the approval record). */
export async function decideChangeRequest(form: FormData) {
  let id = '', approve = true, note = '';
  await run(form, 'changes', 'change', () => {
    id = uuid(form, 'id');
    approve = oneOf(form, 'decision', ['approve', 'reject'] as const) === 'approve';
    note = optionalText(form, 'decision_note') ?? '';
  }, async (sql) => {
    const [{ role }] = await sql<{ role: string }[]>`SELECT app.current_management_role() AS role`;
    if (role !== 'owner') return 'change_executive_required';
    const [cur] = await sql<{ status: string; mine: boolean }[]>`
      SELECT status, requested_by = app.current_session_user() AS mine
        FROM app.change_requests WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid`;
    if (!cur) return 'not_found';
    if (cur.status !== 'requested') return 'not_awaiting_decision';
    if (cur.mine) return 'requester_cannot_decide';
    if (!approve && !note) return 'rejection_reason_required';
    await sql`SELECT app.decide_change_request(${id}::uuid, ${approve}::boolean, ${note || null}::text)`;
  });
}

/** Records that an approved change was implemented. The implementer is the person who records it, and the timestamp is now. */
export async function implementChange(form: FormData) {
  let id = '', result = '';
  await run(form, 'changes', 'change', () => { id = uuid(form, 'id'); result = text(form, 'result_note'); }, async (sql) => {
    const rows = await sql`
      UPDATE app.change_requests
         SET status = 'implemented', implemented_by = app.current_session_user(), implemented_at = now(),
             result_note = ${result}, updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status = 'approved'`;
    if (rows.count !== 1) return 'invalid_transition';
  });
}

/** Cancels a request (only while requested or after approval; does not delete it). */
export async function cancelChange(form: FormData) {
  let id = '';
  await run(form, 'changes', 'change', () => { id = uuid(form, 'id'); }, async (sql) => {
    const rows = await sql`
      UPDATE app.change_requests SET status = 'cancelled', updated_at = now(), updated_by = app.current_session_user()
       WHERE tenant_id = app.current_tenant() AND id = ${id}::uuid AND status IN ('requested','approved')`;
    if (rows.count !== 1) return 'invalid_transition';
  });
}
