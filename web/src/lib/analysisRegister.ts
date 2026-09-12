import 'server-only';

import { withTenant, type TenantReadResult } from './tenant';

export type DuplicatePairRow = {
  measure_a_id: string;
  measure_a_key: string;
  measure_a_name: string;
  measure_b_id: string;
  measure_b_key: string;
  measure_b_name: string;
  shared_risk_count: number;
  shared_asset_count: number;
  overlap_score: '高' | '中' | '低';
};

export type MeasureOption = {
  id: string;
  measure_key: string;
  name: string;
};

export type SimulationRunRow = {
  id: string;
  excluded_measure_id: string;
  excluded_measure_name: string;
  scenario_count: number;
  after_measure_risk_level_sum: number;
  without_measure_risk_level_sum: number;
  run_at: string;
  run_by_name: string | null;
  // true if any scenario in scenario_breakdown has a non-empty
  // other_measures_on_scenario. before_measure/inherent are recorded per risk scenario, not per measure,
  // so this indicates the simulation value may reflect "removing all measures
  // on this scenario" rather than "removing only the target measure"
  // (Codex review 2026-09-03, 3rd round).
  has_shared_measures: boolean;
  // true if baseline_newer_than_after is true for any scenario in scenario_breakdown.
  // after_measure and before_measure/inherent each fetch the "latest evaluation" independently,
  // so there is no guarantee they come from the same evaluation cycle; if the baseline
  // side was re-evaluated at a newer date, this indicates we may be comparing evaluations
  // from different points in time (Codex review 2026-09-03, 5th round).
  has_stale_baseline: boolean;
};

export type MeasureIncidentLinkRow = {
  measure_id: string;
  measure_key: string;
  measure_name: string;
  linked_incident_count: number;
};

export type AnalysisWorkspaceData = {
  duplicatePairs: DuplicatePairRow[];
  // Restrict to measures that can be targets of the exclusion simulation (those with a
  // currently valid after_measure snapshot in app.risk_evaluation_snapshots).
  // Acceptance C4: if this is 0, the UI disables it as "not enough data"
  // (design decision 2026-09-03: along with switching the population from app.incidents to risk
  // evaluation snapshots, the threshold also changed to "whether the target measure has an after_measure
  // evaluation").
  simulatableMeasures: MeasureOption[];
  // Distinguishes the reason when simulatableMeasures is 0, so it can be shown accurately
  // (Codex review 2026-09-03, 5th round: the case with no after_measure at all and
  // the case with after_measure present but filtered down for lack of baseline values (before_measure/inherent)
  // to 0 were showing the same disabled message).
  hasAnyAfterMeasureCandidate: boolean;
  totalIncidentCount: number;
  simulationRuns: SimulationRunRow[];
  measureIncidentLinks: MeasureIncidentLinkRow[];
};

// Threshold for overlap analysis (acceptance C1). Per the open items in the detailed spec, how many shared
// items count as "high" is undecided, so it is pinned here as a provisional, adjustable value.
const OVERLAP_HIGH_THRESHOLD = 3;
const OVERLAP_MEDIUM_THRESHOLD = 2;

function scoreOverlap(sharedRiskCount: number, sharedAssetCount: number): '高' | '中' | '低' {
  const combined = sharedRiskCount + sharedAssetCount;
  if (combined >= OVERLAP_HIGH_THRESHOLD) return '高';
  if (combined >= OVERLAP_MEDIUM_THRESHOLD) return '中';
  return '低';
}

