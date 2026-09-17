-- 配布記録の巻き戻し保護は、0081適用後の後続migrationとして管理する。
-- 既存migrationのdownファイルを変更せず、data-bearing rollback rehearsalで
-- 0083のdownを先に実行して配布記録の消失を拒否できるようにする。
SELECT 1;
