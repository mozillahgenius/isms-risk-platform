-- @run-as: admin
-- 0055: 情報セキュリティ目的（JIS Q 27001:2023 6.2）の受け皿。
--
-- 6.2 は「測定可能な目的」と「達成をどう評価するか」を求める。
-- 数値目標だけを残しても、どう測るかが無ければ達成したかを誰も言えない。
-- そこで measure_how（測り方）を NOT NULL にし、目的だけの登録を許さない。
--
-- 達成の記録（実測値・評価日・評価者）は **達成したときに書く**。
-- 目的を立てた時点では空で、空であること自体が「まだ測っていない」を表す。

SET ROLE schema_owner;

CREATE TABLE app.security_objectives (
  id                uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL,
  fiscal_year       integer NOT NULL,
  title             text NOT NULL,
  -- 何をどこまで、を言葉で書く欄。空の目的を作らせない。
  description       text NOT NULL DEFAULT '',
  -- **測り方は必須**。測れない目的は 6.2 の目的ではない。
  measure_how       text NOT NULL,
  target_value      text NOT NULL DEFAULT '',
  owner_user_id     uuid,
  due_date          date,
  -- 以下は達成を評価したときにだけ入る。立てた時点では空。
  achieved_value    text,
  evaluated_at      timestamptz,
  evaluated_by      uuid,
  status            text NOT NULL DEFAULT 'planned'
                    CHECK (status IN ('planned','in_progress','achieved','not_achieved','cancelled')),
  source_note       text NOT NULL DEFAULT '',
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  updated_by        uuid,
  PRIMARY KEY (tenant_id, id),
  UNIQUE (tenant_id, fiscal_year, title),
  FOREIGN KEY (tenant_id, owner_user_id) REFERENCES app.users(tenant_id, id),
  FOREIGN KEY (tenant_id, evaluated_by)  REFERENCES app.users(tenant_id, id),
  -- 測り方を空文字で埋めて回避できないようにする。
  CHECK (length(btrim(measure_how)) > 0),
  -- **評価したと言うなら、誰がいつ何を測ったかが要る。** 3 つ揃うか、3 つとも空か。
  CHECK (
    (achieved_value IS NULL AND evaluated_at IS NULL AND evaluated_by IS NULL)
    OR (achieved_value IS NOT NULL AND evaluated_at IS NOT NULL AND evaluated_by IS NOT NULL)
  ),
  -- 達成・未達成と言うなら評価が済んでいること。状態だけ先に進めさせない。
  CHECK (status NOT IN ('achieved','not_achieved') OR evaluated_at IS NOT NULL)
);
CREATE INDEX security_objectives_year ON app.security_objectives (tenant_id, fiscal_year);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['security_objectives'] LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON app.%I FOR ALL TO app_rw USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY tenant_read ON app.%I FOR SELECT TO app_ro USING (tenant_id=app.current_tenant())',t);
    EXECUTE format('CREATE POLICY management_definer_access ON app.%I FOR ALL TO schema_owner USING (tenant_id=app.current_tenant()) WITH CHECK (tenant_id=app.current_tenant())',t);
    EXECUTE format('REVOKE ALL ON app.%I FROM PUBLIC',t);
    EXECUTE format('GRANT SELECT ON app.%I TO app_ro',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO app_rw',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE,DELETE ON app.%I TO schema_owner',t);
  END LOOP;
END $$;

COMMENT ON TABLE app.security_objectives IS
  '情報セキュリティ目的（6.2）。measure_how は測り方で必須。達成の評価は achieved_value / evaluated_at / evaluated_by が揃ったときだけ成立する。';

RESET ROLE;
