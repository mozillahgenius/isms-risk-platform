// AI分析の ISMS 限定（2026-09-13）の DB 試験。tests/analysis_isms_scope.sh が使い捨て DB に
// データを入れてから、環境変数を付けて起動する。環境変数が無い通常の `vitest run` では飛ばす。
// データの中身と期待値の数え方は tests/analysis_isms_scope.sh のコメントにある。
import { readFileSync } from 'node:fs';
import { userInfo } from 'node:os';
import postgres, { type TransactionSql } from 'postgres';
import { afterAll, describe, expect, it } from 'vitest';
import { readAnalysisWorkspace, runScopedSimulation, type AnalysisScope } from '../src/lib/analysisQueries';

const DB_URL = process.env.ANALYSIS_TEST_DB_URL;
const ADMIN_URL = process.env.ANALYSIS_TEST_ADMIN_URL;
const TOKEN_A = process.env.ANALYSIS_TEST_TOKEN_A ?? '';
const TOKEN_B = process.env.ANALYSIS_TEST_TOKEN_B ?? '';

const MI1 = '53000000-0000-0000-0000-000000000031';
const MI2 = '53000000-0000-0000-0000-000000000032';
const MN = '53000000-0000-0000-0000-000000000033';
const RI = '53000000-0000-0000-0000-000000000021';
const AI = '53000000-0000-0000-0000-000000000041';
const ISO: AnalysisScope = 'ISO27001:2022';

/**
 * 配備の関門(scripts/deploy_runtime.sh)は、試験を PGPASSFILE と PGHOST/PGPORT/PGUSER を付けて走らせる。
 * psql はそれを読むが postgres.js は PGPASSFILE を読まないので、同じファイルから合う行の
 * パスワードを取り出して渡す(無ければ渡さない=手元の trust 接続のまま)。形式は libpq と同じ
 * 「host:port:database:user:password」で、* は何にでも合い、\: と \\ はエスケープ。
 */
