-- 0013 の巻き戻し
DROP VIEW IF EXISTS app.effective_risk_criteria;
DROP FUNCTION IF EXISTS app.jsonb_to_int_array(jsonb);
DROP FUNCTION IF EXISTS app.expire_deviations();
DROP TABLE IF EXISTS app.deviations;
