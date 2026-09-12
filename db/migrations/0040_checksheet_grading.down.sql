-- 0040 down: remove the storage for automatic checksheet grading
DROP TABLE IF EXISTS app.checksheet_answers;
DROP TABLE IF EXISTS app.checksheet_submissions;