function pgpassPassword(url: string): string | undefined {
  const file = process.env.PGPASSFILE;
  if (!file) return undefined;
  const target = new URL(url);
  const database = decodeURIComponent(target.pathname.replace(/^\//, ''));
  const user = target.searchParams.get('user') ?? process.env.PGUSER ?? userInfo().username;
  const host = process.env.PGHOST ?? 'localhost';
  const port = process.env.PGPORT ?? '5432';
  const matches = (pattern: string, value: string) => pattern === '*' || pattern === value;
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    if (!line || line.startsWith('#')) continue;
    const fields: string[] = [];
    let current = '';
    for (let i = 0; i < line.length; i += 1) {
      if (line[i] === '\\' && i + 1 < line.length) { current += line[i + 1]; i += 1; continue; }
      if (line[i] === ':' && fields.length < 4) { fields.push(current); current = ''; continue; }
      current += line[i];
    }
    fields.push(current);
    if (fields.length !== 5) continue;
    const [h, p, d, u, password] = fields;
    if (matches(h, host) && matches(p, port) && matches(d, database) && matches(u, user)) return password;
  }
  return undefined;
}

/**
 * postgres.js は URL の `?user=` を接続の利用者として使わない(url.username・options.username・PGUSER だけを見る)。
 * そのままだと app_rw のつもりが PGUSER(配備の関門では管理者)で繋がり、パスワードの取り違えで落ちる。
 * `?user=` を取り出して username として渡し、URL からは消す(2026-09-13 に見つけた)。
 */
function connect(url: string) {
  const target = new URL(url);
  const username = target.searchParams.get('user') ?? undefined;
  target.searchParams.delete('user');
  return postgres(target.toString(), { max: 1, onnotice: () => undefined, username, password: pgpassPassword(url) });
}
const app = DB_URL ? connect(DB_URL) : null;
const admin = ADMIN_URL ? connect(ADMIN_URL) : null;

/** 画面の withTenant と同じく、1つのトランザクションでテナント文脈を確立してから fn を走らせる。 */
async function inTenant<T>(token: string, fn: (sql: TransactionSql) => Promise<T>): Promise<T> {
  return (await app!.begin(async (sql) => {
    await sql`SELECT app.set_tenant_context(${token})`;
    return fn(sql);
  })) as T;
}

/**
 * 管理者の接続でタグを1つ外した状態を作り、同じトランザクションの中で範囲つきに読み直してから
 * 巻き戻す(タグの付け外しは承認つきの経路でしか行えないため、試験では複製を止めて直接消す)。
 */
async function withoutTag<T>(table: 'measure_frameworks' | 'risk_scenario_frameworks' | 'asset_frameworks',
  column: 'measure_id' | 'risk_scenario_id' | 'asset_id', id: string, fn: (sql: TransactionSql) => Promise<T>): Promise<T> {
  let captured: T | undefined;
  await admin!.begin(async (sql) => {
    await sql`SET LOCAL session_replication_role = replica`;
    await sql`DELETE FROM ${sql('app.' + table)} WHERE ${sql(column)} = ${id}::uuid AND framework_key = ${ISO}`;
    await sql`SELECT app.set_tenant_context(${TOKEN_A})`;
    captured = await fn(sql);
    throw new Error('ROLLBACK_ON_PURPOSE');
  }).catch((e: unknown) => {
    if (!(e instanceof Error) || e.message !== 'ROLLBACK_ON_PURPOSE') throw e;
  });
  return captured as T;
}

const pairsOf = (rows: { measure_a_id: string; measure_b_id: string; shared_risk_count: number; shared_asset_count: number }[]) =>
  rows.map((p) => [p.measure_a_id, p.measure_b_id, p.shared_risk_count, p.shared_asset_count]);

describe.skipIf(!DB_URL || !ADMIN_URL)('AI分析の範囲（ISMS タグの項目だけ）', () => {
  afterAll(async () => {
    await app?.end();
    await admin?.end();
  });

  it('試験は画面と同じ app_rw で繋いでいる（管理者で繋ぐと RLS を通らずに合格してしまう）', async () => {
    const [{ current_user: who }] = await app!`SELECT current_user`;
    expect(who).toBe('app_rw');
  });

  it('全体（ALL）は範囲で絞る前と同じ結果になる', async () => {
    const w = await inTenant(TOKEN_A, (sql) => readAnalysisWorkspace(sql, 'ALL'));
    // RI と RN の両方、AI と AN の両方で数える。
    expect(pairsOf(w.duplicatePairs)).toEqual([
      [MI1, MI2, 2, 2],
      [MI1, MN, 1, 2],
      [MI2, MN, 1, 2],
    ]);
    expect(w.simulatableMeasures.map((m) => m.id)).toEqual([MI1]);
    expect(w.hasAnyAfterMeasureCandidate).toBe(true);
    expect(w.scopedMeasureCount).toBe(3);
    expect(w.totalIncidentCount).toBe(2);
    expect(w.measureIncidentLinks.map((m) => [m.measure_id, m.linked_incident_count])).toEqual([[MI1, 1], [MN, 1]]);
  });

  it('ISMS では、タグ付きの施策・リスク・資産だけで数え、タグ無しは一覧にも件数にも出ない', async () => {
    const w = await inTenant(TOKEN_A, (sql) => readAnalysisWorkspace(sql, ISO));
    // 共有しているのは ISMS タグ付きの RI と AI だけ。タグ無しの MN との組は出ない。
    expect(pairsOf(w.duplicatePairs)).toEqual([[MI1, MI2, 1, 1]]);
    expect(w.simulatableMeasures.map((m) => m.id)).toEqual([MI1]);
    expect(w.scopedMeasureCount).toBe(2);
    // インシデントにはタグが無いので総件数は全体のまま。施策の一覧だけをタグ付きに絞る。
    expect(w.totalIncidentCount).toBe(2);
    expect(w.measureIncidentLinks.map((m) => m.measure_id)).toEqual([MI1]);
  });

  it('逆向き: タグを外すと、その項目は ISMS の結果から消える', async () => {
    const noMi2 = await withoutTag('measure_frameworks', 'measure_id', MI2, (sql) => readAnalysisWorkspace(sql, ISO));
    expect(noMi2.duplicatePairs).toEqual([]);
    const noRi = await withoutTag('risk_scenario_frameworks', 'risk_scenario_id', RI, (sql) => readAnalysisWorkspace(sql, ISO));
    expect(noRi.duplicatePairs).toEqual([]);
    expect(noRi.simulatableMeasures).toEqual([]);
    const noAi = await withoutTag('asset_frameworks', 'asset_id', AI, (sql) => readAnalysisWorkspace(sql, ISO));
    expect(pairsOf(noAi.duplicatePairs)).toEqual([[MI1, MI2, 1, 0]]);
    // 巻き戻したので、元の状態に戻っている。
    const again = await inTenant(TOKEN_A, (sql) => readAnalysisWorkspace(sql, ISO));
    expect(pairsOf(again.duplicatePairs)).toEqual([[MI1, MI2, 1, 1]]);
  });

  it('改ざんしたフォーム: ISMS 範囲でタグの無い施策を送ると断り、記録を作らない', async () => {
    const count = () => admin!`SELECT count(*)::int AS n FROM app.simulation_runs
      WHERE tenant_id = '53000000-0000-0000-0000-000000000001'`;
    const before = await count();
    const outcome = await inTenant(TOKEN_A, (sql) => runScopedSimulation(sql, MN, ISO));
    expect(outcome).toBe('out_of_scope');
    const after = await count();
    expect(after[0].n).toBe(before[0].n);
  });

  it('実行記録に範囲が残り、履歴は範囲ごとに分かれる（ISMS の合計はタグ付きのシナリオだけ）', async () => {
    expect(await inTenant(TOKEN_A, (sql) => runScopedSimulation(sql, MI1, ISO))).toBe('ok');
    expect(await inTenant(TOKEN_A, (sql) => runScopedSimulation(sql, MI1, 'ALL'))).toBe('ok');
    const iso = await inTenant(TOKEN_A, (sql) => readAnalysisWorkspace(sql, ISO));
    const all = await inTenant(TOKEN_A, (sql) => readAnalysisWorkspace(sql, 'ALL'));
    // ISMS: RI だけ(対策後 4、施策なし 16)。全体: RI と RN(対策後 4+2、施策なし 16+9)。
    expect(iso.simulationRuns.map((r) => [r.scenario_count, r.after_measure_risk_level_sum, r.without_measure_risk_level_sum]))
      .toEqual([[1, 4, 16]]);
    expect(all.simulationRuns.map((r) => [r.scenario_count, r.after_measure_risk_level_sum, r.without_measure_risk_level_sum]))
      .toEqual([[2, 6, 25]]);
    // 他施策と共通の注意書きはタグで絞らない(RI には MI2 と MN も効いている)。
    expect(iso.simulationRuns[0].has_shared_measures).toBe(true);
    // 同じ使い捨て DB を他の試験とも共有するので、この試験のテナントの行だけを数える。
    const scopes = await admin!`SELECT scope, count(*)::int AS n FROM app.simulation_runs
      WHERE tenant_id = '53000000-0000-0000-0000-000000000001' GROUP BY scope ORDER BY scope`;
    expect(scopes.map((r) => [r.scope, r.n])).toEqual([['ALL', 1], ['ISO27001:2022', 1]]);
  });

  it('ISMS タグ付きの施策が無いテナントでは、範囲の中の施策が0件になる', async () => {
    const w = await inTenant(TOKEN_B, (sql) => readAnalysisWorkspace(sql, ISO));
    expect(w.scopedMeasureCount).toBe(0);
    expect(w.simulatableMeasures).toEqual([]);
    expect(w.duplicatePairs).toEqual([]);
  });
});
