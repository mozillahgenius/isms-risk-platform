import 'server-only';

import postgres, { type Sql } from 'postgres';

let client: Sql | null = null;

export function getAgentDb(): Sql {
  if (client) return client;
  client = postgres(process.env.ISMS_AGENT_DATABASE_URL || 'postgres:///isms_dev?user=app_rw', {
    max: 4,
    idle_timeout: 20,
    connect_timeout: 5,
    connection: { default_transaction_read_only: false },
    onnotice: () => {},
  });
  return client;
}
