SET ROLE schema_owner;
DROP TRIGGER IF EXISTS trg_guard_questionnaire_template_question ON app.questionnaire_template_questions;
DROP TRIGGER IF EXISTS trg_guard_questionnaire_template ON app.questionnaire_templates;
DROP FUNCTION IF EXISTS app.guard_questionnaire_template();
ALTER TABLE app.external_questionnaires
  DROP CONSTRAINT IF EXISTS external_questionnaires_template_fk;
ALTER TABLE app.external_questionnaires DROP COLUMN IF EXISTS template_id;
DROP TABLE IF EXISTS app.questionnaire_template_questions;
DROP TABLE IF EXISTS app.questionnaire_templates;
RESET ROLE;
