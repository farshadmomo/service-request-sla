# Design decisions and trade-offs

## Where the rules live

**Every rule that decides what gets stored is in PostgreSQL. n8n orchestrates, and Appsmith
displays.** The SLA calculation, the duplicate rule, the request ID, the allowed values and the
SLA indicators are all SQL, covered by the test suite (`docker compose run --rm db-tests`). A rule
in the database applies to every caller, whether that's n8n, Appsmith, a script or someone in pgAdmin,
and can be tested without clicking through the UI. The price is that part of the logic is SQL rather
than n8n nodes. I think that's right for rules about data, and wrong for integration steps
(validation messages, classification, emails), which stay in n8n.

## Creating a request: one transaction, nothing half-done

n8n validates and classifies, then makes a **single call**: `create_service_request(...)`. Inside
that one statement the database checks for a duplicate, assigns the ID, computes `due_at` and
inserts the row. Either all of it happens or none of it does. There is no sequence of n8n steps
that could stop halfway and leave, say, a request without a due date.

- The function runs with its owner's rights (`SECURITY DEFINER`, with a fixed `search_path`) and is
  the **only way to create a request**. The app role `svc_app` has no INSERT privilege on the
  table.
- If saving fails, the caller gets a 500 with a friendly message, and the n8n run is marked
  **failed**, so it is recorded (below) instead of looking like a success.

## Duplicates

A duplicate is the same `requester_email` plus the same **normalized title**: lower-cased,
punctuation and repeated spaces collapsed, and the Arabic and Persian forms of ی and ک unified. So
"Monthly  sales report!" equals "monthly sales report".

- **Only open requests count.** Once a request is Completed, Resolved or Cancelled, the same title
  can be submitted again (next month's report is a new request).
- **Enforced by a partial unique index**, not by "look first, then insert". Two identical submissions
  arriving at the same moment can't both get in. The race test fires 20 at once: 1 created,
  19 answered as duplicates.
- A duplicate returns **409 with the existing request ID** and its due date, so the requester can
  follow up on what's already there.

## Request IDs

`REQ-<year>-<6 digits>`, e.g. `REQ-2026-000018`, from a database sequence. The year is the
(Gregorian) year of the creation date in Tehran time. Trade-offs:

- **Numbers can have gaps.** A sequence number used by a failed or duplicate attempt is not reused.
  Gap-free numbering would need a lock on every insert, which the ID doesn't need.
- **Numbering doesn't restart each year** (`REQ-2027-000412` can follow `REQ-2026-000411`). IDs stay
  unique and sortable. A yearly reset would need a counter table and locking.

## SLA calculation

- **Asia/Tehran, 17:00** (confirmed). `created_at` and `due_at` are stored in UTC as required. The
  cut-off and "which day is today" are Tehran time, which matters in the evening, when the UTC and
  Tehran dates differ. The tests cover that boundary.
- **Weekend is Saturday and Sunday, as the brief specifies**, even though the usual working week in
  Tehran is different. It's one line in `sla_due_at` if that should change. There are no public
  holidays, as allowed. A holiday table joined into the same function would be the next step.
- **"N business days" = 17:00 on the Nth business day after the day of creation.** The creation day
  never counts, even at 09:00. That gives the same rule for every request instead of a special case
  for "before or after 17:00".
- **`due_at` is a generated column** computed from `created_at` and `priority`, so it can never drift
  from them.
- **The 🟢🟡🔴 indicator is computed when read** (view `v_request_queue`), never stored, so it is
  always current without a job to keep it up to date. Closed requests are judged at `resolved_at`
  (MET/MISSED), which a trigger sets when the status closes the request.
- **P1 is AT RISK from the moment it's created:** its whole SLA (4 h) is inside the 24-hour window.
  That follows directly from the brief's definitions, and it's the right signal for urgent work.

## Validation in three places

The same rules exist in **Appsmith** (instant feedback, the submit button stays disabled), **n8n**
(the trust boundary: anyone with the key can call the webhook, bypassing the form) and the
**database** (CHECK constraints, the last line). The form is a convenience; n8n and the database are
the guards. During development this paid off: when Appsmith was misconfigured and sent the form as a
single string, n8n's validation rejected it cleanly instead of storing garbage.

## Classification

Keyword rules in an n8n Code node: first matching rule wins, and keywords match the start of whole
words, so "report" matches "reports" but "role" doesn't match "control". English only (agreed scope).
It's predictable, testable and free, but crude on free text. The upgrade path is an AI classifier node
in the same place, with the keyword rules as a fallback. The category shows on the queue and in the
report, but the team can't correct it there yet. That would be a small addition (one more column
for `svc_app` to update).

## Security

