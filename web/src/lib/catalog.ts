import 'server-only';
import { query } from './db';
import { safeReason } from './dbError';
import { isPlaceholderBody } from './policyBody';
import { ANNEX_A_CODE, type RegisterKey, type StepFacts } from './isoSteps';
import { ISMS_FRAMEWORK_KEY } from './navigation';
import { withTenant, type TenantReadResult } from './tenant';

// catalog スキーマ（＝ルールの投影）を読むところ。書き込みは一切しない。
// app.* / audit.* はここから触らない（テナント文脈が要る。tenantDataStatus() を参照）。


export type DomVersion = {
  id: string;
  version: string;
  released_at: string;
  changelog: string;
};

export type Provenance = {
  target: 'dom' | 'controls' | 'risk_scenario_templates';
  source_repo: string;
  source_commit: string | null;
  source_path: string;
  source_sha256: string;
  row_count: number;
  loader: string;
  loaded_at: string;
  dom_version: string;
};

export type Framework = {
  key: string;
  name_ja: string;
  version: string;
  source_note: string | null;
  control_count: number;
};

export type Control = {
  id: string;
  framework_key: string;
  code: string;
  title_ja: string;
  // catalog.controls.theme は NULL 可（分類の無い統制が在り得る）。
  // 型を string と偽ると、実データが NULL になった瞬間に画面が落ちる。
  theme: string | null;
  guidance_md: string | null;
  retired_at: string | null;
};

export type RiskTemplate = {
  id: string;
  domain: string;
  area: string;
  phase: number;
  theme: string;
  measure: string;
  frame: string;
  summary: string;
  default_action: string;
  industry_presets: string[];
  retired_at: string | null;
};

export type Policy = {
  key: string;
  title_ja: string;
  body_md: string;
  clause_refs: string[];
  sort_order: number;
};

export type Role = { key: string; name_ja: string; description: string; sort_order: number };
export type AssetClass = { key: string; name_ja: string; rank: number; external_share_policy: string };
export type CalendarEvent = {
  key: string;
  name_ja: string;
  cadence: string;
  offset_months: number | null;
  owner_role: string;
  clause_ref: string | null;
  extendable: boolean;
};
export type RiskCriteria = {
  impact_sec_formula: string;
  band_top_priority: number[];
  band_action: number[];
  band_consider: number[];
  band_accept: number[];
  due_days_top_priority: number;
  due_days_action: number;
};

export type Counts = {
  dom_versions: number;
  frameworks: number;
  controls: number;
  risk_scenario_templates: number;
  policies: number;
  roles: number;
  asset_classes: number;
  calendar_events: number;
  risk_criteria: number;
  framework_mappings: number;
  risk_template_controls: number;
  checks: number;
  check_controls: number;
  connector_manifests: number;
};

export async function getCurrentDom(): Promise<DomVersion | null> {
  return query(async (sql) => {
    const rows = await sql<DomVersion[]>`
      SELECT id, version, released_at, changelog
        FROM catalog.dom_versions WHERE is_current`;
    return rows[0] ?? null;
  });
}

export async function getProvenance(): Promise<Provenance[]> {
  return query(async (sql) => {
    return sql<Provenance[]>`
      SELECT p.target, p.source_repo, p.source_commit, p.source_path, p.source_sha256,
             p.row_count, p.loader, p.loaded_at, d.version AS dom_version
        FROM catalog.seed_provenance p
        JOIN catalog.dom_versions d ON d.id = p.dom_version_id
       ORDER BY p.target`;
  });
}

export async function getCounts(): Promise<Counts> {
  return query(async (sql) => {
    const rows = await sql<Counts[]>`
      SELECT
        (SELECT count(*) FROM catalog.dom_versions)            ::int AS dom_versions,
        (SELECT count(*) FROM catalog.frameworks)              ::int AS frameworks,
        (SELECT count(*) FROM catalog.controls
          WHERE retired_at IS NULL)                            ::int AS controls,
        (SELECT count(*) FROM catalog.risk_scenario_templates
          WHERE retired_at IS NULL)                            ::int AS risk_scenario_templates,
        (SELECT count(*) FROM catalog.policies_default)        ::int AS policies,
        (SELECT count(*) FROM catalog.roles_default)           ::int AS roles,
        (SELECT count(*) FROM catalog.asset_classes_default)   ::int AS asset_classes,
        (SELECT count(*) FROM catalog.calendar_events_default) ::int AS calendar_events,
        (SELECT count(*) FROM catalog.risk_criteria_default)   ::int AS risk_criteria,
        (SELECT count(*) FROM catalog.framework_mappings)      ::int AS framework_mappings,
        (SELECT count(*) FROM catalog.risk_template_controls)  ::int AS risk_template_controls,
        (SELECT count(*) FROM catalog.checks)                  ::int AS checks,
        (SELECT count(*) FROM catalog.check_controls)          ::int AS check_controls,
        (SELECT count(*) FROM catalog.connector_manifests)     ::int AS connector_manifests`;
    return rows[0];
  });
}

