#!/usr/bin/env bash
# M2 read model: run only against the disposable DB created by the test runner.
set -euo pipefail

DB="${ISMS_DB:-}"
case "$DB" in
  isms_test_*) ;;
  *) echo "isms_risk_read_model: ISMS_DB must be an isolated isms_test_* database" >&2; exit 1 ;;
esac

ADMIN="postgres:///$DB"
RO="postgres:///$DB?user=app_ro"
TA='51000000-0000-0000-0000-000000000001'
TB='52000000-0000-0000-0000-000000000002'
UA='51000000-0000-0000-0000-000000000011'
UB='52000000-0000-0000-0000-000000000012'
RA='51000000-0000-0000-0000-000000000021'
RB='52000000-0000-0000-0000-000000000022'
MA='51000000-0000-0000-0000-000000000031'
CA='51000000-0000-0000-0000-000000000041'
CB='51000000-0000-0000-0000-000000000042'
EA='51000000-0000-0000-0000-000000000051'
FA='51000000-0000-0000-0000-000000000061'
FU='51000000-0000-0000-0000-000000000062'
FB='52000000-0000-0000-0000-000000000063'
DA='51000000-0000-0000-0000-000000000071'
CRA='51000000-0000-0000-0000-000000000081'
ASA='51000000-0000-0000-0000-000000000091'
SIA='51000000-0000-0000-0000-000000000101'
SRA='51000000-0000-0000-0000-000000000102'
TOKEN_A='M2-TOKEN-A-012345678901234567890123456789'
TOKEN_B='M2-TOKEN-B-012345678901234567890123456789'

psql -q -v ON_ERROR_STOP=1 "$ADMIN" <<SQL
INSERT INTO catalog.dom_versions (id,version,released_at,changelog,is_current)
VALUES ('51000000-0000-0000-0000-000000002026','m2-test',now(),'M2 fixture',false)
ON CONFLICT (version) DO NOTHING;
INSERT INTO catalog.risk_criteria_default (dom_version_id)
VALUES ('51000000-0000-0000-0000-000000002026')
ON CONFLICT (dom_version_id) DO NOTHING;
INSERT INTO catalog.roles_default (key,name_ja,description,sort_order)
VALUES ('ciso','経営責任者','M2 fixture',1)
ON CONFLICT (key) DO NOTHING;
INSERT INTO catalog.frameworks (key,name_ja,version,source_note)
VALUES ('ISO27001:2022','ISO/IEC 27001','2022','M2 fixture'),
       ('RISK-MANAGEMENT','リソースマネジメント','1.0','M2 fixture')
ON CONFLICT (key) DO NOTHING;
INSERT INTO catalog.controls (id,framework_key,code,title_ja)
VALUES ('$CA','ISO27001:2022','M2.1','M2 control one'),
       ('$CB','ISO27001:2022','M2.2','M2 control two')
ON CONFLICT (id) DO NOTHING;
INSERT INTO catalog.control_frameworks (control_id,framework_key)
VALUES ('$CA','ISO27001:2022'),('$CB','ISO27001:2022')
ON CONFLICT DO NOTHING;
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO app.tenants (id,name,domain,dom_version_id)
VALUES ('$TA','M2 A','m2-a.example','51000000-0000-0000-0000-000000002026'),
       ('$TB','M2 B','m2-b.example','51000000-0000-0000-0000-000000002026');
INSERT INTO app.users (tenant_id,id,email,display_name)
VALUES ('$TA','$UA','m2-a@example.test','M2 A'),('$TB','$UB','m2-b@example.test','M2 B');
INSERT INTO app.memberships (tenant_id,user_id,role_key)
VALUES ('$TA','$UA','ciso'),('$TB','$UB','ciso');
INSERT INTO app.risk_scenarios
  (tenant_id,id,risk_key,domain,area,phase,theme,measure,frame,summary)
VALUES ('$TA','$RA','M2-A','M2','M2',1,'M2','M2','管理可能性','M2 shared ID'),
       ('$TB','$RB','M2-B','M2','M2',1,'M2','M2','管理可能性','M2 other tenant');
