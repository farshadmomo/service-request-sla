// Prints the n8n credentials as JSON for `n8n import:credentials` (run by n8n/import.sh).
// Built from environment variables, so the secrets live only in .env, never in the repo.
// The ids are the ones the exported workflows refer to; n8n encrypts the data on import.
const { APP_DB_PASSWORD, N8N_WEBHOOK_SECRET } = process.env;
if (!APP_DB_PASSWORD || !N8N_WEBHOOK_SECRET) {
  throw new Error('APP_DB_PASSWORD and N8N_WEBHOOK_SECRET must be set');
}

console.log(JSON.stringify([
  {
    id: 'jQZEwMYdRGui2EKd',
    name: 'service_desk',
    type: 'postgres',
    data: { host: 'postgres', port: 5432, database: 'service_desk', user: 'svc_app', password: APP_DB_PASSWORD, ssl: 'disable' },
  },
  {
    id: 'wClsbgvODWWX4zBw',
    name: 'service_desk webhook key',
    type: 'httpHeaderAuth',
    data: { name: 'X-Api-Key', value: N8N_WEBHOOK_SECRET },
  },
  {
    id: 'fQ3BmSTOONew5ole',
    name: 'Mailpit (local SMTP)',
    type: 'smtp',
    data: { host: 'mailpit', port: 1025, secure: false, user: '', password: '' },
  },
]));
