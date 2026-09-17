-- 0013 app: 逸脱（設計書 2.5 / 1.11）と有効なリスク基準の解決ビュー

CREATE TABLE app.deviations (
  id            uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL,
  kind          text NOT NULL CHECK (kind IN (
                  'risk_band','check_disable','check_threshold',
                  'calendar_extend','policy_edit')),
  target_key    text NOT NULL,                     -- catalog 側のキー
  override      jsonb NOT NULL,                    -- 上書き後の値
  reason        text NOT NULL CHECK (length(btrim(reason)) > 0),
  compensating_control text,                       -- check_disable では必須
  status        text NOT NULL DEFAULT 'requested'
                  CHECK (status IN ('requested','active','expired','withdrawn','rejected')),
  requested_by  uuid NOT NULL, requested_at timestamptz NOT NULL DEFAULT now(),
  approved_by   uuid,          approved_at  timestamptz,
  expires_at    timestamptz,                       -- active では必須
  withdrawn_at  timestamptz,
  weight        numeric(4,1) NOT NULL,             -- 標準適合度スコアの重み（設計書 1.12）
  created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid,
  PRIMARY KEY (tenant_id, id),

  CHECK (kind <> 'check_disable' OR length(btrim(coalesce(compensating_control,''))) > 0),
  -- approved_at も必須にする。設計書は approved_by と expires_at しか要求していないが、
  -- approved_at が NULL だと下の期限上限 CHECK が NULL 比較になり、
  -- 「期限は必須」と書いてあるのに上限が一切効かない（NULL は CHECK を通る）。
  CHECK (status <> 'active'
         OR (approved_by IS NOT NULL AND approved_at IS NOT NULL AND expires_at IS NOT NULL)),
  CHECK (approved_at IS NULL OR expires_at IS NULL OR expires_at > approved_at),
  -- 期限上限（設計書 1.11.3）
  CHECK (status <> 'active' OR expires_at <= approved_at + CASE kind
           WHEN 'check_disable'   THEN interval '180 days'
           WHEN 'check_threshold' THEN interval '180 days'
           ELSE interval '365 days' END)
);
CREATE INDEX deviations_active
  ON app.deviations (tenant_id, kind, target_key) WHERE status = 'active';

-- リスク基準の逸脱は「テナントにつき同時に 1 本」。
-- 複数の active を許すと effective_risk_criteria が同一テナントに複数行を返し、
-- どれが有効な基準なのかが決まらない（設計書のビュー定義は target_key を見ていない）。
CREATE UNIQUE INDEX deviations_one_active_risk_band
  ON app.deviations (tenant_id)
  WHERE kind = 'risk_band' AND status = 'active';

-- 期限切れを毎日 active → expired へ落とす（標準へ自動復帰。受入 #4）
CREATE OR REPLACE FUNCTION app.expire_deviations() RETURNS int
LANGUAGE sql SET search_path = pg_catalog, app AS $$
  WITH x AS (
    UPDATE app.deviations SET status = 'expired'
    WHERE status = 'active' AND expires_at <= now() RETURNING 1
  ) SELECT count(*)::int FROM x;
$$;
ALTER FUNCTION app.expire_deviations() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.expire_deviations() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.expire_deviations() TO app_rw;

-- ------------------------------------------------------------------
-- 有効な設定値の解決は必ずこのビュー経由にする（アプリが catalog を
-- 直接読むと逸脱を無視した挙動になる）。
--
-- 設計書 2.5 からの修正 2 点（理由は docs/DECISIONS.md D-03）:
--   1. security_invoker = true を明示する。既定（definer 権限で評価）だと
--      呼出者ではなくビュー所有者の権限で下位表を読み、RLS を迂回する。
--   2. 設計書は (d.override->>'band_top_priority')::int[] と書いているが、
--      ->> は JSON 配列を '[15, 16]' という文字列で返すため int[] へ
--      キャストできない（PostgreSQL の配列リテラルは '{15,16}'）。
--      jsonb_array_elements_text を通して配列を組み立てる。
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.jsonb_to_int_array(p jsonb) RETURNS int[]
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE
           WHEN p IS NULL OR jsonb_typeof(p) <> 'array' THEN NULL
           ELSE ARRAY(SELECT jsonb_array_elements_text(p)::int)
         END
$$;
ALTER FUNCTION app.jsonb_to_int_array(jsonb) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.jsonb_to_int_array(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.jsonb_to_int_array(jsonb) TO app_rw, app_ro;

CREATE VIEW app.effective_risk_criteria WITH (security_invoker = true) AS
SELECT t.id AS tenant_id,
       coalesce(app.jsonb_to_int_array(d.override->'band_top_priority'), c.band_top_priority)
         AS band_top_priority,
       coalesce(app.jsonb_to_int_array(d.override->'band_action'),       c.band_action)
         AS band_action,
       coalesce(app.jsonb_to_int_array(d.override->'band_consider'),     c.band_consider)
         AS band_consider,
       coalesce(app.jsonb_to_int_array(d.override->'band_accept'),       c.band_accept)
         AS band_accept,
       c.impact_sec_formula,
       (d.id IS NOT NULL) AS is_deviated
FROM app.tenants t
JOIN catalog.risk_criteria_default c ON c.dom_version_id = t.dom_version_id
LEFT JOIN app.deviations d
  ON d.tenant_id = t.id AND d.kind = 'risk_band' AND d.status = 'active';
ALTER VIEW app.effective_risk_criteria OWNER TO schema_owner;
GRANT SELECT ON app.effective_risk_criteria TO app_rw, app_ro;