export async function listFrameworks(): Promise<Framework[]> {
  return query(async (sql) => {
    return sql<Framework[]>`
      SELECT f.key, f.name_ja, f.version, f.source_note,
             (SELECT count(DISTINCT cf.control_id) FROM catalog.control_frameworks cf
               JOIN catalog.controls c ON c.id = cf.control_id
               WHERE cf.framework_key = f.key AND c.retired_at IS NULL)::int AS control_count
        FROM catalog.frameworks f
       ORDER BY f.key`;
  });
}

export type ControlFilter = { q?: string; theme?: string; framework?: string };

export async function listControls(f: ControlFilter = {}): Promise<Control[]> {
  // ここで trim するのは **URL から来た入力**であって、保存値ではない。
  // 保存値の正規化は migration 0023 の CHECK が担う（D-29）ので、画面側では一切行わない。
  // 入力の trim は前後の空白を落とすだけで、保存値は正規形なので突き合わせ結果は変わらない。
  // 手打ちの URL に空白が混ざっても引けるようにするための入力整形。
  const q = (f.q ?? '').trim();
  const theme = (f.theme ?? '').trim();
  const framework = (f.framework ?? '').trim();
  return query(async (sql) => {
    return sql<Control[]>`
      SELECT DISTINCT c.id, c.framework_key, c.code, c.title_ja, c.theme, c.guidance_md, c.retired_at
        FROM catalog.controls c
        LEFT JOIN catalog.control_frameworks cf ON cf.control_id = c.id
       WHERE retired_at IS NULL
         AND (${q} = '' OR c.code ILIKE ${'%' + q + '%'} OR c.title_ja ILIKE ${'%' + q + '%'}
              OR c.theme ILIKE ${'%' + q + '%'})
         AND (${theme} = '' OR c.theme = ${theme} OR c.theme LIKE ${theme + ' / %'})
         AND (${framework} = '' OR cf.framework_key = ${framework})
       ORDER BY c.code`;
  });
}

export async function getControl(id: string): Promise<Control | null> {
  return query(async (sql) => {
    const rows = await sql<Control[]>`
      SELECT id, framework_key, code, title_ja, theme, guidance_md, retired_at
        FROM catalog.controls WHERE id = ${id}::uuid`;
    return rows[0] ?? null;
  });
}

/** 統制の被参照。対応表・リスク雛形からの参照も含め、件数を隠さずそのまま返す。 */
export type ControlBacklinks = {
  mappings_from: number;
  mappings_to: number;
  checks: number;
  risk_templates: number;
  same_theme: number;
};

export async function getControlBacklinks(id: string): Promise<ControlBacklinks> {
  return query(async (sql) => {
    const rows = await sql<ControlBacklinks[]>`
      SELECT
        (SELECT count(*) FROM catalog.framework_mappings WHERE from_control_id = ${id}::uuid)::int AS mappings_from,
        (SELECT count(*) FROM catalog.framework_mappings WHERE to_control_id   = ${id}::uuid)::int AS mappings_to,
        (SELECT count(*) FROM catalog.check_controls     WHERE control_id      = ${id}::uuid)::int AS checks,
        (SELECT count(*) FROM catalog.risk_template_controls WHERE control_id  = ${id}::uuid)::int AS risk_templates,
        -- ここは素の等値でよい。theme は migration 0023 の CHECK 制約により
        -- 「NULL か、正規形の空でない文字列」しか入らないので、素の等値が正規形の一致と
        -- 一致する（画面側で正規化すると、逆に一覧の絞り込みとずれる）。
        -- theme が NULL の統制は「分類なし」なので、NULL 同士を同じ分類と数えない
        -- （SQL の NULL 比較がそのまま偽になる。明示のため IS NOT NULL も書く）。
        (SELECT count(*) FROM catalog.controls c
          WHERE c.retired_at IS NULL AND c.id <> ${id}::uuid
            AND c.theme IS NOT NULL
            AND c.theme = (SELECT theme FROM catalog.controls WHERE id = ${id}::uuid))::int AS same_theme`;
    return rows[0];
  });
}

