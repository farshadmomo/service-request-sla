-- Called every few minutes by the SLA monitor workflow.
-- Stamps open requests that have just become AT RISK (warned_at) or BREACHED (escalated_at)
-- and returns them, so the workflow can tell the team. Each request is reported at most once
-- per state. It is a single statement, so two overlapping runs can't report the same request twice.
CREATE FUNCTION mark_sla_events()
RETURNS TABLE (request_id text, sla_status text, title text, department text, priority text,
               assignee text, requester_email text, due_at timestamptz)
LANGUAGE sql
BEGIN ATOMIC
  UPDATE service_request r
  SET warned_at    = CASE WHEN q.sla_status = 'AT_RISK'  THEN now() ELSE r.warned_at END,
      escalated_at = CASE WHEN q.sla_status = 'BREACHED' THEN now() ELSE r.escalated_at END
  FROM v_request_queue q
  WHERE q.request_id = r.request_id
    AND request_is_open(r.status)
    AND ((q.sla_status = 'AT_RISK'  AND r.warned_at IS NULL)
      OR (q.sla_status = 'BREACHED' AND r.escalated_at IS NULL))
  RETURNING r.request_id, q.sla_status, r.title, r.department, r.priority,
            r.assignee, r.requester_email, r.due_at;
END;
