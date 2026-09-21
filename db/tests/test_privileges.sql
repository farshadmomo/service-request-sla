-- svc_app should only be able to do what the app needs
-- runs as svc_app (SET LOCAL ROLE) and everything is rolled back at the end
BEGIN;
SET LOCAL ROLE svc_app;

DO $$
DECLARE
  a jsonb;
BEGIN
  ASSERT current_user = 'svc_app', format('expected to run as svc_app, not %s', current_user);

  -- allowed
  a :=create_service_request('Priv Test', 'priv@example.com', 'Legal',
         'Privilege check request', 'Created through the function.', 'P2', 'Other');
  ASSERT (a->>'created')::boolean, 'svc_app should create requests through the function';

  UPDATE service_request
  SET status = 'In Progress', assignee = 'automation-team', priority = 'P1',
      warned_at = now(), escalated_at = now()
  WHERE request_id = a->>'request_id';
  ASSERT FOUND, 'svc_app should update status, assignee, priority, warned_at and escalated_at';

  ASSERT (SELECT status FROM v_request_queue WHERE request_id = a->>'request_id') = 'In Progress',
    'svc_app should read the queue view';

  INSERT INTO workflow_error_log (workflow_name, node_name, error_message)
  VALUES ('Privilege test', 'Save request', 'test error');
  ASSERT (SELECT count(*) FROM workflow_error_log WHERE workflow_name = 'Privilege test') = 1,
    'svc_app should add and read error log entries';

  PERFORM mark_sla_events();

  -- not allowed
  -- checking the privilege directly too, a direct insert also fails on the sequence
  -- so it would hide a wrong insert grant
  ASSERT NOT has_table_privilege('svc_app', 'service_request', 'INSERT'),
    'svc_app must not have INSERT on service_request';

  BEGIN
    INSERT INTO service_request (requester_name, requester_email, department, title, description,
                                 category, declared_priority, priority)
    VALUES ('Direct', 'direct@example.com', 'IT', 'Direct insert', 'Bypassing the function.', 'Other', 'P2', 'P2');
    RAISE EXCEPTION 'direct INSERT was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    UPDATE service_request SET created_at = now() - interval '10 days' WHERE request_id = a->>'request_id';
    RAISE EXCEPTION 'changing created_at was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    DELETE FROM service_request WHERE request_id = a->>'request_id';
    RAISE EXCEPTION 'DELETE was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    TRUNCATE service_request;
    RAISE EXCEPTION 'TRUNCATE was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    DELETE FROM workflow_error_log;
    RAISE EXCEPTION 'deleting error log entries was allowed';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  RAISE NOTICE 'test_privileges: all cases passed';
END $$;

ROLLBACK;
