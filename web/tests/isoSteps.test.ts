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

// 実測の下敷き。ここを部分的に壊して「落ちること」を確かめるのが本題。
const FULL: StepFacts = {
  counts: {
    controls: 304,
    risk_scenario_templates: 196,
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

// いまの実データ: 附属書 A は 0 件、規程は全件が仮置き、記録の機能はほぼ無い。
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

  // 期待値を ISO_STEPS から作ると、段階を削っても通ってしまう。並びをここに固定する。
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
    // 端から端まで辿り切れる（辿れなければ循環か切断がある）
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
  // required が空だと every() が真になって usable に化ける。型では防げないのでここで止める。
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

  // 記録として数えてよいのは、実施の証跡になり得るものだけ。
  // 禁止リストではなく**許可リスト**で書く。禁止リストは source を増やしたときに穴が空く。
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

  // 許可リストは「register を使ってよい」までしか言わない。
  // どの台帳を、どの画面につないだかは別に固定する。ここを固定しないと、
  // registerKey を取り違えても href を間違えても、試験は全部通る
  // （資産の欄がリスクの件数を出していても気づけない）。
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
        if (!want) continue; // 別の担当が足した台帳は、その担当の試験で固定する
        expect(t.source.registerKey, `${id} の台帳`).toBe(want.registerKey);
        expect(t.href, `${id} の行き先`).not.toBeNull();
        const url = new URL(t.href!, 'https://management.invalid');
        expect(url.pathname, `${id} の行き先`).toBe(want.path);
        // 段階の画面は ISMS のレンズ。行き先でレンズが外れると、
        // 段階側の件数（ISO 対象）と台帳側の一覧（全社）が食い違う。
        expect(url.searchParams.get('framework'), `${id} の枠組み`).toBe('ISO27001:2022');
        expect(url.searchParams.get('mode'), `${id} のモード`).toBe('isms');
      }
    }
    // 期待した 3 件が実在すること。定義ごと消えても落ちるようにする。
    for (const id of Object.keys(EXPECTED)) {
      expect(seen, `${id} が段階から消えている`).toContain(id);
    }
  });

  // 0065: 組織の課題（4.1）・利害関係者（4.2）は、規格が文書化情報を求めないので件数を出すだけ。
  // 必須にすると、今は満たしている適用範囲の段階が既存テナントで満たさない表示に変わる（2026-09-12 決定）。
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

  // 0066: A.5.31 は附属書 A の統制。適用は適用宣言書で決まるので、運用の段階に件数表示だけで載る。
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

  // 0068: 事業継続は計画と試験を別の欄にし、どちらも運用の段階に件数表示だけで載る。
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

  // 0069: A.8.8 も附属書 A の統制。運用の段階に件数表示だけで載る。
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

  // 0070: A.8.32 も附属書 A の統制。運用の段階に件数表示だけで載る。
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

  // カタログ（全テナント共有の下敷き）を記録として数えない。
  // 記録は自社の運用データ（app スキーマ）から出る。
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
          // **ここに足す前に web/src/app/<名前>/page.tsx が在ることを確かめる。**
          // organization と wizard はディレクトリだけ在ってページが無く、
          // 指すと 404 になる（実際に指しかけてこの検査が止めた）。
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

  // 箇条は形だけ見ても意味が無い。段階との対応そのものを固定する。
  // 10.1/10.2 の順、6.1.3（d が適用宣言書）、A.5.35/A.5.36 の置き場所を誤って動かせば落ちる。
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
    // 設定と DB が一致していれば両方 0
    expect(diffAssignment(['a', 'b'], ['a', 'b'])).toEqual({ inDbOnly: [], inConfigOnly: [] });
    // DB に足して割り当てを忘れた
    expect(diffAssignment(['a'], ['a', 'b']).inDbOnly).toEqual(['b']);
    // 設定に存在しないキーを書いた
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
    // 分母は「要る規程の数」。DB に在る数だけを分母にすると、
    // 1 本抜け落ちても残りがそろっているだけで「使える」になる。
    const t = tool({ kind: 'policies', keys: ['p01_basic', 'does_not_exist'] });
    expect(resolveTool(t, FULL)).toEqual({ kind: 'placeholder', count: 1, total: 2 });

    const gone = clone(FULL);
    delete gone.policyBodies.p01_basic;
    expect(resolveTool(t, gone)).toEqual({ kind: 'empty' });

    // 5 本要るうち 1 本が DB から消えると、残り 4 本が実本文でも落ちる
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

    // 件数だけ見ていると、附属書 A ではない統制を紐付けても通ってしまう
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

    // 5 件そろっていても、監査人が居なければ独立性は担保されない
    const noAuditor = clone(FULL);
    noAuditor.roleKeys = ['ciso', 'secretariat', 'risk_owner', 'employee', 'extra'];
    expect(noAuditor.roleKeys.length).toBe(5);
    expect(resolveTool(t, noAuditor)).toEqual({ kind: 'empty' });

    const all = tool({ kind: 'roles', keys: [...ALL_ROLE_KEYS] });
    expect(resolveTool(all, noAuditor)).toEqual({ kind: 'placeholder', count: 4, total: 5 });
  });

  it('規程のキー判定でプロトタイプのプロパティを拾わない', () => {
    // `k in obj` で書くと、これが「DB に在る規程」として数えられてしまう
    const t = tool({ kind: 'policies', keys: ['toString', 'constructor'] });
    expect(resolveTool(t, FULL)).toEqual({ kind: 'empty' });
  });

  it('附属書 A の集計が壊れているとき、使える側へ倒さない', () => {
    const t = tool({ kind: 'annexA' });
    const nan = clone(FULL);
    nan.annexA = { total: Number.NaN, wellFormed: 0 };
    expect(resolveTool(t, nan)).toEqual({ kind: 'unreadable' });

    // 形の合う件数が総数を超えるのは集計が壊れている
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

    // NaN を「未投入」に、Infinity を「使える」に化けさせない
    const nan = clone(FULL);
    nan.verifiedCheckRuns = Number.NaN;
    expect(resolveTool(t, nan)).toEqual({ kind: 'unreadable' });
    const inf = clone(FULL);
    inf.verifiedCheckRuns = Number.POSITIVE_INFINITY;
    expect(resolveTool(t, inf)).toEqual({ kind: 'unreadable' });
  });

  // 台帳は 0 件・未実装・読めないの取り違えが起きやすい。3 つとも別々に固定する。
  it('台帳は行があれば使えると出す', () => {
    const t = tool({ kind: 'register', registerKey: 'assets' }, 'record');

    // 登録されていれば、承認や管理責任者の有無に関係なく使える側に出す
    // （2026-09-07 のユーザー判断。ここを 0 件側へ倒さない）。
    expect(resolveTool(t, FULL)).toEqual({ kind: 'present', count: 17 });

    const one = clone(FULL);
    one.registers!.assets = 1;
    expect(resolveTool(t, one)).toEqual({ kind: 'present', count: 1 });

    // 台帳が空のときだけ未投入
    const empty = clone(FULL);
    empty.registers!.assets = 0;
    expect(resolveTool(t, empty)).toEqual({ kind: 'empty' });
  });

  it('台帳が読めないときに 0 件と言わない', () => {
    const t = tool({ kind: 'register', registerKey: 'risks' }, 'record');

    // テナント文脈が無い・DB が落ちている
    const unread = clone(FULL);
    unread.registers = null;
    expect(resolveTool(t, unread)).toEqual({ kind: 'unreadable' });

    // 数え方が壊れている値を、未投入にも使えるにも化けさせない
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

  // キーの取り違えは静かに嘘になる（資産の欄がリスクの件数を出す）。
  it('台帳のキーごとに別の実測を読む', () => {
    const f = clone(FULL);
    const at = (k: RegisterKey) =>
      resolveTool(tool({ kind: 'register', registerKey: k }, 'record'), f);
    // **全キーを個別に確かめる。** 一部だけ見ると、増えたキーが
    // 別のキーの件数を出していても気づけない。
    for (const [key, want] of Object.entries(f.registers!) as [RegisterKey, number][]) {
      expect(at(key), `${key} の件数`).toEqual(
        want > 0 ? { kind: 'present', count: want } : { kind: 'empty' },
      );
    }
    // 期待値が全キー分そろっていること（キーを足して fixture を忘れると素通りする）。
    // 0063 で統制の有効性評価（controlEffectiveness）を足して 17。
    // 0065 で組織の課題（contextIssues）・利害関係者（interestedParties）を足して 19。
    // 0066 で法令・契約上の要求事項（legalRequirements）を足して 20。
    // 0068 で事業継続の計画（continuityPlans）・試験（continuityTests）を足して 22。
    // 0069 で脆弱性（vulnerabilities）を足して 23。
    // 0070 で変更の申請（changeRequests）を足して 24。
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
    // 読めているときに読めないと言わない
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
