// AI分析(画面⑧)の読み取りとシミュレーション実行の SQL。
//
// 2026-09-13(総指揮の決定): リスクマネジメント全体だけでなく、ISMS 側(ISO27001:2022 タグの付いた
// 施策・リスクシナリオ・資産だけ)でも使えるようにする。範囲は引数で受け取り、SQL の中で
// 「ALL なら常に真、ISO27001:2022 ならタグがあること」という条件だけを足す。全体(ALL)の結果は
// 変更前と同じになる。タグは関連から推論せず、明示的に付いたものだけを見る(0046 の方針)。
//
// このモジュールは 'server-only' を読み込まない。テナント文脈を確立したトランザクション(sql)を
// 受け取るだけにして、DB 試験(tests/analysis_isms_scope.sh)から同じ関数を直接呼べるようにする。
// 画面からは analysisRegister.ts / app/analysis/actions.ts が withTenant 経由で呼ぶ。
import type { TransactionSql } from 'postgres';

/** AI分析の範囲。ALL=範囲で絞らない全体、ISO27001:2022=ISMS タグ付きの項目だけ。 */
export const ANALYSIS_SCOPES = ['ALL', 'ISO27001:2022'] as const;
export type AnalysisScope = (typeof ANALYSIS_SCOPES)[number];
export const ISMS_ANALYSIS_SCOPE: AnalysisScope = 'ISO27001:2022';

export function parseAnalysisScope(value: unknown): AnalysisScope | null {
  return typeof value === 'string' && (ANALYSIS_SCOPES as readonly string[]).includes(value)
    ? (value as AnalysisScope)
    : null;
}

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
  // scenario_breakdown内のいずれかのシナリオでother_measures_on_scenarioが
  // 空でない場合true。before_measure/inherentは施策単位ではなくリスク
  // シナリオ単位の記録のため、このシミュレーションが「対象施策だけを外す」
  // ではなく「このシナリオの全施策を外す」場合の値になっている可能性が
  // あることを示す(Codexレビュー2026-09-03 3回目指摘)。
  has_shared_measures: boolean;
  // scenario_breakdown内のいずれかのシナリオでbaseline_newer_than_afterが
  // trueの場合true。after_measureとbefore_measure/inherentは独立に
  // 「最新の評価」を取得しているため同一評価サイクルである保証が無く、
  // 基準側がより新しい日付で再評価されている場合は時点がずれた評価同士を
  // 比較している可能性があることを示す(Codexレビュー2026-09-03 5回目指摘)。
  has_stale_baseline: boolean;
};

export type MeasureIncidentLinkRow = {
  measure_id: string;
  measure_key: string;
  measure_name: string;
  linked_incident_count: number;
};

export type AnalysisWorkspaceData = {
  scope: AnalysisScope;
  duplicatePairs: DuplicatePairRow[];
  // 除外シミュレーションの対象にできる施策(app.risk_evaluation_snapshotsに
  // 現在有効なafter_measureスナップショットを持つもの)だけに絞る。
  // 受入C4: これが0件なら「十分なデータが無い」としてUIで無効化する
  // (goto-twin決裁2026-09-03: 母数をapp.incidentsからリスク評価スナップ
  // ショットへ差し替えたことに伴い、閾値も「対象施策にafter_measure
  // 評価があるか」へ変更)。
  simulatableMeasures: MeasureOption[];
  // simulatableMeasuresが0件の時、その理由を正確に表示するための区別
  // (Codexレビュー2026-09-03 5回目指摘: after_measureが1件も無い場合と、
  // after_measureはあるが基準値(before_measure/inherent)が足りず絞り込みで
  // 0件になった場合とで、同じ無効化メッセージを出していた)。
  hasAnyAfterMeasureCandidate: boolean;
  // 範囲の中にある(退役していない)施策の数。ISMS 範囲でタグ付きの施策が1件も無いときに、
  // 無効化の理由を「ISMS タグの付いた施策が無い」と正確に出すため(2026-09-13)。
  scopedMeasureCount: number;
  // インシデントにはタグの仕組みが無いので、範囲にかかわらず全体の件数(画面では「全体の件数」と明記する)。
  totalIncidentCount: number;
  simulationRuns: SimulationRunRow[];
  measureIncidentLinks: MeasureIncidentLinkRow[];
};