export type RiskFilter = { q?: string; domain?: string; frame?: string; framework?: string };

export async function listRisks(f: RiskFilter = {}): Promise<RiskTemplate[]> {
  const q = (f.q ?? '').trim();
  const domain = (f.domain ?? '').trim();
  const frame = (f.frame ?? '').trim();
  const framework = (f.framework ?? '').trim();
  return query(async (sql) => {
    return sql<RiskTemplate[]>`
      SELECT DISTINCT r.id, r.domain, r.area, r.phase, r.theme, r.measure, r.frame, r.summary,
             r.default_action, r.industry_presets, r.retired_at
        FROM catalog.risk_scenario_templates r
        LEFT JOIN catalog.risk_template_frameworks rtf ON rtf.template_id = r.id
       WHERE r.retired_at IS NULL
         AND (${q} = '' OR r.summary ILIKE ${'%' + q + '%'} OR r.theme ILIKE ${'%' + q + '%'}
              OR r.measure ILIKE ${'%' + q + '%'} OR r.domain ILIKE ${'%' + q + '%'})
         AND (${domain} = '' OR r.domain = ${domain})
         AND (${frame} = '' OR r.frame = ${frame})
         AND (${framework} = '' OR rtf.framework_key = ${framework})
       ORDER BY r.phase, r.area, r.theme, r.measure`;
  });
}

/** 絞り込みの選択肢に使う領域の一覧。Phase は独立した列として扱う。 */
export async function listRiskDomains(framework = ''): Promise<string[]> {
  return query(async (sql) => {
    const rows = await sql<{ domain: string }[]>`
      SELECT DISTINCT r.area AS domain FROM catalog.risk_scenario_templates r
      LEFT JOIN catalog.risk_template_frameworks rtf ON rtf.template_id = r.id
       WHERE r.retired_at IS NULL AND (${framework} = '' OR rtf.framework_key = ${framework})
       ORDER BY r.area`;
    return rows.map((r) => r.domain);
  });
}

export async function getRisk(id: string): Promise<RiskTemplate | null> {
  return query(async (sql) => {
    const rows = await sql<RiskTemplate[]>`
      SELECT id, domain, area, phase, theme, measure, frame, summary, default_action, industry_presets, retired_at
        FROM catalog.risk_scenario_templates WHERE id = ${id}::uuid`;
    return rows[0] ?? null;
  });
}