INSERT INTO app.risk_scenario_frameworks (tenant_id,risk_scenario_id,framework_key)
VALUES ('$TA','$RA','RISK-MANAGEMENT'),('$TA','$RA','ISO27001:2022'),
       ('$TB','$RB','RISK-MANAGEMENT'),('$TB','$RB','ISO27001:2022');
INSERT INTO app.measures (tenant_id,id,measure_key,name,summary,strategy)
VALUES ('$TA','$MA','M2-M','M2 measure','M2 measure','mitigate');
INSERT INTO app.measure_frameworks (tenant_id,measure_id,framework_key)
VALUES ('$TA','$MA','RISK-MANAGEMENT');
INSERT INTO app.framework_relation_origins
  (tenant_id,entity_type,entity_id,framework_key,generation_id,origin_kind,origin_id)
VALUES ('$TA','risk_scenario','$RA','RISK-MANAGEMENT',gen_random_uuid(),'human','m2 fixture'),
       ('$TA','risk_scenario','$RA','ISO27001:2022',gen_random_uuid(),'human','m2 fixture'),
       ('$TB','risk_scenario','$RB','RISK-MANAGEMENT',gen_random_uuid(),'human','m2 fixture'),
       ('$TB','risk_scenario','$RB','ISO27001:2022',gen_random_uuid(),'human','m2 fixture'),
       ('$TA','measure','$MA','RISK-MANAGEMENT',gen_random_uuid(),'human','m2 fixture');
INSERT INTO app.framework_relation_events
  (tenant_id,entity_type,entity_id,framework_key,generation_id,event_kind)
SELECT tenant_id,entity_type,entity_id,framework_key,generation_id,'created'
  FROM app.framework_relation_origins
 WHERE origin_id = 'm2 fixture';
INSERT INTO app.risk_control_links (tenant_id,risk_scenario_id,control_id)
VALUES ('$TA','$RA','$CA'),('$TA','$RA','$CB');
INSERT INTO app.control_implementations (tenant_id,control_id,status)
VALUES ('$TA','$CA','operating');
INSERT INTO app.evidences (tenant_id,id,kind,title,collected_at,freshness_days,state)
VALUES ('$TA','$EA','manual','M2 shared evidence',now(),30,'valid');
INSERT INTO app.control_evidence_links (tenant_id,control_id,evidence_id)
VALUES ('$TA','$CA','$EA'),('$TA','$CB','$EA');
INSERT INTO app.findings (tenant_id,id,source,title,severity,status)
VALUES ('$TA','$FA','internal_audit','bridged finding','high','detected'),
       ('$TA','$FU','internal_audit','unbridged finding','high','detected'),
       ('$TB','$FB','internal_audit','other tenant finding','high','detected');
INSERT INTO app.finding_risk_scenarios (tenant_id,finding_id,risk_scenario_id,created_by)
VALUES ('$TA','$FA','$RA','$UA'),('$TB','$FB','$RB','$UB');
INSERT INTO app.deviations (tenant_id,id,kind,target_key,override,reason,status,requested_by,approved_by,approved_at,expires_at,weight)
VALUES ('$TA','$DA','risk_band','M2','{"band_accept":[1,2]}'::jsonb,'M2 criterion deviation','active','$UA','$UA',now(),now()+interval '1 day',1);
INSERT INTO app.risk_criteria (tenant_id,id,dom_version_id,impact_sec_formula,band_top_priority,band_action,band_consider,band_accept,deviation_id,valid_from)
VALUES ('$TA','$CRA','51000000-0000-0000-0000-000000002026','max_cia','{25}','{16}','{4}','{1}','$DA',CURRENT_DATE);
INSERT INTO app.risk_assessments
  (tenant_id,id,risk_scenario_id,risk_criteria_id,status,prob,confidentiality,integrity,availability,impact_sec,impact_biz,assessed_by,approved_by,approved_at,valid_from)
