# Service Request Intake & SLA Tracking

Replaces the spreadsheet the Automation team uses for internal requests. Employees submit a
request in **Appsmith**. **n8n** validates, classifies and stores it in **PostgreSQL**, where its
SLA due date is set. The team works from a live queue with SLA indicators. At-risk and breached
requests are emailed out, and a report page shows SLA performance and automation errors.

```
Employee ─► Appsmith: Submit Request ─POST /webhook/service-request─► n8n: Intake
                                                                        │ validate → classify
                                                                        ▼
            PostgreSQL: create_service_request()  one transaction: duplicate check, ID, due date
             ▲       ▲
             │       └─ every 15 min ─ n8n: SLA Monitor ─► email: at risk → team, breached → lead
             │
Automation team ◄─ Appsmith: Queue (filters, status updates) · Report (SLA, errors)

Any failed n8n run ─► n8n: Error Handler ─► workflow_error_log ─► shown on the Report page
```

The reasoning behind the design, and what was left out, is in [docs/DECISIONS.md](docs/DECISIONS.md).

## What runs

| Service | URL | Purpose |
|---|---|---|
| Appsmith (Community Edition) | http://localhost | Submit form, queue, report |
| n8n 1.123.4 | http://localhost:5678 | Intake webhook, SLA monitor, error handler |
| PostgreSQL 17 | localhost:5433 | Data and all business rules |
| Mailpit | http://localhost:8025 | Catches the SLA emails (no real mail is sent) |

## Setup

Needs Docker Desktop (or Docker Engine with Compose v2). The first start downloads about 2 GB of
images.

**1. Secrets.** Copy the example file and replace the three values with long random strings:

```powershell
Copy-Item .env.example .env     # macOS/Linux: cp .env.example .env
```

| Variable | Used for |
|---|---|
| `POSTGRES_PASSWORD` | the database admin (`postgres`) |
| `APP_DB_PASSWORD` | `svc_app`, the least-privilege role that n8n and Appsmith use |
| `N8N_WEBHOOK_SECRET` | the `X-Api-Key` header the intake webhook requires |

**2. Start everything.**

```powershell
docker compose up -d
```

On the first start the database is created from `db/init`, and a one-shot `n8n-import` container
loads n8n's credentials (built from `.env`) and the three workflows from `n8n/workflows`.

**3. n8n: one-time activation.** Open http://localhost:5678 and create the owner account (local
only; any email works). Open **Service Request - Intake**, move any node slightly, save, and switch
it **Active**. Do the same for **Service Request - SLA Monitor**. Leave the Error Handler inactive:
n8n runs it by itself. The save is needed because n8n 1.123 can't activate a freshly imported
workflow until it has been saved once (see DECISIONS).

**4. Appsmith: import the app.** Open http://localhost, create the admin account (local only), then
**Create new → Import** and choose `appsmith/service_desk.json`. The export contains no secrets, so
Appsmith asks for the two datasources:

| Datasource | Field | Value |
|---|---|---|
| `service_desk` (PostgreSQL) | Host / Port | `postgres` / `5432` (pre-filled) |
| | Database name | `service_desk` |
| | Username / Password | `svc_app` / your `APP_DB_PASSWORD` |
| | SSL mode | Disable |
| `n8n` (Authenticated API) | URL | `http://n8n:5678/webhook` (pre-filled) |
| | Authentication | API Key: key `X-Api-Key`, value your `N8N_WEBHOOK_SECRET`, add to **Header** |

**5. Try it.** Submit a request on **Submit Request**, then submit the same title again to see the
duplicate check. It appears on **Queue** within a minute. A P1 request is AT RISK from the start (its
whole SLA is 4 hours), so the SLA Monitor emails the team at its next quarter-hour run: check
http://localhost:8025.

Start over with an empty system: `docker compose down -v`, then `docker compose up -d`.

## Using it

- **Submit Request:** name, email, department, title, description and declared priority, checked as
  you type. A confirmation shows the request ID and due time. A repeat of an open request shows the
  existing ID instead.
- **Queue:** open work first, earliest due date first. **Status** and **Department** are
  multi-selects that combine (Open + In Progress in IT, say). Select a row to see its details, change its
  status or assignee. The list refreshes every minute.