- **Least privilege:** n8n and Appsmith connect as `svc_app`. It can call the create function, read
  the queue, update only `status`, `assignee`, `priority` and the two notification stamps, and add
  (not change or delete) error log entries. Even someone editing a query in Appsmith can't rewrite
  `created_at` to hide a breach. The privilege tests check all of this.
- **Secrets only in `.env`** (not committed). n8n's credentials are generated from it on the first
  start and stored encrypted by n8n. The repo holds workflow files, which reference credentials by
  ID only. The Appsmith export holds no passwords or keys.
- **Webhook authentication:** a shared key in the `X-Api-Key` header. Appsmith sends it from its
  server, so the key never reaches the browser.
- **Queries use prepared statements:** Appsmith filter values reach Postgres as parameters, never
  as SQL text.
- **Appsmith's SSRF protection stays on.** It blocks `host.docker.internal` on Docker Desktop
  (that name resolves to a private IPv6 address). Rather than disabling the filter, the services run
  on one compose network and address each other by name.
- **Known gap: requester identity is typed in, not proven.** With Appsmith login in front of it,
  the email would come from `appsmith.user.email` instead of a text field.

## Failures

- A database error in intake goes out on the Postgres node's error output: the caller gets a 500
  with a friendly message, and a Stop and Error node marks the run failed.
- The **Error Handler** workflow (n8n's error workflow, linked from Intake and SLA Monitor) writes
  each failed run to `workflow_error_log`, with a link to the run in n8n. The Report page shows the
  latest entries, so failures are visible without opening n8n.
- **Limitation:** if the database itself is down, the log can't be written either. The run is still
  marked failed in n8n's execution list. In production the error workflow would also alert through
  a channel that doesn't depend on the database (email or chat).

## SLA monitoring and escalation

- **Every 15 minutes** n8n calls `mark_sla_events()`. In one statement it stamps and returns the
  open requests that have just become AT RISK (`warned_at`) or BREACHED (`escalated_at`). So each
  request is reported **once per state**, not every 15 minutes, and two overlapping runs can't
  report the same request twice.
- AT RISK → email to the Automation team. BREACHED → email to the team lead with the team copied
  (the escalation). Email steps retry on failure.
- **Trade-off, at most once:** the stamp and the email are separate systems. If the mail server
  stays down through the retries, that one email is lost. The failure is still logged, and the
  request still shows 🔴 on the queue, which is the record. Sending at least once instead would
  risk duplicate emails.
- Locally, all mail goes to **Mailpit**. In production only the n8n SMTP credential changes.

## The queue

- Filters are multi-selects: several values in one filter widen the results (Open **or** In
  Progress), and the two filters narrow each other (status **and** department). Nothing selected
  means "all".
- **Refreshes every 60 seconds** (polling), because SLA labels change with the clock and others
  change requests. At this scale one small query per open screen per minute is nothing. Pushing
  changes (Postgres LISTEN/NOTIFY → websocket) is the upgrade if there were hundreds of viewers.
- The table's primary key is `request_id`, so a refresh that re-orders rows keeps the **same
  request** selected. Without it, Save could update a different request than the one on screen.
- **Last write wins** when two people edit the same request. An `updated_at` check in the UPDATE
  would detect it if that becomes a problem.
- **Priority can't be changed from the queue.** The brief sets `due_at` at creation, and
  re-prioritising would move the SLA promise. The requester's `declared_priority` is kept separately
  from `priority`, so a triage step can be added without a schema change.

## Reporting

"SLA met" counts **delivered** requests only (Completed or Resolved), judged when they closed.
Cancelled work is neither met nor missed. A department with nothing delivered shows "—", not 0%.
Numbers are all-time; a date range is the next step as data grows.

## Deployment

- **One `docker compose up -d`** starts Postgres, n8n, Appsmith and Mailpit, and services reach each
  other by name. The n8n version is pinned (1.123.4) because the exported workflows and the import
  script depend on it. Appsmith is the Community Edition, so no license is needed.
- **The database schema is created from `db/init` on the first start** (numbered files, applied in
  order). Changes after that are applied by hand. A migration tool (Flyway, sqitch) is the upgrade
  once the schema starts changing in production.
- **n8n 1.123 import quirks, handled without touching n8n's internal tables:** a workflow saved as
  active fails to import into an empty database, so `import.sh` imports inactive copies. And an
  imported workflow must be saved once before it can be activated, so that's a documented one-time
  step. Writing into n8n's tables would automate it, but it would break on the next n8n upgrade.
- Postgres is published on host port **5433**, so it can run next to a local Postgres on 5432.
- Appsmith and n8n usage telemetry is switched off.

## Not done (next steps)

Login for requesters and the team; holidays; date range on reports; a triage step (priority change
with a fresh SLA); notifications to the requester; backups; HTTPS in front of the services;
monitoring beyond the error log.
