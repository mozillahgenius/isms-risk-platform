-- 0044 app: 画面⑧(AI分析・シミュレーション)の施策除外シミュレーション実行記録
--
-- goto-twin決裁(2026-09-03、twin-consult-log C-20260903-085834-0288)にもとづき、
-- 画面⑦(インシデント管理)の実運用データがまだ僅少な段階でも着手する。
-- 受入条件(詳細仕様書、Kaname作業ログKaname作業ログ参照):
--   C1: 重複分析は同一リスク/同一資産をカバーする施策の組を機械的に検出する
--   C2: シミュレーション結果は「サンプル値」か「実データに基づく推定」かを明示
--   C3: 実行のたびにapp.simulation_runsへ記録が残り、再現・検証できる
--   C4: 十分なデータが無い場合、機能を明示的に無効化する(黙って不確かな
--       数値を出さない)
--
-- 実装方針(goto-twin決裁で固定): 重複分析・シミュレーションは決定論ロジック
-- (LLM不使用)。本番DBへダミー/テストデータは投入しない(このmigration自体も
-- スキーマのみで、データは一切書き込まない)。
--
-- 設計の経緯(2回の見直し):
--   1回目(Codexレビュー2026-09-03指摘): 当初案は「全体インシデント件数−
--   対象施策に紐づくインシデント件数=施策除外後の予測件数」としていたが、
--   意味が逆転していた(施策に紐づくインシデントは「施策が有効な状態でも
--   起きた事案」であり、除外したら無かったことになる=減るわけではない)。
--   このシステムはapp.incidentsだけでは除外時の増減方向を決定論的に出す
--   根拠が無いと判断し、「除外シミュレーション」を諦めて「施策別インシデ
--   ント紐づけ集計(現状の実測)」へ機能の性質を変更した。
--
--   2回目(goto-twin再決裁、2026-09-03): 上記の前提が誤りだった。
--   app.risk_evaluation_snapshots(0027)は、リスクシナリオごとに
--   stage IN ('inherent','before_measure','after_measure')でrisk_level
--   (probability×impact)を記録しており、施策(measure_id)に紐づく
--   after_measureスナップショットと、その前段階(before_measureが無ければ
--   inherent)の評価値が既に存在する。「施策を外した場合」の反実仮想は、
--   この評価値の差そのものであり、時系列データや施策の実施期間は不要。
--   方向は定義上「防御が無くなる=リスク値は現状以上になる」の一方向のみ
--   (前段階の評価が現状より低い=逆転していれば、それは評価記録の不整合
--   であり、数値化せず「評価値が不整合」として拒否する)。
--   これにより「除外シミュレーション」という当初の機能性質を維持したまま
--   実装できるため、詳細仕様書の改訂は不要と判断した(goto-twin決裁)。
--
--   インシデントへの紐づけ件数集計(1回目の見直しで作った機能)は、
--   「シミュレーション」とは呼ばず、参考情報として別パネルに残す
--   (画面のライブクエリのみ。専用の実行記録テーブルは持たない)。
--
-- スキーマ: 対象シナリオ単位の内訳(risk_scenario_id・施策あり/なしの
-- risk_level・評価日)をscenario_breakdown(jsonb配列)に保存する。件数の
-- 合計だけでなく、後日データが変わった後も「何を比較したか」を検証できる
-- ようにするため(C3、Codexレビュー2026-09-03指摘: 当初は合計件数のみで
-- 内訳が無く再現できなかった)。methodは自由記述をやめ、固定値のCHECKで
-- 縛る(将来ロジックを追加する時は許容値を増やす)。

CREATE TABLE app.simulation_runs (
  id                            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id                     uuid NOT NULL,
  excluded_measure_id           uuid NOT NULL,
  scenario_count                integer NOT NULL,
  after_measure_risk_level_sum  integer NOT NULL,
  without_measure_risk_level_sum integer NOT NULL,
  scenario_breakdown            jsonb NOT NULL,
  method                        text NOT NULL
                                 CHECK (method = 'risk_level_after_vs_before_or_inherent'),
  run_by                        uuid,
  run_at                        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, id),
  FOREIGN KEY (tenant_id, excluded_measure_id) REFERENCES app.measures(tenant_id, id),
  FOREIGN KEY (tenant_id, run_by) REFERENCES app.users(tenant_id, id),
  CHECK (scenario_count >= 1),
  CHECK (after_measure_risk_level_sum >= 0),
  CHECK (without_measure_risk_level_sum >= 0),
  -- 施策除外は防御を無くす方向の反実仮想なので、除外後のリスク値合計は
  -- 現状(施策あり)合計を下回らない。逆転データはアプリ層で検知して
  -- INSERT自体を行わない(「評価値が不整合」として拒否、数値化しない)ため、
  -- ここは最終防衛線としてのCHECK。
  CHECK (without_measure_risk_level_sum >= after_measure_risk_level_sum),
  CHECK (jsonb_typeof(scenario_breakdown) = 'array')
);