export async function getRiskControlCount(id: string): Promise<number> {
  return query(async (sql) => {
    const rows = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n FROM catalog.risk_template_controls WHERE template_id = ${id}::uuid`;
    return rows[0].n;
  });
}

export async function listPolicies(): Promise<Policy[]> {
  return query(async (sql) => {
    return sql<Policy[]>`
      SELECT key, title_ja, body_md, clause_refs, sort_order
        FROM catalog.policies_default ORDER BY sort_order`;
  });
}

export async function getPolicy(key: string): Promise<Policy | null> {
  return query(async (sql) => {
    const rows = await sql<Policy[]>`
      SELECT key, title_ja, body_md, clause_refs, sort_order
        FROM catalog.policies_default WHERE key = ${key}`;
    return rows[0] ?? null;
  });
}

export async function listRoles(): Promise<Role[]> {
  return query(async (sql) => {
    return sql<Role[]>`
      SELECT key, name_ja, description, sort_order FROM catalog.roles_default ORDER BY sort_order`;
  });
}

export async function listAssetClasses(): Promise<AssetClass[]> {
  return query(async (sql) => {
    return sql<AssetClass[]>`
      SELECT key, name_ja, rank, external_share_policy
        FROM catalog.asset_classes_default ORDER BY rank DESC`;
  });
}

export async function listCalendar(): Promise<CalendarEvent[]> {
  return query(async (sql) => {
    return sql<CalendarEvent[]>`
      SELECT key, name_ja, cadence, offset_months, owner_role, clause_ref, extendable
        FROM catalog.calendar_events_default
       ORDER BY CASE cadence
                  WHEN 'daily' THEN 1 WHEN 'weekly' THEN 2 WHEN 'monthly' THEN 3
                  WHEN 'quarterly' THEN 4 WHEN 'semiannual' THEN 5 WHEN 'annual' THEN 6
                  ELSE 7 END, coalesce(offset_months, 99), key`;
  });
}

export async function getRiskCriteria(): Promise<RiskCriteria | null> {
  return query(async (sql) => {
    const rows = await sql<RiskCriteria[]>`
      SELECT r.impact_sec_formula, r.band_top_priority, r.band_action, r.band_consider,
             r.band_accept, r.due_days_top_priority, r.due_days_action
        FROM catalog.risk_criteria_default r
        JOIN catalog.dom_versions d ON d.id = r.dom_version_id AND d.is_current`;
    return rows[0] ?? null;
  });
}

export type CheckRow = {
  key: string;
  title_ja: string;
  severity: string;
  cadence: string;
  connectors: string[];
  coverage_required: string;
  due_days: number;
  assign_to: string;
};

export async function listChecks(): Promise<CheckRow[]> {
  return query(async (sql) => {
    return sql<CheckRow[]>`
      SELECT key, title_ja, severity, cadence, connectors, coverage_required, due_days, assign_to
        FROM catalog.checks ORDER BY key`;
  });
}

/**
 * 運用（テナント業務）データの読み取り可否。
 *
 * 画面は app_ro で繋いでおり、app.* には RLS のテナント文脈が要る。
 * 文脈が無い状態で読むと「0 件」ではなく `tenant context is not set` で失敗する。
 * つまり「運用データ 0 件」と書くのは嘘になる。読めないなら読めないと出す。
 */
/** チェックの最新の実行結果（テナント文脈が要る）。 */
export type CheckRunRow = {
  check_key: string;
  title_ja: string;
  severity: string;
  cadence: string;
  result: 'pass' | 'fail' | 'inconclusive' | 'error';
  row_count: number | null;
  coverage_ratio: string | null;
  negative_verified: boolean;
  verified_digest: string | null;
  /** その確認が、いまのチェックの中身に対しても有効か。null = 確認していない */
  digest_current: boolean | null;
  error_detail: string | null;
  started_at: string;
};

/** チェックごとに最新の 1 件だけを返す。履歴は別の画面の話。 */
export const LATEST_CHECK_RUNS_SQL = `
  SELECT c.key AS check_key, c.title_ja, c.severity, c.cadence,
         r.result, r.row_count, r.coverage_ratio, r.negative_verified,
         r.verified_digest, r.error_detail, r.started_at,
         -- 記録は書き換えない（監査記録を後から直せる仕組みは証拠にならない）。
         -- 代わりに「その確認がいまの定義にも当てはまるか」をここで出す。
         CASE WHEN r.negative_verified
              THEN r.verified_digest = catalog.check_digest(c.key) END AS digest_current
    FROM catalog.checks c
    LEFT JOIN LATERAL (
           SELECT * FROM app.check_runs cr
            WHERE cr.check_key = c.key
            ORDER BY cr.started_at DESC LIMIT 1) r ON true
   ORDER BY CASE c.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2
                            WHEN 'medium' THEN 3 ELSE 4 END, c.key`;

export type TenantSummary = {
  tenant_name: string;
  tenant_domain: string;
  dom_version: string;
  policies: number;
  members: number;
};

export type ControlImplementationStatus = 'not_started' | 'designing' | 'operating' | 'verified';

export type TenantRegisterSummary = {
  assets: number;
  measures: number;
  risks: number;
  risk_snapshots: number;
  control_implementations: number;
  control_evidence_links: number;
  control_status: Record<ControlImplementationStatus, number>;
};

export type TenantDataStatus =
  | { readable: true; tenants: number }
  | { readable: false; reason: string };

export async function getTenantDataStatus(): Promise<TenantDataStatus> {
  try {
    const n = await query(async (sql) => {
      const rows = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM app.tenants`;
      return rows[0].n;
    });
    return { readable: true, tenants: n };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // 画面には丸めた理由しか出さない。丸める前をここでログへ残す。
    // 残さないと、画面の「詳細はサーバのログを参照」が指す先が存在しないことになる。
    console.error('[operations] 運用データを読めませんでした:', e);
    return { readable: false, reason: safeReason(msg) };
  }
}

/** テナントの概要とチェックの最新結果。テナント文脈が要るので withTenant 経由で読む。 */
export async function getTenantOperations(frameworkKey = ''): Promise<
  TenantReadResult<{
    summary: TenantSummary | null;
    register: TenantRegisterSummary;
    runs: CheckRunRow[];
  }>
