#!/bin/sh
# Runs in the one-shot n8n-import service before n8n starts (see docker-compose.yml).
# First start only: loads the credentials (built from .env) and the workflows in
# n8n/workflows. After that it does nothing, so changes made in the n8n editor are never
# overwritten. Start over: docker compose down -v
# Intake and SLA Monitor are then activated once in the editor: in this n8n version the CLI
# can't activate an imported workflow (it has no version history yet), and doing it here would
# mean writing into n8n's internal tables, which breaks on upgrade.
set -e
marker=/home/node/.n8n/.service-desk-imported
if [ -f "$marker" ]; then
  echo "n8n is already set up, nothing to import"
  exit 0
fi

trap 'rm -f /tmp/credentials.json' EXIT  # the plain-text secrets never outlive this script
node /import/credentials.js > /tmp/credentials.json
n8n import:credentials --input=/tmp/credentials.json

# n8n 1.123 can't import a workflow saved as active into an empty database (it records a
# "deactivated" event before the workflow exists: FOREIGN KEY constraint failed), and a
# workflow downloaded while live is saved as active. So it imports copies marked inactive.
mkdir -p /tmp/workflows
node -e '
const fs = require("fs");
for (const file of fs.readdirSync("/import/workflows").filter((f) => f.endsWith(".json"))) {
  const workflow = JSON.parse(fs.readFileSync(`/import/workflows/${file}`, "utf8"));
  workflow.active = false;
  delete workflow.activeVersionId;
  fs.writeFileSync(`/tmp/workflows/${file}`, JSON.stringify(workflow));
}'
n8n import:workflow --separate --input=/tmp/workflows

touch "$marker"
