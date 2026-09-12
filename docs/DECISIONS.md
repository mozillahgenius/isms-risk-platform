# Design decisions and deviations from the design document

> Source of truth: the detailed design document ("ISMS / Risk Management Platform, Detailed Design v2.0").
> When this file and the design document disagree, the design document wins — except for the items
> listed here. Each item below is a case where **implementing the design document literally would fail
> the design document's own acceptance criteria**, or would not work on PostgreSQL. This file records
> why we deviated and what is guaranteed instead.

Each item is written as "what the design document says / the problem we measured / the implementation
we chose / what is and is not guaranteed".

---

## D-01 Do not trust the tenant context GUC as-is

**Design document 2.2 / 9.2**: `app.current_tenant()` reads `current_setting('app.tenant_id')` and
raises an exception if it is not set.

**Problem measured**: `app.tenant_id` is a custom GUC, so `app_rw` can itself write
`SET LOCAL app.tenant_id = '<another tenant's uuid>'`. The design document's implementation trusts that
value as-is, so **a connection can bypass RLS and reach another tenant's data**.
This fails Phase 1 acceptance item #7 of the design document: "a connection that sets `app.tenant_id`
directly, without going through `set_tenant_context()`, must not reach tenant data".

**Implementation chosen** (`0006_tenant_context.up.sql`):

- An HMAC key is stored in `app.tenant_context_keys` (singleton, owned by `schema_owner`, no privileges for application roles)
- `app.set_tenant_context()` sets `app.tenant_sig` in addition to `app.tenant_id`
  - signature = hex of `hmac('v1:' || tenant_id || ':' || pg_backend_pid(), key, 'sha256')`
  - A separator and a version prefix remove concatenation ambiguity. If the key or any argument is NULL, no signature is produced and an exception is always raised (fail closed)
- `app.current_tenant()` recomputes and compares the signature, and raises if it does not match
- `pg_stat_activity.backend_start` is **not used**. Inside `SECURITY DEFINER`, `current_user` becomes
  the function owner, which cannot see other roles' session rows, so the value can be NULL

**Guaranteed** (verified by `tests/rls_test.sh`):

1. A `SET` on a new connection without a signature is rejected
2. Swapping in another tenant's ID makes the signature mismatch and is rejected
3. Moving a signature to another backend is rejected because `pg_backend_pid()` differs
4. The argument of `set_tenant_context()` is bound to a secret held by the caller (the session token)

**Not guaranteed (residual risk, stated explicitly)**:

- We do not prove that "the current GUC was always set through the function". A caller that has once
  legitimately called `set_tenant_context()` on a backend can read its own signature via
  `current_setting` and re-set it later on the same backend. **However, it can only ever obtain its own
  tenant**, so this is not a privilege escalation
- `pg_backend_pid()` can be reused. On a different backend whose PID has wrapped around to the same
  value, an old signature for the same tenant could pass. This is also limited to the caller's own
  tenant and does not cross tenant boundaries
- All signatures can be invalidated at once by rotating the key (updating `app.tenant_context_keys`)

**Operating condition**: `set_config(..., true)` is equivalent to `SET LOCAL` and disappears at the end
of the transaction. **Always do `BEGIN → set_tenant_context → business queries → COMMIT` within a
single transaction.** Calling only `set_tenant_context()` in autocommit mode does not carry over to the
next statement (this is also tested). PgBouncer is assumed to run in transaction pooling mode.

---

## D-02 Store a hash of the token in `app.sessions`

**Design document 2.3**: `app.sessions` has only `id uuid`. `set_tenant_context(p_session uuid)` takes
that id.

**Problem measured**: the `app_rw` DB role is shared across tenants, so the DB cannot use
`session_user` to decide "is the caller really the owner of this session?". Knowing a session UUID would
be enough to switch to any tenant.

**Implementation chosen**:

- Added `app.sessions.token_hash bytea NOT NULL UNIQUE` (sha256, fixed 32 bytes)
- `app.set_tenant_context(p_token text)` takes the raw token and looks it up by hash. The raw token is never stored in the DB
- Tokens shorter than 32 characters are rejected (recommended: hex of 32 bytes from a CSPRNG = 64 characters)
- `app.create_session()` / `app.revoke_session()` are provided as `SECURITY DEFINER`, and
  **no table privileges on `app.sessions` are granted to `app_rw` / `app_ro` at all**
