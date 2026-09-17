-- The only way n8n creates requests. One call = one transaction, so it either:
--   * inserts the request and returns it           (created = true)
--   * finds an open duplicate and returns that one (created = false)
--   * raises an error for bad input and writes nothing
-- SECURITY DEFINER: runs with the owner's rights, so the app user can create
-- requests through this function without having INSERT on the table.
CREATE OR REPLACE FUNCTION create_service_request(
  p_requester_name    text,
  p_requester_email   text,
  p_department        text,
  p_title             text,
  p_description       text,
  p_declared_priority text,
  p_category          text,
  p_priority          text DEFAULT NULL  -- final priority if triage overrides the declared one
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r       service_request;
  created boolean := true;
BEGIN
  INSERT INTO service_request
    (requester_name, requester_email, department, title, description,
     category, declared_priority, priority)
  VALUES
    (btrim(p_requester_name), lower(btrim(p_requester_email)), p_department,
     btrim(p_title), btrim(p_description),
     p_category, p_declared_priority, coalesce(p_priority, p_declared_priority))
  ON CONFLICT (requester_email, normalized_title) WHERE request_is_open(status)
  DO NOTHING
  RETURNING * INTO r;

  IF NOT FOUND THEN
    created := false;
    -- STRICT: if the duplicate was closed in the instant between the two
    -- statements, raise an error instead of returning nothing; n8n can retry.
    SELECT * INTO STRICT r
    FROM service_request s
    WHERE s.requester_email = lower(btrim(p_requester_email))
      AND s.normalized_title = normalize_title(p_title)
      AND request_is_open(s.status);
  END IF;

  RETURN jsonb_build_object(
    'created',    created,
    'request_id', r.request_id,
    'status',     r.status,
    'category',   r.category,
    'priority',   r.priority,
    'created_at', r.created_at,
    'due_at',     r.due_at
  );
END $$;

-- The Automation team's queue: every request plus its SLA state.
-- The state is calculated when the view is read, because it changes with the clock:
--   BREACHED  due time has passed (closed requests: they were closed late)
--   AT_RISK   still open and due within the next 24 hours
--   ON_TRACK  everything else (closed requests: they were closed on time)
CREATE OR REPLACE VIEW v_request_queue AS
SELECT
  r.*,
  s.sla_status,
  CASE s.sla_status
    WHEN 'ON_TRACK' THEN '🟢 ON TRACK'
    WHEN 'AT_RISK'  THEN '🟡 AT RISK'
    ELSE                 '🔴 BREACHED'
  END AS sla_label
FROM service_request r
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN coalesce(r.resolved_at, now()) > r.due_at                         THEN 'BREACHED'
    WHEN r.resolved_at IS NULL AND r.due_at - now() <= interval '24 hours' THEN 'AT_RISK'
    ELSE                                                                        'ON_TRACK'
  END AS sla_status
) s;
