-- 0043: メンバーシップ・部門責任者への付与をDB側でも堅牢化する
--
-- 背景(Codexレビュー2026-09-03指摘): organization/actions.ts のアプリ層で
-- 対象ユーザー行をFOR UPDATEでロックし、退職・停止済みユーザーへの役割付与を
-- 拒否するよう直したが、これはWebアプリのServer Action経路にしか効かない。
-- app_rw ロールを持つ別経路(直接SQL、将来の別アプリ・バッチ等)から
-- app.memberships / app.departments へ直接INSERTされると、
--   1) 監査人の兼任禁止トリガー(0005 check_auditor_exclusivity)は同時INSERTの
--      未コミット行を見落とし、兼任状態のまま両方コミットされ得る
--   2) 退職・停止済みユーザーへの役割付与・部門責任者指定を止める仕組みが無い
-- という2つの穴がアプリ層の修正だけでは残る。0005は本番デプロイ済みで
-- 直接編集できない(frozen)ため、CREATE OR REPLACE FUNCTION でトリガー本体を
-- ここで差し替える。
--
-- 注: BEGIN/COMMITはここには書かない。scripts/migrate.shがファイル全体を
-- 既に1トランザクションで包んでいる(DDL+台帳更新のアトミック性のため)。
--
-- 注(Codexレビュー2026-09-03 5回目指摘、実測で確認): app.provision_tenant()
-- (0021, SECURITY DEFINER・所有者schema_owner)はテナント新規作成時に
-- 初期の管理者membershipをINSERTし、その際このファイルのトリガーも発火する。
-- ところがschema_ownerのapp.usersに対するRLSポリシーは0005の
-- ctx_user_lookup(SELECT専用, USING(true))とprov_user_insert(INSERT専用)
-- のみで、UPDATE/ALLに該当するポリシーが無い。PostgreSQLの仕様上、
-- SELECT ... FOR UPDATEはUPDATEコマンド相当のポリシー適用を受けるため、
-- 対象行がSELECTでは見えていてもFOR UPDATEでは0行に絞り込まれ、ロックが
-- 静かに空振りする(エラーにはならず、実測で確認: SET ROLE schema_owner;
-- SELECT ... FOR UPDATE が既存行に対して0件を返した)。schema_ownerでの
-- ロックを実効化するため、契約の狭いUPDATE専用ポリシーを追加する
-- (0005のctx_user_lookupと同じ「定義者が文脈確立・プロビジョニングのために
-- 必要な最小限だけ見える」方針を踏襲。schema_ownerは既にprov_user_insertで
-- app.usersへの任意INSERTを持つ信頼された定義者ロールであり、ロック目的の
-- UPDATE可視性を追加しても信頼境界は実質的に変わらない)。
--
-- 注(Codexレビュー2026-09-03 6回目指摘、検討・棄却): 以下2案を検討し
-- いずれも採らなかった。
--   (a) advisory lock (pg_advisory_xact_lock) への置き換え:
--       このリポジトリの0018→0019で既に検証・却下済みの手法。advisory lock
--       はロック待ちが終わってもREAD COMMITTEDのスナップショットを更新
--       しないため、待った後も相手のコミット結果が見えず、直列化の体を
--       成さない(0019_tenant_row_lock.up.sqlの解説を参照)。行ロックの
--       方が正しい。
--   (b) FOR UPDATEの代わりにFOR SHAREを使えばUPDATE系ポリシーが不要になる
--       のでは、という案: 実測で否定した。ctx_user_lockを外した状態で
--       SET ROLE schema_owner; SELECT ... FOR SHARE を既存行に対して実行
--       すると、FOR UPDATEと同じく0件になった。PostgreSQLのRLSは
--       FOR SHARE/FOR UPDATEを区別せずどちらもUPDATE系ポリシーの充足を
--       要求するため、この代替では回避できない。
-- 結論: RLS配下でschema_ownerに行ロックを取らせる以上、UPDATE可視性の
-- 付与(ctx_user_lock)以外に選択肢が無い。
--
-- 注(Codexレビュー2026-09-03 8回目指摘、対応): ただし付与範囲は全テナント・
-- 全行に広げる必要は無かった。0021のprov_user_insert等が既に使っている
-- app.provisioning_target()(SET LOCALのGUC 'app.provisioning'を読む
-- STABLE関数)は、provision_tenant()(0021/0022どちらの再定義でも
-- membershipsへのINSERTの前にset_configされている)実行中だけ、
-- いま作成中のテナントIDを返す。これと同じ絞り込みをctx_user_lockの
-- USING/WITH CHECKにも適用し、「schema_ownerが任意テナントの任意行を
-- ロック・更新できる」ではなく「いま作っているテナントの行だけ」に
-- 狭める(prov_user_insertと同じ信頼境界)。
CREATE POLICY ctx_user_lock ON app.users FOR UPDATE TO schema_owner
  USING (tenant_id = app.provisioning_target())
  WITH CHECK (tenant_id = app.provisioning_target());

