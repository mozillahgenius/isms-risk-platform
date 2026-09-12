# Read-only pull connectors

## Scope

This connector contract lets the verification layer probe six declared source
systems without storing credential values in Git, event files, or logs.

| source | driver | access mode | credential reference |
|---|---|---|---|
| mkt | PostgreSQL | database role | `cred.pull.mkt` |
| ops | PostgreSQL | database role | `cred.pull.ops` |
| backoffice | PostgreSQL | database role | `cred.pull.backoffice` |
| knowledge | PostgreSQL | database role | `cred.pull.knowledge` |
| automation | SQLite | filesystem read-only | `cred.pull.automation` |
| el | PostgreSQL | database role | `cred.pull.el` |

The canonical references are in
[`connectors/read_only_sources.contract.json`](../connectors/read_only_sources.contract.json).
Only `credential_ref` and environment-variable names (for example
`ISMS_PULL_DSN_BACKOFFICE`, `ISMS_PULL_DSN_KNOWLEDGE`, `ISMS_PULL_DSN_AUTOMATION`)
are recorded there; the values are supplied by the runtime credential store. The
`t24` strings in the contract's evidence references are historical identifiers and
carry no meaning beyond naming the evidence set.

## Execution boundary

Run these steps in order:

1. `scripts/validate_pull_sources.py` validates the six-source contract.
2. `scripts/read_only_pull_preflight.py --isolated` checks configuration,
   identifiers, driver availability, and the SQLite file without connecting to
   any source.
3. `scripts/run_read_only_pulls.py --isolated` runs the PostgreSQL or SQLite
   probe for each source and emits credential-free events.
4. `scripts/validate_pull_events.py <event-directory>` verifies that all six
   events form one complete snapshot before delivery to the verification layer.
5. `scripts/snapshot_pull_events.py freeze <event-directory> <manifest>` writes
   a non-overwriting SHA-256 manifest; `verify` detects changed, missing, or
   extra event files before the snapshot is accepted as evidence.

The probe reads one count and attempts INSERT, UPDATE, DELETE, TRUNCATE,
CREATE, ALTER, and DROP. The write and DDL attempts must be rejected; they are
only permission probes and must not be treated as business changes.

`--isolated` is mandatory. The runner reports missing configuration and probe
failures as events instead of treating an unmeasured source as healthy.

## Verification available without live sources

```sh
bash tests/test-read-only-pulls.sh
```

This covers the six-source success fixture and reverse checks for missing
configuration, writable PostgreSQL/SQLite behavior, unsafe identifiers,
read-only event forgery, and an incomplete event batch.

## Runtime evidence still required

The contract is intentionally marked
`runner_implemented_pending_runtime_access`. The following are not proven by
the fixture tests and must be obtained in each deployment:

- six actual read-only roles and their credential-store references;
- a real SELECT plus all seven DML/DDL refusal results for each source;
- an approved append-only delivery path from the validated event batch into the
  verification layer;
- an observed event snapshot retained as operational evidence.

Provision roles, alter permissions, or change environment values only through
your own change-management process.
