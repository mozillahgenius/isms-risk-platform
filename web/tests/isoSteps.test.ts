import { describe, expect, it } from 'vitest';
import {
  ALL_ROLE_KEYS,
  ANNEX_A_CODE,
  ISO_STEPS,
  PHASE_ORDER,
  assessStep,
  assignedCalendarKeys,
  assignedPolicyKeys,
  diffAssignment,
  getStep,
  resolveTool,
  statusLabel,
  statusNote,
  stepNeighbors,
  STATUS_BUCKETS,
  type RegisterKey,
  type StepFacts,
  type StepTool,
} from '../src/lib/isoSteps';

// The measured baseline. The point is to break parts of it and confirm the test fails.
const FULL: StepFacts = {
  counts: {
    controls: 8,
    risk_scenario_templates: 9,
    policies: 12,
    roles: 5,
    asset_classes: 4,
    calendar_events: 14,
    frameworks: 3,
    risk_criteria: 1,
    framework_mappings: 0,
    risk_template_controls: 0,
    checks: 4,
    check_controls: 1,
    connector_manifests: 0,
  },
  policyBodies: Object.fromEntries(
    [
      'p01_basic',
      'p02_scope',
      'p03_org',
      'p04_ra',
      'p05_rt_soa',
      'p06_asset',
      'p07_access',
      'p08_people',
      'p09_physical',
      'p10_technical',
      'p11_vendor',
      'p12_incident',
      'p13_docs',
      'p14_awareness',
      'p15_monitor',
      'p16_audit',
      'p17_review',
      'p18_nc',
      'p19_change',
      'p20_crypto',
      'p21_log',
      'p22_vuln',
      'p23_dev',
      'p24_cloud',
      'p25_remote',
      'p26_privacy',
      'p27_legal',
      'p28_ai',
    ].map((k) => [k, true]),
  ),
  calendarKeys: [
    'daily_checks',
    'weekly_findings',
    'monthly_accounts',
    'monthly_endpoints',
    'quarterly_sharing',
    'quarterly_deviation',
    'quarterly_restore',
    'semiannual_vendors',
    'annual_risk',
    'annual_audit',
    'annual_review',
    'annual_training',
    'event_onboarding',
    'event_offboarding',
  ],
  roleKeys: ['ciso', 'secretariat', 'risk_owner', 'auditor', 'employee'],
  annexA: { total: 93, wellFormed: 93 },
  verifiedCheckRuns: 4,
  registers: { assets: 17, risks: 18, measures: 19, competencies: 4, trainings: 3, scopeStatement: 1, scopeApprovals: 1, approvedPolicyVersions: 28, roleAssignments: 5, tenantPolicies: 28, soaControls: 93, audits: 1, auditFindings: 8, correctiveActions: 8, managementReviews: 1, securityObjectives: 4, controlEffectiveness: 2, contextIssues: 3, interestedParties: 5, legalRequirements: 6, continuityPlans: 2, continuityTests: 3, vulnerabilities: 4, changeRequests: 5 },
};

// Current real data: Annex A has 0 items, all policies are placeholders, and there is almost no records functionality.
const clone = (f: StepFacts): StepFacts => ({
  counts: { ...f.counts },
  policyBodies: { ...f.policyBodies },
  calendarKeys: [...f.calendarKeys],
  roleKeys: [...f.roleKeys],
  annexA: { ...f.annexA },
  verifiedCheckRuns: f.verifiedCheckRuns,
  registers: f.registers === null ? null : { ...f.registers },
});

const NOW_FACTS: StepFacts = {
  ...clone(FULL),
  policyBodies: Object.fromEntries(Object.keys(FULL.policyBodies).map((k) => [k, false])),
  annexA: { total: 0, wellFormed: 0 },
  verifiedCheckRuns: null,
  registers: null,
};