-- (1) 監査人の兼任禁止(0005)の同時実行raceを閉じる。
-- 対象ユーザー行(app.users)をFOR UPDATEでロックしてから兼任チェックする。
-- 同一ユーザーへの同時INSERT/UPDATEはこのロックで直列化され、後続の
-- トランザクションは先行トランザクションのコミット結果を必ず見てから
-- 判定できるようになる(ロックが無いと互いの未コミット行を見落とす)。
CREATE OR REPLACE FUNCTION app.check_auditor_exclusivity() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  PERFORM 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.user_id FOR UPDATE;
  IF EXISTS (
    SELECT 1 FROM app.memberships m
    WHERE m.tenant_id = NEW.tenant_id AND m.user_id = NEW.user_id
      AND m.revoked_at IS NULL AND m.id <> NEW.id
      AND (m.role_key = 'auditor') <> (NEW.role_key = 'auditor')
  ) THEN
    RAISE EXCEPTION 'auditor role cannot be combined with other roles';
  END IF;
  RETURN NEW;
END $$;

-- (2) 退職・停止済みユーザーへの役割付与をDB側でも拒否する。
-- このトリガー単体でもFOR UPDATEでロックする。trg_auditor_exclusivity
-- (トリガー名の辞書順で先に発火し、同じユーザー行をロックする)に
-- 依存すれば偶然closeされるが、それは発火順という暗黙の前提に頼ることに
-- なり壊れやすい。関数単体で自己完結させる(Codexレビュー2026-09-03
-- 4回目指摘: 「ロックパターンに統一」というコメントと実装が食い違って
-- いた)。
CREATE OR REPLACE FUNCTION app.check_membership_active_user() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  PERFORM 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.user_id FOR UPDATE;
  IF NOT EXISTS (
    SELECT 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.user_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'membership cannot be granted to a non-active user';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_membership_active_user BEFORE INSERT OR UPDATE ON app.memberships
  FOR EACH ROW WHEN (NEW.revoked_at IS NULL)
  EXECUTE FUNCTION app.check_membership_active_user();

-- (3) 部門責任者(owner_user_id)も同様に、非活性ユーザーを指定できないようにする。
-- FOR UPDATEで対象ユーザー行をロックしてから確認する。ロックが無いと、
-- 「トランザクションAがactiveを確認→トランザクションBが同じユーザーを
-- suspendedへ更新してコミット→Aが部門登録をコミット」というTOCTOUが
-- DB側のこのトリガー自体に残る(Codexレビュー2026-09-03 3回目指摘)。
CREATE OR REPLACE FUNCTION app.check_department_owner_active() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF NEW.owner_user_id IS NOT NULL THEN
    PERFORM 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.owner_user_id FOR UPDATE;
    IF NOT EXISTS (
      SELECT 1 FROM app.users WHERE tenant_id = NEW.tenant_id AND id = NEW.owner_user_id AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'department owner must be an active user';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_department_owner_active BEFORE INSERT OR UPDATE ON app.departments
  FOR EACH ROW EXECUTE FUNCTION app.check_department_owner_active();
