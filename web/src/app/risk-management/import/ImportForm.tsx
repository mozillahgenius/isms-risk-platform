'use client';

import { useActionState, useState } from 'react';
import {
  ASSET_COLUMNS, ASSIGNMENT_COLUMNS, DEPARTMENT_COLUMNS, IMPORT_LIMITS, POLICY_COLUMNS, RISK_COLUMNS, type ImportKind,
} from '@/lib/csvImport';
import { applyImport, previewImport, type ImportState } from './actions';

const EMPTY: ImportState = { stage: 'idle', kind: 'assets', csv: '', sha256: '', issues: [], plan: [], message: '' };

const KIND_LABEL: Record<ImportKind, string> = {
  assets: '資産', risks: 'リスク', departments: '部署', assignments: '所属の部署への割り当て', policies: '規程（下書き）',
};
const COLUMNS = {
  assets: ASSET_COLUMNS, risks: RISK_COLUMNS, departments: DEPARTMENT_COLUMNS, assignments: ASSIGNMENT_COLUMNS,
  policies: POLICY_COLUMNS,
} as const;

/** Two-step import: verify the contents (writes nothing) -> import exactly the verified contents. */
export function ImportForm() {
  const [kind, setKind] = useState<ImportKind>('assets');
  const [checked, check, checking] = useActionState(previewImport, EMPTY);
  const [applied, apply, applying] = useActionState(applyImport, EMPTY);
  const columns: readonly { name: string; required: boolean }[] = COLUMNS[kind];
  // After importing, do not show the import control for the same verified contents (prevent double submission).
  const alreadyApplied = applied.stage === 'imported' && applied.sha256 === checked.sha256;
  // If the type changes after verification, do not allow importing with that result (keep the on-screen type and the imported type consistent).
  const kindChanged = checked.stage !== 'idle' && checked.kind !== kind;
  const canApply = checked.stage === 'checked' && checked.issues.length === 0 && checked.plan.length > 0 && !alreadyApplied
    && !kindChanged;

  return (
    <div className="flex flex-col gap-4">
      <form action={check} className="card flex flex-col gap-3 p-5">
        <h2 className="text-[16px] font-semibold">1. ファイルを選んで内容を確かめる（まだ何も書き込みません）</h2>
        <div className="flex flex-wrap gap-3">
          <label className="flex flex-col gap-1 text-[12px]">
            取り込むもの
            <select className="input" name="kind" value={kind} onChange={(e) => setKind(e.target.value as ImportKind)}>
              <option value="assets">資産</option>
              <option value="risks">リスク（関連資産は登録済みの資産キーで指す）</option>
              <option value="departments">部署（上位は部署の名前で指す）</option>
              <option value="assignments">所属の部署への割り当て（利用者はメールで指す。役割は変えない）</option>
              <option value="policies">規程（下書きの版を足す。承認と有効化は規程の画面で）</option>
            </select>
          </label>
          <label className="flex flex-col gap-1 text-[12px]">
            CSV ファイル（UTF-8・{IMPORT_LIMITS.maxBytes / 1_000_000} MB・{IMPORT_LIMITS.maxRows} 行まで）
            <input className="input" name="file" type="file" accept=".csv,text/csv" required />
          </label>
        </div>
        <p className="text-[12px] text-[var(--muted)]">
          1 行目は見出し。使える列: {columns.map((c) => `${c.name}${c.required ? '（必須）' : ''}`).join('、')}。
          既に登録されているキーは上書きせず誤りにします。先頭が = + - @ の値は、表計算で式として動くため受け付けません。
        </p>
        <div>
          <button className="btn btn-primary px-3 py-2 text-sm" type="submit" disabled={checking}>
            {checking ? '確かめています…' : '内容を確かめる'}
          </button>
        </div>
      </form>

      {checked.stage !== 'idle' && (
        <section className="card flex flex-col gap-3 p-5" aria-live="polite">
          <h2 className="text-[16px] font-semibold">2. 確かめた結果（{KIND_LABEL[checked.kind]}）</h2>
          <p className={`text-[13px] font-semibold ${checked.stage === 'failed' || checked.issues.length > 0 ? 'text-[var(--badge-danger-fg)]' : ''}`}
             role={checked.stage === 'failed' || checked.issues.length > 0 ? 'alert' : 'status'}>
            {checked.message}
          </p>
          {kindChanged && (
            <p className="text-[13px] font-semibold text-[var(--badge-danger-fg)]" role="alert">
              取り込むものを変えました。この結果では取り込めません。ファイルを選んで、もう一度確かめてください
            </p>
          )}
          {checked.issues.length > 0 && (
            <div className="overflow-x-auto">
              <table className="w-full min-w-[560px] border-collapse text-[13px]">
                <thead><tr className="border-b border-[var(--border)] text-left text-[12px] text-[var(--muted)]">
                  <th className="px-3 py-2 font-medium">行</th><th className="px-3 py-2 font-medium">列</th>
                  <th className="px-3 py-2 font-medium">誤り</th>
                </tr></thead>
                <tbody>
                  {checked.issues.map((i, n) => (
                    <tr key={n} className="border-b border-[var(--border)] last:border-0">
                      <td className="px-3 py-2">{i.row === 0 ? 'ファイル全体' : `${i.row} 行目`}</td>
                      <td className="px-3 py-2">{i.column ?? '—'}</td>
                      <td className="px-3 py-2">{i.message}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {checked.plan.length > 0 && (
            <details open={checked.issues.length === 0}>
              <summary className="cursor-pointer text-[13px]">取り込める行（{checked.plan.length} 件）</summary>
              <ul className="mt-2 max-h-64 overflow-y-auto text-[12px]">
                {checked.plan.map((p) => <li key={p.row}>{p.row} 行目: {p.key} {p.label}</li>)}
              </ul>
            </details>
          )}
          {canApply && (
            <form action={apply}>
              <input type="hidden" name="kind" value={checked.kind} />
              <input type="hidden" name="checked_sha256" value={checked.sha256} />
              <textarea hidden readOnly name="csv" value={checked.csv} />
              <button className="btn btn-primary px-3 py-2 text-sm" type="submit" disabled={applying}>
                {applying ? '取り込んでいます…' : `${checked.plan.length} 件を取り込む`}
              </button>
              <p className="mt-1 text-[11px] text-[var(--muted)]">全件を 1 回で書き込みます。1 件でも失敗したときは何も残りません。</p>
            </form>
          )}
        </section>
      )}

      {applied.stage !== 'idle' && (
        <section className="card flex flex-col gap-2 p-5">
          <p className={`text-[13px] font-semibold ${applied.stage === 'failed' ? 'text-[var(--badge-danger-fg)]' : 'text-[var(--badge-success-fg)]'}`}
             role={applied.stage === 'failed' ? 'alert' : 'status'}>
            {applied.message}
          </p>
          {applied.issues.length > 0 && (
            <ul className="text-[12px]">
              {applied.issues.map((i, n) => <li key={n}>{i.row === 0 ? 'ファイル全体' : `${i.row} 行目`}: {i.message}</li>)}
            </ul>
          )}
        </section>
      )}
    </div>
  );
}
