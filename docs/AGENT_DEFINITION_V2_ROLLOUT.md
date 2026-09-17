# Endpoint collector definition v2 rollout

## Release unit

The following three artifacts are one release unit and must carry the same
`definition_hash`:

1. `agent/internal/definition/v2.json`
2. the `isms-agent` binary built from the same Git revision
3. the active `catalog.agent_definitions` row (`version = 2`, `platform = macos`)

The seed computes the SHA-256 from the checked-in JSON and updates the v2 row
in one database transaction. v1 remains stored as historical, inactive data.
No binary may be deployed when its embedded hash differs from the active row.

The implementation-side comparison found no `osqueryi` on the three reachable
Macs, while the fixed Native commands were executable. Therefore v2 selects
Native for the current macOS fleet; the unreachable devices remain an explicit
post-deployment verification item.

For `CHK-ENDPOINT-009`, v2 records the `/Applications` direct-child scope in
the definition itself (`location_prefixes`, `location_depth`, and explicit
exclusions for `/System/Applications` and `~/Applications`). The item runs
`system_profiler` and `/usr/bin/find` and records scoped path-set differences
in the signed `application_inventory_mismatches` evidence; any difference is
a CHK-ENDPOINT-009 violation. Directory-only
applications are also included in the unapproved-name result, so an
application omitted by `system_profiler` cannot silently disappear.
`include_hidden_bundles=true` makes dot-prefixed `.app` bundles part of the
declared population instead of silently dropping them.

For CHK-ENDPOINT-003, v2 records commercial EDR evidence in `edr_vendor` and
macOS built-in protection evidence in `builtin_protection`. Commercial EDR is
matched from `/bin/ps` PIDs through macOS's kernel-backed `proc_pidpath`, then
against the fixed `executable_path_prefixes` in v2; process names and
command-line arguments are not accepted as evidence. The latter contains
the XProtect process count, XProtect.bundle version, XProtect.app/Remediator
version, `spctl --status`, `csrutil status`, and `systemextensionsctl list`.
The checker accepts either a non-`none` commercial vendor or a complete,
enabled built-in protection record, while retaining both fields for audit.
The v2 definition explicitly declares `promotes_to=["edr_running"]` for the
built-in item, so a complete XProtect record also sets the aggregate
`edr_running=true` while leaving `edr_vendor="none"` when no commercial EDR is
present.

## Preflight

```sh
shasum -a 256 agent/internal/definition/v2.json
go -C agent test ./...
go -C agent build -o dist/isms-agent-v2 ./cmd/isms-agent
```

Before the production switch, record the old active version/hash and the new
JSON hash. Verify that the binary embeds the new definition and that the
acceptance test uses `definition_version = 2`.

## Three-point switch

During a maintenance window, pause the endpoint collection schedule, deploy
the v2 binary to the one-person pilot MacBook Pro, and verify its local collect
output before allowing the schedule to resume. Then run the v2 definition seed
(`ISMS_DB="$ISMS_DB" python3 db/seeds/0005_agent_definition.py`) and verify exactly one active macOS row, matching version and hash. Finally,
run one signed posture submission from a canary device and confirm the stored
snapshot has version 2 and the same hash. Resume collection only after the
canary succeeds.

The order is intentionally fail-closed: an old v1 agent is not silently
interpreted as v2, and an active v2 hash never authorizes a different
collector implementation.
The posture API keeps the v1 and v2 payload contracts available for the
rollback procedure, but only the active catalog row is authorized. While v2
is active, v1 posture submissions are rejected because the v1 row is inactive;
the rollback transaction activates v1 and deactivates v2 before the v1 canary
is submitted.

## Rollback

Rollback is a coordinated three-point reversal, not a file-only change:

1. pause collection and retain all v2 snapshots and audit records;
2. redeploy the previously recorded v1 binary, built from its recorded Git
   revision and embedded v1 hash;
3. restore the v1 row as the sole active macOS definition in a transaction,
   then verify the canary posture submission and resume collection.

The v2 row is kept inactive for forensic comparison. No snapshot or audit row
is deleted. If the old binary artifact is unavailable, stop rather than
activating a mismatched definition; rebuild it from the recorded Git revision
and re-run the acceptance test first.

## Evidence required for completion

- release Git revision, v2 JSON SHA-256, binary checksum, and active DB hash;
- the pilot MacBook Pro enrollment/identity mapping;
- the pilot signed posture result, including CHK-ENDPOINT-010;
- rollback decision record if the canary or any fail-closed validation fails.