- TTL is at most 24 hours. Rotation is "`create_session` with a new token → `revoke` the old one"

**Side effect**: `app.sessions` and `app.memberships` must be read by the definer **before** the
context is established. `FORCE ROW LEVEL SECURITY` also applies to the owner, so lookup policies for
`schema_owner` (`ctx_session_lookup` / `ctx_membership_lookup`) are created explicitly.
Without them, `set_tenant_context()` could not validate its own argument — a chicken-and-egg problem.

---

## D-03 Two issues in the `app.effective_risk_criteria` view

The view definition in **design document 2.5** has two problems.

1. **`security_invoker` is not specified**: an ordinary PostgreSQL view reads its underlying tables with
   the owner's privileges, which bypasses RLS. We specify `WITH (security_invoker = true)` explicitly.
   CI (`check_rls.sql` check 10) enforces this for every view in the `app` schema.
2. **`(d.override->>'band_top_priority')::int[]` does not work**: `->>` returns a JSON array as the
   string `[15, 16]`, but a PostgreSQL array literal is `{15,16}`, so the cast fails.
   We added `app.jsonb_to_int_array()`, which builds the array through `jsonb_array_elements_text`.

---

## D-04 The residual-risk check was silently skipped (generated columns and BEFORE triggers)

**Design document 2.7**: `app.validate_residual()` looks at `NEW.level_sec_after` and rejects the row
"if residual > inherent within the same cycle".

**Problem measured**: `level_sec_after` is a `GENERATED ALWAYS AS (...) STORED` column, and
**at BEFORE-trigger time it has not been computed yet, so it is always NULL**.
The function therefore always exits at the initial `IF ... IS NULL THEN RETURN NEW`, and
**the check never ran even once** (we only found this by writing a test).

**Implementation chosen**: the trigger computes `NEW.prob_after * NEW.impact_sec_after` itself.
`tests/domain_test.sh` confirms that both "an increase within the same cycle is rejected" and
"an increase on re-evaluation requires a reason" actually fail.

---

## D-05 Explicit table privileges and schema USAGE for the `app` schema

The design document defines RLS policies for `app_rw` / `app_ro`, but
**does not write the GRANTs for the table privileges themselves**. RLS only controls row visibility; it
is not a substitute for authorizing operation types or role privileges (without privileges, the table is
not reachable at all).

`0015_rls_and_grants.up.sql` makes the following explicit:

- On each table in `app`: `SELECT, INSERT, UPDATE, DELETE` to `app_rw`, `SELECT` to `app_ro`
  (`GRANT ALL` is not used; `TRUNCATE` / `REFERENCES` / `TRIGGER` are not granted)
- On each table in `catalog`: `SELECT` only
- `ALTER DEFAULT PRIVILEGES` is per-executor and does not apply retroactively to existing objects, so
  **we do not rely on it**. CI inspects the effective privileges of the real objects directly with `aclexplode`

### Execute privileges per function

| Function | app_rw | app_ro | auth_svc | auditlogd | Notes |
|---|:--:|:--:|:--:|:--:|---|
| `app.current_tenant()` | yes | yes | no | yes | Called when evaluating RLS policy expressions, so both roles need it |
| `app.set_tenant_context(text)` | yes | yes | no | no | |
| `app.tenant_context_signature(uuid)` | **no** | **no** | no | no | Granting it would allow forging a signature for any tenant. Enforced by CI check 12 |
| `app.create_session(...)` | **no** | **no** | yes | no | Granting it to app_rw would allow issuing a session for any tenant (D-12). CI check 13 |
| `app.revoke_session(text)` | yes | no | yes | no | Revocation is a legitimate operation for whoever knows the token |
| `app.rebuild_effective_grants(uuid)` | yes | no | no | |
| `app.expire_deviations()` | yes | no | no | |
| `audit.append(...)` | no | no | yes | |
| `audit.verify_chain()` | yes | yes | no | Also granted to `audit_verifier` |

---

## D-06 Reordered definitions and foreign keys added afterwards

- `app.grants` references `app.oauth_apps` by FK, but the listing order in design document 2.6 is the
  reverse. Since it is not circular, we reordered so that `oauth_apps` is created first (no later `ALTER` needed)
