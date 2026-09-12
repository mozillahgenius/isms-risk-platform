'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';
import { queueMail, questionnaireMailBody } from '@/lib/mailOutbox';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ANSWER_TYPES = ['text', 'boolean', 'single_choice'] as const;
const TEMPLATE_KINDS = ['checklist', 'survey'] as const;

function required(form: FormData, key: string, max: number): string {
  const value = String(form.get(key) ?? '').trim();
  if (!value || value.length > max) throw new Error(`${key} is required`);
  return value;
}

function optional(form: FormData, key: string, max: number): string | null {
  const value = String(form.get(key) ?? '').trim();
  if (value.length > max) throw new Error(`${key} が長すぎます`);
  return value || null;
}

function uuid(form: FormData, key: string): string {
  const value = required(form, key, 80);
  if (!UUID.test(value)) throw new Error(`invalid ${key}`);
  return value;
}

const BASE = '/operations/external-resources';

function route(form: FormData, path: string): string {
  const mode = String(form.get('mode') ?? '');
  return mode === 'isms' || mode === 'risk' ? `${path}${path.includes('?') ? '&' : '?'}mode=${mode}` : path;
}

function parseOrRedirect<T>(form: FormData, parse: () => T): T {
  try {
    return parse();
  } catch {
    redirect(route(form, `${BASE}?error=invalid_input`));
  }
}

/**
 * Choices are received newline-separated and turned into a jsonb array. With fewer than 2 for
 * single_choice the questionnaire cannot be answered, so apply the same rule as 0060's CHECK here too
 * (the DB is the real backstop; this is to return readable wording).
 */
function parseOptions(raw: string | null, answerType: string): string[] {
  const options = (raw ?? '')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, 20);
  if (answerType === 'single_choice' && options.length < 2) {
    throw new Error('single_choice には選択肢が 2 つ以上必要です');
  }
  return answerType === 'single_choice' ? options : [];
}

