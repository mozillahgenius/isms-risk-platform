-- 0011 の巻き戻し（依存の逆順）
DROP TABLE IF EXISTS app.approvals;
DROP TABLE IF EXISTS app.tasks;
DROP TABLE IF EXISTS app.incidents;
DROP TABLE IF EXISTS app.vendor_assessments;
DROP TABLE IF EXISTS app.vendors;
DROP TABLE IF EXISTS app.management_review_outputs;
DROP TABLE IF EXISTS app.management_review_inputs;
DROP TABLE IF EXISTS app.management_reviews;
DROP TABLE IF EXISTS app.auditor_competences;
DROP TABLE IF EXISTS app.audit_items;
DROP TABLE IF EXISTS app.audits;
DROP TABLE IF EXISTS app.audit_programs;
DROP TABLE IF EXISTS app.training_records;
DROP TABLE IF EXISTS app.trainings;
DROP TABLE IF EXISTS app.policy_acknowledgements;
DROP TABLE IF EXISTS app.policy_versions;
DROP TABLE IF EXISTS app.policies;
DROP TABLE IF EXISTS app.corrective_actions;
-- 0010 の exceptions に後付けした FK を先に外す
ALTER TABLE IF EXISTS app.exceptions DROP CONSTRAINT IF EXISTS exceptions_finding_fk;
DROP TABLE IF EXISTS app.findings;
