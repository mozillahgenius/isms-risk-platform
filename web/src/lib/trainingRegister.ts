import 'server-only';

import { withTenant, type TenantReadResult } from './tenant';

export type TrainingRecordRow = {
  training_id: string;
  user_id: string;
  course_title: string;
  course_tags: string[];
  member_name: string;
  member_email: string;
  completed_at: string;
  score: number | null;
  evidence_ref: string;
  evaluation_status: '未評価' | '有効' | '要確認' | '対象外';
  imported_at: string | null;
};

export type TrainingWorkspaceData = {
  records: TrainingRecordRow[];
  relevantTags: string[];
  canManage: boolean;
};

export async function getTrainingWorkspace(): Promise<TenantReadResult<TrainingWorkspaceData>> {
  return withTenant(async (sql) => {
    const records = await sql<TrainingRecordRow[]>`
      SELECT tr.training_id, tr.user_id, t.title AS course_title,
             t.tags AS course_tags, u.display_name AS member_name,
             u.email::text AS member_email, tr.completed_at::text,
             tr.score, tr.evidence_ref, tr.evaluation_status,
             tr.imported_at::text
        FROM app.training_records tr
        JOIN app.trainings t
          ON t.tenant_id = tr.tenant_id AND t.id = tr.training_id
        JOIN app.users u
          ON u.tenant_id = tr.tenant_id AND u.id = tr.user_id
       WHERE t.tags && ARRAY['isms','risk-management']::text[]
       ORDER BY tr.completed_at DESC NULLS LAST, t.title, u.display_name`;
    const permissions = await sql<{ can_manage: boolean }[]>`
      SELECT EXISTS (
        SELECT 1 FROM app.memberships m
        JOIN app.users u ON u.tenant_id=m.tenant_id AND u.id=m.user_id
        WHERE m.user_id=app.current_session_user()
          AND m.role_key IN ('ciso','secretariat')
          AND m.revoked_at IS NULL AND u.status='active'
      ) AS can_manage`;
    return {
      records,
      relevantTags: ['isms', 'risk-management'],
      canManage: permissions[0]?.can_manage ?? false,
    };
  });
}
