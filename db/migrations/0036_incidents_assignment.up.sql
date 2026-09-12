-- 0036 app: add assignment to a risk owner and related-risk links to incident management
--
-- app.incidents was created in 0011 but was not used at all from the web side or by individual RLS settings,
-- and had only id/title/occurred_at/detected_at/severity/status
-- (confirmed by reading: no references in web/src/, 0 rows). RLS is already enabled by 0015's bulk application
-- (automatically covered as an app table with tenant_id), so only columns are added here.
--
-- Request: "for each incident, allow assigning its risk owner".
-- The existing app.memberships (role_key='risk_owner') and app.departments.owner_user_id
-- can be referenced as-is, so no dedicated assignee master is needed (principle of reusing existing code).

ALTER TABLE app.incidents
  ADD COLUMN summary          text NOT NULL DEFAULT '',
  ADD COLUMN related_risk_id  uuid,
  ADD COLUMN related_measure_id uuid,
  ADD COLUMN assignee_user_id uuid,
  ADD COLUMN resolved_at      timestamptz;

ALTER TABLE app.incidents
  ADD CONSTRAINT incidents_related_risk_fk
    FOREIGN KEY (tenant_id, related_risk_id) REFERENCES app.risk_scenarios(tenant_id, id),
  ADD CONSTRAINT incidents_related_measure_fk
    FOREIGN KEY (tenant_id, related_measure_id) REFERENCES app.measures(tenant_id, id),
  ADD CONSTRAINT incidents_assignee_fk
    FOREIGN KEY (tenant_id, assignee_user_id) REFERENCES app.users(tenant_id, id);

COMMENT ON COLUMN app.incidents.summary IS '発生状況・対応の要約';
COMMENT ON COLUMN app.incidents.related_risk_id IS '関連リスク(画面①)。設定時、部門のリスクオーナーをアサイン先の既定値として提案する';
COMMENT ON COLUMN app.incidents.related_measure_id IS '関連施策(画面③)。任意';
COMMENT ON COLUMN app.incidents.assignee_user_id IS 'アサイン先。app.memberships(role_key=''risk_owner'')を持つ利用者から選ぶ運用を想定するが、DB側では強制しない(事務局が変更可能な既定値のため)';
COMMENT ON COLUMN app.incidents.resolved_at IS 'status=''closed''にした時点を記録。未決事項(重大度基準・SLA)は運用実績を見てから決める';
