# Codzilla management internal API

The API exposes `POST /internal/v1/risks/tag-iso`, the compatibility endpoint `POST /internal/v1/risks/accept`, and the evidence-bound successor `POST /internal/v2/risks/accept`. All require an exact JSON envelope of `{input,context}` and a Bearer token. `input` never contains tenant, actor, command, path, or approval identity.

`tag-iso` accepts the original v1 context shape with numeric `policy_version` and the evidence-bound shape below. The v1 accept parser still recognizes the original six-field request, but it does not execute it without immutable approval, policy, and expiry evidence. Instead it returns HTTP `426` with `MANAGEMENT_V2_REQUIRED`, a successor link, and no DB mutation. Callers must preflight and move to `/internal/v2/risks/accept`; during the migration window, evidence-bound requests sent to v1 continue to work.

`context.actor_id` is the pinned service principal, and must equal both `ISMS_MANAGEMENT_ACTOR_ID` and the signed database-session identity. `context.requester_id` is the UUID of the user who initiated the operation; it is recorded in the immutable management audit row and is covered by the idempotency hash, but does not select the service principal or authorize the database session.

Set these server-only values before enabling the routes:

- `ISMS_MANAGEMENT_S2S_TOKEN`: at least 32 characters; shared only with the fixed Codzilla management adapter.
- `ISMS_MANAGEMENT_TENANT_ID` and `ISMS_MANAGEMENT_ACTOR_ID`: fixed UUIDs for the service identity.
- `ISMS_MANAGEMENT_SESSION_TOKEN`: a valid ISMS session token for the same tenant and actor. The route verifies the database session context matches the signed envelope.

The requester must have active `ciso` membership for `accept`, while the service actor must be a registered internal management principal. Acceptance takes `evaluation_snapshot_id`/`evaluation_snapshot_sha256`, `inherent_snapshot_id`/`inherent_snapshot_sha256`, `reason`, and an explicit ISO-8601 `expires_at`; it never accepts caller-provided risk levels. Its context must also include `approval_id`, `policy_version_id`, and `policy_version_sha256`. The approval binding covers both reason and expiry. The database locks both immutable snapshots, recomputes their hashes, derives residual and inherent levels, and records the full binding in approval, acceptance, audit, and receipt rows. Apply migrations `0047_internal_management_operations` through `0052_management_workflows` before routing traffic. The operation ID is the idempotency key: exact replay returns the stored receipt, while a changed request with the same ID returns `409`.

Browser deviation actions use the same rule. Send a lowercase hexadecimal `operation_id` (12–64 characters) generated once per user intent and preserve it across retries. Migration `0052_management_workflows` stores immutable receipts independently for request, approval, and close transitions; a matching replay returns the original lifecycle receipt, while a changed payload with the same intent ID fails with `IDEMPOTENCY_CONFLICT`. Legacy forms without that field derive a deterministic ID from their submitted payload for retry compatibility; new clients should always send one.
