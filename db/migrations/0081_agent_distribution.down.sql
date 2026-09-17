SET ROLE schema_owner;
CREATE OR REPLACE FUNCTION app.mark_mail_sent(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, app AS $$
DECLARE v_purpose text; v_related_type text; v_related_id uuid;
BEGIN
  PERFORM app.require_mail_worker();
  UPDATE app.mail_outbox
     SET status='sent', sent_at=now(), last_error='', updated_at=now()
   WHERE tenant_id=app.current_tenant() AND id=p_id AND status='sending'
  RETURNING purpose, related_type, related_id INTO v_purpose, v_related_type, v_related_id;
  IF v_purpose IS NULL THEN RAISE EXCEPTION 'mail % is not in sending state', p_id; END IF;
  IF v_purpose='external_questionnaire' AND v_related_type='external_questionnaire' THEN
    UPDATE app.external_questionnaires SET status='sent', sent_at=now(), updated_at=now()
     WHERE tenant_id=app.current_tenant() AND id=v_related_id AND status='queued';
  END IF;
END $$;
ALTER FUNCTION app.mark_mail_sent(uuid) OWNER TO schema_owner;
REVOKE ALL ON FUNCTION app.mark_mail_sent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.mark_mail_sent(uuid) TO mail_worker;
DROP FUNCTION IF EXISTS app.mark_agent_installation(bytea,text,text,uuid,text);
DROP FUNCTION IF EXISTS app.lookup_agent_installation(bytea);
DROP FUNCTION IF EXISTS app.issue_agent_installation(text,text,text,text,text,text,interval);
DROP TABLE IF EXISTS app.agent_installations;
ALTER TABLE app.mail_outbox
  DROP CONSTRAINT IF EXISTS mail_outbox_purpose_check;
ALTER TABLE app.mail_outbox
  ADD CONSTRAINT mail_outbox_purpose_check
  CHECK (purpose IN ('external_questionnaire','work_assignment'));
RESET ROLE;
