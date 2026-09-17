-- @run-as: admin

-- 関数を落とすだけ。**承認記録（app.approvals の行）は消さない。**
-- 承認したという事実は 0056 が入る前から app.approvals に置ける形で、
-- この migration が作ったのは経路であって記録ではない。
-- 経路を戻すために証跡を消すのは筋が違う。

SET ROLE schema_owner;

DROP FUNCTION IF EXISTS app.approve_iso_scope(text);

RESET ROLE;