export async function saveExternalResource(form: FormData) {
  const { name, serviceName, criticality } = parseOrRedirect(form, () => {
    const value = String(form.get('criticality') ?? 'medium');
    if (!['high', 'medium', 'low'].includes(value)) throw new Error('invalid criticality');
    return {
      name: required(form, 'name', 240),
      serviceName: optional(form, 'service_name', 240),
      criticality: value,
    };
  });
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_work_permission('vendor', NULL::uuid, 'create')`;
    await sql`
      INSERT INTO app.vendors (tenant_id, name, service_name, discovery_source, criticality, created_by, updated_by)
      VALUES (app.current_tenant(), ${name}, ${serviceName}, 'manual', ${criticality},
              app.current_session_user(), app.current_session_user())`;
  });
  if (!result.ok) redirect(route(form, `${BASE}?error=${result.reason}`));
  revalidatePath(BASE);
  redirect(route(form, `${BASE}?saved=1`));
}

// ------------------------------------------------------------------
// Templates
// ------------------------------------------------------------------

export async function saveTemplate(form: FormData) {
  const { name, kind, purpose, description } = parseOrRedirect(form, () => {
    const value = String(form.get('kind') ?? 'checklist');
    if (!TEMPLATE_KINDS.includes(value as (typeof TEMPLATE_KINDS)[number])) throw new Error('invalid kind');
    return {
      name: required(form, 'name', 200),
      kind: value,
      purpose: optional(form, 'purpose', 2000) ?? '',
      description: optional(form, 'description', 4000) ?? '',
    };
  });
  const result = await withTenantWrite(async (sql) => {
    const existing = await sql<{ id: string }[]>`
      SELECT id FROM app.questionnaire_templates
       WHERE tenant_id=app.current_tenant() AND name=${name}`;
    if (existing.length > 0) return { outcome: 'duplicate_template' as const, id: '' };
    const rows = await sql<{ id: string }[]>`
      INSERT INTO app.questionnaire_templates
        (tenant_id, name, kind, purpose, description, created_by, updated_by)
      VALUES (app.current_tenant(), ${name}, ${kind}, ${purpose}, ${description},
              app.current_session_user(), app.current_session_user())
      RETURNING id`;
    return { outcome: 'ok' as const, id: rows[0]?.id ?? '' };
  });
  if (!result.ok) redirect(route(form, `${BASE}?error=${result.reason}`));
  if (result.data.outcome !== 'ok') redirect(route(form, `${BASE}?error=${result.data.outcome}`));
  revalidatePath(BASE);
  redirect(route(form, `${BASE}?saved=1&template=${result.data.id}`));
}

export async function updateTemplate(form: FormData) {
  const { id, name, kind, purpose, description, isActive } = parseOrRedirect(form, () => {
    const value = String(form.get('kind') ?? 'checklist');
    if (!TEMPLATE_KINDS.includes(value as (typeof TEMPLATE_KINDS)[number])) throw new Error('invalid kind');
    return {
      id: uuid(form, 'template_id'),
      name: required(form, 'name', 200),
      kind: value,
      purpose: optional(form, 'purpose', 2000) ?? '',
      description: optional(form, 'description', 4000) ?? '',
      isActive: String(form.get('is_active') ?? '') === 'on',
    };
  });
  const result = await withTenantWrite(async (sql) => {
    const rows = await sql<{ id: string }[]>`
      UPDATE app.questionnaire_templates
         SET name=${name}, kind=${kind}, purpose=${purpose}, description=${description},
             is_active=${isActive}, updated_at=now(), updated_by=app.current_session_user()
       WHERE tenant_id=app.current_tenant() AND id=${id}::uuid
       RETURNING id`;
    return rows.length === 1 ? ('ok' as const) : ('not_found' as const);
  });
  if (!result.ok) redirect(route(form, `${BASE}?error=${result.reason}`));
  if (result.data !== 'ok') redirect(route(form, `${BASE}?error=${result.data}`));
  revalidatePath(BASE);
  redirect(route(form, `${BASE}?saved=1&template=${id}`));
}

export async function addTemplateQuestion(form: FormData) {
  const { templateId, prompt, answerType, options, isRequired } = parseOrRedirect(form, () => {
    const value = String(form.get('answer_type') ?? 'text');
    if (!ANSWER_TYPES.includes(value as (typeof ANSWER_TYPES)[number])) throw new Error('invalid answer_type');
    return {
      templateId: uuid(form, 'template_id'),
      prompt: required(form, 'prompt', 1000),
      answerType: value,
      options: parseOptions(optional(form, 'options', 2000), value),
      isRequired: String(form.get('required') ?? '') === 'on',
    };
  });
  const result = await withTenantWrite(async (sql) => {
    // Numbering is max + 1. UNIQUE(tenant_id, template_id, ordinal) exists, so
    // with concurrent additions one fails. If it fails, the user can just press again.
    await sql`
      INSERT INTO app.questionnaire_template_questions
        (tenant_id, template_id, ordinal, prompt, answer_type, options, required)
      SELECT app.current_tenant(), ${templateId}::uuid,
             coalesce(max(ordinal), 0) + 1, ${prompt}, ${answerType},
             ${JSON.stringify(options)}::jsonb, ${isRequired}
        FROM app.questionnaire_template_questions
       WHERE tenant_id=app.current_tenant() AND template_id=${templateId}::uuid`;
  });
  if (!result.ok) redirect(route(form, `${BASE}?error=${result.reason}&template=${templateId}`));
  revalidatePath(BASE);
  redirect(route(form, `${BASE}?saved=1&template=${templateId}`));
}

export async function removeTemplateQuestion(form: FormData) {
  const templateId = parseOrRedirect(form, () => uuid(form, 'template_id'));
  const questionId = parseOrRedirect(form, () => uuid(form, 'question_id'));
  const result = await withTenantWrite(async (sql) => {
    await sql`
      DELETE FROM app.questionnaire_template_questions
       WHERE tenant_id=app.current_tenant() AND template_id=${templateId}::uuid
         AND id=${questionId}::uuid`;
    // Close the gap left after deletion. If numbers skip, "Q3" of a sent questionnaire
    // no longer matches "Q3" of the template and they cannot be reconciled.
    // UNIQUE(tenant_id, template_id, ordinal) cannot be deferred, so first
    // shift them far out, then renumber to 1..n (CHECK (ordinal > 0) means
    // negative temporary values cannot be used).
    await sql`
      UPDATE app.questionnaire_template_questions
         SET ordinal = ordinal + 1000
       WHERE tenant_id=app.current_tenant() AND template_id=${templateId}::uuid`;
    await sql`
      WITH renumbered AS (
        SELECT id, row_number() OVER (ORDER BY ordinal) AS rn
          FROM app.questionnaire_template_questions
         WHERE tenant_id=app.current_tenant() AND template_id=${templateId}::uuid
      )
      UPDATE app.questionnaire_template_questions q
         SET ordinal = renumbered.rn
        FROM renumbered
       WHERE q.id = renumbered.id AND q.tenant_id=app.current_tenant()`;
  });
  if (!result.ok) redirect(route(form, `${BASE}?error=${result.reason}&template=${templateId}`));
  revalidatePath(BASE);
  redirect(route(form, `${BASE}?saved=1&template=${templateId}`));
}

// ------------------------------------------------------------------
// Questionnaires
// ------------------------------------------------------------------

export async function createQuestionnaire(form: FormData) {
  const {
    vendorId, templateId, title, purpose, recipientName, recipientEmail, dueDate,
  } = parseOrRedirect(form, () => {
    const email = required(form, 'recipient_email', 254).toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error('invalid recipient_email');
    const due = optional(form, 'due_date', 10);
    if (due && !/^\d{4}-\d{2}-\d{2}$/.test(due)) throw new Error('invalid due_date');
    return {
      vendorId: uuid(form, 'vendor_id'),
      templateId: uuid(form, 'template_id'),
      title: required(form, 'title', 240),
      purpose: optional(form, 'purpose', 4000) ?? '',
      recipientName: optional(form, 'recipient_name', 200) ?? '',
      recipientEmail: email,
      dueDate: due,
    };
  });
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'questionnaire_manage')`;
    const template = await sql<{ id: string; question_count: number }[]>`
      SELECT t.id,
             (SELECT count(*)::int FROM app.questionnaire_template_questions q
               WHERE q.tenant_id=t.tenant_id AND q.template_id=t.id) AS question_count
        FROM app.questionnaire_templates t
       WHERE t.tenant_id=app.current_tenant() AND t.id=${templateId}::uuid AND t.is_active`;
    if (template.length !== 1) return { outcome: 'template_not_found' as const, id: '' };
    if (template[0].question_count === 0) return { outcome: 'template_empty' as const, id: '' };

    const rows = await sql<{ id: string }[]>`
      INSERT INTO app.external_questionnaires
        (tenant_id, vendor_id, template_id, title, purpose, recipient_name, recipient_email,
         due_date, created_by, updated_by)
      VALUES
        (app.current_tenant(), ${vendorId}::uuid, ${templateId}::uuid, ${title}, ${purpose},
         ${recipientName}, ${recipientEmail}::citext, ${dueDate}::date,
         app.current_session_user(), app.current_session_user())
      RETURNING id`;
    const questionnaireId = rows[0]?.id;
    if (!questionnaireId) throw new Error('questionnaire not created');
    // Questions are copied from the template, not referenced, so that later edits to the template
    // do not change the contents of questionnaires already sent.
    await sql`
      INSERT INTO app.external_questionnaire_questions
        (tenant_id, questionnaire_id, ordinal, prompt, answer_type, options, required)
      SELECT app.current_tenant(), ${questionnaireId}::uuid, q.ordinal, q.prompt,
             q.answer_type, q.options, q.required
        FROM app.questionnaire_template_questions q
       WHERE q.tenant_id=app.current_tenant() AND q.template_id=${templateId}::uuid
       ORDER BY q.ordinal`;
    return { outcome: 'ok' as const, id: questionnaireId };
  });
  if (!result.ok) redirect(route(form, `${BASE}?error=${result.reason}`));
  if (result.data.outcome !== 'ok') redirect(route(form, `${BASE}?error=${result.data.outcome}`));
  revalidatePath(BASE);
  redirect(route(form, `${BASE}/${result.data.id}?saved=1`));
}