- `app.exceptions.finding_id` → `app.findings` spans migrations 0010 and 0011, so it is added
  afterwards with `ALTER TABLE ... ADD CONSTRAINT`
- Design document 4.2 hand-writes the RLS for `app.effective_grants`, but that would duplicate the
  generation rule used for the other tables, so it is folded into the bulk generation in 0015

---

## D-07 Audit log: definer policies and an append helper

Design document 8.3 only defines an INSERT policy for `auditlogd`. However, numbering `chain_seq` and
chaining `prev_hash` require "reading the previous row", and `auditlogd` has no SELECT privilege.

We provide `audit.append()` as `SECURITY DEFINER`, combining numbering, hash computation, and insertion
(the caller cannot break the chain). The owner is also subject to `FORCE RLS`, so
**only INSERT and SELECT policies** are created for `schema_owner`.
No UPDATE / DELETE policies are created = **even the owner cannot rewrite past rows at the RLS level**.
This guarantees invariant 6 of design document 8.3 more strongly than `REVOKE` would.

Verifying the `signature` is the responsibility of an independent process, so `audit.verify_chain()`
does not look at it. It verifies only the chain and the hashes.

---

## D-08 Roles exist cluster-wide

If `0001_init.down.sql` unconditionally `DROP`s the roles, it always fails when another database in the
same cluster (for example, development and CI databases side by side) still references them.
It now checks `pg_shdepend` and **keeps the roles while dependencies from other databases remain**.

---

## D-09 Do not use NFKC for Phase 0 normalization

When we initially used NFKC, a category label ending in a full-width parenthesized suffix such as
`（Phase1）` became `(Phase1)`. NFKC folds full-width parentheses and full-width alphanumerics to their
half-width forms, so it **rewrites the ledger values themselves**.
The round trip stays consistent, but changing the values that enter the DB relative to the original is
alteration, not normalization, so we do not use it.

Strings use **NFC** (folding only composition/decomposition variations). Whitespace (NBSP / full-width
space / consecutive spaces / line breaks) is handled explicitly. Only numeric columns are parsed with
NFKC (to accept full-width digits).
The full rule set is in `phase0/NORMALIZATION.md`.

---

## D-10 Discrepancies between measurements and the design document (numbers)

