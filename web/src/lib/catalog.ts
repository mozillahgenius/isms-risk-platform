import 'server-only';
import { query } from './db';
import { safeReason } from './dbError';
import { isPlaceholderBody } from './policyBody';
import { ANNEX_A_CODE, type RegisterKey, type StepFacts } from './isoSteps';
import { ISMS_FRAMEWORK_KEY } from './navigation';
import { withTenant, type TenantReadResult } from './tenant';

// Reads the catalog schema (= the projection of the rules). Never writes anything.
// app.* / audit.* are not touched from here (they need tenant context; see tenantDataStatus()).


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
  // catalog.controls.theme is nullable (a control may have no classification).
  // Typing it as string would crash the screen the moment real data turns out NULL.
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
  // What is trimmed here is **input coming from the URL**, not the stored value.
  // Normalizing stored values is the job of the CHECK in migration 0023 (D-29), so the screen does none of it.
  // Trimming the input only drops leading/trailing whitespace, and stored values are canonical, so the match result is unchanged.
  // Input shaping so that a hand-typed URL still resolves even if it contains whitespace.
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

/** References to a control. Includes references from mappings and risk templates, and returns the counts as is without hiding them. */
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

/** List of domains used for filter options. Phase is treated as an independent column. */
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
 * Whether operational (tenant business) data can be read.
 *
 * The screens connect as app_ro, and app.* needs an RLS tenant context.
 * Reading without a context fails with `tenant context is not set` instead of returning "0 rows".
 * So writing "0 operational records" would be a lie. If it cannot be read, say it cannot be read.
 */
/** Latest run result of each check (needs tenant context). */
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
  /** Whether that verification is still valid for the check's current content. null = not verified */
  digest_current: boolean | null;
  error_detail: string | null;
  started_at: string;
};

/** Returns only the latest one per check. History belongs to a different screen. */
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
    // The screen only shows a sanitized reason. Log the unsanitized one here.
    // Without this, the screen's "see the server log for details" would point to something that does not exist.
    console.error('[operations] 運用データを読めませんでした:', e);
    return { readable: false, reason: safeReason(msg) };
  }
}

/** Tenant overview and latest check results. Needs tenant context, so read via withTenant. */
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
// Measurements used to judge the stages (how ISMS is being advanced)
//
// Some things cannot be called "done" from row counts alone.
//   - Even with 12 policies, if their bodies are placeholders, they are not in place
//   - No matter how many controls there are, if they are not Annex A controls, they cannot be matched against the Statement of Applicability
//   - Even with 4 check definitions, without a record confirming they fail when run against a broken state, they are not evidence
// So queries that read the "content", not just the counts, live here.
// ---------------------------------------------------------------------------

export type AnnexAShape = { total: number; wellFormed: number };

/**
 * ISO/IEC 27001:2022 Annex A controls.
 *
 * Looking only at counts, linking controls that are not Annex A to ISO27001:2022 would still pass.
 * Also count how many have codes of the form A.x.y, and pass any discrepancy to the screen and the judgment.
 * The judgment is done on the isoSteps side (annexA in resolveTool). This only returns measurements.
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
 * Number of check results whose reverse verification is done.
 *
 * "It ran" alone is not treated as evidence. Count only those confirmed to fail when broken (negative_verified)
 * and whose confirmation **also applies to the check's current content** (the fingerprint matches).
 * When it cannot be read for lack of tenant context, return null rather than 0.
 * Writing 0 when it could not be read would be a lie.
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
 * Measurements of the organization's own ledger (app schema). Needs tenant context, so read via withTenant.
 *
 * What is counted is **rows registered in the ledger**. Approval and assignment of a responsible manager are not counting conditions
 * (user decision of 2026-09-07: data that has been entered is treated as valid as is).
 * Return null when it could not be read (do not mix it up with 0).
 *
 * **Always filter by frameworkKey.** There is a single ledger, and frameworks are lenses on top of it
 * (ISMS_SHARED_LEDGER_DESCRIPTION in navigation.ts). Counting without filtering would mix
 * IPO-readiness-only assets and measures into the ISO screens, and the counts would disagree with other screens.
 */
// "Up to today" compares against today in JST ((now() AT TIME ZONE 'Asia/Tokyo')::date). current_date depends on the DB time zone,
// so with a UTC DB, records entered with today's date between 0:00 and 8:59 JST would not be counted. Aligned with the registration side (todayJst in the server actions).
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
 * Read, in a single pass, the measurements needed to judge the stages and the lists the stage screens show.
 *
 * Policies, the annual calendar, and roles are needed both for the judgment (keys and substantive body) and for displaying the lists.
 * Reading them separately for judgment and display queries the same tables twice, and
 * if the DB changes between the two reads, the judgment and the list disagree within the same screen.
 * The rows read once here are used for both (the count aggregation getCounts is a separate query).
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
      // The stage screens (/ and /steps/*) always end up in ISMS mode via resolveAppMode.
      // Ledger counts are also counted within that framework (so the numbers match the other ISMS screens).
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