COMMENT ON TABLE app.simulation_runs IS '画面⑧: 施策除外シミュレーション(リスク評価スナップショットの施策あり/なし比較)の実行記録。C3(再現・検証)の実体';
COMMENT ON COLUMN app.simulation_runs.scenario_breakdown IS '対象リスクシナリオごとの内訳(risk_scenario_id・施策ありrisk_level/評価日・施策なしrisk_level/stage/評価日)。後日データが変わっても何を比較したかを検証できるようにするため保存する';

-- scenario_count・各合計値がscenario_breakdownの実際の中身と一致することを
-- DB側でも強制する。アプリ経路は正しく計算しているが、直接SQL等の別経路で
-- 件数・合計だけ辻褄を合わせた(内訳が伴わない)行を作れてしまうとC3(再現・
-- 検証)の保証が崩れる(Codexレビュー2026-09-03 5回目指摘)。PostgreSQLの
-- CHECK制約はサブクエリを書けない(jsonb_array_elementsのような集合を返す
-- 関数はCHECK式に直接使えない)ため、BEFORE INSERTトリガーで検証する。
CREATE OR REPLACE FUNCTION app.check_simulation_run_breakdown() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_count integer;
  v_after_sum integer;
  v_without_sum integer;
  v_all_keys_present boolean;
BEGIN
  -- ?演算子はキーの「存在」だけを見る(値がJSON nullでも真になる)。
  -- 値がnullのままだと((elem->>'after_level')::int)がSQL NULLになり、
  -- sum()がそれを無視して静かに合計を減らすため、->>でIS NOT NULLまで
  -- 確認する(Codexレビュー2026-09-03 6回目指摘)。
  SELECT count(*), coalesce(sum((elem ->> 'after_level')::int), 0),
         coalesce(sum((elem ->> 'without_measure_level')::int), 0),
         bool_and(
           elem ->> 'risk_scenario_id' IS NOT NULL
           AND elem ->> 'after_snapshot_id' IS NOT NULL
           AND elem ->> 'after_level' IS NOT NULL
           AND elem ->> 'after_assessed_on' IS NOT NULL
           AND elem ->> 'without_measure_snapshot_id' IS NOT NULL
           AND elem ->> 'without_measure_level' IS NOT NULL
           AND elem ->> 'without_measure_stage' IS NOT NULL
           AND elem ->> 'without_measure_assessed_on' IS NOT NULL
         )
    INTO v_count, v_after_sum, v_without_sum, v_all_keys_present
    FROM pg_catalog.jsonb_array_elements(NEW.scenario_breakdown) elem;

  IF v_count IS DISTINCT FROM NEW.scenario_count THEN
    RAISE EXCEPTION 'scenario_breakdown の件数(%)がscenario_count(%)と一致しません', v_count, NEW.scenario_count;
  END IF;
  IF v_after_sum IS DISTINCT FROM NEW.after_measure_risk_level_sum THEN
    RAISE EXCEPTION 'scenario_breakdown のafter_level合計(%)がafter_measure_risk_level_sum(%)と一致しません', v_after_sum, NEW.after_measure_risk_level_sum;
  END IF;
  IF v_without_sum IS DISTINCT FROM NEW.without_measure_risk_level_sum THEN
    RAISE EXCEPTION 'scenario_breakdown のwithout_measure_level合計(%)がwithout_measure_risk_level_sum(%)と一致しません', v_without_sum, NEW.without_measure_risk_level_sum;
  END IF;
  IF NEW.scenario_count > 0 AND NOT coalesce(v_all_keys_present, false) THEN
    RAISE EXCEPTION 'scenario_breakdown の要素に必須項目が欠けています';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_simulation_run_breakdown BEFORE INSERT ON app.simulation_runs
  FOR EACH ROW EXECUTE FUNCTION app.check_simulation_run_breakdown();

-- ポリシー自体は他のtenant_id付きテーブルと同じ標準形(tenant_isolation FOR ALL)
-- に揃える(scripts/ci/check_rls.sqlがこの形を一律に検査するため、ここだけ
-- 別形にすると検査の一般化が崩れる)。実行記録を追記専用にする実効的な強制は
-- GRANTで行う: app_rwにUPDATE/DELETEを与えない。PostgreSQLはRLSより先に
-- テーブル権限(GRANT)を見るため、ポリシーがALLをカバーしていてもGRANTが
-- 無ければUPDATE/DELETE文はそもそも実行できない。0027のapp.risk_evaluation_
-- snapshots(履歴はUPDATE/DELETE不可)と同じ確立済みパターンを踏襲する。
DO $$
BEGIN
  ALTER TABLE app.simulation_runs ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.simulation_runs FORCE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON app.simulation_runs FOR ALL TO app_rw
    USING (tenant_id = app.current_tenant())
    WITH CHECK (tenant_id = app.current_tenant());
  CREATE POLICY tenant_read ON app.simulation_runs FOR SELECT TO app_ro
    USING (tenant_id = app.current_tenant());
  REVOKE ALL ON app.simulation_runs FROM PUBLIC;
  GRANT SELECT, INSERT ON app.simulation_runs TO app_rw;
  GRANT SELECT ON app.simulation_runs TO app_ro;
END $$;
