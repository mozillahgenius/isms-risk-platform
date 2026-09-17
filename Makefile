.PHONY: help db-reset migrate down seed business-seed business-control-status test risk-register-test phase0 ci connector-test agent-test \
        web-install web web-build web-start web-test web-check web-verify \
        tenant checker checker-test \
        backup backup-verify

ISMS_DB ?= isms_dev

help:
	@echo "make db-reset     空 DB を作り直して全マイグレーションを適用"
	@echo "make migrate      未適用のマイグレーションを適用"
	@echo "make down         直近 1 本を巻き戻す（make down N=all で全部）"
	@echo "make seed         DOM 2026.1 と既存 CSV マスタを投入（冪等）＋出所を記録"
	@echo "make business-seed 自社の資産・施策・リスク初期案を投入（テナントトークンが必要）"
	@echo "make business-control-status 自社管理策の実態判定を反映（テナントトークンが必要）"
	@echo "make sync-policies 標準規程を既存テナントへ反映（DRY=1 で巻き戻して確認だけ）"
	@echo "make risk-register-test リスク台帳の不正入力と履歴権限を確認"
	@echo "make test         テナント分離・ドメイン制約のテスト（使い捨て DB。isms_dev は汚さない）"
	@echo "make phase0       Phase 0 の受入（xlsx 往復・差分 0 件）"
	@echo "make ci           品質ゲート一式（DB 側）"
	@echo ""
	@echo "make tenant       テナントを 1 つ作りセッショントークンを出す（NAME/DOMAIN/EMAIL/ADMIN）"
	@echo "make checker      標準チェックを実行（TOKEN=... RECEIPT_ID=... 。落ちることを確かめてから合否を出す）"
	@echo "make checker-test チェック機能の受入（隔離 DB で通しに確かめる）"
	@echo "make agent-test   Phase 3a macOS エージェント受入（隔離 DB + API）"
	@echo ""
	@echo "make web-install  画面の依存を入れる（lockfile どおり）"
	@echo "make web          画面を開発モードで起動（http://0.0.0.0:3110）"
	@echo "make web-build    画面を本番ビルド"
	@echo "make web-start    ビルド済みの画面を起動（http://0.0.0.0:3110）"
	@echo "make web-check    画面の型検査・lint・単体テスト・ビルド"
	@echo "make web-verify   上に加えて外形検査（空 DB・DB 断で実際に落ちるかまで見る）"
	@echo ""
	@echo "make backup        DB を pg_dump -Fc でバックアップ（既定 ~/backups/isms-platform）"
	@echo "make backup-verify 最新バックアップを使い捨て DB へ実際に復旧して検証"

db-reset:
	dropdb --if-exists $(ISMS_DB)
	createdb $(ISMS_DB)
	ISMS_DB=$(ISMS_DB) ./scripts/migrate.sh up

migrate:
	ISMS_DB=$(ISMS_DB) ./scripts/migrate.sh up

N ?= 1
down:
	ISMS_DB=$(ISMS_DB) ./scripts/migrate.sh down $(N)

backup:
	ISMS_DB=$(ISMS_DB) ./scripts/backup_restore.sh backup

backup-verify:
	ISMS_DB=$(ISMS_DB) ./scripts/backup_restore.sh verify

seed:
	psql -v ON_ERROR_STOP=1 -q -d $(ISMS_DB) -f db/seeds/0001_dom_2026_1.sql
	ISMS_DB=$(ISMS_DB) python3 db/seeds/load_csv.py
	psql -v ON_ERROR_STOP=1 -q -d $(ISMS_DB) -f db/seeds/0002_checks_core.sql
	ISMS_DB=$(ISMS_DB) python3 db/seeds/0003_connectors.py
	psql -v ON_ERROR_STOP=1 -q -d $(ISMS_DB) -f db/seeds/0004_phase2_checks.sql
	ISMS_DB=$(ISMS_DB) python3 db/seeds/0005_agent_definition.py
	psql -v ON_ERROR_STOP=1 -q -d $(ISMS_DB) -f db/seeds/0006_phase3_device_checks.sql
	psql -v ON_ERROR_STOP=1 -q -d $(ISMS_DB) -f db/seeds/0007_policies_core.sql
	psql -v ON_ERROR_STOP=1 -q -d $(ISMS_DB) -f db/seeds/0008_policies_extended.sql
	psql -v ON_ERROR_STOP=1 -q -d $(ISMS_DB) -f db/seeds/0009_relationships.sql
	psql -v ON_ERROR_STOP=1 -q -d $(ISMS_DB) -f scripts/ci/check_seeds.sql
	ISMS_DB=$(ISMS_DB) python3 db/seeds/record_provenance.py

