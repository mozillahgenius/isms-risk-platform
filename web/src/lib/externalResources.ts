import 'server-only';

import { withTenantActor, type TenantReadResult } from './tenant';
import { MANAGEMENT_ROLE_LABEL, type ManagementRole } from './workAssignments';

export { MANAGEMENT_ROLE_LABEL };
export type { ManagementRole };

export const QUESTIONNAIRE_STATUS_LABEL: Record<string, string> = {
  draft: '下書き',
  ready: '送信準備済み',
  queued: '送信待ち',
  sent: '送信済み',
  in_progress: '回答中',
  submitted: '回答受領',
  reviewed: 'レビュー済み',
  cancelled: '取消',
};

export const TEMPLATE_KIND_LABEL: Record<string, string> = {
  checklist: 'チェックリスト',
  survey: 'アンケート',
};

export const ANSWER_TYPE_LABEL: Record<string, string> = {
  text: '記述',
  boolean: 'はい / いいえ',
  single_choice: '選択肢から1つ',
};

export const DELIVERY_STATUS_LABEL: Record<string, string> = {
  queued: '送信待ち',
  sending: '送信中',
  sent: '送信済み',
  failed: '送信失敗',
  cancelled: '取消',
};

export type VendorRow = {
  id: string;
  name: string;
  service_name: string | null;
  criticality: string | null;
  questionnaire_count: number;
};

export type QuestionRow = {
  id: string;
  ordinal: number;
  prompt: string;
  answer_type: string;
  options: unknown;
  required: boolean;
};

export type TemplateRow = {
  id: string;
  name: string;
  kind: string;
  purpose: string;
  description: string;
  is_active: boolean;
  question_count: number;
};

export type QuestionnaireRow = {
  id: string;
  vendor_id: string;
  vendor_name: string;
  template_name: string | null;
  title: string;
  purpose: string;
  recipient_name: string;
  recipient_email: string;
  due_date: string | null;
  status: string;
  question_count: number;
  answered_count: number;
  queued_at: string | null;
  sent_at: string | null;
  delivery_status: string | null;
  delivery_error: string | null;
};

export type ExternalResourceWorkspace = {
  role: ManagementRole;
  canManage: boolean;
  canWork: boolean;
  canSend: boolean;
  organizationName: string;
  vendors: VendorRow[];
  templates: TemplateRow[];
  selectedTemplate: (TemplateRow & { questions: QuestionRow[] }) | null;
  questionnaires: QuestionnaireRow[];
};

async function loadTemplates(
  sql: Parameters<Parameters<typeof withTenantActor>[0]>[0],
): Promise<TemplateRow[]> {
  return sql<TemplateRow[]>`
    SELECT t.id, t.name, t.kind, t.purpose, t.description, t.is_active,
           (SELECT count(*)::int FROM app.questionnaire_template_questions q
             WHERE q.tenant_id=t.tenant_id AND q.template_id=t.id) AS question_count
      FROM app.questionnaire_templates t
     WHERE t.tenant_id=app.current_tenant()
     ORDER BY t.is_active DESC, t.name`;
}

export async function getExternalResourceWorkspace(
  query: { templateId?: string } = {},
): Promise<TenantReadResult<ExternalResourceWorkspace>> {
  const templateId = /^[0-9a-f-]{36}$/i.test(query.templateId ?? '') ? query.templateId! : '';
  return withTenantActor(async (sql) => {
    const roleRows = await sql<{ role: ManagementRole }[]>`SELECT app.current_management_role() AS role`;
    const role = roleRows[0]?.role ?? 'none';

    const [tenantRows, vendors, templates, questionnaires, workRows] = await Promise.all([
      sql<{ name: string }[]>`SELECT name FROM app.tenants WHERE id=app.current_tenant()`,
      sql<VendorRow[]>`
        SELECT v.id, v.name, v.service_name, v.criticality,
               (SELECT count(*)::int FROM app.external_questionnaires q
                 WHERE q.tenant_id=v.tenant_id AND q.vendor_id=v.id) AS questionnaire_count
          FROM app.vendors v
         WHERE v.tenant_id=app.current_tenant() ORDER BY v.name`,
      loadTemplates(sql),
      // 送信状態は app.mail_outbox が正本。質問票側の status だけを見ていると
      // 「送ったつもりで失敗している」が画面から分からない。
      sql<QuestionnaireRow[]>`
        SELECT q.id, q.vendor_id, v.name AS vendor_name, t.name AS template_name,
               q.title, q.purpose, q.recipient_name, q.recipient_email::text,
               q.due_date::text, q.status,
               (SELECT count(*)::int FROM app.external_questionnaire_questions qq
                 WHERE qq.tenant_id=q.tenant_id AND qq.questionnaire_id=q.id) AS question_count,
               (SELECT count(*)::int FROM app.external_questionnaire_answers qa
                 WHERE qa.tenant_id=q.tenant_id AND qa.questionnaire_id=q.id
                   AND btrim(qa.answer_text) <> '') AS answered_count,
               q.queued_at::text, q.sent_at::text,
               mo.status AS delivery_status, mo.last_error AS delivery_error
          FROM app.external_questionnaires q
          JOIN app.vendors v ON v.tenant_id=q.tenant_id AND v.id=q.vendor_id
          LEFT JOIN app.questionnaire_templates t
            ON t.tenant_id=q.tenant_id AND t.id=q.template_id
          LEFT JOIN LATERAL (
            SELECT status, last_error FROM app.mail_outbox m
             WHERE m.tenant_id=q.tenant_id AND m.purpose='external_questionnaire'
               AND m.related_type='external_questionnaire' AND m.related_id=q.id
             ORDER BY m.queued_at DESC LIMIT 1
          ) mo ON true
         WHERE q.tenant_id=app.current_tenant()
         ORDER BY q.created_at DESC`,
      sql<{ one: number }[]>`
        SELECT 1 AS one
          FROM app.work_items w
          JOIN app.work_item_assignees a
            ON a.tenant_id=w.tenant_id AND a.work_item_id=w.id
         WHERE w.tenant_id=app.current_tenant()
           AND w.work_type='external_resource_review'
           AND w.status NOT IN ('completed','cancelled')
           AND a.user_id=app.current_session_user()
           AND a.assignment_role IN ('owner','editor')
           AND a.status NOT IN ('declined','cancelled','completed')
         LIMIT 1`,
    ]);

    let selectedTemplate: (TemplateRow & { questions: QuestionRow[] }) | null = null;
    if (templateId) {
      const found = templates.find((t) => t.id === templateId);
      if (found) {
        const questions = await sql<QuestionRow[]>`
          SELECT id, ordinal, prompt, answer_type, options, required
            FROM app.questionnaire_template_questions
           WHERE tenant_id=app.current_tenant() AND template_id=${templateId}::uuid
           ORDER BY ordinal`;
        selectedTemplate = { ...found, questions };
      }
    }

    return {
      role,
      canManage: ['owner', 'admin', 'manager'].includes(role),
      canWork: ['owner', 'admin', 'manager'].includes(role) || workRows.length > 0,
      canSend: ['owner', 'admin'].includes(role),
      organizationName: tenantRows[0]?.name ?? '',
      vendors,
      templates,
      selectedTemplate,
      questionnaires,
    };
  });
}

