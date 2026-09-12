import 'server-only';

import { query } from './db';
import { withTenant, type TenantReadResult } from './tenant';

export type ConnectorManifestRow = {
  connector: string;
  version: number;
  kind: 'reader' | 'elevated_reader' | 'writer';
  manifest: unknown;
};

export type IntegrationRow = {
  id: string;
  connector: string;
  manifest_version: number;
  kind: 'reader' | 'elevated_reader' | 'writer';
  status: 'active' | 'paused' | 'error' | 'revoked';
  secret_ref: string;
  approved_by: string | null;
  approved_at: string | null;
  cursors: unknown;
  created_at: string;
  updated_at: string;
};

export type IntegrationRunRow = {
  id: string;
  integration_id: string;
  resource_name: string;
  mode: 'full' | 'incremental';
  started_at: string;
  finished_at: string | null;
  fetched: number | null;
  collected: number | null;
  unreadable: number | null;
  gone: number | null;
  not_collected: number | null;
  coverage_ratio: string | null;
  status: 'success' | 'partial' | 'failed';
  error_detail: string | null;
};

export type IntegrationResourceRunRow = {
  id: string;
  integration_run_id: string;
  resource_name: string;
  external_id: string | null;
  collection_state: 'collected' | 'unreadable' | 'gone' | 'not_collected';
  http_status: number | null;
  record_count: number;
  error_detail: string | null;
  observed_at: string;
};

export type IntegrationSettings = {
  integrations: IntegrationRow[];
  runs: IntegrationRunRow[];
  resourceRuns: IntegrationResourceRunRow[];
};

export async function getConnectorManifests(): Promise<ConnectorManifestRow[]> {
  return query(async (sql) => {
    return sql<ConnectorManifestRow[]>`
      SELECT connector, version, kind, manifest
        FROM catalog.connector_manifests
       ORDER BY connector, version DESC`;
  });
}

export async function getIntegrationSettings(): Promise<TenantReadResult<IntegrationSettings>> {
  return withTenant(async (sql) => {
    const integrations = await sql<IntegrationRow[]>`
      SELECT id, connector, manifest_version, kind, status, secret_ref,
             approved_by, approved_at, cursors, created_at, updated_at
        FROM app.integrations
       ORDER BY updated_at DESC, connector`;

    const runs = await sql<IntegrationRunRow[]>`
      SELECT id, integration_id, resource_name, mode, started_at, finished_at,
             fetched, collected, unreadable, gone, not_collected,
             coverage_ratio::text, status, error_detail
        FROM app.integration_runs
       ORDER BY started_at DESC
       LIMIT 200`;

    const resourceRuns = await sql<IntegrationResourceRunRow[]>`
      SELECT rr.id, rr.integration_run_id, rr.resource_name, rr.external_id,
             rr.collection_state, rr.http_status, rr.record_count, rr.error_detail,
             rr.observed_at
        FROM app.integration_resource_runs rr
        JOIN app.integration_runs r
          ON r.tenant_id = rr.tenant_id AND r.id = rr.integration_run_id
       ORDER BY rr.observed_at DESC
       LIMIT 500`;

    return { integrations, runs, resourceRuns };
  });
}
