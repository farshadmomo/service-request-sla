#!/bin/sh
# Creates svc_app, the login n8n and Appsmith use, with only the rights they need:
#   create requests -> EXECUTE create_service_request (no direct INSERT)
#   read the queue  -> SELECT on the table and the view
#   work the queue  -> UPDATE of status / assignee / priority / warned_at / escalated_at only
#   no DELETE; created_at, due_at and resolved_at can't be written by the app.
# The password comes from APP_DB_PASSWORD (set in .env, passed in by docker-compose).
set -e

psql -v ON_ERROR_STOP=1 -v app_pw="$APP_DB_PASSWORD" \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE svc_app LOGIN PASSWORD :'app_pw';

GRANT SELECT ON service_request, v_request_queue TO svc_app;
GRANT UPDATE (status, assignee, priority, warned_at, escalated_at) ON service_request TO svc_app;

REVOKE EXECUTE ON FUNCTION create_service_request(text, text, text, text, text, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION create_service_request(text, text, text, text, text, text, text, text) TO svc_app;
SQL