export type QuestionnaireDetail = {
  role: ManagementRole;
  canManage: boolean;
  canSend: boolean;
  questionnaire: QuestionnaireRow;
  questions: (QuestionRow & { answer_text: string })[];
  deliveries: {
    id: string; status: string; to_email: string; subject: string;
    queued_at: string; sent_at: string | null; attempts: number; last_error: string;
  }[];
};

export async function getQuestionnaireDetail(id: string): Promise<TenantReadResult<QuestionnaireDetail | null>> {
  return withTenantActor(async (sql) => {
    const roleRows = await sql<{ role: ManagementRole }[]>`SELECT app.current_management_role() AS role`;
    const role = roleRows[0]?.role ?? 'none';
    const rows = await sql<QuestionnaireRow[]>`
      SELECT q.id, q.vendor_id, v.name AS vendor_name, t.name AS template_name,
             q.title, q.purpose, q.recipient_name, q.recipient_email::text,
             q.due_date::text, q.status,
             (SELECT count(*)::int FROM app.external_questionnaire_questions qq
               WHERE qq.tenant_id=q.tenant_id AND qq.questionnaire_id=q.id) AS question_count,
             (SELECT count(*)::int FROM app.external_questionnaire_answers qa
               WHERE qa.tenant_id=q.tenant_id AND qa.questionnaire_id=q.id
                 AND btrim(qa.answer_text) <> '') AS answered_count,
             q.queued_at::text, q.sent_at::text,
             NULL::text AS delivery_status, NULL::text AS delivery_error
        FROM app.external_questionnaires q
        JOIN app.vendors v ON v.tenant_id=q.tenant_id AND v.id=q.vendor_id
        LEFT JOIN app.questionnaire_templates t
          ON t.tenant_id=q.tenant_id AND t.id=q.template_id
       WHERE q.tenant_id=app.current_tenant() AND q.id=${id}::uuid`;
    if (rows.length === 0) return null;
    const questions = await sql<(QuestionRow & { answer_text: string })[]>`
      SELECT qq.id, qq.ordinal, qq.prompt, qq.answer_type, qq.options, qq.required,
             coalesce(qa.answer_text, '') AS answer_text
        FROM app.external_questionnaire_questions qq
        LEFT JOIN app.external_questionnaire_answers qa
          ON qa.tenant_id=qq.tenant_id AND qa.questionnaire_id=qq.questionnaire_id
         AND qa.question_id=qq.id
       WHERE qq.tenant_id=app.current_tenant() AND qq.questionnaire_id=${id}::uuid
       ORDER BY qq.ordinal`;
    const deliveries = await sql<QuestionnaireDetail['deliveries']>`
      SELECT id, status, to_email::text, subject, queued_at::text, sent_at::text,
             attempts, last_error
        FROM app.mail_outbox
       WHERE tenant_id=app.current_tenant() AND purpose='external_questionnaire'
         AND related_type='external_questionnaire' AND related_id=${id}::uuid
       ORDER BY queued_at DESC`;
    return {
      role,
      canManage: ['owner', 'admin', 'manager'].includes(role),
      canSend: ['owner', 'admin'].includes(role),
      questionnaire: rows[0],
      questions,
      deliveries,
    };
  });
}