export async function getAnalysisWorkspace(): Promise<TenantReadResult<AnalysisWorkspaceData>> {
  return withTenant(async (sql) => {
    // Overlap analysis (C1): whether measures cover the same risk and same asset, aggregated each time
    // from the existing app.risk_treatments (measure -> risk assessment) and app.risk_scenario_assets
    // (risk -> asset) as a live query. No dedicated table is kept
    // (this feature shows current state and does not need to keep history).
    // risk_treatments may have multiple rows (revision history) for the same (measure, risk_scenario) pair,
    // so collapse with DISTINCT. Cancelled (status='cancelled'), past versions superseded by
    // revision (recorded_until IS NOT NULL), expired
    // (valid_to <= today; same exclusive end-date meaning as 0008's EXCLUDE constraint daterange('[)'))
    // and not-yet-started (valid_from > today) rows are not "currently valid treatments"
    // and are excluded (Codex review 2026-09-03: initially these were also picked up as overlaps.
    // The 2nd round also found the missing lower bound on valid_from, unchecked status/validity of
    // risk_assessments themselves, and retired risks/assets not being excluded; all were
    // addressed together).
    type RawPair = {
      measure_a_id: string; measure_a_key: string; measure_a_name: string;
      measure_b_id: string; measure_b_key: string; measure_b_name: string;
      shared_risk_count: number; shared_asset_count: number;
    };
    const rawPairs = await sql<RawPair[]>`
      WITH current_treatments AS (
        SELECT rt.measure_id, ra.risk_scenario_id
          FROM app.risk_treatments rt
          JOIN app.risk_assessments ra ON ra.tenant_id = rt.tenant_id AND ra.id = rt.risk_assessment_id
          JOIN app.risk_scenarios rs ON rs.tenant_id = ra.tenant_id AND rs.id = ra.risk_scenario_id
                                     AND rs.status = 'active'
         WHERE rt.tenant_id = app.current_tenant()
           AND rt.measure_id IS NOT NULL
           AND rt.status <> 'cancelled'
           AND rt.recorded_until IS NULL
           -- valid_toは0008のEXCLUDE制約(daterange(valid_from, valid_to, '[)'))
           -- と同じ終了日排他の意味に統一する: valid_to <= 今日はその日から
           -- 失効扱いのため、有効の条件は valid_to > 今日(以上ではない)
           -- (Codexレビュー2026-09-03 phase-gate指摘)。
           AND rt.valid_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
           AND (rt.valid_to IS NULL OR rt.valid_to > (now() AT TIME ZONE 'Asia/Tokyo')::date)
           -- risk_assessment自体も、改定前の過去版・未承認・未来開始・失効
           -- していないこと(Codexレビュー2026-09-03 phase-gate指摘:
           -- valid_fromの下限漏れでrisk_assessmentだけ未来開始が素通りしていた)。
           AND ra.status = 'approved'
           AND ra.recorded_until IS NULL
           AND ra.valid_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
           AND (ra.valid_to IS NULL OR ra.valid_to > (now() AT TIME ZONE 'Asia/Tokyo')::date)
      ), measure_risks AS (
        SELECT DISTINCT ct.measure_id, ct.risk_scenario_id
          FROM current_treatments ct
          JOIN app.measures m ON m.tenant_id = app.current_tenant() AND m.id = ct.measure_id AND m.status <> 'retired'
      ), measure_assets AS (
        SELECT DISTINCT ct.measure_id, rsa.asset_id
          FROM current_treatments ct
          JOIN app.risk_scenario_assets rsa
            ON rsa.tenant_id = app.current_tenant() AND rsa.risk_scenario_id = ct.risk_scenario_id
          JOIN app.assets ast ON ast.tenant_id = app.current_tenant() AND ast.id = rsa.asset_id
                              AND ast.status = 'active'
          JOIN app.measures m ON m.tenant_id = app.current_tenant() AND m.id = ct.measure_id AND m.status <> 'retired'
      ), risk_overlap AS (
        SELECT a.measure_id AS measure_a, b.measure_id AS measure_b, count(*)::int AS shared_risk_count
          FROM measure_risks a
          JOIN measure_risks b ON b.risk_scenario_id = a.risk_scenario_id AND b.measure_id > a.measure_id
         GROUP BY a.measure_id, b.measure_id
      ), asset_overlap AS (
        SELECT a.measure_id AS measure_a, b.measure_id AS measure_b, count(*)::int AS shared_asset_count
          FROM measure_assets a
          JOIN measure_assets b ON b.asset_id = a.asset_id AND b.measure_id > a.measure_id
         GROUP BY a.measure_id, b.measure_id
      )
      SELECT
        coalesce(r.measure_a, a.measure_a) AS measure_a_id,
        coalesce(r.measure_b, a.measure_b) AS measure_b_id,
        coalesce(r.shared_risk_count, 0) AS shared_risk_count,
        coalesce(a.shared_asset_count, 0) AS shared_asset_count,
        ma.measure_key AS measure_a_key, ma.name AS measure_a_name,
        mb.measure_key AS measure_b_key, mb.name AS measure_b_name
        FROM risk_overlap r
        FULL OUTER JOIN asset_overlap a ON a.measure_a = r.measure_a AND a.measure_b = r.measure_b
        JOIN app.measures ma ON ma.tenant_id = app.current_tenant() AND ma.id = coalesce(r.measure_a, a.measure_a)
        JOIN app.measures mb ON mb.tenant_id = app.current_tenant() AND mb.id = coalesce(r.measure_b, a.measure_b)
       ORDER BY (coalesce(r.shared_risk_count, 0) + coalesce(a.shared_asset_count, 0)) DESC,
                ma.measure_key, mb.measure_key`;

    const duplicatePairs: DuplicatePairRow[] = rawPairs.map((p) => ({
      ...p,
      overlap_score: scoreOverlap(p.shared_risk_count, p.shared_asset_count),
    }));

    // Exclusion simulation (narrowing targets for acceptance C4): only offer as choices measures that have
    // a currently valid (assessed_on <= today JST; same as the "future date = target not yet reached"
    // convention established in riskRegister.ts) after_measure snapshot in app.risk_evaluation_snapshots.
    // Without one there is nothing to compare against even if run, so it cannot be computed
    // (design decision 2026-09-03: the population was switched here from app.incidents).
    // Additionally, if even one target scenario lacks before_measure/inherent,
    // actions.ts rejects with missing_baseline_data. The DB save is prevented, but
    // "shown as a choice yet fails when pressed" falls short of C4's intent to "explicitly
    // disable at choice-generation time", so only measures whose comparison baselines exist for all
    // scenarios are offered as choices (Codex review 2026-09-03, 4th round).
    const simulatableMeasures = await sql<MeasureOption[]>`
      WITH after_scenarios AS (
        SELECT DISTINCT s.measure_id, s.risk_scenario_id
          FROM app.risk_evaluation_snapshots s
          JOIN app.risk_scenarios rs
            ON rs.tenant_id = s.tenant_id AND rs.id = s.risk_scenario_id AND rs.status = 'active'
         WHERE s.tenant_id = app.current_tenant() AND s.stage = 'after_measure'
           AND s.assessed_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
           AND s.measure_id IS NOT NULL
      ), baseline_scenarios AS (
        SELECT DISTINCT risk_scenario_id
          FROM app.risk_evaluation_snapshots
         WHERE tenant_id = app.current_tenant() AND stage IN ('before_measure', 'inherent')
           AND assessed_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
      )
      SELECT DISTINCT m.id, m.measure_key, m.name
        FROM app.measures m
        JOIN after_scenarios asc1 ON asc1.measure_id = m.id
       WHERE m.tenant_id = app.current_tenant() AND m.status <> 'retired'
         AND NOT EXISTS (
           SELECT 1 FROM after_scenarios asc2
            WHERE asc2.measure_id = m.id
              AND asc2.risk_scenario_id NOT IN (SELECT risk_scenario_id FROM baseline_scenarios)
         )
       ORDER BY m.measure_key`;

    const [{ exists: hasAnyAfterMeasureCandidate }] = await sql<{ exists: boolean }[]>`
      SELECT EXISTS (
        SELECT 1
          FROM app.risk_evaluation_snapshots s
          JOIN app.risk_scenarios rs
            ON rs.tenant_id = s.tenant_id AND rs.id = s.risk_scenario_id AND rs.status = 'active'
          JOIN app.measures m ON m.tenant_id = s.tenant_id AND m.id = s.measure_id AND m.status <> 'retired'
         WHERE s.tenant_id = app.current_tenant() AND s.stage = 'after_measure'
           AND s.assessed_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
      ) AS exists`;

    const [{ n: totalIncidentCount }] = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM app.incidents WHERE tenant_id = app.current_tenant()`;

    const simulationRuns = await sql<SimulationRunRow[]>`
      SELECT s.id, s.excluded_measure_id, m.name AS excluded_measure_name,
             s.scenario_count, s.after_measure_risk_level_sum, s.without_measure_risk_level_sum,
             to_char(s.run_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI') AS run_at,
             u.display_name AS run_by_name,
             EXISTS (
               SELECT 1 FROM jsonb_array_elements(s.scenario_breakdown) elem
                WHERE jsonb_array_length(elem -> 'other_measures_on_scenario') > 0
             ) AS has_shared_measures,
             EXISTS (
               SELECT 1 FROM jsonb_array_elements(s.scenario_breakdown) elem
                WHERE (elem -> 'baseline_newer_than_after')::boolean
             ) AS has_stale_baseline
        FROM app.simulation_runs s
        JOIN app.measures m ON m.tenant_id = s.tenant_id AND m.id = s.excluded_measure_id
        LEFT JOIN app.users u ON u.tenant_id = s.tenant_id AND u.id = s.run_by
       ORDER BY s.run_at DESC
       LIMIT 50`;

    // Reference panel (demoted from "simulation" by design decision 2026-09-03;
    // live query only, no dedicated run records): for each measure, lists the number of
    // items currently linked via app.incidents.related_measure_id.
    // It does not predict "what happens if the measure is removed"; it is the actual current linkage.
    const measureIncidentLinks = await sql<MeasureIncidentLinkRow[]>`
      SELECT m.id AS measure_id, m.measure_key, m.name AS measure_name,
             count(i.id)::int AS linked_incident_count
        FROM app.measures m
        LEFT JOIN app.incidents i
          ON i.tenant_id = m.tenant_id AND i.related_measure_id = m.id
       WHERE m.tenant_id = app.current_tenant() AND m.status <> 'retired'
       GROUP BY m.id, m.measure_key, m.name
      HAVING count(i.id) > 0
       ORDER BY count(i.id) DESC, m.measure_key`;

    return {
      duplicatePairs, simulatableMeasures, hasAnyAfterMeasureCandidate,
      totalIncidentCount, simulationRuns, measureIncidentLinks,
    };
  });
}