// 重複分析(受入C1)の閾値。詳細仕様書の未決事項どおり、何件共通していたら
// 「高」とするかは未確定のため、暫定値としてここに固定し調整可能にしておく。
const OVERLAP_HIGH_THRESHOLD = 3;
const OVERLAP_MEDIUM_THRESHOLD = 2;

function scoreOverlap(sharedRiskCount: number, sharedAssetCount: number): '高' | '中' | '低' {
  const combined = sharedRiskCount + sharedAssetCount;
  if (combined >= OVERLAP_HIGH_THRESHOLD) return '高';
  if (combined >= OVERLAP_MEDIUM_THRESHOLD) return '中';
  return '低';
}

/** テナント文脈を確立済みのトランザクションで、範囲に応じた分析画面のデータを読む。 */
export async function readAnalysisWorkspace(sql: TransactionSql, scope: AnalysisScope): Promise<AnalysisWorkspaceData> {
  // 重複分析(C1): 施策(measure)が同一リスク・同一資産をカバーしているかを、
  // 既存の app.risk_treatments(施策→リスク評価)・app.risk_scenario_assets
  // (リスク→資産)から都度集計するライブクエリ。専用テーブルは持たない
  // (現在の状態を見る機能であり、履歴を残す必要が無いため)。
  // risk_treatmentsは同一(measure, risk_scenario)組に複数行(改定履歴)を
  // 持ちうるためDISTINCTで畳む。取消済み(status='cancelled')・改定で
  // 置き換えられた過去版(recorded_until IS NOT NULL)・有効期限切れ
  // (valid_to <= 今日。0008のEXCLUDE制約daterange('[)')と同じ終了日排他の
  // 意味)・開始前(valid_from > 今日)は「現在有効な対応」では
  // ないため除外する(Codexレビュー2026-09-03指摘)。
  // ISMS 範囲では、施策・リスクシナリオ・資産の3つともにタグを要求する。共有リスク数・共有資産数に
  // ISMS 外の項目が混ざらないようにするため(2026-09-13)。共有が0になった組は結果に現れない。
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
         -- と同じ終了日排他の意味に統一する(Codexレビュー2026-09-03 phase-gate指摘)。
         AND rt.valid_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
         AND (rt.valid_to IS NULL OR rt.valid_to > (now() AT TIME ZONE 'Asia/Tokyo')::date)
         AND ra.status = 'approved'
         AND ra.recorded_until IS NULL
         AND ra.valid_from <= (now() AT TIME ZONE 'Asia/Tokyo')::date
         AND (ra.valid_to IS NULL OR ra.valid_to > (now() AT TIME ZONE 'Asia/Tokyo')::date)
         AND (${scope} = 'ALL' OR EXISTS (
               SELECT 1 FROM app.risk_scenario_frameworks rf
                WHERE rf.tenant_id = rs.tenant_id AND rf.risk_scenario_id = rs.id AND rf.framework_key = ${scope}))
    ), scoped_measures AS (
      SELECT m.id
        FROM app.measures m
       WHERE m.tenant_id = app.current_tenant() AND m.status <> 'retired'
         AND (${scope} = 'ALL' OR EXISTS (
               SELECT 1 FROM app.measure_frameworks mf
                WHERE mf.tenant_id = m.tenant_id AND mf.measure_id = m.id AND mf.framework_key = ${scope}))
    ), measure_risks AS (
      SELECT DISTINCT ct.measure_id, ct.risk_scenario_id
        FROM current_treatments ct
        JOIN scoped_measures sm ON sm.id = ct.measure_id
    ), measure_assets AS (
      SELECT DISTINCT ct.measure_id, rsa.asset_id
        FROM current_treatments ct
        JOIN scoped_measures sm ON sm.id = ct.measure_id
        JOIN app.risk_scenario_assets rsa
          ON rsa.tenant_id = app.current_tenant() AND rsa.risk_scenario_id = ct.risk_scenario_id
        JOIN app.assets ast ON ast.tenant_id = app.current_tenant() AND ast.id = rsa.asset_id
                            AND ast.status = 'active'
       WHERE ${scope} = 'ALL' OR EXISTS (
               SELECT 1 FROM app.asset_frameworks af
                WHERE af.tenant_id = ast.tenant_id AND af.asset_id = ast.id AND af.framework_key = ${scope})
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

  // 除外シミュレーション(受入C4対象の絞り込み): app.risk_evaluation_snapshots
  // に、現在有効(assessed_on <= 今日JST)なafter_measureスナップショットを持つ施策だけを
  // 選択肢にする。さらに、対象シナリオのうち1つでもbefore_measure/inherentが無ければ
  // 選択肢に出さない(Codexレビュー2026-09-03 4回目指摘)。ISMS 範囲では、施策と
  // 対象シナリオの両方にタグを要求し、C4 の規則もその範囲の中で当てる(2026-09-13)。
  const simulatableMeasures = await sql<MeasureOption[]>`
    WITH after_scenarios AS (
      SELECT DISTINCT s.measure_id, s.risk_scenario_id
        FROM app.risk_evaluation_snapshots s
        JOIN app.risk_scenarios rs
          ON rs.tenant_id = s.tenant_id AND rs.id = s.risk_scenario_id AND rs.status = 'active'
       WHERE s.tenant_id = app.current_tenant() AND s.stage = 'after_measure'
         AND s.assessed_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
         AND s.measure_id IS NOT NULL
         AND (${scope} = 'ALL' OR EXISTS (
               SELECT 1 FROM app.risk_scenario_frameworks rf
                WHERE rf.tenant_id = rs.tenant_id AND rf.risk_scenario_id = rs.id AND rf.framework_key = ${scope}))
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
       AND (${scope} = 'ALL' OR EXISTS (
             SELECT 1 FROM app.measure_frameworks mf
              WHERE mf.tenant_id = m.tenant_id AND mf.measure_id = m.id AND mf.framework_key = ${scope}))
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
         AND (${scope} = 'ALL' OR (
               EXISTS (SELECT 1 FROM app.risk_scenario_frameworks rf
                        WHERE rf.tenant_id = rs.tenant_id AND rf.risk_scenario_id = rs.id AND rf.framework_key = ${scope})
               AND EXISTS (SELECT 1 FROM app.measure_frameworks mf
                            WHERE mf.tenant_id = m.tenant_id AND mf.measure_id = m.id AND mf.framework_key = ${scope})))
    ) AS exists`;

  const [{ n: scopedMeasureCount }] = await sql<{ n: number }[]>`
    SELECT count(*)::int AS n
      FROM app.measures m
     WHERE m.tenant_id = app.current_tenant() AND m.status <> 'retired'
       AND (${scope} = 'ALL' OR EXISTS (
             SELECT 1 FROM app.measure_frameworks mf
              WHERE mf.tenant_id = m.tenant_id AND mf.measure_id = m.id AND mf.framework_key = ${scope}))`;

  const [{ n: totalIncidentCount }] = await sql<{ n: number }[]>`
    SELECT count(*)::int AS n FROM app.incidents WHERE tenant_id = app.current_tenant()`;

  // 履歴は、いま見ている範囲で実行したものだけを出す。範囲は実行時に記録したもの(0078)で、
  // 施策の今のタグから推定しない(タグは後から外せるので、過去の実行の範囲を再現できなくなる)。
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
     WHERE s.scope = ${scope}
     ORDER BY s.run_at DESC
     LIMIT 50`;

  // 参考パネル(goto-twin決裁2026-09-03で「シミュレーション」から降格、
  // 生きたクエリのみ・専用の実行記録は持たない): 施策ごとに、現状
  // app.incidents.related_measure_idで紐づいている件数を一覧表示する。
  // ISMS 範囲では施策をタグ付きに限る(インシデント側にはタグの仕組みが無い)。
  const measureIncidentLinks = await sql<MeasureIncidentLinkRow[]>`
    SELECT m.id AS measure_id, m.measure_key, m.name AS measure_name,
           count(i.id)::int AS linked_incident_count
      FROM app.measures m
      LEFT JOIN app.incidents i
        ON i.tenant_id = m.tenant_id AND i.related_measure_id = m.id
     WHERE m.tenant_id = app.current_tenant() AND m.status <> 'retired'
       AND (${scope} = 'ALL' OR EXISTS (
             SELECT 1 FROM app.measure_frameworks mf
              WHERE mf.tenant_id = m.tenant_id AND mf.measure_id = m.id AND mf.framework_key = ${scope}))
     GROUP BY m.id, m.measure_key, m.name
    HAVING count(i.id) > 0
     ORDER BY count(i.id) DESC, m.measure_key`;

  return {
    scope, duplicatePairs, simulatableMeasures, hasAnyAfterMeasureCandidate, scopedMeasureCount,
    totalIncidentCount, simulationRuns, measureIncidentLinks,
  };
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
  // 同じリスクシナリオに、対象施策以外で現在有効な対応を持つ施策のキー。
  // 空でなければ、before_measure/inherentはシナリオ単位の記録なので、
  // このシミュレーションは「対象施策だけを外す」のではなく「このシナリオの
  // 全施策を外す」場合の値になっている可能性がある(Codexレビュー2026-09-03
  // 3回目指摘)。数値を歪めずに開示する。
  other_measures_on_scenario: string[];
};

export type SimulationOutcome =
  | 'ok'
  | 'measure_not_found'
  | 'out_of_scope'
  | 'insufficient_data'
  | 'missing_baseline_data'
  | 'inconsistent_data';

/**
 * 施策除外シミュレーションを1回実行し、結果を app.simulation_runs に範囲つきで記録する。
 * テナント文脈を確立した書き込みトランザクションで呼ぶ。
 */
export async function runScopedSimulation(
  sql: TransactionSql,
  excludedMeasureId: string,
  scope: AnalysisScope,
): Promise<SimulationOutcome> {
  // 施策の実在確認(テナント越境はFKが別途強制するが、対象が現テナントに
  // 実在するかはここで先に確認しフレンドリーなエラーへ寄せる)。
  // status <> 'retired' も見る(Codexレビュー2026-09-03 2回目指摘)。
  const measure = await sql<{ id: string; in_scope: boolean }[]>`
    SELECT m.id,
           (${scope} = 'ALL' OR EXISTS (
             SELECT 1 FROM app.measure_frameworks mf
              WHERE mf.tenant_id = m.tenant_id AND mf.measure_id = m.id AND mf.framework_key = ${scope})) AS in_scope
      FROM app.measures m
     WHERE m.tenant_id = app.current_tenant() AND m.id = ${excludedMeasureId}::uuid
       AND m.status <> 'retired'`;
  if (measure.length === 0) return 'measure_not_found';
  // ISMS 範囲なのにタグの無い施策が送られてきたら(改ざんしたフォーム・古いページ)拒否する。
  if (!measure[0].in_scope) return 'out_of_scope';

  // goto-twin決裁2026-09-03: 施策除外の反実仮想は、app.risk_evaluation_
  // snapshots(0027)のafter_measure(施策あり)とbefore_measure/inherent
  // (施策なし)のrisk_level差そのもの。assessed_on <= 今日(JST)のものだけを現状とし、
  // 各リスクシナリオについて最新のafter_measure(対象施策限定)と、最新の
  // before_measure(無ければinherent)を1件ずつ取る。廃止済み(retired)リスク
  // シナリオは除外し、同点時は snapshot id を最終 tie-break に使う(再現性のため)。
  // ISMS 範囲では、合計に使うリスクシナリオをタグ付きに限る(2026-09-13)。
  // 「他施策と共通」の判定(other_measures)はタグで絞らない。数値が何を意味するかの
  // 注意書きなので、絞ると本当に必要な注意を隠すことになる(総指揮の決定)。
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
         AND (${scope} = 'ALL' OR EXISTS (
               SELECT 1 FROM app.risk_scenario_frameworks rf
                WHERE rf.tenant_id = rs.tenant_id AND rf.risk_scenario_id = rs.id AND rf.framework_key = ${scope}))
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
      -- before_measureをinherentより優先する(施策が無い状態としてより具体的な評価のため)。
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
      -- 同じシナリオに対象施策以外の「現在有効な対応」があるか(C1のcurrent_treatmentsと
      -- 同じ定義。Codexレビュー2026-09-03 4回目指摘)。存在確認のみ行い、結果側で開示する。
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

  // C4: 範囲の中に対象施策の after_measure スナップショットが無ければ算出不能。
  if (rows.length === 0) return 'insufficient_data';

  // 比較対象(before_measure/inherent)が無いシナリオを黙って除外し部分集計を保存すると、
  // 合計値が実際より小さく見える(Codexレビュー2026-09-03 3回目指摘)。1件でも基準が無ければ拒否する。
  if (rows.some((r) => r.without_measure_level === null)) return 'missing_baseline_data';
  const comparisons = rows.map((r) => ({
    ...r,
    without_measure_level: r.without_measure_level as number,
    without_measure_stage: r.without_measure_stage as 'before_measure' | 'inherent',
    without_measure_assessed_on: r.without_measure_assessed_on as string,
  }));

  // 施策除外は防御を無くす方向の反実仮想なので、除外後(施策なし)のrisk_levelは現状(施策あり)以上に
  // なるはず。逆転している評価データが1件でもあれば、記録の不整合として数値化せず拒否する
  // (goto-twin決裁2026-09-03。DBには書き込まない)。
  if (comparisons.some((c) => c.without_measure_level < c.after_level)) return 'inconsistent_data';

  // 基準側の評価日が対策後の評価日より後(=対策後より新しい基準評価が別途行われている)場合だけ、
  // 時点がずれた評価同士を比較している可能性として開示する(Codexレビュー2026-09-03 5回目指摘。
  // 6回目指摘で「日付が完全一致でなければ全て開示」の代案は、通常の評価の流れまで警告に埋もれる
  // ため不採用)。
  const withStaleBaselineFlag = comparisons.map((c) => ({
    ...c,
    baseline_newer_than_after: c.without_measure_assessed_on > c.after_assessed_on,
  }));

  const scenarioCount = withStaleBaselineFlag.length;
  const afterSum = withStaleBaselineFlag.reduce((sum, c) => sum + c.after_level, 0);
  const withoutSum = withStaleBaselineFlag.reduce((sum, c) => sum + c.without_measure_level, 0);

  await sql`
    INSERT INTO app.simulation_runs
      (tenant_id, excluded_measure_id, scope, scenario_count, after_measure_risk_level_sum,
       without_measure_risk_level_sum, scenario_breakdown, method, run_by)
    VALUES
      (app.current_tenant(), ${excludedMeasureId}::uuid, ${scope}, ${scenarioCount}, ${afterSum}, ${withoutSum},
       ${sql.json(withStaleBaselineFlag)}, 'risk_level_after_vs_before_or_inherent', app.current_session_user())`;
  return 'ok';
}
