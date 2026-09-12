import 'server-only';

import { withTenant, type TenantReadResult } from './tenant';

export type RateRow = {
  id: string;
  role: string;
  hourly_rate: string;
  effective_from: string;
  source_note: string;
};

export type EducationRecordRow = {
  id: string;
  program_name: string;
  role: string;
  member_id: string | null;
  member_name: string | null;
  hours: string;
  conducted_on: string;
  related_measure_id: string | null;
  related_measure_name: string | null;
  // The rate_master unit rate that was valid as of the implementation date. If none, unset (rate not registered).
  hourly_rate: string | null;
  // hours × hourly_rate. If no rate is registered, null (not treated as 0 yen = prevents oversights).
  cost_amount: string | null;
  source_note: string;
};

export type MeasureCostRow = {
  id: string;
  measure_key: string;
  name: string;
  budget_amount: string | null;
  education_cost: string;
  total_cost: string;
};

export type MemberOption = { id: string; display_name: string };
export type MeasureOption = { id: string; measure_key: string; name: string };

export type CostWorkspaceData = {
  rates: RateRow[];
  educationRecords: EducationRecordRow[];
  measureCosts: MeasureCostRow[];
  members: MemberOption[];
  measures: MeasureOption[];
};

export async function getCostWorkspace(): Promise<TenantReadResult<CostWorkspaceData>> {
  return withTenant(async (sql) => {
    const rates = await sql<RateRow[]>`
      SELECT id, role, hourly_rate, effective_from::text, source_note
        FROM app.rate_master
       ORDER BY role, effective_from DESC`;

    const educationRecords = await sql<EducationRecordRow[]>`
      SELECT er.id, er.program_name, er.role, er.member_id, u.display_name AS member_name,
             er.hours, er.conducted_on::text, er.related_measure_id, m.name AS related_measure_name,
             rm.hourly_rate,
             CASE WHEN rm.hourly_rate IS NULL THEN NULL ELSE er.hours * rm.hourly_rate END AS cost_amount,
             er.source_note
        FROM app.education_records er
        LEFT JOIN app.users u ON u.tenant_id = er.tenant_id AND u.id = er.member_id
        LEFT JOIN app.measures m ON m.tenant_id = er.tenant_id AND m.id = er.related_measure_id
        LEFT JOIN LATERAL (
          -- 実施日(conducted_on)時点で有効だった単価を引く。「今の単価」ではなく
          -- 「その工数が発生した当時の単価」でコストを計算する(過去の記録を
          -- 単価改定のたびに書き換えない、という追記型の考え方に合わせる)。
          SELECT hourly_rate FROM app.rate_master rmm
           WHERE rmm.tenant_id = er.tenant_id AND rmm.role = er.role
             AND rmm.effective_from <= er.conducted_on
           ORDER BY rmm.effective_from DESC
           LIMIT 1
        ) rm ON true
       ORDER BY er.conducted_on DESC, er.created_at DESC`;

    const measureCosts = await sql<MeasureCostRow[]>`
      SELECT m.id, m.measure_key, m.name, m.budget_amount,
             coalesce(edu.education_cost, 0) AS education_cost,
             coalesce(m.budget_amount, 0) + coalesce(edu.education_cost, 0) AS total_cost
        FROM app.measures m
        LEFT JOIN (
          SELECT er.related_measure_id, sum(er.hours * rm.hourly_rate) AS education_cost
            FROM app.education_records er
            JOIN LATERAL (
              SELECT hourly_rate FROM app.rate_master rmm
               WHERE rmm.tenant_id = er.tenant_id AND rmm.role = er.role
                 AND rmm.effective_from <= er.conducted_on
               ORDER BY rmm.effective_from DESC
               LIMIT 1
            ) rm ON true
           WHERE er.related_measure_id IS NOT NULL
           GROUP BY er.related_measure_id
        ) edu ON edu.related_measure_id = m.id
       WHERE m.status <> 'retired'
       ORDER BY m.measure_key`;

    const members = await sql<MemberOption[]>`
      SELECT id, display_name FROM app.users WHERE status = 'active' ORDER BY display_name`;

    const measures = await sql<MeasureOption[]>`
      SELECT id, measure_key, name FROM app.measures WHERE status <> 'retired' ORDER BY measure_key`;

    return { rates, educationRecords, measureCosts, members, measures };
  });
}
