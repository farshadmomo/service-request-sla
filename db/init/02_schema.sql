-- number part of the request id (REQ-2026-000123)
-- MAXVALUE because lpad would cut a 7 digit number and give duplicate ids
CREATE SEQUENCE request_number_seq MAXVALUE 999999;

CREATE TABLE service_request (
  request_id        text PRIMARY KEY DEFAULT
                      'REQ-' || to_char(now() AT TIME ZONE 'Asia/Tehran', 'YYYY') || '-'
                      || lpad(nextval('request_number_seq')::text, 6, '0'),

  -- from the form
  requester_name    text NOT NULL CHECK (char_length(btrim(requester_name)) BETWEEN 2 AND 100),
  requester_email   text NOT NULL CHECK (requester_email = lower(btrim(requester_email))
                                         AND requester_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  department        text NOT NULL CHECK (department IN ('Finance', 'IT', 'HR', 'Operations', 'Sales', 'Legal')),
  title             text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 5 AND 150),
  description       text NOT NULL CHECK (char_length(btrim(description)) BETWEEN 10 AND 5000),
  declared_priority text NOT NULL CHECK (declared_priority IN ('P1', 'P2', 'P3', 'P4')),

  -- set by n8n and the team
  category          text NOT NULL CHECK (category IN ('Report Request', 'Data Fix', 'Access Request',
                                                      'New Automation', 'Other')),
  priority          text NOT NULL CHECK (priority IN ('P1', 'P2', 'P3', 'P4')),
  status            text NOT NULL DEFAULT 'Open'
                      CHECK (status IN ('Open', 'In Progress', 'Completed', 'Resolved', 'Cancelled')),
  assignee          text,

  -- filled in by the db
  normalized_title  text GENERATED ALWAYS AS (normalize_title(title)) STORED,
  created_at        timestamptz NOT NULL DEFAULT now(),
  due_at            timestamptz GENERATED ALWAYS AS (sla_due_at(created_at, priority)) STORED,
  resolved_at       timestamptz,
  warned_at         timestamptz,  -- at risk email sent
  escalated_at      timestamptz,  -- breached email sent
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- sequence belongs to the table (dropped with it)
ALTER SEQUENCE request_number_seq OWNED BY service_request.request_id;

-- one open request per email + title
-- unique index instead of checking in n8n, so two requests at the same time can't both get in
-- closed ones don't count, the same title can be sent again later
CREATE UNIQUE INDEX service_request_open_dedupe
  ON service_request (requester_email, normalized_title)
  WHERE request_is_open(status);

-- sets updated_at and resolved_at on every update
-- resolved_at: set when closed, kept while closed, cleared if reopened
-- whatever the client sends for these two is ignored
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
