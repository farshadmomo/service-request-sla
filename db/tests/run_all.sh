#!/bin/sh
# Runs inside a throwaway Postgres container (the db-tests service in docker-compose.yml):
# builds the database from db/init exactly like a fresh install, then runs every test.
#   docker compose run --rm db-tests
set -e

docker-entrypoint.sh postgres >/tmp/postgres.log 2>&1 &
pg=$!
# Network connections are only accepted once the init scripts have finished.
until pg_isready -q -h localhost -U postgres; do
  kill -0 "$pg" 2>/dev/null || { cat /tmp/postgres.log; echo "FAILED: database setup"; exit 1; }
  sleep 1
done

run() { psql -q -h localhost -U postgres -d service_desk -v ON_ERROR_STOP=1 "$@"; }

run -f /tests/test_sla.sql
run -f /tests/test_requests.sql
run -f /tests/test_sla_events.sql
run -f /tests/test_privileges.sql

# 20 identical submissions at the same moment must create exactly one request.
start=$(run -tA -c "SELECT now() + interval '2 seconds'")
pids=
for i in $(seq 20); do
  psql -q -tA -h localhost -U svc_app -d service_desk -v ON_ERROR_STOP=1 -v start="$start" \
       -f /tests/race.sql >/tmp/race_$i.log 2>&1 &
  pids="$pids $!"
done
wait $pids || true
if grep -q ERROR /tmp/race_*.log; then cat /tmp/race_*.log; echo "FAILED: race test"; exit 1; fi
rows=$(run -tA -c "SELECT count(*) FROM service_request WHERE requester_email = 'race@example.com'")
[ "$rows" = 1 ] || { echo "FAILED: race test created $rows requests, expected 1"; exit 1; }
dupes=$(grep -l '"created": false' /tmp/race_*.log | wc -l)
echo "race test: 20 simultaneous submissions -> 1 request created, $dupes answered as duplicates"

echo "ALL DATABASE TESTS PASSED"
