import 'server-only';

import { withTenant, type TenantReadResult } from './tenant';
import { hasIdentityProvisioningConfiguration } from './identityAccessConfig';

export type IdentityAccessSummary = {
  principals: number;
  activePrincipals: number;
  applications: number;
  assignedEntitlements: number;
  openRequests: number;
  failedRequests: number;
};

export type IdentityApplicationRow = {
  id: string;
  app_key: string;
  name: string;
  provider: string;
  provisioning_mode: 'manual' | 'api' | 'scim' | 'google_workspace';
  status: 'planned' | 'active' | 'paused' | 'retired';
  licenses: number;
  assigned: number;
};

export type ProvisioningRequestRow = {
  request_id: string;
  action: string;
  provider: 'google_workspace';
  primary_email: string;
  application_name: string | null;
  license_name: string | null;
  requested_by_email: string;
  reason: string;
  status: 'draft' | 'approved' | 'dispatched' | 'succeeded' | 'failed' | 'cancelled';
  requested_at: string;
  finished_at: string | null;
  error_code: string | null;
};

export type IdentityAccessOverview = {
  summary: IdentityAccessSummary;
  applications: IdentityApplicationRow[];
  requests: ProvisioningRequestRow[];
};

export function isIdentityProvisioningConfigured(environment: NodeJS.ProcessEnv = process.env): boolean {
  return hasIdentityProvisioningConfiguration(environment);
}

export async function getIdentityAccessOverview(): Promise<TenantReadResult<IdentityAccessOverview>> {
  return withTenant(async (sql) => {
    const summaryRows = await sql<IdentityAccessSummary[]>`
      SELECT
        (SELECT count(*)::int FROM app.identity_principals) AS principals,
        (SELECT count(*)::int FROM app.identity_principals WHERE lifecycle_state = 'active') AS "activePrincipals",
        (SELECT count(*)::int FROM app.application_catalog WHERE status <> 'retired') AS applications,
        (SELECT count(*)::int FROM app.entitlement_assignments WHERE state = 'assigned') AS "assignedEntitlements",
        (SELECT count(*)::int FROM app.provisioning_requests WHERE status IN ('draft','approved','dispatched')) AS "openRequests",
        (SELECT count(*)::int FROM app.provisioning_requests WHERE status = 'failed') AS "failedRequests"`;

    const applications = await sql<IdentityApplicationRow[]>`
      SELECT a.id, a.app_key, a.name, a.provider, a.provisioning_mode, a.status,
             count(DISTINCT l.id)::int AS licenses,
             count(DISTINCT e.id) FILTER (WHERE e.state = 'assigned')::int AS assigned
        FROM app.application_catalog a
        LEFT JOIN app.license_catalog l
          ON l.tenant_id = a.tenant_id AND l.application_id = a.id AND l.status = 'active'
        LEFT JOIN app.entitlement_assignments e
          ON e.tenant_id = l.tenant_id AND e.license_id = l.id
       WHERE a.status <> 'retired'
       GROUP BY a.tenant_id, a.id
       ORDER BY a.name`;

    const requests = await sql<ProvisioningRequestRow[]>`
      SELECT r.request_id, r.action, r.provider, p.primary_email,
             a.name AS application_name, l.name AS license_name,
             r.requested_by_email, r.reason, r.status,
             r.requested_at, r.finished_at, r.error_code
        FROM app.provisioning_requests r
        JOIN app.identity_principals p
          ON p.tenant_id = r.tenant_id AND p.id = r.principal_id
        LEFT JOIN app.application_catalog a
          ON a.tenant_id = r.tenant_id AND a.id = r.application_id
        LEFT JOIN app.license_catalog l
          ON l.tenant_id = r.tenant_id AND l.id = r.license_id
       ORDER BY r.requested_at DESC
       LIMIT 50`;

    return {
      summary: summaryRows[0] ?? {
        principals: 0,
        activePrincipals: 0,
        applications: 0,
        assignedEntitlements: 0,
        openRequests: 0,
        failedRequests: 0,
      },
      applications,
      requests,
    };
  });
}
