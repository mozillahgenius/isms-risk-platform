import 'server-only';

import { readAnalysisWorkspace, type AnalysisScope, type AnalysisWorkspaceData } from './analysisQueries';
import { withTenant, type TenantReadResult } from './tenant';

// 型と SQL は analysisQueries.ts に置く('server-only' を読み込まないので、DB 試験から同じ関数を呼べる)。
// ここは画面から使う入口で、テナント文脈を確立してから範囲つきで読む。
export type {
  AnalysisScope,
  AnalysisWorkspaceData,
  DuplicatePairRow,
  MeasureIncidentLinkRow,
  MeasureOption,
  SimulationRunRow,
} from './analysisQueries';

/** AI分析の画面データ。scope=ALL は全体、ISO27001:2022 は ISMS タグ付きの項目だけ(2026-09-13)。 */
export async function getAnalysisWorkspace(scope: AnalysisScope = 'ALL'): Promise<TenantReadResult<AnalysisWorkspaceData>> {
  return withTenant((sql) => readAnalysisWorkspace(sql, scope));
}
