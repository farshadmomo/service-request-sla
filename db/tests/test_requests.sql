-- Tests for create_service_request, the duplicate rule, the update trigger and v_request_queue.
-- Everything runs inside BEGIN ... ROLLBACK, so no test data is left behind.
BEGIN;

DO $$
DECLARE
  a  jsonb;
  b  jsonb;
  r  service_request;
  n  int;
  t1 text;
  t2 text;
BEGIN
  -- Create
  a := create_service_request('Sara Ahmadi', '  Sara@Example.com ', 'Finance',
         'Monthly  sales report', 'Need the monthly sales report by region.', 'P3', 'Report Request');
  ASSERT (a->>'created')::boolean, 'first submission should be created';
  ASSERT a->>'request_id' ~ '^REQ-\d{4}-\d{6}$', format('bad request_id: %s', a->>'request_id');
  SELECT * INTO r FROM service_request WHERE request_id = a->>'request_id';
  ASSERT r.requester_email = 'sara@example.com', 'email should be stored trimmed and lower-case';
  ASSERT r.due_at = sla_due_at(r.created_at, 'P3'), 'due_at should come from the SLA function';

  -- Duplicate: same requester, title differs only in case / spacing / punctuation
  b := create_service_request('Sara A.', 'sara@example.com', 'Finance',
         'monthly sales report!', 'Another description here.', 'P1', 'Report Request');
  ASSERT NOT (b->>'created')::boolean, 'duplicate should not be created';
  ASSERT b->>'request_id' = a->>'request_id', 'duplicate should return the original request_id';

  -- Same title from a different requester is not a duplicate
  b := create_service_request('Reza Karimi', 'reza@example.com', 'IT',
         'Monthly sales report', 'Need the monthly sales report too.', 'P3', 'Report Request');
  ASSERT (b->>'created')::boolean, 'same title from another requester should be created';

  -- Once the original is closed, the same title can be submitted again
  UPDATE service_request SET status = 'Resolved' WHERE request_id = a->>'request_id';
  b := create_service_request('Sara Ahmadi', 'sara@example.com', 'Finance',
         'Monthly sales report', 'Need it again for next month.', 'P3', 'Report Request');
  ASSERT (b->>'created')::boolean AND b->>'request_id' <> a->>'request_id',
    'resubmission after closing should create a new request';

  -- Persian: Arabic yeh/kaf and half-space vs. space are the same title
  t1 := 'اصلاح داده' || U&'\200C' || 'های مشتری کرمان';
  t2 := translate(replace(t1, U&'\200C', ' '), U&'\06CC\06A9', U&'\064A\0643');
  ASSERT t1 <> t2, 'test setup: the two variants should differ byte-wise';
  a := create_service_request('Ali Rezaei', 'ali@example.com', 'HR', t1, 'Customer records need fixing.', 'P2', 'Data Fix');
  b := create_service_request('Ali Rezaei', 'ali@example.com', 'HR', t2, 'Customer records need fixing.', 'P2', 'Data Fix');
  ASSERT (a->>'created')::boolean AND NOT (b->>'created')::boolean,
    'Persian keyboard variants should count as duplicates';
  -- ...but a genuinely different Persian title is not
  b := create_service_request('Ali Rezaei', 'ali@example.com', 'HR',
         'اصلاح داده' || U&'\200C' || 'های فروش تهران', 'Sales records need fixing.', 'P2', 'Data Fix');
  ASSERT (b->>'created')::boolean, 'different Persian titles must not collide';

  -- Bad input fails cleanly: an error is raised and nothing is written
  SELECT count(*) INTO n FROM service_request;
  BEGIN
    PERFORM create_service_request('Bad Email', 'not-an-email', 'Finance', 'Valid title', 'Valid description.', 'P2', 'Other');
    RAISE EXCEPTION 'invalid email was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM create_service_request('Bad Dept', 'x@example.com', 'Marketing', 'Valid title', 'Valid description.', 'P2', 'Other');
    RAISE EXCEPTION 'unknown department was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    PERFORM create_service_request('Bad Prio', 'x@example.com', 'IT', 'Valid title', 'Valid description.', 'P9', 'Other');
    RAISE EXCEPTION 'unknown priority was accepted';
  EXCEPTION WHEN check_violation OR invalid_parameter_value THEN NULL;
  END;
  BEGIN
    PERFORM create_service_request('Blank Title', 'x@example.com', 'IT', '    ', 'Valid description.', 'P2', 'Other');
    RAISE EXCEPTION 'blank title was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT (SELECT count(*) FROM service_request) = n, 'failed submissions must not write rows';

  -- Changing priority recomputes due_at
  SELECT * INTO r FROM service_request WHERE request_id = a->>'request_id';
  UPDATE service_request SET priority = 'P1' WHERE request_id = r.request_id;
  ASSERT (SELECT due_at FROM service_request WHERE request_id = r.request_id) = r.created_at + interval '4 hours',
    'changing priority should recompute due_at';

  -- resolved_at is managed by the trigger, not by clients
  UPDATE service_request SET status = 'Completed' WHERE request_id = r.request_id;
  ASSERT (SELECT resolved_at FROM service_request WHERE request_id = r.request_id) IS NOT NULL,
    'closing should set resolved_at';
  UPDATE service_request SET status = 'In Progress', resolved_at = now() - interval '1 day'
  WHERE request_id = r.request_id;
  ASSERT (SELECT resolved_at FROM service_request WHERE request_id = r.request_id) IS NULL,
    'reopening should clear resolved_at and ignore the value sent';

  -- Queue view SLA states
  INSERT INTO service_request (requester_name, requester_email, department, title, description,
                               category, declared_priority, priority, created_at)
  VALUES
    ('Queue Test', 'queue@example.com', 'IT', 'P1 opened 5h ago',  'SLA view test row.', 'Other', 'P1', 'P1', now() - interval '5 hours'),
    ('Queue Test', 'queue@example.com', 'IT', 'P1 opened 1h ago',  'SLA view test row.', 'Other', 'P1', 'P1', now() - interval '1 hour'),
    ('Queue Test', 'queue@example.com', 'IT', 'P4 opened now',     'SLA view test row.', 'Other', 'P4', 'P4', now()),
    ('Queue Test', 'queue@example.com', 'IT', 'P1 closed late',    'SLA view test row.', 'Other', 'P1', 'P1', now() - interval '5 hours'),
    ('Queue Test', 'queue@example.com', 'IT', 'P1 closed on time', 'SLA view test row.', 'Other', 'P1', 'P1', now() - interval '1 hour');
  UPDATE service_request SET status = 'Resolved'
  WHERE requester_email = 'queue@example.com' AND title LIKE 'P1 closed%';

  ASSERT (SELECT sla_status FROM v_request_queue WHERE title = 'P1 opened 5h ago')  = 'BREACHED', 'past due should be BREACHED';
  ASSERT (SELECT sla_status FROM v_request_queue WHERE title = 'P1 opened 1h ago')  = 'AT_RISK',  'due within 24h should be AT_RISK';
  ASSERT (SELECT sla_status FROM v_request_queue WHERE title = 'P4 opened now')     = 'ON_TRACK', 'due beyond 24h should be ON_TRACK';
  ASSERT (SELECT sla_status FROM v_request_queue WHERE title = 'P1 closed late')    = 'BREACHED', 'closed after due should stay BREACHED';
  ASSERT (SELECT sla_status FROM v_request_queue WHERE title = 'P1 closed on time') = 'ON_TRACK', 'closed before due should be ON_TRACK';
  ASSERT (SELECT sla_label  FROM v_request_queue WHERE title = 'P1 opened 1h ago')  = '🟡 AT RISK', 'label should match status';

  RAISE NOTICE 'test_requests: all cases passed';
END $$;

ROLLBACK;
