-- Failures recorded by the n8n error workflow, one row per failed run.
-- Runs after 04_app_role.sh, so svc_app already exists.
-- The app may add and read entries, but not change or delete them.
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
