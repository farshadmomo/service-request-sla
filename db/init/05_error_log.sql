-- failed n8n runs, written by the error workflow
-- needs svc_app, so it runs after 04_app_role.sh
-- svc_app can insert and read, not update or delete
CREATE TABLE workflow_error_log (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  workflow_name text NOT NULL,
  node_name     text,
  error_message text NOT NULL,
  execution_id  text,
  execution_url text
);

GRANT SELECT, INSERT ON workflow_error_log TO svc_app;
