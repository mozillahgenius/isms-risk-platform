import { getOrganizationProfile } from '@/lib/organizationRegister';
import { saveCertificationBody, saveScopeStatement } from '@/app/organization/actions';
import {
  dash, first, ModeField, NoSession, OrganizationShell, type SearchParams,
} from '@/app/organization/shell';

export const dynamic = 'force-dynamic';
export const metadata = { title: '組織情報' };

export default async function OrganizationProfilePage({ searchParams }: { searchParams: SearchParams }) {
  const [result, sp] = await Promise.all([getOrganizationProfile(), searchParams]);
  const data = result.ok ? result.data : null;
  const mode = first(sp.mode);

  return (
    <OrganizationShell
      active="profile"
      mode={mode}
      saved={first(sp.saved)}
      error={first(sp.error)}
      role={data?.role ?? null}
      title="組織情報"
      description={<>
        組織名・ISMS適用範囲の声明と、審査機関の情報です。ISMS構築ウィザードのステップ1・2に対応します。
      </>}
    >
      {!data ? <NoSession /> : <>
      <section className="card p-4">
        <h2 className="text-[15px] font-semibold">組織名・ISMS適用範囲</h2>
        <p className="mt-1 text-[12px] text-[var(--muted)]">組織名: {data.tenant.name}(設定画面から変更)</p>
        {data.canManageOrg ? (
          <form action={saveScopeStatement} className="mt-3 flex flex-col gap-2">
            <ModeField mode={mode} />
            <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">ISMS適用範囲の声明
              <textarea className="input min-h-24" name="iso_scope_statement" defaultValue={data.tenant.iso_scope_statement} placeholder="対象事業・組織・拠点・情報資産の範囲を記載" />
            </label>
            <div><button className="btn btn-primary" type="submit">保存</button></div>
          </form>
        ) : (
          <p className="mt-3 whitespace-pre-wrap text-[13px]">
            {data.tenant.iso_scope_statement || '適用範囲は未設定です。'}
          </p>
        )}
      </section>

      <section className="card p-4">
        <h2 className="text-[15px] font-semibold">審査機関情報</h2>
        {data.canManageOrg && (
        <form action={saveCertificationBody} className="mt-3 grid gap-3 rounded-[var(--radius)] bg-[var(--surface-2)] p-3 md:grid-cols-2">
          <ModeField mode={mode} />
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">審査機関名<input className="input" name="body_name" placeholder="〇〇審査登録機構" required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">認証規格<input className="input" name="certification_standard" defaultValue="ISO/IEC 27001:2022" required /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">登録番号(任意)<input className="input" name="certificate_number" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">連絡先(任意)<input className="input" name="contact_info" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">初回認証日(任意)<input className="input" type="date" name="initial_certified_on" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">直近審査日(任意)<input className="input" type="date" name="last_audit_on" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)]">次回審査予定日(任意)<input className="input" type="date" name="next_audit_on" /></label>
          <label className="flex flex-col gap-1 text-[12px] text-[var(--muted)] md:col-span-2">出所・判断メモ<input className="input" name="source_note" /></label>
          <div className="md:col-span-2"><button className="btn btn-primary" type="submit">登録</button></div>
        </form>
        )}
        <div className="mt-3 overflow-x-auto">
          <table className="min-w-[780px] w-full border-collapse text-[13px]">
            <thead>
              <tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                <th className="px-3 py-2 font-medium">審査機関</th><th className="px-3 py-2 font-medium">規格</th>
                <th className="px-3 py-2 font-medium">登録番号</th><th className="px-3 py-2 font-medium">初回認証日</th>
                <th className="px-3 py-2 font-medium">直近審査日</th><th className="px-3 py-2 font-medium">次回審査予定日</th>
              </tr>
            </thead>
            <tbody>
              {data.certificationBodies.length === 0 ? (
                <tr><td className="px-3 py-6 text-[var(--muted)]" colSpan={6}>審査機関はまだ登録されていません。</td></tr>
              ) : data.certificationBodies.map((c) => (
                <tr key={c.id} className="border-b border-[var(--border)] last:border-0">
                  <td className="px-3 py-2">{c.body_name}</td>
                  <td className="px-3 py-2 text-[var(--muted)]">{c.certification_standard}</td>
                  <td className="px-3 py-2 text-[var(--muted)]">{c.certificate_number || '—'}</td>
                  <td className="px-3 py-2 text-[var(--muted)]">{dash(c.initial_certified_on)}</td>
                  <td className="px-3 py-2 text-[var(--muted)]">{dash(c.last_audit_on)}</td>
                  <td className="px-3 py-2 text-[var(--muted)]">{dash(c.next_audit_on)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
      </>}
    </OrganizationShell>
  );
}
