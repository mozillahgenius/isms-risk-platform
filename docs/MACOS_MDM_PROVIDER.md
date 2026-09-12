# macOS MDM provider integration

## Status and scope

Management currently provides macOS posture collection and fixed, audited RMM
operations through a local endpoint agent driven by an external device dispatch
orchestrator. This is not Apple MDM.

Apple MDM support will be added as a separate provider boundary. NanoMDM is the
preferred first adapter because it exposes the Apple MDM protocol without
forcing the Management application to become the protocol server. NanoMDM is
not yet deployed or connected by this change.

## Responsibility split

| Component | Responsibility |
|---|---|
| Management | Device inventory, desired state, approval, reason, status and audit reference |
| Local endpoint agent | Posture collection and allowlisted local RMM operations |
| Knowledge base (optional) | Organization knowledge, inventory provenance and durable audit context |
| MDM provider worker | Typed command dispatch, idempotency, retry and result normalization |
| NanoMDM | APNs-backed Apple MDM protocol, enrollment and command transport |
| Apple Business Manager | Organization ownership and Automated Device Enrollment |

Management must not store APNs private keys, ADE tokens, bootstrap tokens,
FileVault recovery keys or bearer credentials in ordinary application tables or
render them in the UI. The provider worker receives secrets from its dedicated
secret store only for the operation that needs them.

## Management information architecture

The existing device-management screen remains the single entrance and shows two
clearly named sections:

1. `Agent posture`: last collection, policy state and available fixed RMM actions.
2. `Apple MDM`: enrollment state, supervision, profile compliance, application
   state and pending typed commands.

An absent provider is shown as `未接続` ("not connected"), never as zero devices or compliant.
The UI does not expose a free-form command field. Destructive commands require a
fresh approval record and a second confirmation that names the exact device.

## Typed provider operations

The first adapter supports only an explicit operation union:

- `device.refresh`
- `profile.install`
- `profile.remove`
- `application.install`
- `application.remove`
- `os.update.schedule`
- `device.lock`
- `device.erase`

Every request carries a tenant-scoped device ID, request ID, idempotency key,
approved template/version, operator, reason and approval reference. Arbitrary
URLs, shell commands, profile payloads and vendor-specific command bodies are
not accepted from the browser.

## Orchestration choice

| Option | Suitable role | Decision |
|---|---|---|
| Typed worker + database queue | Deterministic approval, dispatch and result gates | Default for MDM commands |
| Shell + cron | Read-only reconciliation and health checks | Acceptable when the operation is idempotent and bounded |
| Coding-agent orchestration | Implementation, migration rehearsal and evidence review | Development-time use only |
| General-purpose agent orchestrator | Cross-system, recurring coordination | Candidate, not a command acceptance gate |

If an agent orchestrator is adopted, its role is to call the typed worker or
existing CLIs; it does not emit raw MDM commands. The database request ID remains the
idempotency authority, worker failure leaves the request failed or retryable
without implying device success, and a human approval is still required before
profile removal, lock or erase. Deterministic security gates call the target
worker directly instead of trusting an LLM decision as proof of acceptance.

## Delivery phases

### Phase 1: read-only enrollment and inventory

- Prepare Apple Business Manager, APNs certificate and Automated Device
  Enrollment ownership.
- Deploy NanoMDM in an isolated environment and connect a read-only inventory
  adapter.
- Reconcile serial number, hardware UUID and enrollment identity without
  treating any one mutable identifier as sufficient proof.
- Display enrollment, supervision and last check-in state in Management.
- Monitor APNs certificate, ADE server token and Apps & Books location token
  expiry with explicit renewal owners and lead-time alerts.
- Ingest Declarative Device Management declarations and status reports as a
  separate read model from classic queued MDM commands.

### Phase 2: non-destructive configuration

- Version and sign configuration profiles outside the browser.
- Add profile installation/removal, PPPC, FileVault enablement and recovery-key
  escrow through fixed templates.
- Add application deployment using Apple-supported distribution entitlements.
- Manage Apps & Books assignment, reclaim and location-token rotation as a
  lifecycle instead of treating application installation as a one-way command.
- Escrow Bootstrap Token and Activation Lock bypass material only in the
  dedicated MDM secret boundary; Management shows presence and rotation state,
  never the values.
- Keep the local endpoint agent as the richer posture signal and fallback
  diagnostic path; do not duplicate its scheduler elsewhere.

### Phase 3: high-risk commands

- Add lock and erase only after two-person approval, exact-device confirmation,
  expiry and recovery rehearsal are verified.
- Record acceptance and provider result separately; a queued command is not a
  successful device change.
- Make retry idempotent and fail closed when tenant, device or approval context
  differs.

## Acceptance gates

1. APNs/ADE enrollment succeeds on a disposable organization-owned Mac.
2. A cross-tenant device ID cannot be read or commanded.
3. Duplicate request IDs do not create duplicate MDM commands.
4. A profile round trip is observable from approval through device acknowledgement.
5. FileVault escrow is unreadable from Management and ordinary application roles.
6. Expired approval, unknown template and arbitrary provider payload are rejected.
7. Provider outage remains visible as unavailable and does not become compliant.
8. Backup and restore retain inventory and audit history without exporting MDM secrets.
9. Local endpoint agent collection continues during provider failure.
10. Lock and erase are unavailable until their separate high-risk gate passes.
11. DDM declaration/status reconciliation remains tenant-scoped and converges
    after an offline device reconnects.
12. APNs, ADE and Apps & Books token expiry alerts fire before the documented
    renewal window and an expired token fails closed.
13. Bootstrap Token escrow and Activation Lock bypass values cannot be read by
    Management or ordinary database roles, while presence can be audited.
14. Apps & Books seats are reclaimed on deprovision and duplicate assignment
    requests remain idempotent.

## External prerequisites

Production enrollment cannot be completed from source code alone. It requires
an organization-controlled Apple Business Manager tenant, APNs certificate,
Automated Device Enrollment assignment, signing material and a dedicated secret
store. Those external actions must be completed and recorded before production
cutover.
