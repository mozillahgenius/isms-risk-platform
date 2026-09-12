# Outbound mail (request notifications and external questionnaires)

Sending checklists/questionnaires to external resources and notifying people of
work requests follows one rule: **the web UI enqueues, a separate process sends.**

```
Web UI (management_web) -> only inserts a row into app.mail_outbox
                         |
                         v
scripts/send_mail_outbox.py (mail_worker + SMTP credentials) -> SMTP -> recipient
                         |
                         v
          on success status='sent', and the questionnaire also becomes 'sent'
```

## Why the split

- **The web process never holds SMTP credentials.** If a system that is itself in
  ISMS scope held a direct outbound channel, any UI vulnerability would become
  an outbound-mail vulnerability.
- **A single click cannot cause a mis-send.** Enqueueing and sending are
  separate, so you can inspect `app.mail_outbox` and stop a message before it
  leaves.
- **Every send is recorded.** Recipient, subject, body, attempt count and failure
  reason stay in `app.mail_outbox` and serve directly as audit evidence.

## Permissions

| Operation | Who | Implementation |
|---|---|---|
| Enqueue a questionnaire | owner, admin | `require_management_permission(..., 'questionnaire_send')` |
| Enqueue a request notification | owner, admin, manager | `require_management_permission(..., 'notify')` |
| Actually send | the `mail_worker` role only | `scripts/send_mail_outbox.py --apply` run by your scheduler |

### Role separation

Only the **dedicated `mail_worker` role** can advance the state of the queue.

- `app_rw` (i.e. the web `management_web` login) has only `SELECT` and `INSERT`.
  It has neither `UPDATE` nor `DELETE`.
- The four state-transition functions (`claim_mail_batch` / `mark_mail_sent` /
  `mark_mail_failed` / `reclaim_stale_mail`) are `SECURITY DEFINER` and check
  `session_user = 'mail_worker'` first. `app_rw` is not even granted `EXECUTE`.
- Therefore, even with a defect on the web side, **nobody can create a "sent"
  record without actually sending a message**. A row can enter `sent` only from
  `sending`, and only a worker that claimed it with `FOR UPDATE SKIP LOCKED` can
  move it to `sending`.
- Only `reclaim_stale_mail()` can write the `[unconfirmed]` marker, so there is no
  path to erase the marker and put the row back into the resend set.

This applies the same idea as `management_web` in migration 0050 (one role per
boundary, and functions callable only by that role) to outbound mail.

INSERTs into `app.mail_outbox` are enforced by the trigger `trg_guard_mail_outbox`.

UPDATEs do not go through the management-role check, because the sending worker
advances the state and has no personal identity. Instead,
`trg_guard_mail_outbox_update` **freezes the content**:

- purpose, recipient address, recipient name, subject, body, related object,
  enqueue time and creator **cannot be changed**
- a row that has become `sent` cannot move to any other state
- the attempt count cannot decrease
- `DELETE` is granted to nobody (a deletable record is not evidence)
- state moves only `queued -> sending -> sent / failed`.
  **`sent` can be entered only from `sending`**, so a "sent" record cannot be
  fabricated without sending

In other words, once enqueued, "what was going to be sent to whom" is fixed; it
cannot later be rewritten to go to someone else, and an unsent message cannot be
made to look sent.

Recipient names and subjects cannot contain control characters; bodies allow only
newlines and tabs (CHECK constraints).

## Configuration (never commit values to the repository)

Put these in an owner-only environment file at a path of your choosing and load it
in the job that runs `scripts/send_mail_outbox.py`.

| Variable | Meaning |
|---|---|
| `ISMS_SMTP_HOST` | SMTP server |
| `ISMS_SMTP_PORT` | default 587 (STARTTLS); 465 means SMTPS |
| `ISMS_SMTP_USER` / `ISMS_SMTP_PASSWORD` | SMTP authentication |
| `ISMS_SMTP_FROM` | sender; `Display Name <address>` form allowed |
| `ISMS_SMTP_REPLY_TO` | optional; separate reply-to address |
| `ISMS_SMTP_CA_FILE` | optional; verify against a private CA certificate |
| `ISMS_SMTP_STARTTLS` | default `require`; `off` is allowed **only for loopback** targets |
| `ISMS_MAIL_TENANT_TOKEN` | session token of the tenant whose queue is sent |
| `ISMS_MAIL_DATABASE_URL` | DB connection. **The role must be `mail_worker`** (`app_rw` cannot send) |

The web side uses only `ISMS_WEB_BASE_URL` (the base for links in notification
mail). **There is no fallback value.** If it is unset, mail contains no link and
just says "from 'My assignments' in the management UI" — so one deployment's URL
never leaks into mail sent by another deployment.