> {
  return withTenant(async (sql) => {
    const summary = await sql<TenantSummary[]>`
      SELECT t.name AS tenant_name, t.domain AS tenant_domain, d.version AS dom_version,
             (SELECT count(*)::int FROM app.policies)                             AS policies,
             (SELECT count(*)::int FROM app.memberships WHERE revoked_at IS NULL) AS members
        FROM app.tenants t
        JOIN catalog.dom_versions d ON d.id = t.dom_version_id
       LIMIT 1`;
    const registerRows = await sql<{
      assets: number;
      measures: number;
      risks: number;
      risk_snapshots: number;
      control_implementations: number;
      control_evidence_links: number;
      control_not_started: number;
      control_designing: number;
      control_operating: number;
      control_verified: number;
    }[]>`
      SELECT
        (SELECT count(*)::int FROM app.assets a WHERE a.status = 'active'
          AND (${frameworkKey} = '' OR EXISTS (SELECT 1 FROM app.asset_frameworks af
            WHERE af.tenant_id = a.tenant_id AND af.asset_id = a.id AND af.framework_key = ${frameworkKey}))) AS assets,
        (SELECT count(*)::int FROM app.measures m WHERE m.status <> 'retired'
          AND (${frameworkKey} = '' OR EXISTS (SELECT 1 FROM app.measure_frameworks mf
            WHERE mf.tenant_id = m.tenant_id AND mf.measure_id = m.id AND mf.framework_key = ${frameworkKey}))) AS measures,
        (SELECT count(*)::int FROM app.risk_scenarios r WHERE r.status = 'active'
          AND (${frameworkKey} = '' OR EXISTS (SELECT 1 FROM app.risk_scenario_frameworks rf
            WHERE rf.tenant_id = r.tenant_id AND rf.risk_scenario_id = r.id AND rf.framework_key = ${frameworkKey}))) AS risks,
        (SELECT count(*)::int FROM app.risk_evaluation_snapshots s
          WHERE ${frameworkKey} = '' OR EXISTS (SELECT 1 FROM app.risk_scenario_frameworks rf
            WHERE rf.tenant_id = s.tenant_id AND rf.risk_scenario_id = s.risk_scenario_id AND rf.framework_key = ${frameworkKey})) AS risk_snapshots,
        (SELECT count(*)::int FROM app.control_implementations ci
          WHERE ci.valid_to IS NULL AND ci.recorded_until IS NULL
          AND (${frameworkKey} = '' OR EXISTS (SELECT 1 FROM catalog.control_frameworks cf
            WHERE cf.control_id = ci.control_id AND cf.framework_key = ${frameworkKey}))) AS control_implementations,
        (SELECT count(*)::int FROM app.control_evidence_links ce
          WHERE ${frameworkKey} = '' OR EXISTS (SELECT 1 FROM catalog.control_frameworks cf
            WHERE cf.control_id = ce.control_id AND cf.framework_key = ${frameworkKey})) AS control_evidence_links,
        (SELECT count(*)::int FROM app.control_implementations ci
          WHERE ci.valid_to IS NULL AND ci.recorded_until IS NULL AND ci.status = 'not_started'
          AND (${frameworkKey} = '' OR EXISTS (SELECT 1 FROM catalog.control_frameworks cf
            WHERE cf.control_id = ci.control_id AND cf.framework_key = ${frameworkKey}))) AS control_not_started,
        (SELECT count(*)::int FROM app.control_implementations ci
          WHERE ci.valid_to IS NULL AND ci.recorded_until IS NULL AND ci.status = 'designing'
          AND (${frameworkKey} = '' OR EXISTS (SELECT 1 FROM catalog.control_frameworks cf
            WHERE cf.control_id = ci.control_id AND cf.framework_key = ${frameworkKey}))) AS control_designing,
        (SELECT count(*)::int FROM app.control_implementations ci
          WHERE ci.valid_to IS NULL AND ci.recorded_until IS NULL AND ci.status = 'operating'
          AND (${frameworkKey} = '' OR EXISTS (SELECT 1 FROM catalog.control_frameworks cf
            WHERE cf.control_id = ci.control_id AND cf.framework_key = ${frameworkKey}))) AS control_operating,
        (SELECT count(*)::int FROM app.control_implementations ci
          WHERE ci.valid_to IS NULL AND ci.recorded_until IS NULL AND ci.status = 'verified'
          AND (${frameworkKey} = '' OR EXISTS (SELECT 1 FROM catalog.control_frameworks cf
            WHERE cf.control_id = ci.control_id AND cf.framework_key = ${frameworkKey}))) AS control_verified`;
    const register = registerRows[0];
    const runs = frameworkKey
      ? await sql<CheckRunRow[]>`
          SELECT c.key AS check_key, c.title_ja, c.severity, c.cadence,
                 r.result, r.row_count, r.coverage_ratio, r.negative_verified,
                 r.verified_digest, r.error_detail, r.started_at,
                 CASE WHEN r.negative_verified
                      THEN r.verified_digest = catalog.check_digest(c.key) END AS digest_current
            FROM catalog.checks c
            LEFT JOIN LATERAL (
                   SELECT * FROM app.check_runs cr
                    WHERE cr.check_key = c.key
                    ORDER BY cr.started_at DESC LIMIT 1) r ON true
           WHERE EXISTS (
                 SELECT 1
                   FROM catalog.check_controls cc
                   JOIN catalog.control_frameworks cf ON cf.control_id = cc.control_id
                  WHERE cc.check_key = c.key AND cf.framework_key = ${frameworkKey})
           ORDER BY CASE c.severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2
                                    WHEN 'medium' THEN 3 ELSE 4 END, c.key`
      : (await sql.unsafe(LATEST_CHECK_RUNS_SQL)) as unknown as CheckRunRow[];
    return {
      summary: summary[0] ?? null,
      register: {
        assets: register.assets,
        measures: register.measures,
        risks: register.risks,
        risk_snapshots: register.risk_snapshots,
        control_implementations: register.control_implementations,
        control_evidence_links: register.control_evidence_links,
        control_status: {
          not_started: register.control_not_started,
          designing: register.control_designing,
          operating: register.control_operating,
          verified: register.control_verified,
        },
      },
      runs,
    };
  });
}