DRY ?=
business-seed:
	python3 scripts/seed_business_register.py $(if $(DRY),--dry-run,)

business-control-status:
	python3 scripts/update_control_implementation_status.py $(if $(DRY),--dry-run,)

# テナントを作った後で標準規程を足した／本文を書いたときに使う。
# provision_tenant はテナント作成時にしか展開しないので、これが無いと既存テナントへ届かない。
sync-policies:
	python3 scripts/sync_tenant_policies.py $(if $(DRY),--dry-run,)

risk-register-test:
	./tests/risk_register_invariants.sh

# 受入試験は **使い捨ての DB** で走らせる。$(ISMS_DB) には触らない。
# 試験は catalog にも行を足すため、共有 DB で流すと残骸が残り、画面の件数が seed と食い違う。
test:
	./tests/run_isolated.sh

# --- チェック機能（checker）---------------------------------------------------
NAME   ?= 検査用
DOMAIN ?= example.invalid
EMAIL  ?= admin@example.invalid
ADMIN  ?= 管理者
tenant:
	ISMS_DB=$(ISMS_DB) python3 scripts/new_tenant.py \
	  --name "$(NAME)" --domain "$(DOMAIN)" --admin-email "$(EMAIL)" --admin-name "$(ADMIN)"

# TOKEN は make tenant が出したもの。履歴に残したくなければ ISMS_CHECKER_TOKEN で渡す。
# RECEIPT_ID は⑦のPOST受付(app.accept_verification_receipt等)で発行された実行許可ID。
# checker.py 側で必須化されたため、未指定なら checker.py 自身が exit 2 で拒否する。
checker:
	ISMS_DB=$(ISMS_DB) python3 scripts/checker.py $(if $(TOKEN),--token "$(TOKEN)",) $(if $(RECEIPT_ID),--verification-receipt-id "$(RECEIPT_ID)",)

checker-test:
	./tests/checker_test.sh

connector-test:
	./tests/connector_replay_test.sh

agent-test:
	./tests/agent_acceptance_test.sh

phase0:
	ISMS_DB=$(ISMS_DB) ./phase0/run_acceptance.sh

ci:
	./scripts/ci/run.sh

# --- 画面 ---------------------------------------------------------------------
# 依存の導入と起動は分ける。起動のたびに npm を走らせると、lockfile と違う版が
# 黙って入り込む余地ができる。lockfile があるときは npm ci（lockfile どおりに入れ直す）。
web-install:
	cd web && if [ -f package-lock.json ]; then npm ci; else npm install; fi

# VPS の oauth2-proxy 経由でアクセスするため 0.0.0.0:3110 で待つ。
# Loki が *:3100 を使うためポートを 3110 へ移動した。
web: web-install
	cd web && npm run dev

web-build: web-install
	cd web && npm run build

web-start:
	cd web && npm run start

web-test:
	cd web && npm test

web-check: web-install
	cd web && npm run typecheck && npm run lint && npm test && npm run build

# 外形検査。**壊した状態で実際に落ちること**まで見る（seed していない隔離 DB・届かない接続先）。
# isms_dev を壊したり PostgreSQL を止めたりはしない。
web-verify: web-check
	ISMS_DB=$(ISMS_DB) ./scripts/ci/check_web.sh
