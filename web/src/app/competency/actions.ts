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

// 0037(cost)のCodexレビューで確立した方針をそのまま踏襲する:
// フォームはHTML5 date inputでYYYY-MM-DDを保証するが、改ざん可能なので
// サーバー側でも形式・実在日付を検証する。
const isoDate = (form: FormData, key: string, label: string): string => {
  const raw = text(form, key, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) throw new Error(`${label} はYYYY-MM-DD形式で入力してください`);
  const d = new Date(`${raw}T00:00:00Z`);
  const [y, m, day] = raw.split('-').map(Number);
  if (d.getUTCFullYear() !== y || d.getUTCMonth() + 1 !== m || d.getUTCDate() !== day) {
    throw new Error(`${label} が実在する日付ではありません`);
  }
  return raw;
};

const STATUSES = ['充足', '育成中', '未充足'] as const;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const route = (form: FormData, value: string): string => {
  const mode = form.get('mode');
  return mode === 'isms' || mode === 'risk'
    ? `${value}${value.includes('?') ? '&' : '?'}mode=${mode}`
    : value;
};

export async function saveRequirement(form: FormData) {
  const role = text(form, 'role', 100);
  const requiredCompetency = text(form, 'required_competency', 200);
  const description = optionalText(form, 'description', 2000) ?? '';
  const result = await withTenantWrite(async (sql) => {
    // rate_master(0037)と違い、要件定義は他の計算が過去分を遡って参照する
    // ものではない(単なる定義テキスト)ため、再登録は説明文の更新として
    // 扱ってよい(upsert)。同じ(role, required_competency)への再登録を
    // エラーにする必要はない。
    await sql`
      INSERT INTO app.competency_requirements (tenant_id, role, required_competency, description)
      VALUES (app.current_tenant(), ${role}, ${requiredCompetency}, ${description})
      ON CONFLICT (tenant_id, role, required_competency) DO UPDATE
        SET description = EXCLUDED.description, updated_at = now()`;
  });
  if (!result.ok) redirect(route(form, `/competency?error=${result.reason}`));
  revalidatePath('/competency');
  redirect(route(form, '/competency?saved=1'));
}

export async function saveFulfillment(form: FormData) {
  const requirementId = text(form, 'requirement_id', 80);
  const memberId = text(form, 'member_id', 80);
  const status = text(form, 'status', 20);
  if (!STATUSES.includes(status as (typeof STATUSES)[number])) throw new Error('invalid status');
  const manualEvidenceRef = optionalText(form, 'evidence_ref', 2000) ?? '';
  if (manualEvidenceRef.toLowerCase().startsWith('elearning://')) {
    throw new Error('eLearning evidence must be selected from evaluated records');
  }
  const trainingEvidenceId = optionalText(form, 'training_evidence_id', 100);
  const assessedOn = isoDate(form, 'assessed_on', '確認日');
  const result = await withTenantWrite(async (sql) => {
    let evidenceRef = manualEvidenceRef;
    let evidenceTrainingId: string | null = null;
    let evidenceTrainingUserId: string | null = null;
    if (trainingEvidenceId) {
      const [trainingId, evidenceUserId, extra] = trainingEvidenceId.split(':');
      if (extra || !UUID.test(trainingId) || !UUID.test(evidenceUserId) || evidenceUserId !== memberId) {
        throw new Error('invalid training evidence');
      }
      const evidence = await sql<{ evidence_ref: string }[]>`
        SELECT evidence_ref
          FROM app.training_records
         WHERE training_id=${trainingId}::uuid AND user_id=${memberId}::uuid
           AND evaluation_status='有効' AND evidence_ref <> ''`;
      if (evidence.length !== 1) throw new Error('invalid training evidence');
      evidenceRef = evidence[0].evidence_ref;
      evidenceTrainingId = trainingId;
      evidenceTrainingUserId = memberId;
    }
    // requirement_id・member_idの組は1行に集約する(UNIQUE制約)ので、
    // 既存記録の更新として扱う(充足状況は「今どうか」の一覧のため、
    // 履歴ではなく最新値を保持する設計。0037の重複=拒否とは性質が違う:
    // こちらは同じ組み合わせへの再評価が正常な運用)。
    await sql`
      INSERT INTO app.competency_fulfillments
        (tenant_id, requirement_id, member_id, status, evidence_ref, assessed_on,
         training_id, training_user_id)
      VALUES
        (app.current_tenant(), ${requirementId}::uuid, ${memberId}::uuid, ${status}, ${evidenceRef}, ${assessedOn}::date,
         ${evidenceTrainingId}::uuid, ${evidenceTrainingUserId}::uuid)
      ON CONFLICT (tenant_id, requirement_id, member_id) DO UPDATE
        SET status = EXCLUDED.status, evidence_ref = EXCLUDED.evidence_ref,
            assessed_on = EXCLUDED.assessed_on,
            training_id = EXCLUDED.training_id,
            training_user_id = EXCLUDED.training_user_id,
            updated_at = now()`;
  });
  if (!result.ok) redirect(route(form, `/competency?error=${result.reason}`));
  revalidatePath('/competency');
  redirect(route(form, '/competency?saved=1'));
}