// ---------------------------------------------------------------------------
// 段階（ISMS の進め方）の判定に使う実測
//
// 行数だけでは「できている」と言えないものがある。
//   - 規程は 12 本あっても本文が仮置きなら、整備済みではない
//   - 統制は 304 件あっても附属書 A のものでなければ、適用宣言書の相手にならない
//   - チェックは定義が 4 本あっても、実行して落ちることを確かめた記録が無ければ証拠にならない
// なので、件数のほかに「中身」を読む問い合わせをここに置く。
// ---------------------------------------------------------------------------

export type AnnexAShape = { total: number; wellFormed: number };

/**
 * ISO/IEC 27001:2022 附属書 A の統制。
 *
 * 件数だけを見ると、附属書 A ではない統制を ISO27001:2022 に紐付けても通ってしまう。
 * コードが A.x.y の形をしている件数を併せて数え、食い違いを画面と判定へ渡す。
 * 判定は isoSteps 側（resolveTool の annexA）で行う。ここは実測を返すだけ。
 */
export async function getAnnexAShape(): Promise<AnnexAShape> {
  return query(async (sql) => {
    const rows = await sql<{ code: string }[]>`
      SELECT code FROM catalog.controls
       WHERE framework_key = 'ISO27001:2022' AND retired_at IS NULL`;
    return {
      total: rows.length,
      wellFormed: rows.filter((r) => ANNEX_A_CODE.test(r.code)).length,
    };
  });
}

/**
 * 逆向きの確認が済んだチェック結果の件数。
 *
 * 「実行した」だけでは証拠にしない。壊して落ちることを確かめた（negative_verified）うえで、
 * その確認が**いまのチェックの中身にも当てはまる**（指紋が一致する）ものだけを数える。
 * テナント文脈が無くて読めないときは 0 ではなく null を返す。
 * 読めていないのに 0 件と書くのは嘘になる。
 */
export async function getVerifiedCheckRunCount(): Promise<number | null> {
  const r = await withTenant(async (sql) => {
    const rows = await sql<{ n: number }[]>`
      SELECT count(*)::int AS n
        FROM catalog.checks c
        JOIN LATERAL (
               SELECT * FROM app.check_runs cr
                WHERE cr.check_key = c.key
                ORDER BY cr.started_at DESC LIMIT 1) r ON true
       WHERE r.result IS NOT NULL
         AND r.negative_verified
         AND r.verified_digest = catalog.check_digest(c.key)`;
    return rows[0].n;
  });
  return r.ok ? r.data : null;
}

/**
 * 自社の台帳（app スキーマ）の実測。テナント文脈が要るので withTenant 経由で読む。
 *
 * 数えるのは**台帳に登録されている行**。承認や管理責任者の割り当ては数の条件にしない
 * （2026-09-07 のユーザー判断。入っているデータはそのまま有効として扱う）。
 * 読めなかったときは null を返す（0 件と混ぜない）。
 *
 * **frameworkKey で必ず絞る。** 台帳は 1 本で、枠組みはその上のレンズ
 * （navigation.ts の ISMS_SHARED_LEDGER_DESCRIPTION）。絞らずに数えると、
 * ISO の画面に上場準備だけの資産・施策まで混ざり、他の画面と数が食い違う。
 */
