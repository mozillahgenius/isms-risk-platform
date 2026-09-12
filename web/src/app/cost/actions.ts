'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { withTenantWrite } from '@/lib/tenant';

const text = (form: FormData, key: string, max = 1000): string => {
  const value = String(form.get(key) ?? '').trim();
  if (!value || value.length > max) throw new Error(`${key} is required`);
  return value;
};

const optionalText = (form: FormData, key: string, max = 4000): string | null => {
  const value = String(form.get(key) ?? '').trim();
  return value ? value.slice(0, max) : null;
};

// Allow only decimals that fit the precision of numeric(p,s). Values exceeding the digits, NaN, and negatives are
// rejected explicitly here rather than delegated to DB CHECK/precision errors (same policy as 0035).
const decimal = (
  form: FormData, key: string, pattern: RegExp, label: string,
  allowZero: boolean,
): number => {
  const raw = String(form.get(key) ?? '').trim();
  if (!raw || !pattern.test(raw)) {
    throw new Error(`${label} は${allowZero ? '0以上' : '0より大きい'}の数値で、桁数の上限内で入力してください`);
  }
  const n = Number(raw);
  if (allowZero ? !(n >= 0) : !(n > 0)) {
    throw new Error(`${label} は${allowZero ? '0以上' : '0より大きい'}の数値で入力してください`);
  }
  return n;
};

// An HTML5 date input guarantees YYYY-MM-DD, but forms can be tampered with, so
// validate the format and that the date actually exists on the server side too. Avoid delegating to DateStyle-dependent behavior
// or DB errors (Codex review 2026-09-02 finding).
const isoDate = (form: FormData, key: string, label: string): string => {
  const raw = text(form, key, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) throw new Error(`${label} はYYYY-MM-DD形式で入力してください`);
  const d = new Date(`${raw}T00:00:00Z`);
  const [y, m, day] = raw.split('-').map(Number);
  if (d.getUTCFullYear() !== y || d.getUTCMonth() + 1 !== m || d.getUTCDate() !== day) {
    throw new Error(`${label} が実在する日付ではありません`);
  }
  return raw;
};

const route = (form: FormData, value: string): string => {
  const mode = form.get('mode');
  return mode === 'isms' || mode === 'risk'
    ? `${value}${value.includes('?') ? '&' : '?'}mode=${mode}`
    : value;
};

export async function saveRate(form: FormData) {
  const role = text(form, 'role', 100);
  // Hourly rate allows 0 yen, matching the DB CHECK (hourly_rate >= 0) (e.g. free-of-charge work).
  // Effort (hours) is time actually spent on an activity, so 0 is not allowed; the two are distinguished
  // (Codex review 2026-09-02 finding: a >0 constraint had mistakenly been imposed on the rate as well).
  const hourlyRate = decimal(form, 'hourly_rate', /^\d{1,8}(\.\d{1,2})?$/, '時間単価', true);
  const effectiveFrom = isoDate(form, 'effective_from', '適用開始日');
  const sourceNote = optionalText(form, 'source_note', 2000) ?? '';
  const result = await withTenantWrite(async (sql) => {
    // rate_master is append-only (past training costs look up the rate as of the execution date via LATERAL JOIN
    // each time, so rewriting existing rows would silently change past costs).
    // Re-registering the same (role, effective_from) is treated as a mistake, not a revision,
    // and detected atomically with ON CONFLICT DO NOTHING + RETURNING (SELECT->INSERT would
    // be a TOCTOU under concurrent requests. Codex review 2026-09-02 finding).
    // Do not call redirect() inside this callback (withTenantWrite's catch would
    // catch Next.js's redirect control flow as an ordinary error).
    const rows = await sql<{ id: string }[]>`
      INSERT INTO app.rate_master (tenant_id, role, hourly_rate, effective_from, source_note)
      VALUES (app.current_tenant(), ${role}, ${hourlyRate}, ${effectiveFrom}::date, ${sourceNote})
      ON CONFLICT (tenant_id, role, effective_from) DO NOTHING
      RETURNING id`;
    return rows.length > 0;
  });
  if (!result.ok) redirect(route(form, `/cost?error=${result.reason}`));
  if (!result.data) redirect(route(form, '/cost?error=duplicate_rate'));
  revalidatePath('/cost');
  redirect(route(form, '/cost?saved=1'));
}

export async function saveEducationRecord(form: FormData) {
  const programName = text(form, 'program_name', 200);
  const role = text(form, 'role', 100);
  const memberId = optionalText(form, 'member_id', 80);
  const hours = decimal(form, 'hours', /^\d{1,4}(\.\d{1,2})?$/, '工数(時間)', false);
  const conductedOn = isoDate(form, 'conducted_on', '実施日');
  const relatedMeasureId = optionalText(form, 'related_measure_id', 80);
  const sourceNote = optionalText(form, 'source_note', 2000) ?? '';
  const result = await withTenantWrite(async (sql) => {
    await sql`
      INSERT INTO app.education_records
        (tenant_id, program_name, role, member_id, hours, conducted_on, related_measure_id, source_note)
      VALUES
        (app.current_tenant(), ${programName}, ${role},
         ${memberId ? memberId : null}::uuid, ${hours}, ${conductedOn}::date,
         ${relatedMeasureId ? relatedMeasureId : null}::uuid, ${sourceNote})`;
  });
  if (!result.ok) redirect(route(form, `/cost?error=${result.reason}`));
  revalidatePath('/cost');
  redirect(route(form, '/cost?saved=1'));
}
