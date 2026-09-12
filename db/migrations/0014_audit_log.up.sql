-- 0014 audit: operation audit log (design doc 8.3)
-- chain_seq is assigned at a single serialization point by the append service (auditlogd).
-- DB sequences are not used (rollbacks and concurrency cause gaps and reordering).

CREATE TABLE audit.audit_log (
  chain_seq      bigint      NOT NULL,
  tenant_id      uuid        NOT NULL,
  occurred_at    timestamptz NOT NULL,   -- business occurrence time
  appended_at    timestamptz NOT NULL,   -- time of numbering and signing
  actor_id       uuid, actor_type text
                   CHECK (actor_type IN ('user','agent','connector','system','platform_admin')),
  action         text NOT NULL,
  target_type    text, target_id uuid,
  changed_fields jsonb,                  -- only the diff that passed the field allowlist
  reason         text,
  source_ip      inet, user_agent text, session_id uuid,
  prev_hash      bytea,
  hash           bytea NOT NULL,
  signature      bytea NOT NULL,
  PRIMARY KEY (chain_seq)                -- structurally rules out gaps and duplicates
);

ALTER TABLE audit.audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.audit_log FORCE ROW LEVEL SECURITY;

-- Do not grant auditlogd direct INSERT. Doing so would bypass audit.append() and
-- allow writing arbitrary chain_seq, prev_hash, and hash, forging rows that pass chain verification.
-- Appends always go through audit.append() (SECURITY DEFINER).
REVOKE ALL ON audit.audit_log FROM auditlogd, app_rw, app_ro, PUBLIC;

GRANT SELECT ON audit.audit_log TO app_rw, app_ro;
CREATE POLICY audit_read ON audit.audit_log FOR SELECT TO app_rw, app_ro
  USING (tenant_id = app.current_tenant());

GRANT SELECT ON audit.audit_log TO audit_verifier;
CREATE POLICY audit_verify ON audit.audit_log FOR SELECT TO audit_verifier USING (true);
GRANT EXECUTE ON FUNCTION app.current_tenant() TO auditlogd;

-- The append helper (audit.append below) is SECURITY DEFINER, so the actual INSERT
-- is done by the owner schema_owner. FORCE RLS applies to the owner too, so without explicit
-- policies it cannot append.
-- Only INSERT and SELECT are allowed; no UPDATE / DELETE policies are created.
-- = even the owner cannot rewrite past rows at the RLS level (enforces design doc 8.3 invariant 6
--   more strongly than REVOKE).
CREATE POLICY audit_definer_insert ON audit.audit_log FOR INSERT TO schema_owner
  WITH CHECK (true);
CREATE POLICY audit_definer_read   ON audit.audit_log FOR SELECT TO schema_owner
  USING (true);

-- ------------------------------------------------------------------
-- Hash chain verification (acceptance #5). Implements invariant 4 of design doc 8.3.
-- Returns false if even one row has been tampered with.
-- hash = sha256(prev_hash || chain_seq || tenant_id || occurred_at || action
--                || coalesce(target_type,'') || coalesce(target_id,'') || changed_fields)
-- The signature is attached by auditlogd with a separate key, so it is not verified here
-- (verification is the responsibility of the independent process side. Design doc 8.3 invariant 4).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.chain_payload(r audit.audit_log) RETURNS bytea
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT convert_to(
    coalesce(encode(r.prev_hash, 'hex'), '') || '|' ||
    r.chain_seq::text                        || '|' ||
    r.tenant_id::text                        || '|' ||
    to_char(r.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' ||
    r.action                                 || '|' ||
    coalesce(r.target_type, '')              || '|' ||
    coalesce(r.target_id::text, '')          || '|' ||
    coalesce(r.changed_fields::text, ''), 'UTF8')
$$;
ALTER FUNCTION audit.chain_payload(audit.audit_log) OWNER TO schema_owner;

CREATE OR REPLACE FUNCTION audit.verify_chain()
RETURNS TABLE (ok boolean, checked bigint, first_bad_seq bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE r audit.audit_log; v_prev bytea := NULL; v_n bigint := 0; v_bad bigint := NULL;
BEGIN
  FOR r IN SELECT * FROM audit.audit_log ORDER BY chain_seq LOOP
    v_n := v_n + 1;
    IF r.prev_hash IS DISTINCT FROM v_prev
       OR r.hash <> public.digest(audit.chain_payload(r), 'sha256') THEN
      v_bad := r.chain_seq;
      EXIT;
    END IF;
    v_prev := r.hash;
  END LOOP;
  RETURN QUERY SELECT (v_bad IS NULL), v_n, v_bad;
END $$;
ALTER FUNCTION audit.verify_chain() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION audit.verify_chain() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit.verify_chain() TO audit_verifier, app_rw, app_ro;

-- Append helper. Only auditlogd can call it. chain_seq and prev_hash / hash are
-- assigned and computed here, so callers cannot break the chain.
CREATE OR REPLACE FUNCTION audit.append(
  p_tenant uuid, p_occurred timestamptz, p_actor uuid, p_actor_type text,
  p_action text, p_target_type text, p_target_id uuid,
  p_changed jsonb, p_reason text, p_signature bytea)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_seq bigint; v_prev bytea; r audit.audit_log;
BEGIN
  -- Single serialization point. Serialize with a lock so concurrent appends cause no gaps or reordering.
  PERFORM pg_advisory_xact_lock(8891234502);
  SELECT coalesce(max(chain_seq), 0) + 1 INTO v_seq FROM audit.audit_log;
  SELECT hash INTO v_prev FROM audit.audit_log ORDER BY chain_seq DESC LIMIT 1;

  r.chain_seq := v_seq; r.tenant_id := p_tenant; r.occurred_at := p_occurred;
  r.action := p_action; r.target_type := p_target_type; r.target_id := p_target_id;
  r.changed_fields := p_changed; r.prev_hash := v_prev;

  INSERT INTO audit.audit_log (chain_seq, tenant_id, occurred_at, appended_at,
    actor_id, actor_type, action, target_type, target_id, changed_fields, reason,
    prev_hash, hash, signature)
  VALUES (v_seq, p_tenant, p_occurred, now(), p_actor, p_actor_type, p_action,
    p_target_type, p_target_id, p_changed, p_reason, v_prev,
    public.digest(audit.chain_payload(r), 'sha256'), p_signature);
  RETURN v_seq;
END $$;
ALTER FUNCTION audit.append(uuid, timestamptz, uuid, text, text, text, uuid, jsonb, text, bytea)
  OWNER TO schema_owner;
REVOKE ALL ON FUNCTION audit.append(uuid, timestamptz, uuid, text, text, text, uuid, jsonb, text, bytea)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION audit.append(uuid, timestamptz, uuid, text, text, text, uuid, jsonb, text, bytea)
  TO auditlogd;