// 「今日まで」は JST の今日で比べる（(now() AT TIME ZONE 'Asia/Tokyo')::date）。current_date は DB のタイムゾーンで決まり、
// UTC の DB だと JST の 0:00〜8:59 に今日の日付で入れた記録が数に入らない。登録側（サーバーアクションの todayJst）とそろえる。
export async function getRegisterFacts(
  frameworkKey: string,
): Promise<Record<RegisterKey, number> | null> {
  const r = await withTenant(async (sql) => {
    const rows = await sql<Record<RegisterKey, number>[]>`
      SELECT
        (SELECT count(*)::int FROM app.assets a
          WHERE a.status = 'active'
            AND EXISTS (SELECT 1 FROM app.asset_frameworks af
                         WHERE af.tenant_id = a.tenant_id AND af.asset_id = a.id
                           AND af.framework_key = ${frameworkKey}))    AS assets,
        (SELECT count(*)::int FROM app.risk_scenarios r
          WHERE r.status = 'active'
            AND EXISTS (SELECT 1 FROM app.risk_scenario_frameworks rf
                         WHERE rf.tenant_id = r.tenant_id AND rf.risk_scenario_id = r.id
                           AND rf.framework_key = ${frameworkKey}))    AS risks,
        (SELECT count(*)::int FROM app.measures m
          WHERE m.status <> 'retired'
            AND EXISTS (SELECT 1 FROM app.measure_frameworks mf
                         WHERE mf.tenant_id = m.tenant_id AND mf.measure_id = m.id
                           AND mf.framework_key = ${frameworkKey}))    AS measures,
        (SELECT count(*)::int FROM app.competency_requirements)        AS competencies,
        -- 教育は eLearning 側のタグで ISMS 対象を選ぶ（枠組みの中間表を持たない）。
        (SELECT count(*)::int FROM app.trainings t
          WHERE t.tags && ARRAY['isms','risk-management']::text[])     AS trainings,
        -- 適用範囲は 1 テナントに 1 つ。**空文字は 0 件**（列が在ることと書いてあることは別）。
        (SELECT count(*)::int FROM app.tenants
          WHERE btrim(iso_scope_statement) <> '')                      AS "scopeStatement",
        -- 対象が自テナントの適用範囲であるものだけ。app.approvals は
        -- approver_user_id と approved_at が NOT NULL なので、行の存在＝承認済み。
        -- 承認済みであることを SQL でも直接見る。NOT NULL 制約に依存しない
        -- （制約は将来ゆるむことがあるが、この数の意味は変わってはいけない）。
        (SELECT count(*)::int FROM app.approvals
          WHERE target_type = 'iso_scope'
            AND target_id = app.current_tenant()
            AND approver_user_id IS NOT NULL
            AND approved_at IS NOT NULL)                               AS "scopeApprovals",
        -- 承認された版だけを数える。版が在ることと承認されたことは別。
        (SELECT count(*)::int FROM app.policy_versions
          WHERE approved_at IS NOT NULL AND superseded_at IS NULL)     AS "approvedPolicyVersions",
        (SELECT count(*)::int FROM app.memberships
          WHERE revoked_at IS NULL)                                    AS "roleAssignments",
        (SELECT count(*)::int FROM app.policies)                       AS "tenantPolicies",
        -- 適用宣言書は「適用可否」と「理由」の両方が入っている現行の行だけ。
        -- 片方しか無い行を数えると、理由の無い除外が宣言書に載る。
        (SELECT count(*)::int FROM app.control_implementations ci
          WHERE ci.valid_to IS NULL AND ci.recorded_until IS NULL
            AND btrim(coalesce(ci.applicability,'')) <> ''
            AND btrim(coalesce(ci.rationale,'')) <> ''
            AND EXISTS (SELECT 1 FROM catalog.control_frameworks cf
                         WHERE cf.control_id = ci.control_id
                           AND cf.framework_key = ${frameworkKey}))    AS "soaControls",
        -- **計画を実施として数えない。** performed_on が入っている行だけ。
        -- 予定を立てただけで「監査を実施した記録がある」ことにしない。
        -- **未来日を実施済みにしない。** 日付が入っていることと、
        -- その日が来ていることは別。先行入力で実施済みにならないようにする。
        (SELECT count(*)::int FROM app.audits
          WHERE performed_on IS NOT NULL
            AND performed_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date)                          AS audits,
        (SELECT count(*)::int FROM app.findings)                       AS "auditFindings",
        (SELECT count(*)::int FROM app.corrective_actions)             AS "correctiveActions",
        -- **年度の枠を開催として数えない。** held_on が入っている行だけ。
        (SELECT count(*)::int FROM app.management_reviews
          WHERE held_on IS NOT NULL
            AND held_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date)                               AS "managementReviews",
        -- 目的は「測り方が入っているもの」だけ。測れない目的は 6.2 の目的ではない
        -- （DB 側の CHECK でも空を拒否しているが、数の意味をここでも明示する）。
        (SELECT count(*)::int FROM app.security_objectives
          WHERE status <> 'cancelled'
            AND btrim(measure_how) <> '')                              AS "securityObjectives",
        -- 統制の有効性評価（0063）。**先の日付を実施済みにしない。** 評価日が今日までのものだけ。
        -- 判定基準が空の評価は DB が拒否する（CHECK）。ISO の画面なので ISO 対象の施策に絞る。
        (SELECT count(*)::int FROM app.control_effectiveness ce
          WHERE ce.evaluated_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date
            AND EXISTS (SELECT 1 FROM app.measure_frameworks mf
                         WHERE mf.tenant_id = ce.tenant_id AND mf.measure_id = ce.measure_id
                           AND mf.framework_key = ${frameworkKey}))    AS "controlEffectiveness",
        -- 組織の課題（4.1）・利害関係者（4.2）（0065）。有効なもの（status=active）だけ。
        -- ISMS 固有の記録なので枠組みの中間表は持たない（教育と同じく、表そのものが ISMS のもの）。
        (SELECT count(*)::int FROM app.context_issues
          WHERE status = 'active')                                     AS "contextIssues",
        (SELECT count(*)::int FROM app.interested_parties
          WHERE status = 'active')                                     AS "interestedParties",
        -- 法令・規制・契約上の要求事項（A.5.31。0066）。有効なものだけ。適合の評価の有無は数の条件にしない
        -- （登録されている行を数える。2026-09-07 のユーザー判断と同じ）。
        (SELECT count(*)::int FROM app.legal_requirements
          WHERE status = 'active')                                     AS "legalRequirements",
        -- 事業継続の計画（0068）は有効なもの、試験は **実施日が今日までのもの** だけ（予定を実施として数えない）。
        (SELECT count(*)::int FROM app.continuity_plans
          WHERE status = 'active')                                     AS "continuityPlans",
        (SELECT count(*)::int FROM app.continuity_tests
          WHERE tested_on <= (now() AT TIME ZONE 'Asia/Tokyo')::date)                             AS "continuityTests",
        -- 脆弱性（0069）は登録されている行。ただし誤検知は脆弱性ではないので数えない。
        (SELECT count(*)::int FROM app.vulnerabilities
          WHERE status <> 'false_positive')                            AS vulnerabilities,
        -- 変更の申請（0070）は登録されている行。ただし取りやめたものは変更の管理の実績ではないので数えない。
        (SELECT count(*)::int FROM app.change_requests
          WHERE status <> 'cancelled')                                 AS "changeRequests"`;
    return rows[0];
  });
  return r.ok ? r.data : null;
}

