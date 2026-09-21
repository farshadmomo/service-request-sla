-- run_all.sh runs this 20 times at once
-- they all wait for the same :'start' time and send the same request, only 1 should be created
SELECT pg_sleep(greatest(0, extract(epoch FROM :'start'::timestamptz - clock_timestamp())));

SELECT create_service_request('Race Test', 'race@example.com', 'IT',
  'Same request submitted twice', 'Concurrent duplicate submission test.', 'P2', 'Other');
