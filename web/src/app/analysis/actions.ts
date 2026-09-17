'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { ISMS_ANALYSIS_SCOPE, parseAnalysisScope, runScopedSimulation, type AnalysisScope } from '@/lib/analysisQueries';
import { withTenantWrite } from '@/lib/tenant';

// organization/actions.tsで確立したUUID形式検証を踏襲する。改ざんFormDataの
// 不正なUUIDを::uuidキャスト失敗(reason='error')に丸投げしない。
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuidText = (form: FormData, key: string): string => {
  const value = String(form.get(key) ?? '').trim();
  if (!value || !UUID_RE.test(value)) throw new Error(`${key} の形式が不正です`);
  return value;
};

/** 実行後・エラー後は、元の範囲(ISMS か全体か)の画面へ戻す。範囲が読めなければ全体へ戻す。 */
function analysisPath(scope: AnalysisScope | null, query: string): string {
  return `/analysis?mode=${scope === ISMS_ANALYSIS_SCOPE ? 'isms' : 'risk'}&${query}`;
}

export async function runSimulation(form: FormData) {
  // 範囲は画面が hidden で送る。ALL か ISO27001:2022 以外は受け付けない(2026-09-13)。
  const scope = parseAnalysisScope(form.get('scope'));
  if (!scope) redirect(analysisPath(null, 'error=invalid_input'));
  let excludedMeasureId: string;
  try {
    excludedMeasureId = uuidText(form, 'excluded_measure_id');
  } catch {
    redirect(analysisPath(scope, 'error=invalid_input'));
  }

  // 計算と記録は analysisQueries.ts(DB 試験と同じ関数)。範囲の中にない施策は out_of_scope で断る。
  const result = await withTenantWrite((sql) => runScopedSimulation(sql, excludedMeasureId, scope));
  if (!result.ok) redirect(analysisPath(scope, `error=${result.reason}`));
  if (result.data !== 'ok') redirect(analysisPath(scope, `error=${result.data}`));
  revalidatePath('/analysis');
  redirect(analysisPath(scope, 'saved=1'));
}
