-- Numbers for request IDs like REQ-2026-000123.
-- MAXVALUE: lpad() silently cuts numbers longer than 6 digits, which would create
-- duplicate IDs; with MAXVALUE the sequence raises an error instead.
CREATE SEQUENCE request_number_seq MAXVALUE 999999;

CREATE TABLE service_request (
  request_id        text PRIMARY KEY DEFAULT
                      'REQ-' || to_char(now() AT TIME ZONE 'Asia/Tehran', 'YYYY') || '-'
                      || lpad(nextval('request_number_seq')::text, 6, '0'),

  -- Submitted by the requester
  requester_name    text NOT NULL CHECK (char_length(btrim(requester_name)) BETWEEN 2 AND 100),
  requester_email   text NOT NULL CHECK (requester_email = lower(btrim(requester_email))
                                         AND requester_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  department        text NOT NULL CHECK (department IN ('Finance', 'IT', 'HR', 'Operations', 'Sales', 'Legal')),
  title             text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 5 AND 150),
  description       text NOT NULL CHECK (char_length(btrim(description)) BETWEEN 10 AND 5000),
  declared_priority text NOT NULL CHECK (declared_priority IN ('P1', 'P2', 'P3', 'P4')),

  -- Set by n8n and the Automation team
  category          text NOT NULL CHECK (category IN ('Report Request', 'Data Fix', 'Access Request',
                                                      'New Automation', 'Other')),
  priority          text NOT NULL CHECK (priority IN ('P1', 'P2', 'P3', 'P4')),
  status            text NOT NULL DEFAULT 'Open'
                      CHECK (status IN ('Open', 'In Progress', 'Completed', 'Resolved', 'Cancelled')),
  assignee          text,

  -- Maintained by the database
  normalized_title  text GENERATED ALWAYS AS (normalize_title(title)) STORED,
  created_at        timestamptz NOT NULL DEFAULT now(),
  due_at            timestamptz GENERATED ALWAYS AS (sla_due_at(created_at, priority)) STORED,
  resolved_at       timestamptz,
  warned_at         timestamptz,  -- AT RISK notification sent
  escalated_at      timestamptz,  -- BREACHED escalation sent
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- Tie the sequence to the table: dropping the table drops it too, and
-- TRUNCATE ... RESTART IDENTITY resets the numbering.
ALTER SEQUENCE request_number_seq OWNED BY service_request.request_id;

-- Duplicate rule: at most one OPEN request per (requester, normalized title).
-- Enforced by the database, not by a "check, then insert" in n8n, so two
-- simultaneous submissions cannot both get through.
-- Closed requests don't count, so the same title can be requested again later.
CREATE UNIQUE INDEX service_request_open_dedupe
  ON service_request (requester_email, normalized_title)
  WHERE request_is_open(status);

-- On every update:
--   updated_at  = now()
--   resolved_at = set the first time the request moves to a closed status,
--                 kept while it stays closed, cleared if it is reopened.
-- Values that clients send for these two columns are ignored.
CREATE OR REPLACE FUNCTION service_request_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  NEW.resolved_at := CASE
                       WHEN request_is_open(NEW.status) THEN NULL
                       ELSE coalesce(OLD.resolved_at, now())
                     END;
  RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER service_request_before_update
  BEFORE UPDATE ON service_request
  FOR EACH ROW
  EXECUTE FUNCTION service_request_before_update();
