import Link from 'next/link';
import { getImportHistory } from '@/lib/imports';
import { getRecordsActor } from '@/lib/ismsRecords';
import { undoImport } from './actions';
import { ImportForm } from './ImportForm';

export const dynamic = 'force-dynamic';
export const metadata = { title: '初期データの取り込み' };

// Initial data import (design doc 2026-09-11 §8). Imports assets, risks, departments, and membership assignments via CSV, and keeps a record of imports and their reversals.
// Only the top executive and administrators can import (also checked in the server action and the DB).

const ERROR_LABEL: Record<string, string> = {
  invalid_input: '入力を確かめてください',
  not_found: '取り込みの記録が見つかりません',
  already_undone: 'この取り込みはもう取り消されています',
  invalid_session: '本人と役割を確かめられませんでした。ページを開き直してください',
  error: '取り消せませんでした。何も変えていません',
};
const KIND_LABEL: Record<string, string> = {
  assets: '資産', risks: 'リスク', departments: '部署', assignments: '所属の割り当て', policies: '規程（下書き）',
};
// What the reversal did (assets and risks are retired, departments are deleted, assignments are returned to the original department).
const UNDO_LABEL: Record<string, string> = {
  assets: '退役', risks: '退役', departments: '削除', assignments: '元の部署へ戻した', policies: '削除',
};
// Reason it was excluded (the same condition the reversal logic checks).
const SKIP_REASON: Record<string, string> = {
  assets: '対象外は、取り込み後に直された資産か、他の記録（リスク・脆弱性・変更の申請）が参照している資産です。',
  risks: '対象外は、取り込み後に直されたリスクか、他の記録（評価・受容・管理策・指摘・インシデントなど）が参照しているリスクです。',
  departments: '対象外は、取り込み後に直された部署か、下位の部署・所属・資産・施策・リスク・利用システムが参照している部署です。',
  assignments: '対象外は、取り込み後に部署を変えた・直した・失効した所属、元の部署が無くなった所属、'
    + '（オーナー以外が取り消すときの）最高責任者の所属です。',
  policies: '対象外は、承認・有効化・周知確認された版、取り込み後に直された版、後から新しい版が足された版と、'
    + '版が残っている規程です（取り込みで作った規程は、版が無くなったときだけ消します）。',
};

export default async function ImportPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string; retired?: string; skipped?: string; kind?: string }>;
}) {
  const sp = await searchParams;
  const actor = await getRecordsActor();
  const canImport = actor !== null && (actor.role === 'owner' || actor.role === 'admin');
  const history = canImport ? await getImportHistory() : null;

  return (
    <div className="flex flex-col gap-6">
      <div>
        <Link href="/risk-management" className="text-[12px] text-[var(--muted)] underline underline-offset-2">リスクマネジメントへ戻る</Link>
        <h1 className="mt-2 text-[21px] font-semibold">初期データの取り込み</h1>
        <p className="mt-1 max-w-[860px] text-[13px] text-[var(--muted)]">
          資産・リスク・部署を CSV で一括登録し、利用者の所属に部署を割り当て、規程の下書きの版を足します。まず内容を確かめ
          （何も書き込みません）、誤りが無ければ取り込みます。取り込んだ内容は取り込みの記録に残り、間違えたときは取り消せます
          （資産とリスクは消さずに退役させ、部署と規程の下書きは削除し、割り当ては元の部署へ戻します）。
          規程の承認と有効化は、取り込みではせず規程の画面で行います。ファイルそのものは保存しません。
        </p>
      </div>

      {sp.retired !== undefined && (
        <section className="card border-[var(--success)] bg-[var(--success-weak)] p-4" role="status">
          <p className="text-sm font-semibold text-[var(--badge-success-fg)]">
            取り消しました（{UNDO_LABEL[sp.kind ?? ''] ?? '退役'} {sp.retired} 件・対象外 {sp.skipped ?? 0} 件）。
            {SKIP_REASON[sp.kind ?? ''] ?? SKIP_REASON.assets}
          </p>
        </section>
      )}
      {sp.error && (
        <section className="card border-[var(--danger)] bg-[var(--danger-weak)] p-4" role="alert">
          <p className="text-sm font-semibold text-[var(--badge-danger-fg)]">{ERROR_LABEL[sp.error] ?? ERROR_LABEL.error}</p>
        </section>
      )}

      {!canImport ? (
        <div className="card p-5 text-[13px] text-[var(--muted)]">取り込めるのは最高責任者・管理者だけです。</div>
      ) : (
        <>
          <ImportForm />
          <section className="card p-5">
            <h2 className="text-[16px] font-semibold">取り込みの記録</h2>
            {!history?.ok || history.data.length === 0 ? (
              <p className="mt-3 text-[13px] text-[var(--muted)]">まだ取り込みの記録がありません。</p>
            ) : (
              <div className="mt-3 overflow-x-auto">
                <table className="w-full min-w-[760px] border-collapse text-[13px]">
                  <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                    <th className="px-3 py-2 font-medium">取り込んだ日時</th><th className="px-3 py-2 font-medium">種類</th>
                    <th className="px-3 py-2 font-medium">行数</th><th className="px-3 py-2 font-medium">取り込んだ人</th>
                    <th className="px-3 py-2 font-medium">ファイルのハッシュ</th><th className="px-3 py-2 font-medium">取り消し</th>
                  </tr></thead>
                  <tbody>
                    {history.data.map((b) => (
                      <tr key={b.id} className="border-b border-[var(--border)] align-top last:border-0">
                        <td className="px-3 py-2">{b.imported_at}</td>
                        <td className="px-3 py-2">{KIND_LABEL[b.kind] ?? b.kind}</td>
                        {/* CSV row count, same as the display right after import (the number of detail entries differs from the row count for policies and assignments) */}
                        <td className="px-3 py-2">{b.row_count} 行</td>
                        <td className="px-3 py-2">{b.importer_name ?? '—'}</td>
                        <td className="px-3 py-2 font-mono text-[11px]">{b.sha256.slice(0, 16)}…</td>
                        <td className="px-3 py-2">
                          {b.undone_at ? (
                            <span>取り消し済み（{b.undone_at}・{b.undoer_name}）<br />{UNDO_LABEL[b.kind] ?? '退役'} {b.retired_count} 件・対象外 {b.skipped_count} 件</span>
                          ) : (
                            <form action={undoImport}>
                              <input type="hidden" name="batch_id" value={b.id} />
                              <button className="btn px-2 py-1 text-[12px]" type="submit">取り消す</button>
                            </form>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
        </>
      )}
    </div>
  );
}
