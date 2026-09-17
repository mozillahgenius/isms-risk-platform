# backoffice → ISMS HR identity link

The one-person pilot uses the existing `app.identities.hr_employee_id` column.
It stores the immutable text form of `bo.workforce_members.id` from the separate
backoffice database. `worker_ref` is only a changeable human reference and is
never used as the link key. Backoffice is the source of truth; ISMS receives a
projection and never writes back to backoffice.

## Worker reference rule

For this sample pilot, `worker_ref` is assigned as
`EX-HR-<calendar year>-<zero-padded tenant-local serial>`. The serial starts at
`001` for the first active workforce member in the Example Organization tenant and
is allocated from the backoffice workforce ledger, not from an ISMS UUID or an
email address. The pilot value is therefore `EX-HR-2026-001`. The value is a
human-facing backoffice reference only; the immutable cross-system link remains
the UUID in `bo.workforce_members.id`, copied as text to
`app.identities.hr_employee_id`.

## Backoffice source of truth for the pilot

The pilot uses `postgres://127.0.0.1:55432/ssi` as the backoffice source of
truth. `ssi_e2e_codex`, `ssi_e2e_codex_fix`, and any other test database are
never valid sources for `hr_employee_id`. The production container database on
port 55434 is also not this pilot's source of truth.

## Registration path

The backoffice `/admin/hr` page has a current-user-only registration form. It
ensures the logged-in user has a `bo.actors(kind='human')` row, then upserts
`bo.workforce_members` with the supplied `worker_ref`. It does not change the
backoffice schema and it does not create a synchronization job.

After the backoffice row exists, the ISMS-side command is read-only by default:

```sh
python3 scripts/hr_identity_link.py \
  --email '<person email>' \
  --tenant-id '<isms tenant uuid>' \
  --device-id '<enrolled agent device uuid>' \
  --tenant-token '<read-only verification session token>' \
  --provisioner-dsn '<provisioner connection string>'
```

Only an explicit `--apply` writes the ISMS projection. It creates or reuses an
`employee` identity keyed by `hr_employee_id`, then links the one matching
Google Workspace account and assigns the explicitly selected enrolled agent
device to that identity. A missing or differently assigned device fails closed.
It never writes to the backoffice database.

## Verification gate

The command re-reads both databases after an apply and requires exactly one
backoffice workforce member, one matching ISMS identity, one account whose
`identity_id` points to that identity, and the selected device whose
`assigned_identity_id` points to that identity. `--reverse-test` repeats the
verification against the real backoffice and ISMS rows after replacing the
workforce ID with a nonexistent UUID; it must fail before CHK-ENDPOINT-010 is
accepted. `--self-test` remains a local unit-level check of the same invariant.

The backoffice and read-only ISMS endpoints are environment/inputs, not
hardcoded production assumptions. `--tenant-token` (or
`ISMS_WEB_TENANT_TOKEN`) establishes the tenant context for the `app_ro`
verification reads. `--provisioner-dsn` (or
`ISMS_PROVISIONER_DATABASE_URL`) must be a separate `provisioner` connection;
the read-only `--isms-db` connection is never used for the write. Confirm all
URLs used by the operator before any `--apply` execution.
