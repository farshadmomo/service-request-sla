-- Run 20 times in parallel by run_all.sh. Every copy waits until the same
-- moment (:'start'), then submits the same request; only one may be created.
SELECT pg_sleep(greatest(0, extract(epoch FROM :'start'::timestamptz - clock_timestamp())));

SELECT create_service_request('Race Test', 'race@example.com', 'IT',
  'Same request submitted twice', 'Concurrent duplicate submission test.', 'P2', 'Other');