VALUES ('$TA','$ASA','$RA','$CRA','approved',2,3,2,1,3,2,'$UA','$UA',now(),CURRENT_DATE);
INSERT INTO app.risk_evaluation_snapshots
  (tenant_id,id,risk_scenario_id,stage,assessed_on,probability,impact,rationale)
VALUES ('$TA','$SIA','$RA','inherent',CURRENT_DATE,3,3,'M2 inherent');
INSERT INTO app.risk_evaluation_snapshots
  (tenant_id,id,risk_scenario_id,measure_id,stage,assessed_on,probability,impact,rationale)
VALUES ('$TA','$SRA','$RA','$MA','after_measure',CURRENT_DATE,2,2,'M2 residual');
INSERT INTO app.risk_acceptances
  (tenant_id,risk_scenario_id,expected_version,residual_level,inherent_level,reason,accepted_by,evaluation_snapshot_id,evaluation_snapshot_sha256,inherent_snapshot_id,inherent_snapshot_sha256)
VALUES ('$TA','$RA',2,4,9,'M2 acceptance','$UA','$SRA',app.risk_evaluation_snapshot_sha256((SELECT s FROM app.risk_evaluation_snapshots s WHERE s.tenant_id='$TA' AND s.id='$SRA')),'$SIA',app.risk_evaluation_snapshot_sha256((SELECT s FROM app.risk_evaluation_snapshots s WHERE s.tenant_id='$TA' AND s.id='$SIA')));
INSERT INTO app.risk_evaluation_snapshots
  (tenant_id,risk_scenario_id,measure_id,stage,assessed_on,probability,impact,rationale)
VALUES ('$TA','$RA','$MA','after_measure',CURRENT_DATE,1,1,'M2 newer snapshot');
COMMIT;
SELECT app.create_session('$TA','$UA','$TOKEN_A');
SELECT app.create_session('$TB','$UB','$TOKEN_B');
SQL

psql -q -v ON_ERROR_STOP=1 "$RO" <<SQL
BEGIN;
SELECT app.set_tenant_context('$TOKEN_A');
DO \$\$
DECLARE model app.isms_risk_read_model%ROWTYPE;
        definition text;
BEGIN
  SELECT pg_get_viewdef('app.isms_risk_read_model'::regclass, true) INTO definition;
  IF position('Asia/Tokyo' IN definition) = 0 THEN
    RAISE EXCEPTION 'read model current-date boundary is not fixed to Asia/Tokyo';
  END IF;
  IF position('a.assessed_at DESC, a.created_at DESC, a.id DESC' IN definition) = 0
     OR position('ci.recorded_from DESC, ci.created_at DESC, ci.id DESC' IN definition) = 0 THEN
    RAISE EXCEPTION 'read model timestamp ranking lacks deterministic ID tie-break';
  END IF;
  SELECT * INTO model FROM app.isms_risk_read_model WHERE risk_scenario_id='$RA';
  IF NOT FOUND THEN RAISE EXCEPTION 'ISO risk was not visible'; END IF;
  IF model.evidence_total_count <> 1 OR model.evidence_valid_count <> 1 THEN RAISE EXCEPTION 'duplicate evidence inflated counts'; END IF;
  IF jsonb_array_length(model.findings) <> 1 OR model.findings->0->>'title' <> 'bridged finding' THEN RAISE EXCEPTION 'finding attribution was not exact'; END IF;
  IF model.criterion_deviation_status <> 'active' THEN RAISE EXCEPTION 'criterion deviation status missing'; END IF;
  IF model.acceptance_freshness <> 'stale' THEN RAISE EXCEPTION 'stale acceptance was not reported'; END IF;
  IF EXISTS (SELECT 1 FROM app.isms_risk_read_model WHERE risk_scenario_id='$RB') THEN RAISE EXCEPTION 'cross-tenant ISO risk visible'; END IF;
END \$\$;
ROLLBACK;
SQL

echo 'isms_risk_read_model: OK (RLS, JST read date, deterministic ranking, distinct evidence, exact findings, deviation, stale acceptance)'
