# ISMS Risk Management Platform

A multi-tenant web application for running an information security management system (ISMS) and a
company-wide risk register. It connects to SaaS and endpoint data sources, checks whether controls
are actually working, and keeps an auditable history of risks, measures, policies, and evidence.

The data model follows ISO/IEC 27001:2022 (Annex A controls, risk assessment and treatment,
internal audit, management review, corrective actions). The user interface is in Japanese.

## Features

- **Risk register** – assets, risk scenarios, measures (treatments), and evaluation snapshots
  (inherent / before measure / after measure), with heat maps and timelines.
- **ISMS records** – scope, context and interested parties, legal requirements, security
  objectives, internal audits, management reviews, corrective actions, business continuity,
  vulnerabilities, and change requests.
- **Control catalog** – a versioned catalog ("DOM") of controls, risk scenario templates, policies,
  roles, asset classes, risk criteria, and an annual calendar, projected from Git into the database
  with recorded provenance (repository, commit, SHA-256, row counts).
- **Automated checks** – SQL-based control checks that are only recorded as `pass` after they have
  been proven to fail against a negative fixture in a disposable database.
- **Connectors** – a read-only Google Workspace reader (users, groups, OAuth tokens, Drive sharing,
  audit reports) with recorded-response replay tests, plus a contract for read-only database pulls.
- **Endpoint agent** – a small Go agent for macOS (`agent/`) that collects posture data from a
  fixed, reviewed definition and sends Ed25519-signed posture reports.
- **Operations** – incidents, work assignments, external resources and questionnaires, an e-mail
  outbox, identity and license inventory, password-manager status, and optional device control
  through an external dispatch orchestrator.
- **Policies, training, competency, and cost** – policy versioning and approval, training records
  (with optional e-learning sync), competency requirements, and cost tracking.
- **Visualization** – a hierarchy pyramid (2.5D / 3D / WebGL) and a relationship graph of the
  catalog.
- **CSV import** – initial import of assets, risks, organization, and policies.

## Architecture

```
db/migrations/   PostgreSQL schema (catalog / app / audit), up and down migrations
db/seeds/        Catalog seed data (DOM 2026.1, standard checks, policies) and provenance recording
scripts/         migrate.sh, checker, tenant provisioning, connector sync, mail sender, CI gates
connectors/      Connector manifests (Google Workspace) and the read-only pull contract
agent/           macOS endpoint agent (Go)
phase0/          Excel (xlsx) import / export round trip with a machine diff
tests/           Acceptance tests that connect with the real database roles
web/             Next.js (App Router) application
docs/            Design decisions and component documentation
```

Key design points:

- **PostgreSQL is the security boundary.** Every tenant table uses row-level security. The tenant
  context is a signed GUC set by `app.set_tenant_context(<session token>)` inside the same
  transaction; `app_rw` cannot forge it with a plain `SET`.
- **Separate roles per duty**: `app_ro` (read-only UI), `app_rw` (writes), `auth_svc` (session
  issuance), `provisioner` (tenant creation), `mail_worker` (mail outbox), `management_web`
  (trusted-proxy identity binding), and audit roles.
- **Append-only history** for evaluations, audit logs, and receipts.
- **Rules live in Git**; the database is a projection of them.

See [`docs/DECISIONS.md`](docs/DECISIONS.md) for the reasoning behind these choices.

## Requirements

- PostgreSQL 16 or later with the `pgcrypto`, `btree_gist`, and `citext` extensions
  (verified on PostgreSQL 17)
- Python 3.12 or later (`openpyxl` for the Excel round trip; the database is accessed through `psql`)
- Node.js 20.9 or later and npm (web application)
- Go 1.22 or later (endpoint agent, optional)

`docker-compose.yml` contains a PostgreSQL 16 + MinIO setup for local use.

## Getting started

```bash
# 1. Create the database and apply all migrations
make db-reset                  # uses ISMS_DB (default: isms_dev)

# 2. Load the catalog (the bundled sample by default; see "Control catalog" below)
LEGAL_SCRIPTS_DIR=$PWD/db/seeds/snapshots make seed

# 3. Create a tenant and an administrator; prints a session token once
make tenant NAME="Example Inc." DOMAIN=example.com EMAIL=admin@example.com ADMIN="Admin"

# 4. Configure and start the web application
cp web/.env.example web/.env.local   # then set ISMS_WEB_TENANT_TOKEN etc.
make web                             # http://127.0.0.1:3110
```

Other useful targets:

```bash
make test            # tenant isolation and domain constraints (disposable database)
make checker TOKEN=<session token> RECEIPT_ID=<verification receipt id>
make checker-test    # checker acceptance test (disposable database)
make agent-test      # endpoint agent acceptance test
make connector-test  # Google Workspace reader replay test
make web-check       # typecheck, lint, unit tests, and production build of web/
make ci              # database quality gate (see note below)
make backup          # pg_dump backup; make backup-verify restores it into a disposable database
```

Note: `make phase0` exports the xlsx through an external `build_risk_map.py` report generator that
is not part of this repository. Point `RISK_MAP_SCRIPTS_DIR` at the directory that contains it.
`make ci` skips this step (and says so) when `RISK_MAP_SCRIPTS_DIR` is not set.

### Control catalog

Only a **small, fictional sample catalog** is bundled: 8 sample controls and 9 sample risk scenario
templates in [`db/seeds/snapshots/`](db/seeds/snapshots/README.md). It exists so that seeding and
the tests work out of the box; it is not a real control framework.

To use your own catalog, create two CSV files with the same columns and relative paths and point
`LEGAL_SCRIPTS_DIR` at their directory:

```
<dir>/control_check/control_requirements_master.csv   大項目記号,大項目,中項目,小項目コード,小項目,要請No,要請事項
<dir>/risk_map/risk_map_master.csv                     RiskItem,Big,Mid,Frame,Summary,Action
```

```bash
LEGAL_SCRIPTS_DIR=/path/to/my-catalog make seed
```

`db/seeds/load_csv.py` validates the files before loading (UTF-8, no empty values, unique keys,
`RiskItem` ending in `（Phase1）`–`（Phase5）`, `Frame` one of `管理可能性` / `精度` / `スピード`), and
`db/seeds/record_provenance.py` records which files were loaded (path, commit, SHA-256, row count).

### Endpoint agent

```bash
cd agent
go test ./...
go build -o isms-agent ./cmd/isms-agent
./isms-agent enroll|collect|posture|run [flags]
```

Enrollment tokens are issued with `scripts/issue_device_enrollment.py`.

## Configuration

Makefile targets select the database with `ISMS_DB` (database name) and connect through the
standard libpq variables (`PGHOST`, `PGPORT`, `PGUSER`, ...). Leave `DATABASE_URL` unset when you use
them: some scripts (`scripts/migrate.sh`, the seed loaders) prefer `DATABASE_URL` when it is set,
while the `psql` steps in the Makefile always use `ISMS_DB`. The web application
reads server-side environment variables only (nothing is exposed with `NEXT_PUBLIC_`). A complete
annotated list is in [`web/.env.example`](web/.env.example).

| Variable | Purpose |
|---|---|
| `ISMS_WEB_DATABASE_URL` | Read-only connection for the UI (`app_ro`) |
| `ISMS_WRITE_DATABASE_URL` | Write connection (`app_rw`); unset keeps the UI read-only |
| `ISMS_PROXY_DATABASE_URL` | Connection used to bind the proxy-authenticated user (`management_web`) |
| `ISMS_WEB_TENANT_TOKEN` | Tenant session token from `make tenant` |
| `ISMS_DEVICE_CONTROL_PROXY_SECRET` | Shared secret the reverse proxy sends in `x-isms-device-control-proxy-secret` |
| `ISMS_SERVER_ACTIONS_ALLOWED_ORIGINS` | Public origins allowed for Server Actions behind a proxy |
| `ISMS_DEVICE_DISPATCH_URL`, `ISMS_DEVICE_DISPATCH_TOKEN`, `ISMS_DEVICE_DISPATCH_VIEW_TOKEN` | Optional external device dispatch orchestrator |
| `ISMS_DEVICE_CONTROL_ALLOWED_EMAILS`, `ISMS_DEVICE_CONTROL_VIEW_ALLOWED_EMAILS` | E-mail allowlists for device control (execute / view) |
| `ISMS_DEVICE_CONTROL_DEVICES` | JSON list of devices that may be targeted; empty disables device control |
| `ISMS_CONNECTOR_HUB_URL` | Optional link to an external connector hub |
| `ISMS_AGENT_INGEST_SECRET`, `ISMS_AGENT_DEFINITION_PRIVATE_KEY_B64` | Endpoint agent ingestion and definition signing |
| `ISMS_MANAGEMENT_*` | Management internal API ([docs](docs/internal-management-api.md)) |
| `ELEARNING_COMPLETIONS_URL`, `ELEARNING_MANAGEMENT_SYNC_TOKEN` | Optional e-learning completion sync |
| `PASSWORD_MANAGER_*` | Optional password-manager status page |
| `ISMS_SMTP_*`, `ISMS_MAIL_DATABASE_URL` | Mail outbox sender ([docs](docs/MAIL_OUTBOX.md)) |
| `ISMS_SESSION_*` | Session rotation (`scripts/rotate_web_session.py`) |
| `ISMS_GW_*` | Monthly Google Workspace collection wrapper (`scripts/run_google_workspace_monthly.py`) |

Web writes are attributed to a real user: the reverse proxy (for example oauth2-proxy) must send
`x-forwarded-email` together with the shared secret header. If either is missing, writes fail
closed. Do not expose the application without an authenticating reverse proxy.

Scheduling (mail sending, session rotation, monthly collection) is left to the operator; use
systemd timers, cron, or any other scheduler.

## Documentation

- [`docs/DECISIONS.md`](docs/DECISIONS.md) – design decisions and deviations from the design document
- [`docs/MAIL_OUTBOX.md`](docs/MAIL_OUTBOX.md) – mail outbox and sender
- [`docs/READ_ONLY_PULLS.md`](docs/READ_ONLY_PULLS.md) – read-only pull connectors
- [`docs/HR_IDENTITY_LINK.md`](docs/HR_IDENTITY_LINK.md) – backoffice to ISMS HR identity link
- [`docs/internal-management-api.md`](docs/internal-management-api.md) – management internal API
- [`docs/MACOS_MDM_PROVIDER.md`](docs/MACOS_MDM_PROVIDER.md) – macOS MDM provider design
- [`phase0/NORMALIZATION.md`](phase0/NORMALIZATION.md) – Excel normalization rules

## Known issues

- `tests/connector_replay_test.sh` currently fails: the bundled Google Workspace replay fixture
  yields 8 collected resources and 1 `not_collected`, while the test expects 9 collected. This will
  be fixed in a later release.

## License

This project is licensed under the Mozilla Public License, v. 2.0. See [`LICENSE`](LICENSE) for the
full text and [`COPYRIGHT.md`](COPYRIGHT.md) for the copyright notice.
