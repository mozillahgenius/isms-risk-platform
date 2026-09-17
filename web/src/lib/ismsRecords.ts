import 'server-only';

import { withTenant, withTenantActor, type TenantReadResult } from './tenant';

/**
 * ISMS の運用記録（設計書 2026-09-11 §5）を読むところ。
 * 第 1 段: 内部監査（9.2）・指摘と是正処置（10.2）・マネジメントレビュー（9.3）・統制の有効性評価（9.1）。
 * 第 2 段: 情報セキュリティ目的（6.2）・委託先評価（A.5.19〜5.22）・証跡・指摘の例外。
 * §4（0065〜）: 組織の課題（4.1）・利害関係者（4.2）・法令・規制・契約上の要求事項（A.5.31）。
 *
 * 数の意味は段階の画面（catalog.ts の getRegisterFacts）と揃える:
 * 計画は実施として数えない（実施日・開催日・評価日が今日までのものだけが「実施済み」）。
 */

export type Person = { id: string; display_name: string; email: string };
export type MeasureOption = { id: string; measure_key: string; name: string };

/**
 * 一覧に出す件数の上限。段階の画面の件数は上限なしで数えるので、上限に届いたら画面にそう書く
 * （黙って古い記録を隠さない。Codex レビュー 2026-09-12）。
 */
export const LIST_LIMIT = {
  audits: 200, findings: 300, correctiveActions: 300, effectiveness: 300, evidences: 300,
  continuityTests: 200, vulnerabilities: 300, changeRequests: 300,
} as const;

export type AuditRow = {
  id: string;
  fiscal_year: number;
  scope: string;
  criteria: string;
  auditor_user_id: string;
  auditor_name: string | null;
  planned_on: string | null;
  performed_on: string | null;
  finding_count: number;
};

export type FindingRow = {
  id: string;
  audit_id: string | null;
  source: string;
  title: string;
  detail: string | null;
  severity: string;
  status: string;
  due_date: string | null;
  assigned_to: string | null;
  assignee_name: string | null;
  detected_at: string;
};

export type CorrectiveRow = {
  id: string;
  finding_id: string;
  finding_title: string;
  root_cause: string;
  action: string;
  owner_user_id: string | null;
  owner_name: string | null;
  due_date: string | null;
  completed_at: string | null;
  effectiveness_result: string | null;
  effectiveness_reviewed_at: string | null;
  reviewer_name: string | null;
};

export type ReviewRow = {
  id: string;
  fiscal_year: number;
  held_on: string | null;
  chaired_by: string | null;
  chair_name: string | null;
  minutes_md: string;
  approved_count: number;
  last_approved_at: string | null;
  outputs: { id: string; decision: string; owner_name: string | null; due_date: string; status: string }[];
};

export type EffectivenessRow = {
  id: string;
  measure_id: string;
  measure_key: string;
  measure_name: string;
  criteria: string;
  evaluated_on: string;
  result: string;
  evaluator_name: string | null;
  evidence_note: string;
};

export type ObjectiveRow = {
  id: string;
  fiscal_year: number;
  title: string;
  description: string;
  measure_how: string;
  target_value: string;
  owner_name: string | null;
  due_date: string | null;
  status: string;
  achieved_value: string | null;
  evaluated_at: string | null;
  evaluator_name: string | null;
};

export type VendorRow = {
  id: string;
  name: string;
  service_name: string | null;
  criticality: string | null;
  last_assessed_on: string | null;
  last_result: string | null;
  next_due_on: string | null;
  assessment_count: number;
};

export type EvidenceRow = {
  id: string;
  kind: string;
  title: string;
  object_key: string | null;
  collected_at: string;
  freshness_days: number;
  state: string;
  stale: boolean;
};

export type ExceptionRow = {
  id: string;
  finding_id: string;
  finding_title: string;
  reason: string;
  compensating_control: string;
  approver_name: string | null;
  approved_at: string;
  expires_at: string;
  expired: boolean;
};