## Running it

```bash
# List pending messages only (the queue does not advance)
python3 scripts/send_mail_outbox.py --token "$ISMS_MAIL_TENANT_TOKEN" --db isms_dev

# Actually send
python3 scripts/send_mail_outbox.py --token "$ISMS_MAIL_TENANT_TOKEN" --db isms_dev --apply

# Pick up failed rows again (after a human has checked the reason)
python3 scripts/send_mail_outbox.py --token "$ISMS_MAIL_TENANT_TOKEN" --db isms_dev --apply --retry-failed
```

Without `--apply`, not a single message is sent and the queue state does not
advance.

In production, run `scripts/send_mail_outbox.py --apply` periodically (for
example every 2 minutes) from your own scheduler, such as a systemd timer or cron,
with the environment file above loaded.

### Before enabling the schedule

**Check first that no external recipients are still in the queue.** The moment
the schedule is enabled, rows already `queued` go out within one interval. The
listing without `--apply` sends nothing, so use it to review every recipient
before enabling.

```bash
python3 scripts/send_mail_outbox.py --token "$ISMS_MAIL_TENANT_TOKEN" \
  --dsn "$ISMS_MAIL_DATABASE_URL"
```

### Session expiry

`ISMS_MAIL_TENANT_TOKEN` is also an `app.sessions` token and expires after 24 hours,
like the web token. When it expires, the worker keeps failing quietly, so rotate
it periodically (for example every 6 hours) with your scheduler. Use the same
`scripts/rotate_web_session.py` as for the web token, run with
`ISMS_SESSION_ENV_KEY=ISMS_MAIL_TENANT_TOKEN`, `ISMS_SESSION_RESTART=none` and
`ISMS_SESSION_ENV_PATH` pointing at your mail environment file.

## When something fails

A failed row keeps `status='failed'` and `last_error`. **It is not retried
automatically on later runs** (only with `--retry-failed`). Silently retrying
forever would deliver the same questionnaire to the same person many times. The
failure reason is also shown in the UI (questionnaire detail).

Even if several workers run concurrently, claiming uses `FOR UPDATE SKIP LOCKED`,
so the same row is never sent twice.

### Sent but not recorded

A row that the SMTP server accepted but that could not be written back to the DB
is **not marked `failed`** — `failed` would let `--retry-failed` deliver it a second
time. Instead it stays `sending`, and the worker prints "sent but failed to record"
with the id to standard error. The exit code is non-zero.

### Rows stuck in `sending`

If the process dies right after claiming, the row stays `sending` and nobody
picks it up. Normal runs look only at `queued` and `--retry-failed` only at
`failed`, so use the dedicated reclaim command.

```bash
# Move rows that have been 'sending' for 30+ minutes to 'failed' so they become visible
python3 scripts/send_mail_outbox.py --token "$TOKEN" --db isms_dev --reclaim-stale 60
```

**Reclaiming does not resend.** The process may have died after the message
reached the recipient, so check whether it was actually delivered before deciding.

Reclaimed rows get an `[unconfirmed]` marker in `last_error` and are **not picked
up by `--retry-failed`**. They are resent only when, after confirming delivery
status, you explicitly add `--retry-unconfirmed`.

```bash
python3 scripts/send_mail_outbox.py --token "$TOKEN" --db isms_dev \
  --apply --retry-failed --retry-unconfirmed
```

`--reclaim-stale` rejects thresholds shorter than 60 minutes. A short
threshold would push rows still held by a running worker to `failed` and cause
duplicate sends. The listing without `--apply` also shows `sending` rows and their
`last_error`.

## Acceptance

`tests/org_members_and_questionnaires.sh` verifies end to end that:

- the queue does not advance without `--apply`
- `--apply` without SMTP configuration fails without consuming the queue
- an unreachable server leaves `failed` with a reason, never a stuck `sending`
- plaintext SMTP cannot be used for anything other than loopback
- mail actually reaches a fake SMTP server (`tests/fixtures/fake_smtp.py`), the
  subject and body decode correctly, and both the row and the questionnaire reach `sent`
- a sent row's state cannot be reverted, its recipient and body cannot be
  rewritten, and it cannot be `DELETE`d
- a subject cannot contain control characters (newlines and tabs in the body are accepted)
- rows stuck in `sending` are reclaimed by `--reclaim-stale` and are not picked up
  by `--retry-failed` (no automatic resend)
- `--reclaim-stale` rejects thresholds that are too short
- an unsent row cannot be rewritten to `sent`
