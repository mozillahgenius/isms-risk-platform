-- 0044 app: execution records for measure-exclusion simulations on screen 8 (AI analysis / simulation)
--
-- Per the design decision (2026-09-03),
-- this starts even while real operational data on screen 7 (incident management) is still scarce.
-- Acceptance criteria (detailed spec):
--   C1: overlap analysis mechanically detects sets of measures covering the same risk/asset
--   C2: simulation results state explicitly whether they are "sample values" or "estimates based on real data"
--   C3: every run leaves a record in app.simulation_runs so it can be reproduced and verified
--   C4: when there is not enough data, the feature is explicitly disabled (never silently
--       emit uncertain numbers)
--
-- Implementation policy (fixed by design decision): overlap analysis and simulation use deterministic logic
-- (no LLM). No dummy/test data goes into the production DB (this migration itself is
-- schema-only and writes no data at all).
--
-- Design history (two revisions):
--   1st (Codex review 2026-09-03): the original idea was "total incident count minus
--   incidents linked to the target measure = predicted count after excluding the measure", but
--   the meaning was inverted (incidents linked to a measure are "events that happened even with the
--   measure in effect"; excluding the measure does not make them disappear = the count does not drop).
--   We judged that app.incidents alone gives no basis to deterministically derive the
--   direction of change on exclusion, gave up on the "exclusion simulation", and changed the feature into
--   "per-measure incident linkage counts (current actuals)".
--
--   2nd (design re-decision, 2026-09-03): the premise above was wrong.
--   app.risk_evaluation_snapshots (0027) records, per risk scenario,
--   risk_level (probability x impact) for stage IN ('inherent','before_measure','after_measure'),
--   so for an after_measure snapshot linked to a measure (measure_id)
--   the evaluation of the preceding stage (inherent if there is no before_measure) already
--   exists. The counterfactual "if the measure were removed" is
--   exactly the difference between these evaluations; no time series or measure implementation period is needed.
--   By definition the direction is one-way: "the defense goes away = risk is at least the current value"
--   (if the preceding stage's evaluation is lower than the current one, i.e. inverted, that is an inconsistency in
--   the evaluation records; it is not quantified but rejected as "inconsistent evaluations").
--   This allows implementing it while keeping the original nature of the feature as an "exclusion simulation",
--   so no revision of the detailed spec was deemed necessary (design decision).
--
--   The incident linkage counts (the feature built in the 1st revision) are
--   not called a "simulation" and remain in a separate panel as reference information
--   (live query on the screen only; no dedicated execution-record table).
--
-- Schema: the per-scenario breakdown (risk_scenario_id, with/without-measure
-- risk_level, evaluation date) is stored in scenario_breakdown (jsonb array). This is so that
-- not only the totals but also "what was compared" can be verified after the data changes later
-- (C3; Codex review 2026-09-03: originally only totals were stored and
-- with no breakdown it could not be reproduced). method is no longer free text but constrained by a CHECK
-- on fixed values (add allowed values when adding logic in the future).

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
  -- Measure exclusion is a counterfactual that removes a defense, so the post-exclusion risk total
  -- never falls below the current (with-measure) total. Inverted data is detected in the app layer and
  -- the INSERT is not performed at all (rejected as "inconsistent evaluations", not quantified), so
  -- this CHECK is the last line of defense.
  CHECK (without_measure_risk_level_sum >= after_measure_risk_level_sum),
  CHECK (jsonb_typeof(scenario_breakdown) = 'array')
);

COMMENT ON TABLE app.simulation_runs IS '画面⑧: 施策除外シミュレーション(リスク評価スナップショットの施策あり/なし比較)の実行記録。C3(再現・検証)の実体';
COMMENT ON COLUMN app.simulation_runs.scenario_breakdown IS '対象リスクシナリオごとの内訳(risk_scenario_id・施策ありrisk_level/評価日・施策なしrisk_level/stage/評価日)。後日データが変わっても何を比較したかを検証できるようにするため保存する';

-- Enforce on the DB side too that scenario_count and each total match the actual contents of scenario_breakdown.
-- The app path computes them correctly, but if another path such as direct SQL
-- could create rows whose counts/totals merely add up (without a matching breakdown), the C3 (reproduce/
-- verify) guarantee would break (Codex review 2026-09-03, 5th round). PostgreSQL
-- CHECK constraints cannot contain subqueries (set-returning functions such as jsonb_array_elements
-- cannot be used directly in a CHECK expression), so this is verified by a BEFORE INSERT trigger.
CREATE OR REPLACE FUNCTION app.check_simulation_run_breakdown() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
DECLARE
  v_count integer;
  v_after_sum integer;
  v_without_sum integer;
  v_all_keys_present boolean;
BEGIN
  -- The ? operator only checks the key's "existence" (true even if the value is JSON null).
  -- If the value stays null, ((elem->>'after_level')::int) becomes SQL NULL and
  -- sum() ignores it, silently reducing the total, so check with ->> down to IS NOT NULL
  -- (Codex review 2026-09-03, 6th round).
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

-- The policy itself follows the same standard form as other tables with tenant_id (tenant_isolation FOR ALL)
-- (scripts/ci/check_rls.sql checks this form uniformly, so giving just this table
-- a different form would break the generality of the check). Append-only execution records are actually enforced
-- via GRANT: app_rw is not given UPDATE/DELETE. PostgreSQL checks table privileges (GRANT)
-- before RLS, so even if the policy covers ALL, without the GRANT
-- UPDATE/DELETE statements cannot run at all. Follows the established pattern of 0027's app.risk_evaluation_
-- snapshots (history cannot be UPDATEd/DELETEd).
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
