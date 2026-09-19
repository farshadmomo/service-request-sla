-- Tests for mark_sla_events: each open request is reported once when it becomes AT RISK
-- and once when it becomes BREACHED. Runs inside BEGIN ... ROLLBACK, like the other tests.
BEGIN;

DO $$
DECLARE
  on_track jsonb;
  at_risk  jsonb;
  breached jsonb;
  closed   jsonb;
  got      jsonb;
BEGIN
  on_track := create_service_request('Sweep Test', 'sweep@example.com', 'IT',
                'Sweep on track', 'Due in five business days.', 'P4', 'Other');
  at_risk  := create_service_request('Sweep Test', 'sweep@example.com', 'IT',
                'Sweep at risk', 'P1 is due in four hours.', 'P1', 'Other');
  breached := create_service_request('Sweep Test', 'sweep@example.com', 'IT',
                'Sweep breached', 'Created ten days ago.', 'P2', 'Other');
  closed   := create_service_request('Sweep Test', 'sweep@example.com', 'IT',
                'Sweep closed late', 'Completed after its due date.', 'P2', 'Other');

  -- due_at is generated from created_at, so moving created_at back moves the due date too.
  UPDATE service_request SET created_at = now() - interval '10 days'
  WHERE request_id IN (breached->>'request_id', closed->>'request_id');
  UPDATE service_request SET status = 'Completed' WHERE request_id = closed->>'request_id';

  -- First run: the at-risk and the breached request, nothing else
  SELECT jsonb_object_agg(e.request_id, e.sla_status) INTO got
  FROM mark_sla_events() e WHERE e.requester_email = 'sweep@example.com';
  ASSERT got = jsonb_build_object(at_risk->>'request_id', 'AT_RISK', breached->>'request_id', 'BREACHED'),
    format('first run should report one AT_RISK and one BREACHED request, got %s', got);
  ASSERT (SELECT warned_at IS NOT NULL AND escalated_at IS NULL
          FROM service_request WHERE request_id = at_risk->>'request_id'),
    'the at-risk request should get warned_at only';

  -- Second run: already reported, so nothing new
  ASSERT NOT EXISTS (SELECT FROM mark_sla_events() e WHERE e.requester_email = 'sweep@example.com'),
    'a request must not be reported twice for the same state';

  -- The warned request later breaches: reported again, this time as BREACHED
  UPDATE service_request SET created_at = now() - interval '10 days'
  WHERE request_id = at_risk->>'request_id';
  SELECT jsonb_object_agg(e.request_id, e.sla_status) INTO got
  FROM mark_sla_events() e WHERE e.requester_email = 'sweep@example.com';
  ASSERT got = jsonb_build_object(at_risk->>'request_id', 'BREACHED'),
    format('a warned request that breaches should be escalated, got %s', got);

  RAISE NOTICE 'test_sla_events: all cases passed';
END $$;

ROLLBACK;
