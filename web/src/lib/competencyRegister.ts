import 'server-only';

import { withTenant, type TenantReadResult } from './tenant';

export type FulfillmentStatus = '充足' | '育成中' | '未充足';

export type RequirementRow = {
  id: string;
  role: string;
  required_competency: string;
  description: string;
};

export type FulfillmentRow = {
  id: string;
  requirement_id: string;
  role: string;
  required_competency: string;
  member_id: string;
  member_name: string;
  status: FulfillmentStatus;
  evidence_ref: string;
  assessed_on: string;
  evidence_needs_review: boolean;
};

export type MemberOption = { id: string; display_name: string };

export type TrainingEvidenceOption = {
  training_id: string;
  user_id: string;
  evidence_ref: string;
  label: string;
};

export type RequirementSummary = {
  requirement_id: string;
  role: string;
  required_competency: string;
  fulfilled_count: number;
  total_count: number;
};

export type CompetencyWorkspaceData = {
  requirements: RequirementRow[];
  fulfillments: FulfillmentRow[];
  members: MemberOption[];
  summaries: RequirementSummary[];
  trainingEvidence: TrainingEvidenceOption[];
};

export async function getCompetencyWorkspace(): Promise<TenantReadResult<CompetencyWorkspaceData>> {
  return withTenant(async (sql) => {
    const requirements = await sql<RequirementRow[]>`
      SELECT id, role, required_competency, description
        FROM app.competency_requirements
       ORDER BY role, required_competency`;

    const fulfillments = await sql<FulfillmentRow[]>`
      SELECT f.id, f.requirement_id, r.role, r.required_competency,
             f.member_id, u.display_name AS member_name,
             CASE WHEN f.training_id IS NOT NULL AND tr.evaluation_status <> '有効'
                    THEN '育成中' ELSE f.status END AS status,
             f.evidence_ref, f.assessed_on::text,
             (f.training_id IS NOT NULL AND tr.evaluation_status <> '有効') AS evidence_needs_review
        FROM app.competency_fulfillments f
        JOIN app.competency_requirements r
          ON r.tenant_id = f.tenant_id AND r.id = f.requirement_id
        JOIN app.users u ON u.tenant_id = f.tenant_id AND u.id = f.member_id
        LEFT JOIN app.training_records tr
          ON tr.tenant_id=f.tenant_id AND tr.training_id=f.training_id
         AND tr.user_id=f.training_user_id
       ORDER BY r.role, r.required_competency, u.display_name`;

    const members = await sql<MemberOption[]>`
      SELECT id, display_name FROM app.users WHERE status = 'active' ORDER BY display_name`;

    const trainingEvidence = await sql<TrainingEvidenceOption[]>`
      SELECT tr.training_id, tr.user_id, tr.evidence_ref,
             t.title || ' / ' || u.display_name || ' / ' || tr.completed_at::text AS label
        FROM app.training_records tr
        JOIN app.trainings t
          ON t.tenant_id = tr.tenant_id AND t.id = tr.training_id
        JOIN app.users u
          ON u.tenant_id = tr.tenant_id AND u.id = tr.user_id
       WHERE tr.evaluation_status = '有効' AND tr.evidence_ref <> ''
       ORDER BY tr.completed_at DESC NULLS LAST, t.title`;

    // 役割ごとの充足率(受入条件C3: 未充足人数がひと目でわかる)。
    // 「必要な人数」の定義が無いため、分母は「その役割の力量要件に対して
    // 充足状況が記録されているメンバー数」とする(まだ記録が無いメンバーは
    // 分母に含めない。母数の恣意的な仮定を避ける)。
    const summaries = await sql<RequirementSummary[]>`
      SELECT r.id AS requirement_id, r.role, r.required_competency,
             count(*) FILTER (
               WHERE f.status = '充足'
                 AND (f.training_id IS NULL OR tr.evaluation_status = '有効')
             )::int AS fulfilled_count,
             count(f.id)::int AS total_count
        FROM app.competency_requirements r
        LEFT JOIN app.competency_fulfillments f
          ON f.tenant_id = r.tenant_id AND f.requirement_id = r.id
        LEFT JOIN app.training_records tr
          ON tr.tenant_id=f.tenant_id AND tr.training_id=f.training_id
         AND tr.user_id=f.training_user_id
       GROUP BY r.id, r.role, r.required_competency
       ORDER BY r.role, r.required_competency`;

    return { requirements, fulfillments, members, summaries, trainingEvidence };
  });
}
