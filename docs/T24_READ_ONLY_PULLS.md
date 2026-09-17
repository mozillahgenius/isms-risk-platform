# T-24 read-only pull connectors

## Scope

This connector contract lets ⑦ probe the six declared source systems without
storing credential values in Git, event files, or logs.

| source | driver | access mode | credential reference |
|---|---|---|---|
| mkt | PostgreSQL | database role | `cred.pull.mkt` |
| ops | PostgreSQL | database role | `cred.pull.ops` |
| ssi | PostgreSQL | database role | `cred.pull.ssi` |
| kaname | PostgreSQL | database role | `cred.pull.kaname` |
| codzilla | SQLite | filesystem read-only | `cred.pull.codzilla` |
| el | PostgreSQL | database role | `cred.pull.el` |

The canonical references are in
[`connectors/read_only_sources.contract.json`](../connectors/read_only_sources.contract.json).
Only `credential_ref` and environment-variable names are recorded there; the
values are supplied by the runtime credential store.

## Execution boundary

Run these steps in order:

1. `scripts/validate_pull_sources.py` validates the six-source contract.
2. `scripts/read_only_pull_preflight.py --isolated` checks configuration,
   identifiers, driver availability, and the SQLite file without connecting to
   any source.
3. `scripts/run_read_only_pulls.py --isolated` runs the PostgreSQL or SQLite
   probe for each source and emits credential-free events.
4. `scripts/validate_pull_events.py <event-directory>` verifies that all six
   events form one complete snapshot before delivery to ⑦.
5. `scripts/snapshot_pull_events.py freeze <event-directory> <manifest>` writes
   a non-overwriting SHA-256 manifest; `verify` detects changed, missing, or
   extra event files before the snapshot is accepted as evidence.

The probe reads one count and attempts INSERT, UPDATE, DELETE, TRUNCATE,
CREATE, ALTER, and DROP. The write and DDL attempts must be rejected; they are
only permission probes and must not be treated as business changes.

`--isolated` is mandatory. The runner reports missing configuration and probe
failures as events instead of treating an unmeasured source as healthy.

## Verification available without production access

```sh
bash tests/test-read-only-pulls.sh
```

This covers the six-source success fixture and reverse checks for missing
configuration, writable PostgreSQL/SQLite behavior, unsafe identifiers,
read-only event forgery, and an incomplete event batch.

## Runtime evidence still required

The contract is intentionally marked
`runner_implemented_pending_runtime_access`. The following are not claimed by
the fixture tests and require the approved production-change window:

- six actual read-only roles and their credential-store references;
- a real SELECT plus all seven DML/DDL refusal results for each source;
- the approved append-only delivery path from the validated event batch into ⑦;
- an observed event snapshot retained as operational evidence.

Until those items are obtained, T-24 remains in progress. Do not provision
roles, alter permissions, change production environment values, or deliver
events while another approved production-change stream is active.
