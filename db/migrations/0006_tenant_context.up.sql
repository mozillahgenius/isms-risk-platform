-- 0006 app: tenant context (implements design doc 9.2; but the design doc's plain implementation
-- fails acceptance #7, so signature verification is added. For the reason for the deviation and
-- "the scope of properties that can be proven", see docs/DECISIONS.md D-01 / D-02).
--
-- Depends on: 0005's app.sessions / app.memberships, 0001's pgcrypto.

-- ------------------------------------------------------------------
-- Signing key. Only schema_owner can touch it. Never granted to app_rw / app_ro.
-- It is a singleton (only one row allowed) and read with SELECT ... INTO STRICT.
-- ------------------------------------------------------------------
CREATE TABLE app.tenant_context_keys (
  id         smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  secret     bytea NOT NULL CHECK (octet_length(secret) >= 32),
  rotated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON TABLE app.tenant_context_keys FROM PUBLIC;
REVOKE ALL ON TABLE app.tenant_context_keys FROM app_rw, app_ro, auditlogd, audit_verifier;

INSERT INTO app.tenant_context_keys (id, secret) VALUES (1, gen_random_bytes(32));

-- ------------------------------------------------------------------
-- Signature material. Make the delimiter and version explicit to remove ambiguity (prevents concatenation misreads).
-- pg_stat_activity is not used (inside SECURITY DEFINER the owner cannot see other roles'
-- session rows, so backend_start can be NULL).
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.tenant_context_signature(p_tenant uuid) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_secret bytea; v_payload text;
BEGIN
  IF p_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is null' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT secret INTO STRICT v_secret FROM app.tenant_context_keys WHERE id = 1;
  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'tenant context key is missing' USING ERRCODE = 'insufficient_privilege';
  END IF;
  v_payload := 'v1:' || p_tenant::text || ':' || pg_catalog.pg_backend_pid()::text;
  RETURN pg_catalog.encode(
           public.hmac(pg_catalog.convert_to(v_payload, 'UTF8'), v_secret, 'sha256'), 'hex');
END $$;
ALTER FUNCTION app.tenant_context_signature(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.tenant_context_signature(uuid) FROM PUBLIC;
-- Only the two functions below may call this. App roles are not given EXECUTE
-- (granting it would let them forge signatures for any tenant).

-- ------------------------------------------------------------------
-- Set the context. The argument is "a secret held by the caller" = the session token itself.
-- The DB holds only the hash, so anyone who does not know the token cannot create a context.
-- set_config(..., true) = equivalent to SET LOCAL. It disappears at transaction end
-- (no context lingers after returning to the connection pool = acceptance #8).
-- Call sequence: BEGIN -> set_tenant_context -> business queries -> COMMIT.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.set_tenant_context(p_token text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_tenant uuid;
BEGIN
  IF p_token IS NULL OR pg_catalog.length(p_token) < 32 THEN
    RAISE EXCEPTION 'invalid session' USING ERRCODE = 'insufficient_privilege';
  END IF;
  -- Do not keep sessions alive for users/tenants suspended after issuance.
  -- Looking only at expiry and revocation, access would continue with a token already in hand
  -- even after offboarding a user or closing a tenant.
  SELECT m.tenant_id INTO v_tenant
    FROM app.sessions s
    JOIN app.memberships m
      ON m.user_id = s.user_id AND m.tenant_id = s.tenant_id AND m.revoked_at IS NULL
    JOIN app.users u   ON u.tenant_id = s.tenant_id AND u.id = s.user_id
    JOIN app.tenants t ON t.id = s.tenant_id
   WHERE s.token_hash = public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256')
     AND s.expires_at > pg_catalog.now()
     AND s.revoked_at IS NULL
     AND u.status = 'active'
     AND t.status = 'active'
   LIMIT 1;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'invalid session' USING ERRCODE = 'insufficient_privilege';
  END IF;
  PERFORM pg_catalog.set_config('app.tenant_id',  v_tenant::text, true);
  PERFORM pg_catalog.set_config('app.tenant_sig', app.tenant_context_signature(v_tenant), true);
  RETURN v_tenant;
END $$;
ALTER FUNCTION app.set_tenant_context(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.set_tenant_context(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.set_tenant_context(text) TO app_rw, app_ro;

-- ------------------------------------------------------------------
-- Read the context. Do not trust the GUC blindly; recompute and compare the signature.
-- A connection that did a direct SET app.tenant_id cannot produce a signature, so it fails here.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.current_tenant() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE
  v_id  text := pg_catalog.current_setting('app.tenant_id',  true);
  v_sig text := pg_catalog.current_setting('app.tenant_sig', true);
  v_tenant uuid;
BEGIN
  IF v_id IS NULL OR v_id = '' THEN
    RAISE EXCEPTION 'tenant context is not set' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_sig IS NULL OR pg_catalog.length(v_sig) <> 64 THEN
    RAISE EXCEPTION 'tenant context is not signed' USING ERRCODE = 'insufficient_privilege';
  END IF;
  BEGIN
    v_tenant := v_id::uuid;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'tenant context is malformed' USING ERRCODE = 'insufficient_privilege';
  END;
  IF v_sig <> app.tenant_context_signature(v_tenant) THEN
    RAISE EXCEPTION 'tenant context signature mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_tenant;
END $$;
ALTER FUNCTION app.current_tenant() OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.current_tenant() FROM PUBLIC;
-- app_ro also calls this when evaluating RLS policy expressions, so it needs EXECUTE.
GRANT EXECUTE ON FUNCTION app.current_tenant() TO app_rw, app_ro;

-- ------------------------------------------------------------------
-- Issue a session. The caller generates the token with a CSPRNG and passes it in; only the hash stays in the DB.
--
-- **Execute privilege is granted only to auth_svc, not to app_rw.**
-- If app_rw could call this, it could issue a session for any tenant's uuid
-- and pass set_tenant_context() with that token. Signature verification and
-- token hash comparison mean nothing if issuance itself is unrestricted.
-- Only the authentication path (login handling) connects as auth_svc.
-- ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.create_session(
  p_tenant uuid, p_user uuid, p_token text, p_ttl interval DEFAULT interval '12 hours')
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_id uuid;
BEGIN
  -- Reject fewer than 32 characters as insufficient minimum entropy (recommended: hex of 32 CSPRNG bytes = 64 characters)
  IF p_token IS NULL OR pg_catalog.length(p_token) < 32 THEN
    RAISE EXCEPTION 'session token is too short';
  END IF;
  IF p_ttl IS NULL OR p_ttl <= interval '0' OR p_ttl > interval '24 hours' THEN
    RAISE EXCEPTION 'session ttl must be within 24 hours';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM app.memberships m
                   JOIN app.users u   ON u.tenant_id = m.tenant_id AND u.id = m.user_id
                   JOIN app.tenants t ON t.id = m.tenant_id
                  WHERE m.tenant_id = p_tenant AND m.user_id = p_user
                    AND m.revoked_at IS NULL
                    AND u.status = 'active' AND t.status = 'active') THEN
    RAISE EXCEPTION 'user has no active membership in an active tenant';
  END IF;
  INSERT INTO app.sessions (tenant_id, user_id, token_hash, expires_at)
  VALUES (p_tenant, p_user,
          public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256'),
          pg_catalog.now() + p_ttl)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
ALTER FUNCTION app.create_session(uuid, uuid, text, interval) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.create_session(uuid, uuid, text, interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.create_session(uuid, uuid, text, interval) TO auth_svc;

-- Revocation. Rotation is done as "create_session with a new token -> revoke the old one".
CREATE OR REPLACE FUNCTION app.revoke_session(p_token text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog AS $$
DECLARE v_n int;
BEGIN
  UPDATE app.sessions SET revoked_at = pg_catalog.now()
   WHERE token_hash = public.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256')
     AND revoked_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
ALTER FUNCTION app.revoke_session(text) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.revoke_session(text) FROM PUBLIC;
-- Only someone who knows the token can revoke it (cutting off one's own session is legitimate).
GRANT EXECUTE ON FUNCTION app.revoke_session(text) TO auth_svc, app_rw;

-- auth_svc must not touch context establishment or business data. Its only role is issuing sessions.
GRANT USAGE ON SCHEMA app TO auth_svc;
