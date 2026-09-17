-- 0036 app: インシデント管理にリスクオーナーへのアサインと関連リスク紐付けを追加
--
-- app.incidents は 0011 で作成済みだが、Web側からもRLS個別設定からも一切
-- 使われておらず、id/title/occurred_at/detected_at/severity/status しか
-- 無かった(実読で確認: web/src/ に参照なし、行数0)。RLSは0015の一括適用で
-- 既に有効(tenant_idを持つapp表として自動対象)なので、ここでは列追加のみ。
--
-- 依頼: 「各インシデントについて、そのリスクオーナーをアサインできるように」。
-- 既存の app.memberships(role_key='risk_owner') と app.departments.owner_user_id
-- をそのまま参照先にでき、独自のアサイン先マスタは不要(既存コード再利用の原則)。

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