describe('段階の並び', () => {
  it('キーが重複しない', () => {
    const keys = ISO_STEPS.map((s) => s.key);
    expect(new Set(keys).size).toBe(keys.length);
  });

  // Building expectations from ISO_STEPS would pass even if a stage were removed. Pin the order here.
  const EXPECTED_KEYS = [
    'scope',
    'policy',
    'assets',
    'risk-assessment',
    'soa',
    'documents',
    'training',
    'operate',
    'monitor',
    'audit',
    'management-review',
    'improve',
  ];

  it('12 段階が、この並びで在る', () => {
    expect(ISO_STEPS.map((s) => s.key)).toEqual(EXPECTED_KEYS);
  });

  it('番号が 1 から 12 まで連番で欠番が無い', () => {
    expect(ISO_STEPS.map((s) => s.ordinal)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  });

  it('PDCA の区分が段階ごとに固定されている', () => {
    expect(ISO_STEPS.map((s) => s.phase)).toEqual([
      'plan', 'plan', 'plan', 'plan', 'plan',
      'do', 'do', 'do',
      'check', 'check', 'check',
      'act',
    ]);
  });

  it('PDCA の並びが逆行しない', () => {
    const seen = ISO_STEPS.map((s) => PHASE_ORDER.indexOf(s.phase));
    expect(seen.every((v, i) => i === 0 || v >= seen[i - 1])).toBe(true);
    expect(seen.every((v) => v >= 0)).toBe(true);
  });

  it('前後の参照が実在し、端では null、循環しない', () => {
    for (const s of ISO_STEPS) {
      const { prev, next } = stepNeighbors(s.key);
      if (s.ordinal === 1) expect(prev).toBeNull();
      else expect(prev?.ordinal).toBe(s.ordinal - 1);
      if (s.ordinal === ISO_STEPS.length) expect(next).toBeNull();
      else expect(next?.ordinal).toBe(s.ordinal + 1);
    }
    // Can be traversed from end to end (if not, there is a cycle or a break)
    let cur = getStep(ISO_STEPS[0].key);
    let hops = 0;
    while (cur && stepNeighbors(cur.key).next) {
      cur = stepNeighbors(cur.key).next;
      hops += 1;
      if (hops > ISO_STEPS.length) break;
    }
    expect(hops).toBe(ISO_STEPS.length - 1);
  });

  it('未知のキーでは段階も前後も取れない', () => {
    expect(getStep('nope')).toBeNull();
    expect(stepNeighbors('nope')).toEqual({ prev: null, next: null });
  });
});

describe('段階が持つ道具の不変条件', () => {
  // If required is empty, every() is true and it turns into usable. Types cannot prevent this, so stop it here.
  it('どの段階も required な下敷きと記録を 1 つ以上持つ', () => {
    for (const s of ISO_STEPS) {
      const req = s.tools.filter((t) => t.required);
      expect(
        req.filter((t) => t.role === 'reference').length,
        `${s.key} に required な reference が無い`,
      ).toBeGreaterThan(0);
      expect(
        req.filter((t) => t.role === 'record').length,
        `${s.key} に required な record が無い`,
      ).toBeGreaterThan(0);
    }
  });

  it('道具のキーが段階の中で重複しない', () => {
    for (const s of ISO_STEPS) {
      const keys = s.tools.map((t) => t.key);
      expect(new Set(keys).size, s.key).toBe(keys.length);
    }
  });

  // Only things that can serve as evidence of implementation may be counted as records.
  // Write this as an **allowlist**, not a denylist. A denylist leaves holes when sources are added.
  it('記録の取得元は unbuilt・verifiedCheckRuns・register だけ', () => {
    for (const s of ISO_STEPS) {
      for (const t of s.tools) {
        if (t.role !== 'record') continue;
        expect(
          ['unbuilt', 'verifiedCheckRuns', 'register'].includes(t.source.kind),
          `${s.key}/${t.key} は ${t.source.kind} を記録として数えている`,
        ).toBe(true);
      }
    }
  });

  // The allowlist only says "register may be used".
  // Which register is wired to which screen is pinned separately. Without pinning it,
  // all tests pass even if registerKey is mixed up or href is wrong
  // (you could not notice the asset field showing the risk count).
  it('記録欄と台帳と行き先の対応が固定されている', () => {
    const EXPECTED: Record<string, { registerKey: RegisterKey; path: string }> = {
      'assets/asset-register': { registerKey: 'assets', path: '/risk-management/assets' },
      'risk-assessment/risk-register': { registerKey: 'risks', path: '/risk-management/risks' },
      'operate/control-records': { registerKey: 'measures', path: '/risk-management/measures' },
    };
    const seen: string[] = [];
    for (const s of ISO_STEPS) {
      for (const t of s.tools) {
        if (t.source.kind !== 'register') continue;
        const id = `${s.key}/${t.key}`;
        seen.push(id);
        const want = EXPECTED[id];
        if (!want) continue; // Registers added by another owner are pinned in that owner's tests
        expect(t.source.registerKey, `${id} の台帳`).toBe(want.registerKey);
        expect(t.href, `${id} の行き先`).not.toBeNull();
        const url = new URL(t.href!, 'https://management.invalid');
        expect(url.pathname, `${id} の行き先`).toBe(want.path);
        // The stage screens are an ISMS lens. If the destination drops the lens,
        // the stage-side count (ISO scope) and the register-side list (company-wide) disagree.
        expect(url.searchParams.get('framework'), `${id} の枠組み`).toBe('ISO27001:2022');
        expect(url.searchParams.get('mode'), `${id} のモード`).toBe('isms');
      }
    }
    // The expected 3 items must actually exist. Make it fail even if the definition is deleted entirely.
    for (const id of Object.keys(EXPECTED)) {
      expect(seen, `${id} が段階から消えている`).toContain(id);
    }
  });

  // 0065: Organizational issues (4.1) and interested parties (4.2) only show counts, since the standard does not require documented information.
  // Making them required would turn the currently satisfied scope stage into unsatisfied for existing tenants (decided 2026-09-12).
  it('組織の課題・利害関係者は適用範囲の段階に件数表示だけで載る', () => {
    const scope = ISO_STEPS.find((s) => s.key === 'scope')!;
    const want: Record<string, { registerKey: RegisterKey; hash: string }> = {
      'context-issues': { registerKey: 'contextIssues', hash: '#context' },
      'interested-parties': { registerKey: 'interestedParties', hash: '#parties' },
    };
    for (const [key, w] of Object.entries(want)) {
      const t = scope.tools.find((x) => x.key === key);
      expect(t, `${key} が適用範囲の段階に無い`).toBeDefined();
      expect(t!.source, key).toEqual({ kind: 'register', registerKey: w.registerKey });
      expect(t!.required, `${key} は必須にしない`).toBe(false);
      expect(t!.role, key).toBe('record');
      const url = new URL(t!.href!, 'https://management.invalid');
      expect(url.pathname, key).toBe('/iso27001/records');
      expect(url.hash, key).toBe(w.hash);
      expect(url.searchParams.get('mode'), key).toBe('isms');
    }
  });

  // 0066: A.5.31 is an Annex A control. Applicability is decided by the Statement of Applicability, so it appears in the operation stage as a count only.
  it('法令・契約上の要求事項は運用の段階に件数表示だけで載る', () => {
    const operate = ISO_STEPS.find((s) => s.key === 'operate')!;
    const t = operate.tools.find((x) => x.key === 'legal-requirements');
    expect(t, 'legal-requirements が運用の段階に無い').toBeDefined();
    expect(t!.source).toEqual({ kind: 'register', registerKey: 'legalRequirements' });
    expect(t!.required, '必須にしない').toBe(false);
    expect(t!.role).toBe('record');
    const url = new URL(t!.href!, 'https://management.invalid');
    expect(url.pathname).toBe('/iso27001/records');
    expect(url.hash).toBe('#legal');
    expect(url.searchParams.get('mode')).toBe('isms');
  });

  // 0068: Business continuity has separate fields for plans and tests; both appear in the operation stage as counts only.
  it('事業継続の計画と試験は運用の段階に別の欄として件数表示だけで載る', () => {
    const operate = ISO_STEPS.find((s) => s.key === 'operate')!;
    const want: Record<string, RegisterKey> = {
      'continuity-plans': 'continuityPlans',
      'continuity-tests': 'continuityTests',
    };
    for (const [key, registerKey] of Object.entries(want)) {
      const t = operate.tools.find((x) => x.key === key);
      expect(t, `${key} が運用の段階に無い`).toBeDefined();
      expect(t!.source, key).toEqual({ kind: 'register', registerKey });
      expect(t!.required, `${key} は必須にしない`).toBe(false);
      const url = new URL(t!.href!, 'https://management.invalid');
      expect(url.pathname, key).toBe('/iso27001/records');
      expect(url.hash, key).toBe('#continuity');
    }
  });

  // 0069: A.8.8 is also an Annex A control. It appears in the operation stage as a count only.
  it('技術的脆弱性は運用の段階に件数表示だけで載る', () => {
    const operate = ISO_STEPS.find((s) => s.key === 'operate')!;
    const t = operate.tools.find((x) => x.key === 'vulnerabilities');
    expect(t, 'vulnerabilities が運用の段階に無い').toBeDefined();
    expect(t!.source).toEqual({ kind: 'register', registerKey: 'vulnerabilities' });
    expect(t!.required, '必須にしない').toBe(false);
    const url = new URL(t!.href!, 'https://management.invalid');
    expect(url.pathname).toBe('/iso27001/records');
    expect(url.hash).toBe('#vulnerabilities');
  });

  // 0070: A.8.32 is also an Annex A control. It appears in the operation stage as a count only.
  it('変更の申請と承認は運用の段階に件数表示だけで載る', () => {
    const operate = ISO_STEPS.find((s) => s.key === 'operate')!;
    const t = operate.tools.find((x) => x.key === 'change-requests');
    expect(t, 'change-requests が運用の段階に無い').toBeDefined();
    expect(t!.source).toEqual({ kind: 'register', registerKey: 'changeRequests' });
    expect(t!.required, '必須にしない').toBe(false);
    const url = new URL(t!.href!, 'https://management.invalid');
    expect(url.pathname).toBe('/iso27001/records');
    expect(url.hash).toBe('#changes');
  });

  // Do not count the catalog (baseline shared by all tenants) as records.
  // Records come from the organization's own operational data (app schema).
  it('参照の取得元に register を使わない', () => {
    for (const s of ISO_STEPS) {
      for (const t of s.tools) {
        if (t.role !== 'reference') continue;
        expect(t.source.kind, `${s.key}/${t.key}`).not.toBe('register');
      }
    }
  });

  it('href は既存ルートの形をしている', () => {
    for (const s of ISO_STEPS) {
      for (const t of s.tools) {
        if (t.href === null) continue;
        expect(t.href, `${s.key}/${t.key}`).toMatch(
          // **Before adding here, confirm that web/src/app/<name>/page.tsx exists.**
          // organization and wizard exist only as directories without pages,
          // so pointing to them gives 404 (this check actually caught an attempt to point to them).
          /^\/(catalog|operations|graph|steps|risk-management|competency|training|policies|iso27001|incidents)(\/|\?|$)/,
        );
      }
    }
  });

  it('行き先が無い道具は unbuilt か未投入のものだけ', () => {
    for (const s of ISO_STEPS) {
      for (const t of s.tools) {
        if (t.href !== null) continue;
        expect(
          ['unbuilt', 'count'].includes(t.source.kind),
          `${s.key}/${t.key} は行き先が無いのに参照できることになっている`,
        ).toBe(true);
      }
    }
  });

  // Checking only the shape of clauses is meaningless. Pin the mapping to stages itself.
  // Fails if the order of 10.1/10.2, 6.1.3 (d is the Statement of Applicability), or the placement of A.5.35/A.5.36 is moved by mistake.
  it('段階と箇条の対応が固定されている', () => {
    const EXPECTED: Record<string, string[]> = {
      scope: ['4.1', '4.2', '4.3', '4.4'],
      policy: ['5.1', '5.2', '5.3', '6.2', 'A.5.1', 'A.5.2'],
      assets: ['A.5.9', 'A.5.10', 'A.5.12', 'A.5.13'],
      'risk-assessment': ['6.1.1', '6.1.2', '8.2'],
      soa: ['6.1.3', '8.3'],
      documents: ['7.5', '7.5.3'],
      training: ['7.1', '7.2', '7.3', '7.4', 'A.6.3'],
      operate: ['8.1'],
      monitor: ['9.1', 'A.5.36'],
      audit: ['9.2', 'A.5.35'],
      'management-review': ['9.3'],
      improve: ['10.2', '10.1'],
    };
    for (const s of ISO_STEPS) {
      expect(s.clauses.map((c) => c.ref), s.key).toEqual(EXPECTED[s.key]);
    }
  });

  it('横断要求は cross として印を付けてある', () => {
    const CROSS = new Set(['4.1', '4.2', '4.4', '6.1.1', '7.1', '7.4']);
    for (const s of ISO_STEPS) {
      for (const c of s.clauses) {
        expect(c.scope === 'cross', `${s.key}: ${c.ref}`).toBe(CROSS.has(c.ref));
      }
    }
  });

  it('箇条番号が ISO の形をしている', () => {
    for (const s of ISO_STEPS) {
      expect(s.clauses.length, s.key).toBeGreaterThan(0);
      for (const c of s.clauses) {
        expect(c.ref, `${s.key}: ${c.ref}`).toMatch(/^(A\.\d+\.\d+|\d+(\.\d+){0,2})$/);
        expect(c.title.length, `${s.key}: ${c.ref}`).toBeGreaterThan(0);
      }
    }
  });
});

describe('seed の行が段階から浮かない', () => {
  it('規程キーが段階間で一意', () => {
    const keys = assignedPolicyKeys();
    expect(new Set(keys).size).toBe(keys.length);
  });

  it('年間行事キーが段階間で一意', () => {
    const keys = assignedCalendarKeys();
    expect(new Set(keys).size).toBe(keys.length);
  });

  it('5 つのロールがすべてどこかの段階に現れる', () => {
    const used = new Set(ISO_STEPS.flatMap((s) => s.roleKeys));
    for (const r of ALL_ROLE_KEYS) expect(used.has(r), r).toBe(true);
  });

  it('差集合を双方向で出す', () => {
    // If the config and the DB match, both are 0
    expect(diffAssignment(['a', 'b'], ['a', 'b'])).toEqual({ inDbOnly: [], inConfigOnly: [] });
    // Added to the DB but forgot the assignment
    expect(diffAssignment(['a'], ['a', 'b']).inDbOnly).toEqual(['b']);
    // Wrote a key that does not exist in the config
    expect(diffAssignment(['a', 'zz'], ['a']).inConfigOnly).toEqual(['zz']);
  });

  it('いまの seed の実測と突き合わせて浮きが出ない', () => {
    const p = diffAssignment(assignedPolicyKeys(), Object.keys(FULL.policyBodies));
    expect(p).toEqual({ inDbOnly: [], inConfigOnly: [] });
    const c = diffAssignment(assignedCalendarKeys(), FULL.calendarKeys);
    expect(c).toEqual({ inDbOnly: [], inConfigOnly: [] });
  });
});

describe('道具の状態', () => {
  const tool = (source: StepTool['source'], role: StepTool['role'] = 'reference'): StepTool => ({
    key: 't',
    label: 't',
    href: null,
    note: '',
    role,
    required: true,
    source,
  });

  it('unbuilt は常に unbuilt', () => {
    expect(resolveTool(tool({ kind: 'unbuilt' }), FULL)).toEqual({ kind: 'unbuilt' });
  });

  it('count は 0 で未投入', () => {
    expect(resolveTool(tool({ kind: 'count', countKey: 'roles' }), FULL)).toEqual({
      kind: 'present',
      count: 5,
    });
    expect(resolveTool(tool({ kind: 'count', countKey: 'framework_mappings' }), FULL)).toEqual({
      kind: 'empty',
    });
  });

  it('count が数として読めないときは「読めない」と出す（未投入とも機能が無いとも言わない）', () => {
    const broken = clone(FULL);
    (broken.counts as Record<string, unknown>).roles = null;
    expect(resolveTool(tool({ kind: 'count', countKey: 'roles' }), broken)).toEqual({
      kind: 'unreadable',
    });
    for (const bad of [Number.NaN, Number.POSITIVE_INFINITY, -1, 1.5]) {
      const f = clone(FULL);
      f.counts.roles = bad;
      expect(resolveTool(tool({ kind: 'count', countKey: 'roles' }), f), String(bad)).toEqual({
        kind: 'unreadable',
      });
    }
  });

  it('規程の本文が仮置きなら present にしない', () => {
    const t = tool({ kind: 'policies', keys: ['p01_basic', 'p03_org'] });
    expect(resolveTool(t, FULL)).toEqual({ kind: 'present', count: 2 });

    const half = clone(FULL);
    half.policyBodies.p03_org = false;
    expect(resolveTool(t, half)).toEqual({ kind: 'placeholder', count: 1, total: 2 });

    const none = clone(FULL);
    none.policyBodies.p01_basic = false;
    none.policyBodies.p03_org = false;
    expect(resolveTool(t, none)).toEqual({ kind: 'placeholder', count: 0, total: 2 });
  });

  it('要る規程が DB から欠けていれば present にしない', () => {
    // The denominator is "number of required policies". If only the number present in the DB were used,
    // losing one would still be "usable" as long as the rest are complete.
    const t = tool({ kind: 'policies', keys: ['p01_basic', 'does_not_exist'] });
    expect(resolveTool(t, FULL)).toEqual({ kind: 'placeholder', count: 1, total: 2 });

    const gone = clone(FULL);
    delete gone.policyBodies.p01_basic;
    expect(resolveTool(t, gone)).toEqual({ kind: 'empty' });

    // If 1 of the 5 required disappears from the DB, it fails even if the remaining 4 have real bodies
    const five = tool({
      kind: 'policies',
      keys: ['p07_access', 'p09_physical', 'p10_technical', 'p11_vendor', 'p12_incident'],
    });
    expect(resolveTool(five, FULL)).toEqual({ kind: 'present', count: 5 });
    const missing = clone(FULL);
    delete missing.policyBodies.p12_incident;
    expect(resolveTool(five, missing)).toEqual({ kind: 'placeholder', count: 4, total: 5 });
  });

  it('年間行事は一部しか無ければ present にしない', () => {
    const t = tool({ kind: 'calendar', keys: ['annual_training', 'event_onboarding'] });
    expect(resolveTool(t, FULL)).toEqual({ kind: 'present', count: 2 });

    const half = clone(FULL);
    half.calendarKeys = half.calendarKeys.filter((k) => k !== 'event_onboarding');
    expect(resolveTool(t, half)).toEqual({ kind: 'placeholder', count: 1, total: 2 });

    const none = clone(FULL);
    none.calendarKeys = [];
    expect(resolveTool(t, none)).toEqual({ kind: 'empty' });
  });

  it('附属書 A はコードの形が違えば present にしない', () => {
    const t = tool({ kind: 'annexA' });
    expect(resolveTool(t, FULL)).toEqual({ kind: 'present', count: 93 });

    // Looking only at counts would pass even when non-Annex-A controls are linked
    const bad = clone(FULL);
    bad.annexA = { total: 94, wellFormed: 93 };
    expect(resolveTool(t, bad)).toEqual({ kind: 'malformed', wellFormed: 93, total: 94 });

    const empty = clone(FULL);
    empty.annexA = { total: 0, wellFormed: 0 };
    expect(resolveTool(t, empty)).toEqual({ kind: 'empty' });
  });

  it('附属書 A のコードの形', () => {
    for (const ok of ['A.5.9', 'A.8.34', 'A.5.12']) expect(ANNEX_A_CODE.test(ok)).toBe(true);
    for (const ng of ['X-1', 'A.5', '5.9', 'A.5.9.1', 'a.5.9', ' A.5.9']) {
      expect(ANNEX_A_CODE.test(ng), ng).toBe(false);
    }
  });

  it('ロールはキーで見る。総数で代用しない', () => {
    const t = tool({ kind: 'roles', keys: ['auditor'] });
    expect(resolveTool(t, FULL)).toEqual({ kind: 'present', count: 1 });

    // Even with all 5, independence is not assured without an auditor
    const noAuditor = clone(FULL);
    noAuditor.roleKeys = ['ciso', 'secretariat', 'risk_owner', 'employee', 'extra'];
    expect(noAuditor.roleKeys.length).toBe(5);
    expect(resolveTool(t, noAuditor)).toEqual({ kind: 'empty' });

    const all = tool({ kind: 'roles', keys: [...ALL_ROLE_KEYS] });
    expect(resolveTool(all, noAuditor)).toEqual({ kind: 'placeholder', count: 4, total: 5 });
  });

  it('規程のキー判定でプロトタイプのプロパティを拾わない', () => {
    // Written as `k in obj`, this would be counted as "a policy present in the DB"
    const t = tool({ kind: 'policies', keys: ['toString', 'constructor'] });
    expect(resolveTool(t, FULL)).toEqual({ kind: 'empty' });
  });

  it('附属書 A の集計が壊れているとき、使える側へ倒さない', () => {
    const t = tool({ kind: 'annexA' });
    const nan = clone(FULL);
    nan.annexA = { total: Number.NaN, wellFormed: 0 };
    expect(resolveTool(t, nan)).toEqual({ kind: 'unreadable' });

    // A matching-shape count exceeding the total means the aggregation is broken
    const over = clone(FULL);
    over.annexA = { total: 2, wellFormed: 5 };
    expect(resolveTool(t, over)).toEqual({ kind: 'malformed', wellFormed: 5, total: 2 });
  });

  it('チェック結果は読めないときに 0 件と言わない', () => {
    const t = tool({ kind: 'verifiedCheckRuns' }, 'record');
    expect(resolveTool(t, FULL)).toEqual({ kind: 'present', count: 4 });

    const unread = clone(FULL);
    unread.verifiedCheckRuns = null;
    expect(resolveTool(t, unread)).toEqual({ kind: 'unreadable' });

    const zero = clone(FULL);
    zero.verifiedCheckRuns = 0;
    expect(resolveTool(t, zero)).toEqual({ kind: 'empty' });

    // Do not let NaN turn into "not loaded" or Infinity into "usable"
    const nan = clone(FULL);
    nan.verifiedCheckRuns = Number.NaN;
    expect(resolveTool(t, nan)).toEqual({ kind: 'unreadable' });
    const inf = clone(FULL);
    inf.verifiedCheckRuns = Number.POSITIVE_INFINITY;
    expect(resolveTool(t, inf)).toEqual({ kind: 'unreadable' });
  });

  // Registers are prone to confusing 0 items, not implemented, and unreadable. Pin all three separately.
  it('台帳は行があれば使えると出す', () => {
    const t = tool({ kind: 'register', registerKey: 'assets' }, 'record');

    // If registered, show as usable regardless of approval or presence of a management representative
    // (user decision on 2026-09-07; do not tip this toward the 0-items side).
    expect(resolveTool(t, FULL)).toEqual({ kind: 'present', count: 17 });

    const one = clone(FULL);
    one.registers!.assets = 1;
    expect(resolveTool(t, one)).toEqual({ kind: 'present', count: 1 });

    // Not loaded only when the register is empty
    const empty = clone(FULL);
    empty.registers!.assets = 0;
    expect(resolveTool(t, empty)).toEqual({ kind: 'empty' });
  });

  it('台帳が読めないときに 0 件と言わない', () => {
    const t = tool({ kind: 'register', registerKey: 'risks' }, 'record');

    // No tenant context / DB is down
    const unread = clone(FULL);
    unread.registers = null;
    expect(resolveTool(t, unread)).toEqual({ kind: 'unreadable' });

    // Do not let values from a broken count turn into either not loaded or usable
    const nan = clone(FULL);
    nan.registers!.risks = Number.NaN;
    expect(resolveTool(t, nan)).toEqual({ kind: 'unreadable' });

    const inf = clone(FULL);
    inf.registers!.risks = Number.POSITIVE_INFINITY;
    expect(resolveTool(t, inf)).toEqual({ kind: 'unreadable' });

    const neg = clone(FULL);
    neg.registers!.risks = -1;
    expect(resolveTool(t, neg)).toEqual({ kind: 'unreadable' });
  });

  // A key mix-up silently becomes a lie (the asset field shows the risk count).
  it('台帳のキーごとに別の実測を読む', () => {
    const f = clone(FULL);
    const at = (k: RegisterKey) =>
      resolveTool(tool({ kind: 'register', registerKey: k }, 'record'), f);
    // **Check every key individually.** Checking only some means that if an added key
    // shows another key's count, you cannot notice.
    for (const [key, want] of Object.entries(f.registers!) as [RegisterKey, number][]) {
      expect(at(key), `${key} の件数`).toEqual(
        want > 0 ? { kind: 'present', count: want } : { kind: 'empty' },
      );
    }
    // Expectations must cover every key (adding a key but forgetting the fixture would slip through).
    // 0063 added control effectiveness evaluation (controlEffectiveness), making 17.
    // 0065 added organizational issues (contextIssues) and interested parties (interestedParties), making 19.
    // 0066 added legal and contractual requirements (legalRequirements), making 20.
    // 0068 added business continuity plans (continuityPlans) and tests (continuityTests), making 22.
    // 0069 added vulnerabilities (vulnerabilities), making 23.
    // 0070 added change requests (changeRequests), making 24.
    expect(Object.keys(f.registers!).length).toBe(24);
  });
});

describe('段階の状態の導出', () => {
  const step = (tools: StepTool[]) => ({ ...ISO_STEPS[0], tools });
  const t = (
    key: string,
    role: StepTool['role'],
    source: StepTool['source'],
    required = true,
  ): StepTool => ({ key, label: key, href: null, note: '', role, required, source });

  it('下敷きも記録もそろえば usable', () => {
    const s = step([
      t('ref', 'reference', { kind: 'count', countKey: 'roles' }),
      t('rec', 'record', { kind: 'verifiedCheckRuns' }),
    ]);
    expect(assessStep(s, FULL).status).toBe('usable');
  });

  it('記録だけそろって下敷きが欠けているとき「下敷きだけある」と言わない', () => {
    const s = step([
      t('ref', 'reference', { kind: 'count', countKey: 'framework_mappings' }),
      t('rec', 'record', { kind: 'verifiedCheckRuns' }),
    ]);
    const a = assessStep(s, FULL);
    expect(a.status).toBe('partial');
    expect(a.referencesReady).toBe(false);
    expect(a.recordsReady).toBe(true);
    expect(statusLabel(a)).toBe('一部だけそろっている');
    expect(statusNote(a)).not.toContain('下敷きはある');
  });

  it('下敷きだけそろっているときは「下敷きだけある」', () => {
    const s = step([
      t('ref', 'reference', { kind: 'count', countKey: 'roles' }),
      t('rec', 'record', { kind: 'unbuilt' }),
    ]);
    const a = assessStep(s, FULL);
    expect(a.status).toBe('partial');
    expect(a.referencesReady).toBe(true);
    expect(a.recordsReady).toBe(false);
    expect(statusLabel(a)).toBe('下敷きだけある');
  });

  it('見出しの言葉は集計の見出しに必ず含まれる', () => {
    for (const s of ISO_STEPS) {
      expect(STATUS_BUCKETS).toContain(statusLabel(assessStep(s, FULL)));
      expect(STATUS_BUCKETS).toContain(statusLabel(assessStep(s, NOW_FACTS)));
    }
  });

  it('記録を 0 件にすると usable から落ちる', () => {
    const s = step([
      t('ref', 'reference', { kind: 'count', countKey: 'roles' }),
      t('rec', 'record', { kind: 'verifiedCheckRuns' }),
    ]);
    const zero = clone(FULL);
    zero.verifiedCheckRuns = 0;
    const a = assessStep(s, zero);
    expect(a.status).toBe('partial');
    expect(a.missingRequired.map((x) => x.key)).toEqual(['rec']);
  });

  it('記録が unbuilt なら usable にならない', () => {
    const s = step([
      t('ref', 'reference', { kind: 'count', countKey: 'roles' }),
      t('rec', 'record', { kind: 'unbuilt' }),
    ]);
    expect(assessStep(s, FULL).status).toBe('partial');
  });

  it('仮置きの規程を present に数えない', () => {
    const s = step([
      t('ref', 'reference', { kind: 'policies', keys: ['p01_basic'] }),
      t('rec', 'record', { kind: 'verifiedCheckRuns' }),
    ]);
    expect(assessStep(s, FULL).status).toBe('usable');
    const ph = clone(FULL);
    ph.policyBodies.p01_basic = false;
    expect(assessStep(s, ph).status).toBe('partial');
  });

  it('形の合わない統制を present に数えない', () => {
    const s = step([
      t('ref', 'reference', { kind: 'annexA' }),
      t('rec', 'record', { kind: 'verifiedCheckRuns' }),
    ]);
    expect(assessStep(s, FULL).status).toBe('usable');
    const bad = clone(FULL);
    bad.annexA = { total: 94, wellFormed: 93 };
    expect(assessStep(s, bad).status).toBe('partial');
  });

  it('required がひとつも present でなければ none', () => {
    const s = step([
      t('ref', 'reference', { kind: 'count', countKey: 'framework_mappings' }),
      t('rec', 'record', { kind: 'unbuilt' }),
    ]);
    expect(assessStep(s, FULL).status).toBe('none');
  });

  it('required でない道具は状態を動かさない', () => {
    const s = step([
      t('ref', 'reference', { kind: 'count', countKey: 'roles' }),
      t('rec', 'record', { kind: 'verifiedCheckRuns' }),
      t('opt', 'reference', { kind: 'count', countKey: 'framework_mappings' }, false),
    ]);
    expect(assessStep(s, FULL).status).toBe('usable');
    expect(assessStep(s, FULL).missingRequired).toEqual([]);
  });

  it('読めない項目があるとき状態を良い方へ倒さず併記する', () => {
    const s = step([
      t('ref', 'reference', { kind: 'count', countKey: 'roles' }),
      t('rec', 'record', { kind: 'verifiedCheckRuns' }),
    ]);
    const unread = clone(FULL);
    unread.verifiedCheckRuns = null;
    const a = assessStep(s, unread);
    expect(a.status).toBe('partial');
    expect(a.hasUnreadable).toBe(true);
    // Do not say unreadable when it is readable
    expect(assessStep(s, FULL).hasUnreadable).toBe(false);
  });
});

describe('いまの実測に対する状態', () => {
  const NOW = NOW_FACTS;

  it('どの段階も usable にならない', () => {
    for (const s of ISO_STEPS) {
      expect(assessStep(s, NOW).status, s.key).not.toBe('usable');
    }
  });

  it('適用宣言書の段階は附属書 A が無いことを理由に落ちる', () => {
    const soa = getStep('soa');
    expect(soa).not.toBeNull();
    const a = assessStep(soa!, NOW);
    expect(a.tools.find((x) => x.tool.key === 'annex-a')?.state).toEqual({ kind: 'empty' });
    expect(a.missingRequired.map((x) => x.key)).toContain('annex-a');
  });

  it('空の DB ではすべての段階が none になる', () => {
    const EMPTY: StepFacts = {
      counts: Object.fromEntries(
        Object.keys(FULL.counts).map((k) => [k, 0]),
      ) as StepFacts['counts'],
      policyBodies: {},
      calendarKeys: [],
      roleKeys: [],
      annexA: { total: 0, wellFormed: 0 },
      verifiedCheckRuns: null,
      registers: { assets: 0, risks: 0, measures: 0, competencies: 0, trainings: 0, scopeStatement: 0, scopeApprovals: 0, approvedPolicyVersions: 0, roleAssignments: 0, tenantPolicies: 0, soaControls: 0, audits: 0, auditFindings: 0, correctiveActions: 0, managementReviews: 0, securityObjectives: 0, controlEffectiveness: 0, contextIssues: 0, interestedParties: 0, legalRequirements: 0, continuityPlans: 0, continuityTests: 0, vulnerabilities: 0, changeRequests: 0 },
    };
    for (const s of ISO_STEPS) {
      expect(assessStep(s, EMPTY).status, s.key).toBe('none');
    }
  });
});
