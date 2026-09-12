'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';

// Follows the UUID format validation established in organization/actions.ts. Do not leave an invalid UUID from tampered FormData
// to fall through to a ::uuid cast failure (reason='error').
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuidText = (form: FormData, key: string): string => {
  const value = String(form.get(key) ?? '').trim();
  if (!value || !UUID_RE.test(value)) throw new Error(`${key} の形式が不正です`);
  return value;
};

function parseOrRedirect<T>(parse: () => T): T {
  try {
    return parse();
  } catch {
    redirect('/analysis?error=invalid_input');
  }
}

type ScenarioComparison = {
  risk_scenario_id: string;
  after_snapshot_id: string;
  after_level: number;
  after_assessed_on: string;
  without_measure_snapshot_id: string | null;
  without_measure_level: number | null;
  without_measure_stage: 'before_measure' | 'inherent' | null;
  without_measure_assessed_on: string | null;
  // Keys of measures other than the target measure that have after_measure for the same risk scenario.
  // If non-empty, because before_measure/inherent are recorded per scenario,
  // this simulation's value may be not "removing only the target measure" but "removing all measures
  // of this scenario" (Codex review 2026-09-03,
  // 3rd finding). Disclose this without distorting the numbers.
  other_measures_on_scenario: string[];
};

export async function runSimulation(form: FormData) {
  const { excludedMeasureId } = parseOrRedirect(() => ({
    excludedMeasureId: uuidText(form, 'excluded_measure_id'),
  }));

  const result = await withTenantWrite(async (sql) => {
    // Check that the measure exists (the FK separately enforces no cross-tenant references, but whether the target
    // exists in the current tenant is checked here first to return a friendly error).
    // Also check status <> 'retired'. Retired measures are already excluded from the select options, but
    // the path where a tampered form or a stale page sends a retired measure's ID
    // is blocked on the server side too (Codex review 2026-09-03, 2nd finding).
    const measure = await sql<{ id: string }[]>`
      SELECT id FROM app.measures
       WHERE tenant_id = app.current_tenant() AND id = ${excludedMeasureId}::uuid
         AND status <> 'retired'`;
    if (measure.length === 0) return 'measure_not_found' as const;

    // Design decision 2026-09-03: the counterfactual of removing a measure is exactly the risk_level difference in app.risk_evaluation_
    // snapshots (0027) between after_measure (with the measure) and before_measure/inherent
    // (without the measure). No time-series or implementation-period data is needed.
    // Follows the convention established in riskRegister.ts of treating only rows with assessed_on <= today (JST) as
    // current (future dates are targets not yet reached). For each risk scenario,
    // take one row each: the latest after_measure (limited to the target measure) and the latest before_measure (or,
    // if none, inherent). Retired risk scenarios are excluded
    // (Codex review 2026-09-03, 3rd finding). The snapshot id is also used as the final tie-break so that
    // selection among ties (same assessed_on and created_at) is deterministic
    // (same finding: for reproducibility).
    const rows = await sql<ScenarioComparison[]>`
      WITH target_scenarios AS (
        SELECT DISTINCT s.risk_scenario_id
          FROM app.risk_evaluation_snapshots s
          JOIN app.risk_scenarios rs
            ON rs.tenant_id = s.tenant_id AND rs.id = s.risk_scenario_id AND rs.status = 'active'
         WHERE s.tenant_id = app.current_tenant()
           AND s.measure_id = ${excludedMeasureId}::uuid
           AND s.stage = 'after_measure'
           AND s.assessed_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
      ), after_latest AS (
        SELECT DISTINCT ON (s.risk_scenario_id)
               s.risk_scenario_id, s.id AS snapshot_id, s.risk_level, s.assessed_on::text AS assessed_on
          FROM app.risk_evaluation_snapshots s
          JOIN target_scenarios ts ON ts.risk_scenario_id = s.risk_scenario_id
         WHERE s.tenant_id = app.current_tenant()
           AND s.measure_id = ${excludedMeasureId}::uuid
           AND s.stage = 'after_measure'
           AND s.assessed_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
         ORDER BY s.risk_scenario_id, s.assessed_on DESC, s.created_at DESC, s.id DESC
      ), without_measure_latest AS (
        -- before_measureをinherentより優先する(施策が無い状態としてより
        -- 具体的な評価のため)。ORDER BYの(stage='before_measure')DESCで
        -- before_measureがある場合はそちらを、無ければinherentを選ぶ。
        SELECT DISTINCT ON (s.risk_scenario_id)
               s.risk_scenario_id, s.id AS snapshot_id, s.risk_level, s.stage, s.assessed_on::text AS assessed_on
          FROM app.risk_evaluation_snapshots s
          JOIN target_scenarios ts ON ts.risk_scenario_id = s.risk_scenario_id
         WHERE s.tenant_id = app.current_tenant()
           AND s.stage IN ('before_measure', 'inherent')
           AND s.assessed_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
         ORDER BY s.risk_scenario_id, (s.stage = 'before_measure') DESC,
                  s.assessed_on DESC, s.created_at DESC, s.id DESC
      ), other_measures AS (
        -- before_measure/inherentは施策単位ではなくリスクシナリオ単位の
        -- 記録。同じシナリオに対象施策以外の「現在有効な対応」があれば、
        -- この比較は「対象施策だけを外す」ではなく「このシナリオに
        -- 現在対応している施策すべてを外す」場合の値になっている可能性が
        -- ある。C1(重複分析)のcurrent_treatmentsと同じ「現在有効な対応」の
        -- 定義(risk_treatments経由、取消・過去版・失効・未来開始・退役
        -- 施策を除く)を使う(Codexレビュー2026-09-03 4回目指摘: after_measure
        -- の存在だけで判定すると、まだafter_measureが記録されていない
        -- 現行施策を見落とし、退役済み施策の古いafter_measureを誤検出
        -- していた)。存在確認のみ行い、結果側で開示する(除外や補正はしない)。
        SELECT DISTINCT ra.risk_scenario_id, m.measure_key
          FROM app.risk_treatments rt
          JOIN app.risk_assessments ra ON ra.tenant_id = rt.tenant_id AND ra.id = rt.risk_assessment_id
          JOIN target_scenarios ts ON ts.risk_scenario_id = ra.risk_scenario_id
          JOIN app.measures m ON m.tenant_id = rt.tenant_id AND m.id = rt.measure_id AND m.status <> 'retired'
         WHERE rt.tenant_id = app.current_tenant()
           AND rt.measure_id IS NOT NULL
           AND rt.measure_id <> ${excludedMeasureId}::uuid
           AND rt.status <> 'cancelled'
           AND rt.recorded_until IS NULL
           AND rt.valid_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
           AND (rt.valid_to IS NULL OR rt.valid_to > (now() AT TIME ZONE 'Asia/Tokyo')::date)
           AND ra.status = 'approved'
           AND ra.recorded_until IS NULL
           AND ra.valid_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
           AND (ra.valid_to IS NULL OR ra.valid_to > (now() AT TIME ZONE 'Asia/Tokyo')::date)
      )
      SELECT ts.risk_scenario_id,
             a.snapshot_id AS after_snapshot_id, a.risk_level AS after_level, a.assessed_on AS after_assessed_on,
             w.snapshot_id AS without_measure_snapshot_id, w.risk_level AS without_measure_level,
             w.stage AS without_measure_stage, w.assessed_on AS without_measure_assessed_on,
             coalesce(array_agg(DISTINCT om.measure_key) FILTER (WHERE om.measure_key IS NOT NULL), '{}')
               AS other_measures_on_scenario
        FROM target_scenarios ts
        JOIN after_latest a ON a.risk_scenario_id = ts.risk_scenario_id
        LEFT JOIN without_measure_latest w ON w.risk_scenario_id = ts.risk_scenario_id
        LEFT JOIN other_measures om ON om.risk_scenario_id = ts.risk_scenario_id
       GROUP BY ts.risk_scenario_id, a.snapshot_id, a.risk_level, a.assessed_on,
                w.snapshot_id, w.risk_level, w.stage, w.assessed_on`;

    // C4: if the target measure has no after_measure snapshot, it cannot be computed
    // (normally unreachable because the page filters by simulatableMeasures, but in case of
    // races where data changes after the options were generated, or tampered forms, it is checked on the server side
    // too).
    if (rows.length === 0) return 'insufficient_data' as const;

    // Silently excluding scenarios without a comparison baseline (before_measure/inherent) and saving a partial
    // aggregate makes the total look smaller than it really is (Codex review
    // 2026-09-03, 3rd finding). If even one baseline is missing, reject the simulation for the whole
    // target measure (do not produce numbers).
    const missingBaseline = rows.some((r) => r.without_measure_level === null);
    if (missingBaseline) return 'missing_baseline_data' as const;
    // This is right after confirming missingBaseline is false, so at this point without_measure_*
    // is guaranteed non-null in every row. From here on it is handled with types that assume this.
    const comparisons = rows.map((r) => ({
      ...r,
      without_measure_level: r.without_measure_level as number,
      without_measure_stage: r.without_measure_stage as 'before_measure' | 'inherent',
      without_measure_assessed_on: r.without_measure_assessed_on as string,
    }));

    // Removing a measure is a counterfactual in the direction of removing defenses, so the risk_level after removal (without the measure)
    // should be at least the current one (with the measure). If even one evaluation record is inverted,
    // reject it as a record inconsistency without producing numbers (design decision
    // 2026-09-03: handling of "inconsistent evaluation values". Nothing is written to the DB).
    const inconsistent = comparisons.some((c) => c.without_measure_level < c.after_level);
    if (inconsistent) return 'inconsistent_data' as const;

    // after_measure and before_measure/inherent each fetch the "latest evaluation"
    // independently, so there is no guarantee they are from the same evaluation cycle or the same day
    // (this schema has no column linking a cycle). If the baseline evaluation date is
    // after the post-measure evaluation date (= a baseline evaluation newer than the post-measure one was done separately),
    // evaluations from different points in time may be being compared, so disclose it
    // (Codex review 2026-09-03, 5th finding. Without changing the architecture, judging whether
    // the numbers are valid is left to the user).
    //
    // Note (Codex review 2026-09-03, 6th finding; considered and rejected): the alternative "disclose everything unless
    // the dates match exactly (!==)" was considered but not adopted.
    // A baseline (before_measure/inherent) dated earlier than the post-measure evaluation (after_measure)
    // is simply the normal ISMS evaluation flow of "evaluate before the measure -> implement the measure -> re-evaluate after",
    // so differing dates are themselves normal and hold in the vast majority
    // of cases. With !==, even this ordinary case would every time
    // be shown as "evaluation timing mismatch", and the case that truly needs attention, where the baseline
    // is newer than the post-measure evaluation (inverted), would be buried among the warnings
    // (alert fatigue). Keep it one-directional, disclosing only when the baseline is newer than
    // the post-measure evaluation.
    const withStaleBaselineFlag = comparisons.map((c) => ({
      ...c,
      baseline_newer_than_after: c.without_measure_assessed_on > c.after_assessed_on,
    }));

    const scenarioCount = withStaleBaselineFlag.length;
    const afterSum = withStaleBaselineFlag.reduce((sum, c) => sum + c.after_level, 0);
    const withoutSum = withStaleBaselineFlag.reduce((sum, c) => sum + c.without_measure_level, 0);

    await sql`
      INSERT INTO app.simulation_runs
        (tenant_id, excluded_measure_id, scenario_count, after_measure_risk_level_sum,
         without_measure_risk_level_sum, scenario_breakdown, method, run_by)
      VALUES
        (app.current_tenant(), ${excludedMeasureId}::uuid, ${scenarioCount}, ${afterSum}, ${withoutSum},
         ${sql.json(withStaleBaselineFlag)}, 'risk_level_after_vs_before_or_inherent', app.current_session_user())`;
    return 'ok' as const;
  });
  if (!result.ok) redirect(`/analysis?error=${result.reason}`);
  if (result.data !== 'ok') redirect(`/analysis?error=${result.data}`);
  revalidatePath('/analysis');
  redirect('/analysis?saved=1');
}