/**
 * Send a questionnaire.
 *
 * This only goes as far as "enqueue for sending". The actual SMTP send is done by
 * scripts/send_mail_outbox.py in a separate process, which advances this questionnaire's
 * status to sent on success. The split keeps SMTP credentials off the web app, and
 * a record of the send always remains in app.mail_outbox.
 */
export async function sendQuestionnaire(form: FormData) {
  const questionnaireId = parseOrRedirect(form, () => uuid(form, 'questionnaire_id'));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'questionnaire_send')`;
    const rows = await sql<{
      id: string; title: string; purpose: string; recipient_name: string;
      recipient_email: string; due_date: string | null; vendor_name: string;
      organization_name: string;
    }[]>`
      SELECT q.id, q.title, q.purpose, q.recipient_name, q.recipient_email::text,
             q.due_date::text, v.name AS vendor_name, t.name AS organization_name
        FROM app.external_questionnaires q
        JOIN app.vendors v ON v.tenant_id=q.tenant_id AND v.id=q.vendor_id
        JOIN app.tenants t ON t.id=q.tenant_id
       WHERE q.tenant_id=app.current_tenant() AND q.id=${questionnaireId}::uuid
         AND q.status IN ('draft','ready')
       FOR UPDATE OF q`;
    if (rows.length !== 1) return 'not_sendable' as const;
    const questions = await sql<{
      ordinal: number; prompt: string; answer_type: string; options: unknown; required: boolean;
    }[]>`
      SELECT ordinal, prompt, answer_type, options, required
        FROM app.external_questionnaire_questions
       WHERE tenant_id=app.current_tenant() AND questionnaire_id=${questionnaireId}::uuid
       ORDER BY ordinal`;
    if (questions.length === 0) return 'no_questions' as const;

    const sender = await sql<{ email: string }[]>`
      SELECT email::text FROM app.users
       WHERE tenant_id=app.current_tenant() AND id=app.current_session_user()`;

    await queueMail(sql, {
      purpose: 'external_questionnaire',
      toEmail: rows[0].recipient_email,
      toName: rows[0].recipient_name,
      subject: `【ご確認のお願い】${rows[0].title}`,
      bodyText: questionnaireMailBody({
        organizationName: rows[0].organization_name,
        recipientName: rows[0].recipient_name,
        vendorName: rows[0].vendor_name,
        title: rows[0].title,
        purpose: rows[0].purpose,
        dueDate: rows[0].due_date,
        questions,
        contactEmail: sender[0]?.email ?? '',
      }),
      relatedType: 'external_questionnaire',
      relatedId: questionnaireId,
    });

    await sql`
      UPDATE app.external_questionnaires
         SET status='queued', queued_at=now(), updated_at=now(),
             updated_by=app.current_session_user()
       WHERE tenant_id=app.current_tenant() AND id=${questionnaireId}::uuid`;
    return 'ok' as const;
  });
  if (!result.ok) redirect(route(form, `${BASE}/${questionnaireId}?error=${result.reason}`));
  if (result.data !== 'ok') redirect(route(form, `${BASE}/${questionnaireId}?error=${result.data}`));
  revalidatePath(BASE);
  revalidatePath(`${BASE}/${questionnaireId}`);
  redirect(route(form, `${BASE}/${questionnaireId}?queued=1`));
}

/** A staff member records the returned answers. Only answered items are counted. */
export async function recordAnswers(form: FormData) {
  const questionnaireId = parseOrRedirect(form, () => uuid(form, 'questionnaire_id'));
  const markSubmitted = String(form.get('mark_submitted') ?? '') === 'on';
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'questionnaire_manage')`;
    const questions = await sql<{ id: string }[]>`
      SELECT id FROM app.external_questionnaire_questions
       WHERE tenant_id=app.current_tenant() AND questionnaire_id=${questionnaireId}::uuid`;
    for (const question of questions) {
      const answer = String(form.get(`answer_${question.id}`) ?? '').trim().slice(0, 4000);
      await sql`
        INSERT INTO app.external_questionnaire_answers
          (tenant_id, questionnaire_id, question_id, answer_text)
        VALUES (app.current_tenant(), ${questionnaireId}::uuid, ${question.id}::uuid, ${answer})
        ON CONFLICT (tenant_id, questionnaire_id, question_id) DO UPDATE
          SET answer_text=EXCLUDED.answer_text, answered_at=now()`;
    }
    if (markSubmitted) {
      await sql`
        UPDATE app.external_questionnaires
           SET status='submitted', submitted_at=coalesce(submitted_at, now()),
               updated_at=now(), updated_by=app.current_session_user()
         WHERE tenant_id=app.current_tenant() AND id=${questionnaireId}::uuid
           AND status IN ('sent','in_progress','queued')`;
    }
    return 'ok' as const;
  });
  if (!result.ok) redirect(route(form, `${BASE}/${questionnaireId}?error=${result.reason}`));
  revalidatePath(`${BASE}/${questionnaireId}`);
  redirect(route(form, `${BASE}/${questionnaireId}?saved=1`));
}

export async function reviewQuestionnaire(form: FormData) {
  const questionnaireId = parseOrRedirect(form, () => uuid(form, 'questionnaire_id'));
  const result = await withTenantWrite(async (sql) => {
    await sql`SELECT app.require_management_permission(NULL::text, NULL::uuid, 'questionnaire_manage')`;
    const rows = await sql<{ id: string }[]>`
      UPDATE app.external_questionnaires
         SET status='reviewed', reviewed_at=now(), updated_at=now(),
             updated_by=app.current_session_user()
       WHERE tenant_id=app.current_tenant() AND id=${questionnaireId}::uuid
         AND status='submitted'
       RETURNING id`;
    return rows.length === 1 ? ('ok' as const) : ('not_reviewable' as const);
  });
  if (!result.ok) redirect(route(form, `${BASE}/${questionnaireId}?error=${result.reason}`));
  if (result.data !== 'ok') redirect(route(form, `${BASE}/${questionnaireId}?error=${result.data}`));
  revalidatePath(BASE);
  revalidatePath(`${BASE}/${questionnaireId}`);
  redirect(route(form, `${BASE}/${questionnaireId}?saved=1`));
}