/**
 * 段階の判定に要る実測と、段階の画面が並べる一覧を、まとめて 1 回だけ読む。
 *
 * 規程・年間行事・ロールは、判定（キーと本文の実質）にも一覧の表示にも要る。
 * 判定用と表示用で別々に読むと、同じ表を二度引くうえに、
 * 二つの読みの間に DB が変わると、同じ画面の中で判定と一覧が食い違う。
 * ここで 1 度引いた行を両方に使う（件数の集計 getCounts は別の問い合わせ）。
 */
export type StepBundle = {
  facts: StepFacts;
  policies: Policy[];
  calendar: CalendarEvent[];
  roles: Role[];
};

export async function getStepBundle(): Promise<StepBundle> {
  const [counts, policies, calendar, roles, annexA, verifiedCheckRuns, registers] =
    await Promise.all([
      getCounts(),
      listPolicies(),
      listCalendar(),
      listRoles(),
      getAnnexAShape(),
      getVerifiedCheckRunCount(),
      // 段階の画面（/ と /steps/*）は resolveAppMode で必ず ISMS モードになる。
      // 台帳の件数もその枠組みで数える（他の ISMS 画面と数を一致させる）。
      getRegisterFacts(ISMS_FRAMEWORK_KEY),
    ]);
  const facts: StepFacts = {
    counts,
    policyBodies: Object.fromEntries(policies.map((p) => [p.key, !isPlaceholderBody(p.body_md)])),
    calendarKeys: calendar.map((e) => e.key),
    roleKeys: roles.map((r) => r.key),
    annexA,
    verifiedCheckRuns,
    registers,
  };
  return { facts, policies, calendar, roles };
}