export type ContextIssueRow = {
  id: string;
  kind: string;
  title: string;
  description: string;
  isms_impact: string;
  owner_user_id: string | null;
  owner_name: string | null;
  reviewed_on: string | null;
  status: string;
};

export type InterestedPartyRow = {
  id: string;
  name: string;
  category: string;
  requirements: string;
  addressed_in_isms: string;
  owner_user_id: string | null;
  owner_name: string | null;
  reviewed_on: string | null;
  status: string;
};

export type LegalRequirementRow = {
  id: string;
  kind: string;
  title: string;
  requirement: string;
  source_ref: string;
  owner_user_id: string | null;
  owner_name: string | null;
  measure_id: string | null;
  evidence_id: string | null;
  measure_key: string | null;
  measure_name: string | null;
  evidence_title: string | null;
  compliance_status: string;
  assessed_on: string | null;
  assessor_name: string | null;
  next_review_on: string | null;
  status: string;
};

export type ContinuityPlanRow = {
  id: string;
  title: string;
  scope: string;
  rto_hours: number | null;
  rpo_hours: number | null;
  procedure_location: string;
  owner_user_id: string | null;
  owner_name: string | null;
  next_test_due: string | null;
  status: string;
  last_tested_on: string | null;
  last_result: string | null;
  test_count: number;
};

export type ContinuityTestRow = {
  id: string;
  plan_title: string;
  tested_on: string;
  method: string;
  result: string;
  rto_met: boolean | null;
  findings_note: string;
  performer_name: string | null;
  evidence_title: string | null;
};

export type VulnerabilityRow = {
  id: string;
  title: string;
  identifier: string;
  source: string;
  asset_id: string | null;
  asset_key: string | null;
  asset_name: string | null;
  severity: string;
  detected_on: string;
  due_date: string | null;
  status: string;
  resolved_on: string | null;
  resolution_note: string;
  owner_user_id: string | null;
  owner_name: string | null;
};

export type AssetOption = { id: string; asset_key: string; name: string };

export type ChangeRequestRow = {
  id: string;
  title: string;
  description: string;
  impact: string;
  risk_level: string;
  rollback_plan: string;
  asset_id: string | null;
  asset_key: string | null;
  asset_name: string | null;
  planned_on: string | null;
  requested_by: string;
  requester_name: string | null;
  requested_at: string;
  status: string;
  decider_name: string | null;
  decided_at: string | null;
  decision_note: string;
  implementer_name: string | null;
  implemented_at: string | null;
  result_note: string;
};

export type RecordsWorkspace = {
  audits: AuditRow[];
  findings: FindingRow[];
  correctiveActions: CorrectiveRow[];
  reviews: ReviewRow[];
  effectiveness: EffectivenessRow[];
  objectives: ObjectiveRow[];
  vendors: VendorRow[];
  evidences: EvidenceRow[];
  exceptions: ExceptionRow[];
  contextIssues: ContextIssueRow[];
  interestedParties: InterestedPartyRow[];
  legalRequirements: LegalRequirementRow[];
  continuityPlans: ContinuityPlanRow[];
  continuityTests: ContinuityTestRow[];
  vulnerabilities: VulnerabilityRow[];
  assets: AssetOption[];
  changeRequests: ChangeRequestRow[];
  people: Person[];
  auditors: Person[];
  measures: MeasureOption[];
};