| What the design document says | Measured | Action |
|---|---|---|
| Size of the bundled control catalog and standard risk scenario library (1.6 / 1.10 / Part XIII) | Not bundled. Only a small fictional sample catalog (`db/seeds/snapshots/`) ships with this repository | Operators load their own catalog CSVs (same columns) via `LEGAL_SCRIPTS_DIR`. CI derives the expected row counts from the CSV files instead of fixed numbers |
| Standard check catalog of **66 checks** (1.10 / 6.3 / acceptance #1) | Only **4** checks in the design document come with `query_sql` and `negative_fixture` (CHK-SHARE-001 / CHK-SHARE-004 / CHK-TPR-001 / CHK-OPS-006). The other 62 are just a table of key, title, severity, frequency, and related controls | **Not loaded**. We follow the design's own rule that a check without a `negative_fixture` cannot be registered in the catalog (design document 6.4). To avoid misrepresenting the count, no dummy `query_sql` is inserted. This is Phase 2 work |

The `code` of `catalog.controls` is built as `<major category symbol>-<sub-item code>(<requirement No>)`
(e.g. `S-10-10-10(1)`). The example `A-30-10(3)` in design document 2.4 omits a segment and would not
be unique across a catalog.

---

## D-16 Never rewrite an applied migration (operating rule)

`scripts/migrate.sh` records the SHA-256 of both the up and down files in `schema_migrations` when
applying, and compares them with the actual files on every subsequent `up` / `down` / `status`.
**Rewriting a migration that has been applied in any environment will always fail in that environment.**
Fixes are added as new migrations numbered 0016 or later.

At the time this rule was written, migrations 0001–0015 had only been applied to development machines
and CI (which is rebuilt every time). In other words, **there was no deployment target yet**, so direct
edits were allowed during that period. From 0016 onward we only "add". Once the first real deployment
happens, 0001–0015 are frozen as well.

Whether this rule is being followed is checked by CI step 2 (apply all DDL to an empty DB) and by
`verify_checksums`.

---

## D-12 Separate session issuance into `auth_svc` (a role not in the design document)

**Problem measured**: if `app_rw` can call `app.create_session()`, `app_rw` can issue a session
specifying another tenant's uuid and pass `set_tenant_context()` with that token.
**Neither the signature verification of D-01 nor the token matching of D-02 means anything if issuance
itself is unrestricted.** This was pointed out in a review.

**Implementation chosen**: add a sixth role, `auth_svc`, which is not in design document 9.1, and grant
EXECUTE on `app.create_session()` to `auth_svc` only. It is revoked from `app_rw` / `app_ro`. Only the
authentication path (login processing) connects as `auth_svc`.
`auth_svc` has no table privileges at all (enforced by CI check 13).

`app.revoke_session()` is kept for `app_rw`. Only someone who knows the token can revoke it, and ending
one's own session is a legitimate operation.

---

## D-13 Block direct INSERTs into the audit log

**Design document 8.3**: `GRANT INSERT ON audit.audit_log TO auditlogd;` and
`CREATE POLICY audit_insert ... WITH CHECK (true)`.

**Problem measured**: with that, `auditlogd` can bypass `audit.append()` and write rows with arbitrary
`chain_seq` / `prev_hash` / `hash` directly. By computing consistent hashes itself, it could create a
fake history that passes `verify_chain()`.

**Implementation chosen**: direct privileges on `audit.audit_log` are revoked from `auditlogd` too, and
appending is possible only through `audit.append()` (SECURITY DEFINER).
CI check 9b verifies that "no privilege other than SELECT is granted".

---

## D-14 Do not grant UPDATE / DELETE on append-only tables

Design document 2.6 describes `app.device_snapshots` and `app.graph_events` as "append-only", but the
bulk GRANT in 0015 gave them UPDATE / DELETE like the other tables.
In other words, "append-only" was only a claim in a comment.
These two tables were changed to `SELECT, INSERT` only. Enforced by CI check 14.

---

## D-15 Placeholder rows in a control catalog

A control catalog may contain placeholder rows whose requirement No is `-` (no requirement text yet).
We do not bend the input, so such a row is loaded as-is and its `code` ends in `(-)` (e.g. `S-40-10-10(-)`).
CI (`scripts/ci/check_seeds.sql`) accepts this form in addition to `(<number>)`.

---

## D-11 Verification environment

Design document 11.1 assumes PostgreSQL 16. **Verification has been done on PostgreSQL 17 only;
verification on PostgreSQL 16 requires Docker and has not been performed.**
PG16 is defined as the reference for CI, but it has not been run on PG16. Until it is run in an
environment with Docker, we do not claim "verified on PG16".

---

## D-17 Git is the source of truth for rules — but not a single repository

Given the requirement that "rules may be managed with GitHub as the source of truth, or in the DB", we
decided on **Git as the source of truth and the DB as a projection**.
The UI only reads the projection and never rewrites the DB.

In practice, however, the source of truth is **split across two repositories**.

| Target | Source of truth |
|---|---|
| DOM 2026.1 (roles, asset classes, risk criteria, calendar, policies) | `db/seeds/0001_dom_2026_1.sql` in this repository |
| Controls / risk scenario templates | Two CSV files loaded by `db/seeds/load_csv.py` from `LEGAL_SCRIPTS_DIR` (default: the fictional sample in `db/seeds/snapshots/`) |

This repository bundles only a small fictional sample catalog. A real catalog is kept outside the
repository and loaded with `LEGAL_SCRIPTS_DIR`; `db/seeds/record_provenance.py` records its path,
commit and SHA-256 at load time (D-18), so the UI shows which catalog is loaded.

---

## D-18 Provenance is not written in the UI; it is measured at load time and stored in the DB

If the UI shows a fixed string such as "Source: db/seeds/…", it keeps showing the same thing even when
upstream changes. Migration 0020 adds `catalog.seed_provenance`, and `db/seeds/record_provenance.py`
measures and records the **repository, commit, path, SHA-256, and row count** on every load. The UI
reads only from there.

- `row_count` is **measured in the DB after loading**, not declared by the loader (if loading fails
  midway, it is not recorded as "everything was loaded")
- The commit is written **only when the file matches HEAD**. If the working tree is dirty it is NULL,
  and the UI shows "uncommitted changes"

---

## D-19 Do not draw hierarchies derived from classifications the same way as real relationships

Most of the hierarchy in the diagrams is built by **splitting the strings in `controls.theme` /
`risk_scenario_templates.domain`**. The relationship tables (`framework_mappings` /
`risk_template_controls` / `check_controls`) measured 0 rows, so with real relationships alone the
diagram would be an almost edgeless cloud of points.

So edges carry a kind:

- **Real relationship** … something present directly in a column, such as `controls.framework_key` or `calendar_events_default.owner_role`
- **Derived** … built by splitting theme / domain / cadence

The UI shows counts separately as "real N / derived M", and hovering shows which kind an edge is.
Derived intermediate nodes (headings that are not DB rows) are drawn **hollow**.
Mixing the two would make nonexistent relationships look real.

---

## D-20 Do not remove zero-count items from diagrams and lists

A current framework with 0 controls (ISO27001:2022) and mapping tables or checks that have not been
loaded yet are not removed; they remain as nodes/cards colored "not loaded".
Slots that were decided to be out of scope, such as the empty migration slot for the old version
(ISO27001:2013), are deleted from the source of truth.
Removing something that is currently in scope makes it look like "it was never expected" rather than
"it is missing", which hides the gap.

---

## D-21 The UI connects as app_ro and never says "0 rows" for operational data

The UI connects with the `app_ro` role (SELECT on catalog only). In addition,
`default_transaction_read_only` is set on connect so that any attempt to write fails immediately.

`app.*` requires an RLS tenant context, so reading it as `app_ro` **fails with
`tenant context is not set` rather than returning 0 rows**. The operations screens therefore do not say
"0 rows of operational data"; they say **"not in a readable state"**. "0 rows" and "cannot read" are
different things; mixing them would show a screen saying "there are no rules at all" for as long as the
DB is down.

---

## D-22 The check contract (query_sql / expect / negative_fixture)

The design document gives 4 example checks with `query_sql` and `negative_fixture`, but
**does not define the format of `expect` or how pass/fail is decided**. We decided it here.

| Item | Decision |
|---|---|
| `query_sql` | A SELECT that returns the **violating rows**. Passes if it returns no rows |
| `expect` | `{"max_violations": N}`. Up to N rows is treated as a pass |
| `negative_fixture` | SQL that deliberately creates one violation |
| Executing role | `app_ro` (read-only) + tenant context. Catalog SQL is never executed on a writable connection |
| `coverage_ratio` | The whole population is scanned, so 1.000 if the query succeeds, NULL otherwise (writing 0 would read as "looked, and 0%") |

We chose "return the violating rows" because **the evidence is kept as-is**. If a check returned only
a count, someone would have to hunt for "what is violating" again after it fails.

---

## D-23 Only checks confirmed to fail can be recorded as pass (a DB constraint)

`negative_verified` and `verified_digest` were added to `app.check_runs`, together with a constraint
that **`result = 'pass'` cannot be inserted unless `negative_verified` is true** (0021).

A check becomes a check only by "failing when it should fail", not by "having passed".
If this relies on people confirming it, it gets skipped on busy days and green results pile up.
If the recording side has no choice but to comply with a constraint, skipping it means the result
cannot be recorded.

The confirmation has two stages, and it is "confirmed" only when **both** hold:

1. With nothing changed, there are 0 violations (= the precondition holds)
2. Loading the `negative_fixture` produces a violation (= the check works)

Looking only at 2 would misread a check that was already failing as "working".

`verified_digest` is the SHA-256 of `query_sql` and `negative_fixture` at the time of confirmation.
If the content changes, the previous confirmation is no longer valid evidence and must be redone.

**Reverse verification (measured)**: trying the constraint directly is rejected with
`check_runs_pass_requires_negative_verification`.
`scripts/checker.py --skip-verify` makes every check `inconclusive`; not a single one passes.

---

## D-24 Never run negative_fixture on the target DB

Confirmation is done **in a disposable DB created for that purpose**; the target DB is only read.

Even if rolled back, running it on the target DB touches **side effects that are not rolled back**, such
as triggers, audit logs, and sequences. The moment the auditing side changes the audited side's data,
it is no longer an audit ("the audit function never corrects business data").

`scripts/checker.py` recreates `isms_checker_verify` every time, runs migrations → DOM load → check
load → tenant creation → confirmation there, and then discards it.

---

## D-25 How tenants are created (the provisioner role and definer INSERT policies)

Without any tenant, operational data stays empty forever, and the UI cannot say anything beyond
"cannot read". We added `app.provision_tenant()` (SECURITY DEFINER), which creates a tenant, an
administrator, a membership, and the expansion of the 12 standard policies as one unit.

- Only the **`provisioner`** role can call it. It has no table privileges (it can only call this function)
- It is not granted to `app_rw`. A business connection must not be able to create tenants
- INSERT policies for the definer (`schema_owner`) were added to 5 tables, but
  **`WITH CHECK` is restricted to "rows of the tenant currently being created"** (`app.provisioning_target()`).
  A permissive `USING (true)` policy would leak into the read side as well and become a hole
- Check 3c in `scripts/ci/check_rls.sql` mechanically verifies that the target role, command,
  `WITH CHECK` content, and target tables are as expected

**`INSERT ... RETURNING` cannot be used** (measured). RETURNING requires a SELECT policy on the returned
rows, and it fails because the definer is not given a read policy.
Widening reads to work around it would give the definer visibility into every tenant just to create
one. Instead, ids are decided in advance and not read back.

---

## D-26 Only 4 checks can be loaded now (not the 66 in the design document)

The design document assumes 66 standard checks, but the 4 that have `query_sql` and `negative_fixture`
written out all assume data fetched by external connectors (Google Workspace, etc.).
Connectors were not started until Phase 2, so loading them would not work.

Listing checks that do not work only inflates the catalog count and makes it look as if "checks exist".
We narrowed it down to **4 checks that can be decided from the real `app.*` data without connectors**
(`CHK-CORE-*`).

One was dropped along the way. We wrote a check that reads `app.sessions`, but that table is
**definer-only** and cannot be read by `app_ro` (0015 deliberately does not grant privileges, and CI
checks for leaks). It could not work from a read-only audit standpoint, so it was replaced with a check
that detects deviation of policy text from the standard.

### Known gap: no retirement path for checks

`catalog.checks` has no `retired_at`, and once referenced from `app.check_runs` a check
**cannot be deleted** (measured: FK violation). There is currently no way to stop a check that has run
history. Controls and risk templates have `retired_at`, so checks need the same approach. Phase 2 work.

---

## D-27 The pass gate compares content, not just shape

The 0021 constraint only required `negative_verified` and a 64-character `verified_digest` for
`result='pass'`. **Anyone able to write could set true and an arbitrary 64-character value to get a pass.**
The shape was right but the content was never examined, so as a gate it was almost a pass-through.

0022 adds two things:

- `catalog.check_digest(key)` — builds a fingerprint from the check's content. **It is computed in only
  one place: the DB.** The executor (`scripts/checker.py`) also calls this function. If the same formula
  were written in two places, one would eventually change alone, and the diverging side would fail
  **silently open** rather than reporting "mismatch"
- A trigger on `app.check_runs` — setting `negative_verified` requires that `verified_digest`
  **matches the current catalog content**

### What it prevents / what it does not prevent

| | |
|---|---|
| Prevents | Claiming "confirmed" with a random 64-character value |
| Prevents | Rewriting a check after confirmation and passing it on the old confirmation |
| **Does not prevent** | **Whether the fixture was actually run** |

The last one is not visible from the DB. It remains the job of the executor (checker).
We draw the line here: this is as far as "the DB stops it" can be claimed.

### Also fixed

`app.provision_tenant()` referred to `public.gen_random_uuid()` by name.
Even with `search_path` pinned to `pg_catalog`, anyone able to create functions in `public` could
replace it. In this DB, CREATE is revoked from PUBLIC (measured: `f`), but rather than relying on that
setting it was changed to `pg_catalog.gen_random_uuid()` (built in since PG13).

Note that the definer INSERT policies only take effect **because FORCE ROW LEVEL SECURITY is enabled**
(measured: all 50 RLS-enabled tables in `app` have FORCE).
If FORCE were removed, the owner would bypass RLS and `WITH CHECK` would become meaningless.
`scripts/ci/check_rls.sql` checks that FORCE is applied everywhere.

### Addendum: past confirmations are not rewritten; the UI shows whether they are still valid

Even if `catalog.checks` is changed later, the `verified_digest` of already recorded `check_runs`
stays old. We do not rewrite or invalidate past records here.
**A record that can be fixed afterwards does not stand as evidence** (the same reason audit logs are not rewritten).

Instead, the UI shows whether that confirmation **still applies to the current content**:

- Match → "confirmed to fail"
- Mismatch → "content changed after confirmation" (red)

Measured: loosening `expect` switches the display, and restoring it switches it back.

### Remaining assumption: who can replace `public.digest`

The fingerprint computation depends on pgcrypto's `public.digest`. Anyone able to replace it could take
over the computation itself. Measured:

- The ACL of the `public` schema is `pg_database_owner=UC` and `=U` (everyone else has USAGE only)
- The owner of `public.digest` is the database owner

So **only the database owner (superuser)** can replace it, and that principal can bypass everything
anyway. No additional risk is introduced. Moving pgcrypto into a dedicated schema will be done once the
deployment target is decided.

---

## D-28 Acceptance tests never run on a shared DB (`make test` uses a disposable DB)

**What the design document says**: Phase 1 acceptance only says to confirm "rejection at the DB layer"
with real connections. It does not say which DB to run on.

**Problem measured**: `make test` defaulted to `isms_dev`. To create FK targets, `tests/domain_test.sh`
inserts `catalog.frameworks('TEST-FW')` and `catalog.controls('TEST-FW','T.1', without a theme)`, and
does not delete them at the end. As a result, after running `make test` on a development machine:

- `catalog.controls` had one row more than the seed loads (disagreeing with the actual seed count)
- The leftover control had a NULL `theme`, and `/graph` and the control detail page returned **500**

`catalog` is a projection of Git, and **if tests leave their changes behind, the UI disagrees with the
source of truth**.

**Rejected option (add cleanup)**: the tests delete from `audit.audit_log`, `app.risk_criteria` is a
history table that cannot normally be deleted from, and `rls_test.sh` leaves fixtures at the end.
"Restoring the original state" is hard to make exhaustive, and omissions would go unnoticed.

**Implementation chosen** (`tests/run_isolated.sh`, `make test`):

- Create a disposable DB (default `isms_test_<pid>`), load migrations and seeds, and run the tests there
- DROP it via `trap` on exit, failure, or interruption
- **Refuse to run** if the disposable DB name equals the shared DB name (because it gets DROPped)
- **Compare a fingerprint of `catalog` in the shared DB (`$ISMS_DB`, default `isms_dev`) before and after
  the tests.** The fingerprint is an md5 over the contents of every table; row counts alone would miss
  "one row added and one row deleted"

**Reverse verification**: pointing `domain_test.sh` at the shared DB without switching to the disposable
DB makes the fingerprint differ in 4 tables — `controls` / `dom_versions` / `frameworks` /
`risk_criteria_default` — and the check fails, as measured.

**Not guaranteed**: `make ci` still rebuilds and uses `isms_ci` as before.
Within CI the tests add fixtures to `catalog`, but that DB is discarded every time, so there is no impact.

---

## D-29 Enforce the canonical form of classifications (`theme`) in the DB; the UI reads with plain equality

**What the design document says**: controls are split into a hierarchy by `theme` (three levels are
assumed). Handling of NULL and whitespace is not specified.

**Problems measured (two)**:

1. In the DDL `theme` is nullable, but the UI type said `string`.
   `splitTheme(theme: string)` calls `theme.split(...)`, so a single NULL row made `/graph` and the
   control detail page return 500. **The type was lying about the real data.**
2. Digging further, the definition of "what is this control's classification" was **split across
   three places**:

   | Place | Interpretation |
   |---|---|
   | UI `splitTheme` | Split on `' / '`, trim each level with JS `trim`, drop empty levels |
   | List filter | Plain `theme = ?` and `theme LIKE ? || ' / %'` |
   | "Controls in the same classification" | Plain `theme = (…)` |

   The same value was interpreted three ways, so a single row with surrounding whitespace such as
   ` A / B ` was enough to produce **"the detail page says 2, but the linked list shows 0"**.

**Rejected option (normalize in the UI)**: we first normalized `same_theme` with `btrim`, but the list
filter still used plain equality, so **the mismatch merely moved**.
Next we brought the same whitespace set as JS `trim` into SQL, but for values like `' / '` (a separator
only) the UI and SQL still disagreed. **As long as any single place normalizes, it will always disagree
with some other place.**

**Implementation chosen** (migration `0023_control_theme_canonical`): **fix the values themselves to a
single form.**

- `catalog.theme_space_chars()` — the characters treated as whitespace: ECMAScript
  WhiteSpace + LineTerminator (TAB/LF/VT/FF/CR/SP/NBSP/OGHAM/various spaces/LS/PS/NNBSP/MMSP/ideographic space/BOM)
- `catalog.canonical_theme(text)` — split on `' / '`, trim each level with the set above, drop empty
  levels, and join again. Produces the same result as the UI's `splitTheme(theme).join(' / ')`
- `CHECK (theme IS NULL OR (theme <> '' AND theme = catalog.canonical_theme(theme)))`

Now `theme` can only be either "NULL (= unclassified)" or "a non-empty string in canonical form".
From then on **plain equality comparison is identical to canonical comparison**, so the UI no longer
needs to normalize, and the three interpretations agree automatically.

Measured before applying (on the catalog loaded at the time): 0 NULL, 0 empty strings, 0 non-canonical.
No row fails.

Only NULL handling remains on the UI side:

- `Control.theme` and the diagram model's input are `string | null`
- `splitTheme(null | undefined | whitespace only)` returns an empty array. An unclassified control is
  attached **directly under the framework** without intermediate nodes. The row is not removed from the
  diagram (removing it would make counts disagree)
- **No** intermediate node representing "unclassified" is created, so as not to add a classification
  that does not exist
- Lists and detail pages show **"unclassified"** instead of a blank. A blank cannot be distinguished
  from "could not be fetched"
- "See controls in the same classification" is not shown for unclassified controls (it would point to
  an arbitrary collection of unclassified controls)

**Reverse verification**:

- Reverting the guard in `splitTheme` to `theme!.split(...)` **still passes the type check**, but 2 unit
  tests fail. With the same mutation in the build, the external check `4/4c` fails with "the diagram does
  not return 200"
- A mutation that normalizes only `same_theme` makes the external check fail with
  "same-classification count is not 2 (… 3)"
- Running `domain_test.sh` on a DB without `controls_theme_canonical` makes all 5 non-canonical forms
  (surrounding whitespace, whitespace only, separator only, empty string, empty level) fail
  **independently** with "expected to fail but succeeded".
  Each check uses a different `code` (reusing one would make the second and later checks fail for a
  **different reason** — a unique-constraint violation — and look as if the check worked)

**Not guaranteed**: the same constraint is not applied to `catalog.risk_scenario_templates.theme`.
That column is `NOT NULL` and is a leaf label that is not split into levels, so it does not break the
same way, but whitespace variations would split diagram nodes. We have not verified that the real data
has no such variations.

---

## D-30 Framework mappings and risk-to-control links are loaded as "initial mapping candidates"

If `framework_mappings` and `risk_template_controls` stay at 0 rows on the catalog screens, there is no
entry point for reviewing mappings even though controls and risk templates exist.
On the other hand, treating mapping candidates as implemented or evidenced would confuse the catalog
with the operational registers.

**Implementation chosen** (seed `db/seeds/0009_relationships.sql`):

- Register the 93 ISO/IEC 27001:2022 Annex A codes and standard control names in the catalog
- Mappings between IPO-KARTE and ISO are registered as `related`, based on candidates extracted from the names and themes of existing controls
- Risk templates are linked to standard candidates per domain (ISO and existing IPO controls); where a
  template would be orphaned, for example by a domain rename, it is linked to at least one
  representative risk-management control
- `control_frameworks` is re-synchronized so that current controls can be referenced from both IPO-KARTE and RISK-MANAGEMENT
- The seed verifies that Annex A has 93 entries, that every ISO control has mappings, and that every risk template has control links

**Explicitly not guaranteed**: this load does not complete the final judgment of the Statement of
Applicability, operational implementation of controls, approval, evidence, or acceptance of residual
risk. Those are finalized through the individual SoA, risk assessment, and evidence review.
