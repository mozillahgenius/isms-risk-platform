.PHONY: help db-reset migrate down seed test risk-register-test phase0 ci connector-test agent-test \
        web-install web web-build web-start web-test web-check web-verify \
        tenant checker checker-test \
        backup backup-verify

ISMS_DB ?= isms_dev

help:
	@echo "make db-reset     空 DB を作り直して全マイグレーションを適用"
	@echo "make migrate      未適用のマイグレーションを適用"
	@echo "make down         直近 1 本を巻き戻す（make down N=all で全部）"
	@echo "make seed         DOM 2026.1 と統制カタログ CSV（既定は同梱サンプル。LEGAL_SCRIPTS_DIR で差し替え）を投入（冪等）＋出所を記録"
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
	@echo "make web          画面を開発モードで起動（http://127.0.0.1:3110）"
	@echo "make web-build    画面を本番ビルド"
	@echo "make web-start    ビルド済みの画面を起動（http://127.0.0.1:3110）"
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
# Use after adding standard policies or writing bodies after the tenant was created.
# provision_tenant expands them only at tenant creation, so without this they never reach existing tenants.
sync-policies:
	python3 scripts/sync_tenant_policies.py $(if $(DRY),--dry-run,)

risk-register-test:
	./tests/risk_register_invariants.sh

# Acceptance tests run on a **throwaway DB**. $(ISMS_DB) is not touched.
# The tests also add rows to catalog, so running on the shared DB leaves debris and UI counts diverge from the seed.
test:
	./tests/run_isolated.sh

# --- Checks (checker) --------------------------------------------------------
NAME   ?= 検査用
DOMAIN ?= example.invalid
EMAIL  ?= admin@example.invalid
ADMIN  ?= 管理者
tenant:
	ISMS_DB=$(ISMS_DB) python3 scripts/new_tenant.py \
	  --name "$(NAME)" --domain "$(DOMAIN)" --admin-email "$(EMAIL)" --admin-name "$(ADMIN)"

# TOKEN is the one output by make tenant. To keep it out of history, pass it via ISMS_CHECKER_TOKEN.
# RECEIPT_ID is the execution permit ID issued by ⑦'s POST intake (app.accept_verification_receipt etc.).
# checker.py now requires it, so if unspecified checker.py itself rejects with exit 2.
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

# --- UI ----------------------------------------------------------------------
# Keep dependency installation and startup separate. Running npm on every startup leaves room for versions
# differing from the lockfile to slip in silently. With a lockfile, use npm ci (reinstall exactly per lockfile).
web-install:
	cd web && if [ -f package-lock.json ]; then npm ci; else npm install; fi

# Listens on 127.0.0.1:3110. To expose it, put an authenticating reverse proxy (oauth2-proxy etc.) in front.
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

# Page shape checks. Verifies **that it actually fails when broken** (unseeded isolated DB, unreachable connection target).
# Does not break isms_dev or stop PostgreSQL.
web-verify: web-check
	ISMS_DB=$(ISMS_DB) ./scripts/ci/check_web.sh
