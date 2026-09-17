'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';

function requiredText(form: FormData, key: string, max: number): string {
  const value = String(form.get(key) ?? '').trim();
  if (!value || value.length > max) throw new Error(`${key} is required`);
  return value;
}

function secretReference(form: FormData): string {
  const value = requiredText(form, 'secret_ref', 200);
  // KanameコネクタのUUIDを指すURIだけを許可し、資格情報そのものを受け取らない。
  if (!/^kaname:\/\/connector\/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new Error('invalid Kaname connector reference');
  }
  return value;
}

function route(form: FormData, value: string): string {
  const mode = form.get('mode');
  return mode === 'isms' || mode === 'risk'
    ? `${value}${value.includes('?') ? '&' : '?'}mode=${mode}`
    : value;
}

export async function saveIntegration(formData: FormData) {
  if (process.env.ISMS_SETTINGS_WRITE_ENABLED !== '1') redirect(route(formData, '/settings?error=write_disabled'));
  if (!process.env.ISMS_WRITE_DATABASE_URL) redirect(route(formData, '/settings?error=write_db_not_configured'));

  const selection = requiredText(formData, 'manifest_key', 180);
  const separator = selection.lastIndexOf(':');
  if (separator <= 0) throw new Error('invalid manifest selection');
  const connector = selection.slice(0, separator);
  if (!/^[a-z0-9][a-z0-9_.-]*$/.test(connector)) throw new Error('invalid connector');
  const version = Number(selection.slice(separator + 1));
  if (!Number.isSafeInteger(version) || version < 1) throw new Error('invalid manifest version');
  const secretRef = secretReference(formData);
  const status = String(formData.get('status') ?? 'paused');
  if (status !== 'paused' && status !== 'active') throw new Error('invalid integration status');

  const result = await withTenantWrite(async (sql) => {
    // kind はフォーム値を使わず、Git正本の投影から取得する。
    const manifests = await sql<{ kind: 'reader' | 'elevated_reader' | 'writer' }[]>`
      SELECT kind
        FROM catalog.connector_manifests
       WHERE connector = ${connector} AND version = ${version}`;
    const manifest = manifests[0];
    if (!manifest) throw new Error('manifest not found');
    if (manifest.kind !== 'reader') {
      throw new Error('approval workflow is required for this connector');
    }

    await sql`
      INSERT INTO app.integrations
        (tenant_id, connector, manifest_version, kind, status, secret_ref)
      VALUES
        (app.current_tenant(), ${connector}, ${version}, ${manifest.kind}, ${status}, ${secretRef})
      ON CONFLICT (tenant_id, connector) DO UPDATE
        SET manifest_version = EXCLUDED.manifest_version,
            kind = EXCLUDED.kind,
            secret_ref = EXCLUDED.secret_ref,
            status = ${status},
            updated_at = now()`;

    return connector;
  });

  if (!result.ok) redirect(route(formData, `/settings?error=${result.reason}`));
  revalidatePath('/settings');
  revalidatePath('/operations');
  redirect(route(formData, '/settings?saved=1'));
}