export async function getRecordsWorkspace(): Promise<TenantReadResult<RecordsWorkspace>> {
  return withTenant(async (sql) => {
    const audits = await sql<AuditRow[]>`
      SELECT a.id, p.fiscal_year, a.scope, a.criteria, a.auditor_user_id, u.display_name AS auditor_name,
             a.planned_on::text AS planned_on, a.performed_on::text AS performed_on,
             (SELECT count(*)::int FROM app.findings f WHERE f.tenant_id = a.tenant_id AND f.audit_id = a.id) AS finding_count
        FROM app.audits a
        JOIN app.audit_programs p ON p.tenant_id = a.tenant_id AND p.id = a.program_id
        LEFT JOIN app.users u ON u.tenant_id = a.tenant_id AND u.id = a.auditor_user_id
       ORDER BY p.fiscal_year DESC, coalesce(a.performed_on, a.planned_on) DESC NULLS LAST, a.created_at DESC
       LIMIT ${LIST_LIMIT.audits}`;
    const findings = await sql<FindingRow[]>`
      SELECT f.id, f.audit_id, f.source, f.title, f.detail, f.severity, f.status,
             f.due_date::text AS due_date, f.assigned_to, u.display_name AS assignee_name,
             to_char(f.detected_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS detected_at
        FROM app.findings f
        LEFT JOIN app.users u ON u.tenant_id = f.tenant_id AND u.id = f.assigned_to
       ORDER BY f.detected_at DESC
       LIMIT ${LIST_LIMIT.findings}`;
    const correctiveActions = await sql<CorrectiveRow[]>`
      SELECT c.id, c.finding_id, f.title AS finding_title, c.root_cause, c.action, c.owner_user_id,
             o.display_name AS owner_name, c.due_date::text AS due_date,
             to_char(c.completed_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS completed_at,
             c.effectiveness_result,
             to_char(c.effectiveness_reviewed_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS effectiveness_reviewed_at,
             r.display_name AS reviewer_name
        FROM app.corrective_actions c
        JOIN app.findings f ON f.tenant_id = c.tenant_id AND f.id = c.finding_id
        LEFT JOIN app.users o ON o.tenant_id = c.tenant_id AND o.id = c.owner_user_id
        LEFT JOIN app.users r ON r.tenant_id = c.tenant_id AND r.id = c.effectiveness_reviewed_by
       ORDER BY c.created_at DESC
       LIMIT ${LIST_LIMIT.correctiveActions}`;
    const reviewRows = await sql<Omit<ReviewRow, 'outputs'>[]>`
      SELECT m.id, m.fiscal_year, m.held_on::text AS held_on, m.chaired_by, u.display_name AS chair_name,
             coalesce(m.minutes_md, '') AS minutes_md,
             (SELECT count(*)::int FROM app.approvals ap
               WHERE ap.tenant_id = m.tenant_id AND ap.target_type = 'management_review' AND ap.target_id = m.id) AS approved_count,
             (SELECT to_char(max(ap.approved_at) AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI') FROM app.approvals ap
               WHERE ap.tenant_id = m.tenant_id AND ap.target_type = 'management_review' AND ap.target_id = m.id) AS last_approved_at
        FROM app.management_reviews m
        LEFT JOIN app.users u ON u.tenant_id = m.tenant_id AND u.id = m.chaired_by
       ORDER BY m.fiscal_year DESC`;
    const outputs = await sql<{ id: string; review_id: string; decision: string; owner_name: string | null; due_date: string; status: string }[]>`
      SELECT o.id, o.review_id, o.decision, u.display_name AS owner_name, o.due_date::text AS due_date, o.status
        FROM app.management_review_outputs o
        LEFT JOIN app.users u ON u.tenant_id = o.tenant_id AND u.id = o.owner_user_id
       ORDER BY o.due_date`;
    const reviews: ReviewRow[] = reviewRows.map((r) => ({
      ...r,
      outputs: outputs
        .filter((o) => o.review_id === r.id)
        .map((o) => ({ id: o.id, decision: o.decision, owner_name: o.owner_name, due_date: o.due_date, status: o.status })),
    }));
    const effectiveness = await sql<EffectivenessRow[]>`
      SELECT e.id, e.measure_id, m.measure_key, m.name AS measure_name, e.criteria,
             e.evaluated_on::text AS evaluated_on, e.result, u.display_name AS evaluator_name, e.evidence_note
        FROM app.control_effectiveness e
        JOIN app.measures m ON m.tenant_id = e.tenant_id AND m.id = e.measure_id
        LEFT JOIN app.users u ON u.tenant_id = e.tenant_id AND u.id = e.evaluator_user_id
       ORDER BY e.evaluated_on DESC, e.created_at DESC
       LIMIT ${LIST_LIMIT.effectiveness}`;
    const objectives = await sql<ObjectiveRow[]>`
      SELECT o.id, o.fiscal_year, o.title, o.description, o.measure_how, o.target_value,
             u.display_name AS owner_name, o.due_date::text AS due_date, o.status, o.achieved_value,
             to_char(o.evaluated_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS evaluated_at,
             e.display_name AS evaluator_name
        FROM app.security_objectives o
        LEFT JOIN app.users u ON u.tenant_id = o.tenant_id AND u.id = o.owner_user_id
        LEFT JOIN app.users e ON e.tenant_id = o.tenant_id AND e.id = o.evaluated_by
       ORDER BY o.fiscal_year DESC, o.title`;
    // 委託先ごとに最新の評価だけを出す（履歴は app.vendor_assessments に全件ある）。
    const vendors = await sql<VendorRow[]>`
      SELECT v.id, v.name, v.service_name, v.criticality,
             la.assessed_on::text AS last_assessed_on, la.result AS last_result, la.next_due_on::text AS next_due_on,
             (SELECT count(*)::int FROM app.vendor_assessments x WHERE x.tenant_id = v.tenant_id AND x.vendor_id = v.id) AS assessment_count
        FROM app.vendors v
        LEFT JOIN LATERAL (
          SELECT a.assessed_on, a.result, a.next_due_on FROM app.vendor_assessments a
           WHERE a.tenant_id = v.tenant_id AND a.vendor_id = v.id
           ORDER BY a.assessed_on DESC, a.created_at DESC LIMIT 1
        ) la ON true
       ORDER BY v.name`;
    // 鮮度切れ（収集から freshness_days を過ぎた）は、状態が valid のままでも古いと示す。
    const evidences = await sql<EvidenceRow[]>`
      SELECT id, kind, title, object_key,
             to_char(collected_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS collected_at,
             freshness_days, state,
             (collected_at + make_interval(days => freshness_days) < now()) AS stale
        FROM app.evidences
       WHERE deleted_at IS NULL
       ORDER BY collected_at DESC
       LIMIT ${LIST_LIMIT.evidences}`;
    const exceptions = await sql<ExceptionRow[]>`
      SELECT x.id, x.finding_id, f.title AS finding_title, x.reason, x.compensating_control,
             u.display_name AS approver_name,
             to_char(x.approved_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS approved_at,
             to_char(x.expires_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS expires_at,
             (x.expires_at <= now()) AS expired
        FROM app.exceptions x
        JOIN app.findings f ON f.tenant_id = x.tenant_id AND f.id = x.finding_id
        LEFT JOIN app.users u ON u.tenant_id = x.tenant_id AND u.id = x.approved_by
       ORDER BY x.expires_at`;
    // 組織の課題・利害関係者（0065）。有効なものを先に出す（取り下げたものも決定の経緯として残す）。
    const contextIssues = await sql<ContextIssueRow[]>`
      SELECT c.id, c.kind, c.title, c.description, c.isms_impact, c.owner_user_id, u.display_name AS owner_name,
             c.reviewed_on::text AS reviewed_on, c.status
        FROM app.context_issues c
        LEFT JOIN app.users u ON u.tenant_id = c.tenant_id AND u.id = c.owner_user_id
       ORDER BY (c.status = 'active') DESC, c.kind, c.title`;
    const interestedParties = await sql<InterestedPartyRow[]>`
      SELECT p.id, p.name, p.category, p.requirements, p.addressed_in_isms, p.owner_user_id, u.display_name AS owner_name,
             p.reviewed_on::text AS reviewed_on, p.status
        FROM app.interested_parties p
        LEFT JOIN app.users u ON u.tenant_id = p.tenant_id AND u.id = p.owner_user_id
       ORDER BY (p.status = 'active') DESC, p.category, p.name`;
    // 法令・規制・契約上の要求事項（0066）。応える統制・証跡と、適合の評価を一緒に出す。
    const legalRequirements = await sql<LegalRequirementRow[]>`
      SELECT l.id, l.kind, l.title, l.requirement, l.source_ref, l.owner_user_id, u.display_name AS owner_name,
             l.measure_id, l.evidence_id,
             m.measure_key, m.name AS measure_name, e.title AS evidence_title,
             l.compliance_status, l.assessed_on::text AS assessed_on, a.display_name AS assessor_name,
             l.next_review_on::text AS next_review_on, l.status
        FROM app.legal_requirements l
        LEFT JOIN app.users u    ON u.tenant_id = l.tenant_id AND u.id = l.owner_user_id
        LEFT JOIN app.users a    ON a.tenant_id = l.tenant_id AND a.id = l.assessed_by
        LEFT JOIN app.measures m ON m.tenant_id = l.tenant_id AND m.id = l.measure_id
        -- 削除した証跡は「証跡あり」と見せない（今ある証跡と取り違えないように）。
        LEFT JOIN app.evidences e ON e.tenant_id = l.tenant_id AND e.id = l.evidence_id AND e.deleted_at IS NULL
       ORDER BY (l.status = 'active') DESC, l.kind, l.title`;
    // 事業継続の計画（0068）。最後の試験・試験の回数は、実施日が今日までの試験だけから取る（予定を実施として数えない）。
    const continuityPlans = await sql<ContinuityPlanRow[]>`
      SELECT p.id, p.title, p.scope, p.rto_hours, p.rpo_hours, p.procedure_location, p.owner_user_id,
             u.display_name AS owner_name, p.next_test_due::text AS next_test_due, p.status,
             lt.tested_on::text AS last_tested_on, lt.result AS last_result,
             (SELECT count(*)::int FROM app.continuity_tests x
               WHERE x.tenant_id = p.tenant_id AND x.plan_id = p.id AND x.tested_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date) AS test_count
        FROM app.continuity_plans p
        LEFT JOIN app.users u ON u.tenant_id = p.tenant_id AND u.id = p.owner_user_id
        LEFT JOIN LATERAL (
          SELECT t.tested_on, t.result FROM app.continuity_tests t
           WHERE t.tenant_id = p.tenant_id AND t.plan_id = p.id AND t.tested_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
           ORDER BY t.tested_on DESC, t.created_at DESC LIMIT 1
        ) lt ON true
       ORDER BY (p.status = 'active') DESC, p.title`;
    const continuityTests = await sql<ContinuityTestRow[]>`
      SELECT t.id, p.title AS plan_title, t.tested_on::text AS tested_on, t.method, t.result, t.rto_met,
             t.findings_note, u.display_name AS performer_name, e.title AS evidence_title
        FROM app.continuity_tests t
        JOIN app.continuity_plans p ON p.tenant_id = t.tenant_id AND p.id = t.plan_id
        LEFT JOIN app.users u ON u.tenant_id = t.tenant_id AND u.id = t.performed_by
        LEFT JOIN app.evidences e ON e.tenant_id = t.tenant_id AND e.id = t.evidence_id AND e.deleted_at IS NULL
       ORDER BY t.tested_on DESC, t.created_at DESC
       LIMIT ${LIST_LIMIT.continuityTests}`;
    // 脆弱性（0069）。開いているもの（検知・対応中）を先に、重大度の高い順・期限の近い順に出す。
    const vulnerabilities = await sql<VulnerabilityRow[]>`
      SELECT v.id, v.title, v.identifier, v.source, v.asset_id, a.asset_key, a.name AS asset_name, v.severity,
             v.detected_on::text AS detected_on, v.due_date::text AS due_date, v.status,
             v.resolved_on::text AS resolved_on, v.resolution_note, v.owner_user_id, u.display_name AS owner_name
        FROM app.vulnerabilities v
        LEFT JOIN app.assets a ON a.tenant_id = v.tenant_id AND a.id = v.asset_id
        LEFT JOIN app.users u  ON u.tenant_id = v.tenant_id AND u.id = v.owner_user_id
       ORDER BY (v.status IN ('open','in_progress')) DESC,
                CASE v.severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
                v.due_date NULLS LAST, v.detected_on DESC
       LIMIT ${LIST_LIMIT.vulnerabilities}`;
    // 脆弱性を結べる資産は、有効なものだけ。
    const assets = await sql<AssetOption[]>`
      SELECT id, asset_key, name FROM app.assets WHERE status = 'active' ORDER BY asset_key`;
    // 変更の申請（0070）。判断を待っているもの・承認済み（実施待ち）を先に出す。
    const changeRequests = await sql<ChangeRequestRow[]>`
      SELECT c.id, c.title, c.description, c.impact, c.risk_level, c.rollback_plan, c.asset_id,
             a.asset_key, a.name AS asset_name, c.planned_on::text AS planned_on, c.requested_by,
             rq.display_name AS requester_name,
             to_char(c.requested_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS requested_at, c.status,
             d.display_name AS decider_name, to_char(c.decided_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS decided_at,
             c.decision_note, im.display_name AS implementer_name,
             to_char(c.implemented_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD') AS implemented_at, c.result_note
        FROM app.change_requests c
        LEFT JOIN app.assets a ON a.tenant_id = c.tenant_id AND a.id = c.asset_id
        LEFT JOIN app.users rq ON rq.tenant_id = c.tenant_id AND rq.id = c.requested_by
        LEFT JOIN app.users d  ON d.tenant_id = c.tenant_id AND d.id = c.decided_by
        LEFT JOIN app.users im ON im.tenant_id = c.tenant_id AND im.id = c.implemented_by
       ORDER BY CASE c.status WHEN 'requested' THEN 0 WHEN 'approved' THEN 1 ELSE 2 END, c.requested_at DESC
       LIMIT ${LIST_LIMIT.changeRequests}`;
    const people = await sql<Person[]>`
      SELECT u.id, u.display_name, u.email FROM app.users u
       WHERE u.status = 'active'
         -- 担当に選べるのは所属を外されていない人だけ（サーバーアクションの確認と揃える）。
         AND EXISTS (SELECT 1 FROM app.memberships ms
                      WHERE ms.tenant_id = u.tenant_id AND ms.user_id = u.id AND ms.revoked_at IS NULL)
       ORDER BY u.display_name`;
    // 監査人は監査人ロールを持つ有効な利用者（兼任禁止は DB が守る）。
    const auditors = await sql<Person[]>`
      SELECT DISTINCT u.id, u.display_name, u.email
        FROM app.users u
        JOIN app.memberships ms ON ms.tenant_id = u.tenant_id AND ms.user_id = u.id
       WHERE u.status = 'active' AND ms.role_key = 'auditor' AND ms.revoked_at IS NULL
       ORDER BY u.display_name`;
    const measures = await sql<MeasureOption[]>`
      SELECT id, measure_key, name FROM app.measures WHERE status <> 'retired' ORDER BY measure_key`;
    return {
      audits, findings, correctiveActions, reviews, effectiveness,
      objectives, vendors, evidences, exceptions, contextIssues, interestedParties, legalRequirements, continuityPlans, continuityTests,
      vulnerabilities, assets, changeRequests, people, auditors, measures,
    };
  });
}

/**
 * 画面を開いている本人（役割と利用者 ID）。読めなければ null。
 * 記録の一覧は共有のテナントセッションで読むので、「本人の申請か」はそこでは分からない。
 * 本人の経路（プロキシの本人性）で読み、画面の出し分けをサーバーの検査（申請者は判断しない等）とそろえる。
 */
export async function getRecordsActor(): Promise<{ role: string; userId: string } | null> {
  const r = await withTenantActor(async (sql) => {
    const rows = await sql<{ role: string; user_id: string }[]>`
      SELECT app.current_management_role() AS role, app.current_session_user()::text AS user_id`;
    return rows[0] ? { role: rows[0].role, userId: rows[0].user_id } : null;
  });
  return r.ok ? r.data : null;
}

/** 画面を開いている本人の役割（owner/admin/manager/member/auditor/none）。読めなければ null（書き込みは DB が別途確かめる）。 */
export async function getRecordsActorRole(): Promise<string | null> {
  const r = await withTenantActor(async (sql) => {
    const rows = await sql<{ role: string }[]>`SELECT app.current_management_role() AS role`;
    return rows[0]?.role ?? null;
  });
  return r.ok ? r.data : null;
}