- **Report:** open, at-risk and breached counts. SLA met % and average time to deliver per
  department, requests per category, and the last 20 automation errors with links to the failed n8n
  runs.

## SLA rules

| Priority | Target | Due |
|---|---|---|
| P1 | 4 clock hours | created + 4 h, weekends included |
| P2 | 1 business day | 17:00 on the 1st business day after the day it was created |
| P3 | 3 business days | 17:00 on the 3rd business day after |
| P4 | 5 business days | 17:00 on the 5th business day after |

- Business days are Monday to Friday; no public holidays (as the brief specifies).
- **17:00 is Asia/Tehran time**, and "the day it was created" is the Tehran date. `created_at` and
  `due_at` are stored in UTC (17:00 Tehran = 13:30 UTC).
- The day of creation never counts, so a P2 request is due 17:00 the next business day whether it
  came in at 09:00 or 18:00.
- Indicator: 🟢 ON TRACK (due in more than 24 h), 🟡 AT RISK (due within 24 h), 🔴 BREACHED
  (past due). Closed requests show ✅ MET or 🔴 MISSED, judged at the moment they were closed.
  Cancelled requests have no SLA verdict.

## Intake API

Appsmith calls this, and it can be tested directly (Postman, curl):

```
POST http://localhost:5678/webhook/service-request
X-Api-Key: <N8N_WEBHOOK_SECRET>
Content-Type: application/json

{ "requester_name": "Sara Ahmadi", "requester_email": "sara@example.com", "department": "Finance",
  "title": "Monthly sales report", "description": "Sales by region for the board pack.",
  "declared_priority": "P2" }
```

| Status | When | Body |
|---|---|---|
| 201 | created | `request_id`, `status`, `category`, `priority`, `created_at`, `due_at` |
| 409 | the same requester already has an **open** request with this title | `error: duplicate_request` and the existing `request_id`, `status`, `due_at` |
| 400 | invalid input | `error: validation_failed` and `errors: [{ field, message }]` |
| 403 | missing or wrong `X-Api-Key` | n8n's authorization message |
| 500 | could not be saved (e.g. database down) | `error: server_error`; the n8n run is marked failed and logged |

Validation: name 2–100 characters, a valid email, department one of Finance / IT / HR / Operations
/ Sales / Legal, title 5–150, description 10–5000, priority P1–P4. The category (Report Request,
Data Fix, Access Request, New Automation, Other) is assigned by n8n from keywords in the title and
description.

## Tests

```powershell
docker compose run --rm db-tests
```

Builds a throwaway database from `db/init` and runs every test against it (the real database is not
touched):

- **SLA:** weekday, weekend, after-hours, UTC-vs-Tehran date boundary, and unknown-priority cases
- **Requests:** create, duplicate (case, spacing, punctuation and Persian letter variants),
  resubmitting after close, rejected inputs leave no row, the update trigger, the queue view states
- **SLA events:** each request is reported once when AT RISK and once when BREACHED, never twice
- **Privileges:** `svc_app` can do its job and nothing more: no direct INSERT, no DELETE or
  TRUNCATE, no changing `created_at`, and it can add error log entries but not delete them
- **Race:** 20 identical submissions at the same moment create exactly one request

## Project layout

```
docker-compose.yml        all services; db-tests runs only when asked
.env.example              the three secrets to set
db/init/                  schema, run in name order on the first start
  01_functions.sql          sla_due_at, normalize_title, request_is_open
  02_schema.sql             service_request table, duplicate index, update trigger
  03_api.sql                create_service_request (the one way in), v_request_queue
  04_app_role.sh            svc_app role and its privileges
  05_error_log.sql          workflow_error_log
  06_sla_events.sql         mark_sla_events, used by the SLA Monitor
db/tests/                 the test suite above
n8n/workflows/            Intake, SLA Monitor, Error Handler (exported from n8n)
n8n/import.sh             first-start import, run by the n8n-import service
n8n/credentials.js        builds n8n's credentials from .env
appsmith/service_desk.json  the Appsmith app (Submit Request, Queue, Report)
```
