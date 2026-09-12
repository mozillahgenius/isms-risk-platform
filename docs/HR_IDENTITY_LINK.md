# Backoffice → ISMS HR identity link

The link uses the existing `app.identities.hr_employee_id` column. It stores the
immutable text form of `bo.workforce_members.id` from a separate backoffice
database. `worker_ref` is only a changeable human reference and is never used as
the link key. The backoffice is the source of truth; ISMS receives a projection
and never writes back to the backoffice.

## Worker reference rule

A suggested `worker_ref` format is
`HR-<calendar year>-<zero-padded tenant-local serial>`, for example `HR-2026-001`.
The serial is allocated from the backoffice workforce ledger, not from an ISMS
UUID or an email address. The value is a human-facing backoffice reference only;
the immutable cross-system link remains the UUID in `bo.workforce_members.id`,
copied as text to `app.identities.hr_employee_id`.

## Expected backoffice schema

The script reads (read-only) these backoffice relations:

- `bo.workforce_members` (`id`, `org_id`, `actor_id`, `worker_ref`, `active_to`, `created_at`)
- `bo.actors` (`id`, `org_id`, `user_id`, `label`, `kind`)
- `bo.app_users` (`id`, `email`, `display_name`)

The backoffice connection is taken from `--backoffice-db` or
`BACKOFFICE_DATABASE_URL` (default `postgres://127.0.0.1:5432/backoffice`). Point it
at the backoffice source of truth; test or end-to-end databases are never valid
sources for `hr_employee_id`.

## Registration path

The backoffice is expected to provide a registration form that ensures the user
has a `bo.actors(kind='human')` row and then upserts `bo.workforce_members` with
the supplied `worker_ref`. This does not require changing the backoffice schema
or creating a synchronization job.

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
hardcoded deployment assumptions. `--tenant-token` (or
`ISMS_WEB_TENANT_TOKEN`) establishes the tenant context for the `app_ro`
verification reads. `--provisioner-dsn` (or
`ISMS_PROVISIONER_DATABASE_URL`) must be a separate `provisioner` connection;
the read-only `--isms-db` connection is never used for the write. Confirm all
URLs used by the operator before any `--apply` execution.
