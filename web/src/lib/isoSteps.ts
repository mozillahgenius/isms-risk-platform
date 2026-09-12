/**
 * The stages of running an ISMS, and what this system provides for each stage.
 *
 * This holds only "the order of stages" and "the tools each stage needs"; **it holds no state at all**.
 * State is derived every time from what is actually measured in the DB (StepFacts). Baked-in progress
 * would stay green even after the DB is emptied. That would be a lie, so we don't create it.
 *
 * Key premise: **ISO/IEC 27001 does not prescribe the implementation procedure as "stages"**.
 * The standard defines requirements (clauses), not an order in which to start.
 * The 12 stages listed here are one example that orders the standard's requirements the way they are commonly done in practice,
 * and each stage lists its clause numbers so it can be cross-checked against the standard.
 * Gap analysis (understanding the current state before building) and the certification audit (third-party audit) are not
 * requirements of the standard, so they are not numbered and sit outside the stage sequence as references (PREPARATION / CERTIFICATION).
 *
 * Only the clauses **held in this file** are displayed as authoritative.
 * The seed's clause_ref / clause_refs contain known errors, so they are not used as the authoritative mapping.
 *
 * This file is kept as pure data + functions that do not touch server-only (so unit tests can call it directly).
 */

/** Keys in counts used for status determination. catalog.ts's Counts satisfies this structurally. */
export type StepCountKey =
  | 'controls'
  | 'risk_scenario_templates'
  | 'policies'
  | 'roles'
  | 'asset_classes'
  | 'calendar_events'
  | 'frameworks'
  | 'risk_criteria'
  | 'framework_mappings'
  | 'risk_template_controls'
  | 'checks'
  | 'check_controls'
  | 'connector_manifests';

export type StepCounts = Record<StepCountKey, number>;

/**
 * The organization's own registers. They live in the `app` schema and cannot be read without a tenant context.
 * Their source differs from the catalog (the baseline shared by all tenants), so they are a separate kind from count.
 */
export type RegisterKey =
  | 'assets'
  | 'risks'
  | 'measures'
  | 'competencies'
  | 'trainings'
  | 'scopeStatement'
  | 'scopeApprovals'
  | 'approvedPolicyVersions'
  | 'roleAssignments'
  | 'tenantPolicies'
  | 'soaControls'
  | 'audits'
  | 'auditFindings'
  | 'correctiveActions'
  | 'managementReviews'
  | 'securityObjectives'
  | 'controlEffectiveness'
  | 'contextIssues'
  | 'interestedParties'
  | 'legalRequirements'
  | 'continuityPlans'
  | 'continuityTests'
  | 'vulnerabilities'
  | 'changeRequests';

export type RoleKey = 'ciso' | 'secretariat' | 'risk_owner' | 'auditor' | 'employee';

export const ALL_ROLE_KEYS: RoleKey[] = [
  'ciso',
  'secretariat',
  'risk_owner',
  'auditor',
  'employee',
];

/**
 * Clause.
 * scope='cross' marks a cross-cutting requirement that is "not specific to this stage" (4.4, 6.1.1, 7.1, 7.4, etc.).
 * Presenting it as if it belonged exclusively to a stage would misrepresent the standard's structure.
 */
export type ClauseScope = 'primary' | 'cross';
export type Clause = { ref: string; title: string; scope: ClauseScope; note?: string };

/**
 * Role of a tool.
 * reference ... a baseline for rules (catalog side). It is only "available for reference" and is not evidence of operating the ISMS
 * record    ... a record of the organization operating its ISMS (operations side). This is what counts as evidence in an audit
 */
export type ToolRole = 'reference' | 'record';

/**
 * Source of the count. Fixes here, per kind, what present (= usable) means.
 * When adding a kind, add the resolveTool branch and unit tests at the same time.
 */
export type ToolSource =
  /** Row count in catalog. It is definition data, so it is used only for reference */
  | { kind: 'count'; countKey: StepCountKey }
  /** Among the specified policy keys, those whose body is not a placeholder */
  | { kind: 'policies'; keys: string[] }
  /** Among the specified annual event keys, those present in the DB */
  | { kind: 'calendar'; keys: string[] }
  /** Among the specified role keys, those present in the DB. Do not substitute the total count */
  | { kind: 'roles'; keys: RoleKey[] }
  /** Annex A controls of ISO/IEC 27001:2022. Checks not only the count but also the shape of the codes */
  | { kind: 'annexA' }
  /** Check results recorded after confirming they can fail. Requires a tenant context */
  | { kind: 'verifiedCheckRuns' }
  /**
   * Row count of the organization's own register (app schema). Requires a tenant context.
   *
   * What is counted is **registered rows**, not approved rows.
   * Approval and assignment of a responsible manager are not conditions for the count (user decision on 2026-09-07).
   * The stage screen is an ISMS lens, so it shows counts filtered by framework tag.
   * **The actual counting logic lives in one place: the SQL in catalog.ts's getRegisterFacts**. No copy is kept here.
   */
  | { kind: 'register'; registerKey: RegisterKey }
  /** The feature itself does not exist in this system. Do not issue a COUNT */
  | { kind: 'unbuilt' };

export type StepTool = {
  key: string;
  label: string;
  /** Destination. null for things that do not have a screen yet */
  href: string | null;
  /** What it is useful for. One line */
  note: string;
  role: ToolRole;
  required: boolean;
  source: ToolSource;
};

export type StepPhase = 'plan' | 'do' | 'check' | 'act';

export const PHASE_LABEL: Record<StepPhase, string> = {
  plan: '計画',
  do: '実施',
  check: '点検',
  act: '改善',
};

export const PHASE_NOTE: Record<StepPhase, string> = {
  plan: '何を守り、どこまでやるかを決める',
  do: '決めたことを文書と運用に落とす',
  check: '決めたとおりに動いているかを確かめる',
  act: 'ずれを直し、次のサイクルへつなぐ',
};

export const PHASE_ORDER: StepPhase[] = ['plan', 'do', 'check', 'act'];

export type IsoStep = {
  key: string;
  ordinal: number;
  phase: StepPhase;
  /** End with a verb. Not "assets" but "identify assets" */
  title: string;
  /** What gets decided at this stage */
  purpose: string;
  /** A caveat that this is not something the standard prescribes. Some stages have none */
  caveat?: string;
  clauses: Clause[];
  /** What people do. Practical procedures, not screen features */
  actions: string[];
  tools: StepTool[];
  /** Policies relevant to this stage (seed keys). Unique across stages */
  policyKeys: string[];
  /** Annual events relevant to this stage (seed keys). Unique across stages */
  calendarKeys: string[];
  /** Roles involved (seed keys). May appear in multiple stages */
  roleKeys: RoleKey[];
};

/** An unnumbered reference step. Not a requirement of the standard. */
export const PREPARATION = {
  title: 'ギャップ分析（現状把握）',
  detail:
    '着手前に、いまの運用が規格の要求事項とどれだけ離れているかを見る。規格が求めている工程ではないが、実務ではたいてい最初に置く。',
};

export const CERTIFICATION = {
  title: '認証審査（第三者による審査）',
  detail:
    '認証を取るなら、内部監査とマネジメントレビューを一巡させたうえで審査機関の審査を受ける。任意であり、下の 12 段階を終えたことが認証取得を意味するわけではない。',
};

export const ISO_STEPS: IsoStep[] = [
  {
    key: 'scope',
    ordinal: 1,
    phase: 'plan',
    title: '適用範囲を決める',
    purpose:
      'どこまでを ISMS の対象にするかを先に固定する。ここが動くと、資産もリスクも統制も全部引き直しになる。',
    clauses: [
      { ref: '4.1', title: '組織及びその状況の理解', scope: 'cross' },
      { ref: '4.2', title: '利害関係者のニーズ及び期待の理解', scope: 'cross' },
      { ref: '4.3', title: '情報セキュリティマネジメントシステムの適用範囲の決定', scope: 'primary' },
      {
        ref: '4.4',
        title: '情報セキュリティマネジメントシステム',
        scope: 'cross',
        note: 'ISMS の確立・実施・維持・改善という全体要求。この段階だけで満たすものではない',
      },
    ],
    actions: [
      '対象の組織・拠点・業務・情報システムを書き出す',
      '範囲から外すものは、外した理由も併せて書く',
      '外部・内部の課題と、利害関係者の要求を洗い出して範囲の根拠にする',
    ],
    tools: [
      {
        key: 'policy-scope',
        label: '適用範囲の規程雛形',
        href: '/catalog/policies/p02_scope',
        note: '適用範囲は規程の中で宣言する。その下敷き',
        role: 'reference',
        required: true,
        source: { kind: 'policies', keys: ['p02_scope'] },
      },
      {
        key: 'scope-statement',
        label: '自社の適用範囲の記述',
        href: '/operations?mode=isms',
        note: '対象の組織・拠点・業務・情報システムと、範囲から外したものの理由。件数は記述が空でなければ 1（中身が要件を満たすかは数えていない）',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'scopeStatement' },
      },
      {
        // Do not combine description and approval into one line. What is written and what is approved are different things.
        key: 'scope-approval',
        label: '適用範囲の承認記録',
        href: '/operations?mode=isms',
        note: '誰がいつ承認したか。件数は自社の適用範囲に対する、承認者と承認日の入った記録の数',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'scopeApprovals' },
      },
      {
        // 4.1 requires "determining" issues but does not require documented information. Show the count only; do not make it required.
        key: 'context-issues',
        label: '組織の課題（外部・内部）',
        href: '/iso27001/records?mode=isms#context',
        note: 'ISMS の成果に影響する外部・内部の課題と、それが ISMS にどう効くか。件数は有効な課題の数',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'contextIssues' },
      },
      {
        // Same for 4.2. Determine interested parties and their requirements, and which of those the ISMS addresses.
        key: 'interested-parties',
        label: '利害関係者とその要求',
        href: '/iso27001/records?mode=isms#parties',
        note: '顧客・規制当局・従業員・委託先などの、情報セキュリティに関する要求。件数は有効な利害関係者の数',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'interestedParties' },
      },
    ],
    policyKeys: ['p02_scope'],
    calendarKeys: [],
    roleKeys: ['ciso', 'secretariat'],
  },
  {
    key: 'policy',
    ordinal: 2,
    phase: 'plan',
    title: '方針・体制・目的を決める',
    purpose:
      '経営が何を約束するか、誰が何に責任を持つか、いつまでに何を達成するかを決める。ここが無いと現場は判断の拠りどころを持てない。',
    clauses: [
      { ref: '5.1', title: 'リーダーシップ及びコミットメント', scope: 'primary' },
      { ref: '5.2', title: '方針', scope: 'primary' },
      { ref: '5.3', title: '組織の役割，責任及び権限', scope: 'primary' },
      {
        ref: '6.2',
        title: '情報セキュリティ目的及びそれを達成するための計画策定',
        scope: 'primary',
      },
      { ref: 'A.5.1', title: '情報セキュリティのための方針群', scope: 'primary' },
      { ref: 'A.5.2', title: '情報セキュリティの役割及び責任', scope: 'primary' },
    ],
    actions: [
      '基本方針を経営層の名前で出す',
      '標準ロールを自社の実在の人・部署に割り当てる',
      '測れる情報セキュリティ目的を立て、達成の計画と評価の仕方を決める',
    ],
    tools: [
      {
        key: 'policy-basic',
        label: '基本方針・組織規程の雛形',
        href: '/catalog/policies',
        note: '方針と役割の下敷き',
        role: 'reference',
        required: true,
        source: { kind: 'policies', keys: ['p01_basic', 'p03_org'] },
      },
      {
        key: 'roles',
        label: '標準ロール',
        href: '/catalog/org',
        note: '責任を割り当てる先の雛形。自社の役職名へ読み替えて使う',
        role: 'reference',
        required: true,
        // Check by key, not by total. Having 5 entries is not the same as having the needed roles.
        source: { kind: 'roles', keys: ALL_ROLE_KEYS },
      },
      {
        key: 'approved-policy-versions',
        label: '承認された規程の版',
        href: '/policies?mode=isms',
        note: '方針を含む規程のうち、承認日が入っている現行の版の数（差し替え済みの版は数えない）',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'approvedPolicyVersions' },
      },
      {
        key: 'role-assignments',
        label: '役割の割り当て',
        href: '/operations?mode=isms',
        note: '標準ロールを実在の人へ割り当てた記録。件数は有効な割り当ての数',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'roleAssignments' },
      },
      {
        key: 'security-objectives',
        label: '情報セキュリティ目的と測り方',
        href: '/operations?mode=isms',
        note: '測れる目的と、達成をどう測るか。件数は測り方が入っている目的の数。達成の評価は別に記録する',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'securityObjectives' },
      },
    ],
    policyKeys: ['p01_basic', 'p03_org'],
    calendarKeys: [],
    roleKeys: ['ciso', 'secretariat'],
  },
  {
    key: 'assets',
    ordinal: 3,
    phase: 'plan',
    title: '情報資産を洗い出す',
    purpose:
      '守る対象を目録にする。目録に載っていないものは、この先のリスク評価にも統制にも一度も出てこない。',
    caveat:
      '資産を独立した段階として先に洗い出すのは、資産ベースのリスクアセスメント手法を採る場合。規格がこの順序を定めているわけではない。',
    clauses: [
      { ref: 'A.5.9', title: '情報及びその他の関連資産の目録', scope: 'primary' },
      { ref: 'A.5.10', title: '情報及びその他の関連資産の許容される利用', scope: 'primary' },
      { ref: 'A.5.12', title: '情報の分類', scope: 'primary' },
      {
        ref: 'A.5.13',
        title: '情報のラベル付け',
        scope: 'primary',
        note: '分類そのものではなく、分類の結果を現物に表示する統制',
      },
    ],
    actions: [
      '情報・機器・ソフトウェア・サービス・要員を、単位を決めて洗い出す',
      '資産ごとに管理責任者を決める',
      '資産を分類し、社外共有の可否は分類ごとの規則に従わせる',
    ],
    tools: [
      {
        key: 'asset-classes',
        label: '資産分類',
        href: '/catalog/org',
        note: '機密度の段階と、段階ごとの社外共有の扱い',
        role: 'reference',
        required: true,
        source: { kind: 'count', countKey: 'asset_classes' },
      },
      {
        key: 'policy-asset',
        label: '情報資産管理規程の雛形',
        href: '/catalog/policies/p06_asset',
        note: '分類と取扱いの下敷き',
        role: 'reference',
        required: true,
        source: { kind: 'policies', keys: ['p06_asset'] },
      },
      {
        key: 'asset-register',
        label: '自社の情報資産目録',
        href: '/risk-management/assets?framework=ISO27001%3A2022&mode=isms',
        note: '実物を 1 行ずつ載せ、管理責任者と分類を持たせる。件数は ISO 対象として登録されている資産の数',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'assets' },
      },
    ],
    policyKeys: ['p06_asset'],
    calendarKeys: [],
    roleKeys: ['secretariat', 'risk_owner'],
  },
  {
    key: 'risk-assessment',
    ordinal: 4,
    phase: 'plan',
    title: 'リスクアセスメントを行う',
    purpose:
      '起こりうることを並べ、同じ物差しに載せる。物差しを先に決めておかないと、評価するたびに結論が動く。',
    caveat:
      'リスク基準の 5×5 は、この仕組みの標準運用モデルが定める評価方法。規格が尺度を指定しているわけではない。',
    clauses: [
      {
        ref: '6.1.1',
        title: 'リスク及び機会に対処する活動（一般）',
        scope: 'cross',
        note: 'ISMS 全体のリスクと機会への取組み。リスクアセスメントの手法そのものではない',
      },
      { ref: '6.1.2', title: '情報セキュリティリスクアセスメント', scope: 'primary' },
      {
        ref: '8.2',
        title: '情報セキュリティリスクアセスメント',
        scope: 'primary',
        note: '6.1.2 が手順の確立、8.2 がその手順に沿った実施と記録',
      },
    ],
    actions: [
      'リスク基準（発生可能性・影響度の尺度、受容の基準、是正期限）を承認する',
      'リスクシナリオ雛形から自社に当てはまるものを起こし、資産と結び付ける',
      'リスク所有者を決め、評価結果と残留リスクを記録する',
    ],
    tools: [
      {
        key: 'criteria',
        label: 'リスク基準とリスクマップ',
        href: '/catalog/criteria',
        note: '5×5 の帯・是正期限・機密性と完全性と可用性の合成の仕方',
        role: 'reference',
        required: true,
        source: { kind: 'count', countKey: 'risk_criteria' },
      },
      {
        key: 'risk-templates',
        label: 'リスクシナリオ雛形',
        href: '/catalog/risks',
        note: '部門別に起こりうることの下敷き。ここから自社版を起こす',
        role: 'reference',
        required: true,
        source: { kind: 'count', countKey: 'risk_scenario_templates' },
      },
      {
        key: 'policy-ra',
        label: 'リスクアセスメント手順の雛形',
        href: '/catalog/policies/p04_ra',
        note: '手順を文書にするときの下敷き',
        role: 'reference',
        required: true,
        source: { kind: 'policies', keys: ['p04_ra'] },
      },
      {
        key: 'calendar-risk',
        label: '年次の見直し行事',
        href: '/catalog/calendar',
        note: 'リスクアセスメントを毎年見直す予定',
        role: 'reference',
        required: false,
        source: { kind: 'calendar', keys: ['annual_risk'] },
      },
      {
        key: 'risk-register',
        label: '自社のリスク台帳',
        href: '/risk-management/risks?framework=ISO27001%3A2022&mode=isms',
        note: '評価値・リスク所有者・対応方針・残留リスクの受容記録。件数は ISO 対象として登録されているリスクの数',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'risks' },
      },
    ],
    policyKeys: ['p04_ra'],
    calendarKeys: ['annual_risk'],
    roleKeys: ['ciso', 'secretariat', 'risk_owner'],
  },
  {
    key: 'soa',
    ordinal: 5,
    phase: 'plan',
    title: 'リスク対応を決め、適用宣言書をつくる',
    purpose:
      'リスクごとに打つ手を決め、附属書 A と突き合わせる。採用したものだけでなく、採用しなかったものにも理由が要る。',
    clauses: [
      {
        ref: '6.1.3',
        title: '情報セキュリティリスク対応',
        scope: 'primary',
        note: 'd) が適用宣言書。必要な統制・採用の理由・実装状況・附属書 A から除外した理由まで含む',
      },
      {
        ref: '8.3',
        title: '情報セキュリティリスク対応',
        scope: 'primary',
        note: '6.1.3 で立てた計画の実施と記録',
      },
    ],
    actions: [
      'リスクごとに対応方針（低減・移転・回避・受容）を決める',
      '必要な統制を決め、附属書 A と突き合わせて漏れを確認する',
      '採用・除外の理由と実装状況を適用宣言書にまとめ、承認を取る',
    ],
    tools: [
      {
        key: 'annex-a',
        label: 'ISO/IEC 27001:2022 附属書 A の統制',
        href: '/catalog/frameworks',
        note: '適用宣言書で突き合わせる相手。件数だけでなくコードの形も見る',
        role: 'reference',
        required: true,
        source: { kind: 'annexA' },
      },
      {
        key: 'policy-soa',
        label: 'リスク対応手順・適用宣言書の雛形',
        href: '/catalog/policies/p05_rt_soa',
        note: '手順と様式の下敷き',
        role: 'reference',
        required: true,
        source: { kind: 'policies', keys: ['p05_rt_soa'] },
      },
      {
        key: 'risk-control-links',
        label: 'リスクと統制の紐付け',
        href: null,
        note: 'どのリスクをどの統制で抑えるかの対応。表はあるが中身が未投入',
        role: 'reference',
        required: false,
        source: { kind: 'count', countKey: 'risk_template_controls' },
      },
      {
        key: 'soa-record',
        label: '自社の適用宣言書',
        href: '/iso27001?mode=isms',
        note: '統制ごとの採用・除外と理由。件数は適用可否と理由の両方が入っている現行の統制の数',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'soaControls' },
      },
    ],
    policyKeys: ['p05_rt_soa'],
    calendarKeys: [],
    roleKeys: ['ciso', 'secretariat', 'risk_owner'],
  },
  {
    key: 'documents',
    ordinal: 6,
    phase: 'do',
    title: '規程・手順書を整える',
    purpose:
      '決めた統制を、現場が読んで従える文章にする。文書になっていない決定は、担当が替わった時点で消える。',
    clauses: [
      { ref: '7.5', title: '文書化した情報', scope: 'primary' },
      {
        ref: '7.5.3',
        title: '文書化した情報の管理',
        scope: 'primary',
        note: '配布・アクセス・変更・保存・廃棄まで。記録だけの話ではない',
      },
    ],
    actions: [
      '個別規程を自社の言葉に直す',
      '版・承認日・次回見直し日を付けて配布する',
      '誰が読めるか、どう改訂するか、いつ捨てるかを決める',
    ],
    tools: [
      {
        key: 'policy-set',
        label: '個別規程の雛形',
        href: '/catalog/policies',
        note: 'アクセス制御・物理・技術・委託先・インシデントの下敷き',
        role: 'reference',
        required: true,
        source: {
          kind: 'policies',
          keys: ['p07_access', 'p09_physical', 'p10_technical', 'p11_vendor', 'p12_incident'],
        },
      },
      {
        key: 'tenant-policies',
        label: '自社へ展開された規程',
        href: '/policies?mode=isms',
        note: '標準規程から自社テナントへ展開された規程の数。承認済みの版の数は段階 2 で見る',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'tenantPolicies' },
      },
    ],
    policyKeys: [
      'p07_access',
      'p09_physical',
      'p10_technical',
      'p11_vendor',
      'p12_incident',
      'p13_docs',
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
    ],
    calendarKeys: [],
    roleKeys: ['ciso', 'secretariat'],
  },
  {
    key: 'training',
    ordinal: 7,
    phase: 'do',
    title: '教育・訓練を実施する',
    purpose:
      'ルールを知らない人は守れない。誰が何をいつ受けたかを残せて初めて、認識が組織に行き渡ったと言える。',
    clauses: [
      { ref: '7.1', title: '資源', scope: 'cross' },
      { ref: '7.2', title: '力量', scope: 'primary' },
      { ref: '7.3', title: '認識', scope: 'primary' },
      { ref: '7.4', title: 'コミュニケーション', scope: 'cross' },
      { ref: 'A.6.3', title: '情報セキュリティの意識向上，教育及び訓練', scope: 'primary' },
    ],
    actions: [
      '対象者と頻度を決める（入社時・年次・役割が変わったとき）',
      '教材と理解度の確かめ方を用意する',
      '受講の記録を残し、未受講者を追える状態にする',
    ],
    tools: [
      {
        key: 'policy-people',
        label: '人的セキュリティ規程の雛形',
        href: '/catalog/policies/p08_people',
        note: '入退社と教育の下敷き',
        role: 'reference',
        required: true,
        source: { kind: 'policies', keys: ['p08_people'] },
      },
      {
        key: 'calendar-training',
        label: '教育の年間行事',
        href: '/catalog/calendar',
        note: '年次教育と入社時の予定',
        role: 'reference',
        required: true,
        source: { kind: 'calendar', keys: ['annual_training', 'event_onboarding'] },
      },
      {
        key: 'training-records',
        label: '教育・訓練講座',
        href: '/training?mode=isms',
        // **Write what is being counted in label and note.** Training records and effectiveness evaluations are
        // actuals of "who took it"; they do not exist just because a course was registered.
        // Counting them together here would make it look like records exist even with 0 attendances.
        note: 'eラーニングの ISMS・リスクマネジメント講座を同期する。件数は ISO 対象として登録されている講座の数。受講記録と有効性の評価は教育の画面で入れる',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'trainings' },
      },
      {
        key: 'competency-records',
        label: '力量要件',
        href: '/competency?mode=isms',
        // Per-member sufficiency evaluations are actuals, so do not count them together with the number of requirements.
        note: '役割ごとに要る力量。件数は登録されている力量要件の数。メンバーごとの評価は力量の画面で入れ、教育・訓練の実績を根拠として引用する',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'competencies' },
      },
    ],
    policyKeys: ['p08_people', 'p14_awareness'],
    calendarKeys: ['annual_training', 'event_onboarding'],
    roleKeys: ['secretariat', 'employee'],
  },
  {
    key: 'operate',
    ordinal: 8,
    phase: 'do',
    title: '統制を実装して運用し、記録を残す',
    purpose:
      '適用宣言書で選んだ統制を実際に効かせる。選んだことと効いていることは別で、後者には記録が要る。',
    clauses: [
      {
        ref: '8.1',
        title: '運用の計画及び管理',
        scope: 'primary',
        note: 'ここで生む記録は 7.5.3（文書化した情報の管理）に従って管理する',
      },
    ],
    actions: [
      '適用宣言書で採用した統制を、手順・設定・仕組みに落とす',
      '年間行事に沿って棚卸・演習・評価を実施する',
      '実施したことの証跡を、後から第三者が辿れる形で残す',
    ],
    tools: [
      {
        key: 'calendar-ops',
        label: '運用の年間行事',
        href: '/catalog/calendar',
        note: 'アカウント棚卸・端末・外部公開・復元演習・委託先・退職時',
        role: 'reference',
        required: true,
        source: {
          kind: 'calendar',
          keys: [
            'monthly_accounts',
            'monthly_endpoints',
            'quarterly_sharing',
            'quarterly_restore',
            'semiannual_vendors',
            'event_offboarding',
          ],
        },
      },
      {
        key: 'connectors',
        label: 'コネクタ定義',
        href: null,
        note: '実体を読みに行く先の定義。読めた範囲も併せて記録する',
        role: 'reference',
        required: false,
        source: { kind: 'count', countKey: 'connector_manifests' },
      },
      {
        key: 'control-records',
        label: '選んだ統制の実施記録・有効性の記録',
        href: '/risk-management/measures?framework=ISO27001%3A2022&mode=isms',
        note: '統制を実施したことの記録。件数は ISO 対象として登録されている施策の数。効いているかの評価は「監視・測定」の段階の有効性評価に残す',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'measures' },
      },
      {
        // A.5.31 is an Annex A control. Whether it applies is decided by the Statement of Applicability, so show the count only and do not make it required
        // (showing "incomplete" even for the stage of an organization that excluded it would be a wrong display. Decided 2026-09-12).
        key: 'legal-requirements',
        label: '法令・規制・契約上の要求事項',
        href: '/iso27001/records?mode=isms#legal',
        note: '情報セキュリティに関係する要求と、応える統制・証跡、適合の評価。件数は有効な要求事項の数',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'legalRequirements' },
      },
      {
        // A.5.29 / 5.30 are also Annex A controls. Show the count only; do not make them required (decided 2026-09-12).
        // Keep plans and tests in separate fields. Having a plan is different from having tested it and seen it work.
        key: 'continuity-plans',
        label: '事業継続の計画',
        href: '/iso27001/records?mode=isms#continuity',
        note: '中断・障害のときに何をどう続けるか。件数は有効な計画の数',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'continuityPlans' },
      },
      {
        key: 'continuity-tests',
        label: '事業継続の試験の記録',
        href: '/iso27001/records?mode=isms#continuity',
        note: '計画を試した記録。件数は実施日が今日までの試験の数（予定は数えない）',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'continuityTests' },
      },
      {
        // A.8.8 is also an Annex A control. Show the count only; do not make it required (decided 2026-09-12).
        key: 'vulnerabilities',
        label: '技術的脆弱性の記録',
        href: '/iso27001/records?mode=isms#vulnerabilities',
        note: '検知した脆弱性と、対応期限・状態。件数は登録されている脆弱性の数（誤検知は数えない）',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'vulnerabilities' },
      },
      {
        // A.8.32 is also an Annex A control. Show the count only; do not make it required (decided 2026-09-12).
        key: 'change-requests',
        label: '変更の申請と承認の記録',
        href: '/iso27001/records?mode=isms#changes',
        note: '変更の申請・経営層の承認・実施の記録。件数は登録されている申請の数（取りやめは数えない）',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'changeRequests' },
      },
    ],
    policyKeys: [],
    calendarKeys: [
      'monthly_accounts',
      'monthly_endpoints',
      'quarterly_sharing',
      'quarterly_restore',
      'semiannual_vendors',
      'event_offboarding',
    ],
    roleKeys: ['secretariat', 'risk_owner', 'employee'],
  },
  {
    key: 'monitor',
    ordinal: 9,
    phase: 'check',
    title: '監視・測定して有効性を評価する',
    purpose:
      '決めたとおりに動いているかを、当事者の自己申告ではなく実体から確かめる。確かめていない合格は合格ではない。',
    clauses: [
      { ref: '9.1', title: '監視，測定，分析及び評価', scope: 'primary' },
      {
        ref: 'A.5.36',
        title: '情報セキュリティのための方針群，規則及び標準の順守',
        scope: 'primary',
        note: '文書を作る統制ではなく、決めたとおりに守られているかを確かめる統制',
      },
    ],
    actions: [
      '何を・いつ・誰が測るかを決める',
      '自動チェックを回し、違反と判定不能を分けて扱う',
      'チェック自体を壊して落ちることを確かめてから、合格として数える',
    ],
    tools: [
      {
        key: 'checks',
        label: '標準チェック',
        href: '/catalog/checks',
        note: '自動で回す点検の定義',
        role: 'reference',
        required: true,
        source: { kind: 'count', countKey: 'checks' },
      },
      {
        key: 'calendar-daily',
        label: '日次の実行行事',
        href: '/catalog/calendar',
        note: '自動チェックの実行とドリフト通知',
        role: 'reference',
        required: true,
        source: { kind: 'calendar', keys: ['daily_checks'] },
      },
      {
        key: 'check-runs',
        label: '落ちることを確かめたチェック結果',
        href: '/operations',
        note: '実行結果のうち、逆向きの確認が済み、いまの定義にも当てはまるもの',
        role: 'record',
        required: true,
        source: { kind: 'verifiedCheckRuns' },
      },
      {
        // 9.1 requires not only "monitoring and measurement" but also evaluation of effectiveness. Count it separately from records of what was done (measures).
        key: 'control-effectiveness',
        label: '統制の有効性評価',
        href: '/iso27001/records?mode=isms#effectiveness',
        note: '何をもって有効とみなすか（判定基準）と、評価日・評価者・結果の記録。**件数は評価日が今日までの ISO 対象の評価の数**',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'controlEffectiveness' },
      },
    ],
    policyKeys: ['p15_monitor'],
    calendarKeys: ['daily_checks'],
    roleKeys: ['secretariat'],
  },
  {
    key: 'audit',
    ordinal: 10,
    phase: 'check',
    title: '内部監査を行う',
    purpose:
      '運用している当人とは別の目で、規格の要求と自社の規程の両方に照らして確かめる。',
    clauses: [
      { ref: '9.2', title: '内部監査', scope: 'primary' },
      {
        ref: 'A.5.35',
        title: '情報セキュリティの独立したレビュー',
        scope: 'primary',
        note: '9.2 の内部監査を代替するものではなく、独立した視点でのレビューを求める補完の統制',
      },
    ],
    actions: [
      '監査プログラム（頻度・方法・責任・報告）を決める',
      '監査人が自分の担当業務を監査しない配置にする',
      '監査調書と指摘を残し、是正処置につなげる',
    ],
    tools: [
      {
        key: 'calendar-audit',
        label: '内部監査の年間行事',
        href: '/catalog/calendar',
        note: '年次の内部監査の予定と担当ロール',
        role: 'reference',
        required: true,
        source: { kind: 'calendar', keys: ['annual_audit'] },
      },
      {
        key: 'auditor-role',
        label: '監査人ロール',
        href: '/catalog/org',
        note: '業務データを変更できない役割として定義されている',
        role: 'reference',
        required: true,
        // Do not substitute the total number of roles. Even with 5 roles, independence is not ensured without an auditor.
        source: { kind: 'roles', keys: ['auditor'] },
      },
      {
        key: 'audit-records',
        label: '内部監査の実施記録',
        href: '/iso27001/records?mode=isms',
        note: '実施した監査の記録。**件数は実施日が今日までに入っている監査の数**。計画や先の予定は数えない',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'audits' },
      },
      {
        key: 'audit-findings',
        label: '監査の指摘',
        href: '/iso27001/records?mode=isms',
        note: '監査で出た指摘。件数は登録されている指摘の数',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'auditFindings' },
      },
    ],
    policyKeys: ['p16_audit'],
    calendarKeys: ['annual_audit'],
    roleKeys: ['auditor', 'secretariat'],
  },
  {
    key: 'management-review',
    ordinal: 11,
    phase: 'check',
    title: 'マネジメントレビューを行う',
    purpose:
      '経営層が、実績と資源の過不足を見て次の一手を決める。事務局の報告会ではなく、経営の意思決定の場。',
    clauses: [{ ref: '9.3', title: 'マネジメントレビュー', scope: 'primary' }],
    actions: [
      '前回からの変化・監査結果・チェック結果・未対応の指摘を入力としてそろえる',
      '目的の達成度と資源の過不足を評価する',
      '決めたこと（改善・資源配分・方針の変更）を議事として残す',
    ],
    tools: [
      {
        key: 'calendar-review',
        label: 'マネジメントレビューの年間行事',
        href: '/catalog/calendar',
        note: '年次のレビューの予定と主宰ロール',
        role: 'reference',
        required: true,
        source: { kind: 'calendar', keys: ['annual_review'] },
      },
      {
        key: 'review-records',
        label: 'マネジメントレビューの記録',
        href: '/iso27001/records?mode=isms',
        note: '入力・議事・決定事項を持つレビューの記録。**件数は開催日が今日までに入っているレビューの数**。年度の枠や先の予定は数えない',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'managementReviews' },
      },
    ],
    policyKeys: ['p17_review'],
    calendarKeys: ['annual_review'],
    roleKeys: ['ciso', 'secretariat'],
  },
  {
    key: 'improve',
    ordinal: 12,
    phase: 'act',
    title: '不適合を是正し、継続的に改善する',
    purpose:
      '見つかったずれを閉じ、閉じたことを確かめる。原因まで戻らずに現象だけ直すと、同じものが翌期また出る。',
    clauses: [
      {
        ref: '10.2',
        title: '不適合及び是正処置',
        scope: 'primary',
        note: '2022 年版では 10.2 が是正処置。2013 年版とは番号が入れ替わっている',
      },
      {
        ref: '10.1',
        title: '継続的改善',
        scope: 'primary',
        note: '番号は 10.2 より小さいが、実務では不適合の是正を先に回し、その積み重ねを継続的改善につなげる',
      },
    ],
    actions: [
      '不適合を記録し、原因を追い、処置と期限を決める',
      '処置後にもう一度確かめて閉じる',
      '同種の不適合が他に無いかを横へ展開する',
    ],
    tools: [
      {
        key: 'calendar-findings',
        label: '是正・逸脱の年間行事',
        href: '/catalog/calendar',
        note: '未対応の指摘レビューと、逸脱の棚卸',
        role: 'reference',
        required: true,
        source: { kind: 'calendar', keys: ['weekly_findings', 'quarterly_deviation'] },
      },
      {
        key: 'nonconformity',
        label: '不適合（指摘）の台帳',
        href: '/iso27001/records?mode=isms',
        note: '検出した不適合。件数は登録されている指摘の数',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'auditFindings' },
      },
      {
        // Count findings and corrective actions separately. Do not hide a state where findings exist but corrective actions are 0.
        key: 'corrective-actions',
        label: '是正処置の台帳',
        href: '/iso27001/records?mode=isms',
        note: '原因・処置・再確認まで追う記録。件数は登録されている是正処置の数',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'correctiveActions' },
      },
    ],
    policyKeys: ['p18_nc'],
    calendarKeys: ['weekly_findings', 'quarterly_deviation'],
    roleKeys: ['ciso', 'secretariat', 'risk_owner'],
  },
];

// ---------------------------------------------------------------------------
// Deriving status
// ---------------------------------------------------------------------------

/**
 * Measured values. Only values read from the DB go here; no defaults are given.
 * With defaults, a failure to read would turn into "0 items".
 */
export type StepFacts = {
  counts: StepCounts;
  /** Policy keys present in the DB -> whether the body has real content (is not a placeholder) */
  policyBodies: Record<string, boolean>;
  /** Annual event keys present in the DB */
  calendarKeys: string[];
  /** Role keys present in the DB */
  roleKeys: string[];
  /** ISO/IEC 27001:2022 controls. total is the count; wellFormed is the count in A.x.y form */
  annexA: { total: number; wellFormed: number };
  /** Count of check results whose reverse check is complete. null when unreadable */
  verifiedCheckRuns: number | null;
  /**
   * Row counts of the organization's own registers. null when there is no tenant context or the DB cannot be read.
   * **Do not mix null with "0 items".** The former means it could not be read; the latter means it was measured and was 0.
   */
  registers: Record<RegisterKey, number> | null;
};

/**
 * Whether a value can be trusted as a count.
 *
 * Passing NaN, Infinity, or non-numeric values straight into comparisons makes `> 0` come out true or false,
 * turning them into either "usable" or "not populated". Treat unreadable values as unreadable.
 * Since these are counts, only **non-negative integers** pass. A value like 1.5 items means the counting is broken.
 */
function isCount(n: unknown): n is number {
  return typeof n === 'number' && Number.isInteger(n) && n >= 0;
}

export type ToolState =
  /** Usable */
  | { kind: 'present'; count: number }
  /** Rows exist but the content is a placeholder */
  | { kind: 'placeholder'; count: number; total: number }
  /** A count exists but it does not have the expected shape */
  | { kind: 'malformed'; wellFormed: number; total: number }
  /** The table exists but has 0 rows */
  | { kind: 'empty' }
  /** The feature itself does not exist */
  | { kind: 'unbuilt' }
  /** Not in a readable state (neither 0 items nor unimplemented) */
  | { kind: 'unreadable' };

export const TOOL_STATE_LABEL: Record<ToolState['kind'], string> = {
  present: '使える',
  placeholder: '中身が仮置き',
  malformed: '形が合っていない',
  empty: '未投入',
  unbuilt: '機能が無い',
  unreadable: '読めない',
};

/**
 * The shape of Annex A control codes.
 *
 * The 2022 edition's Annex A has only 4 categories: A.5 (organizational), A.6 (people), A.7 (physical), A.8 (technological).
 * Loosening it to `A\.\d+\.\d+` would also accept non-existent categories like A.9.1,
 * and it would no longer serve as grounds for "Annex A controls are present".
 */
export const ANNEX_A_CODE = /^A\.[5-8]\.\d{1,2}$/;

/** Count only the keys contained in the set. Look only at own properties. */
function countKnown(keys: readonly string[], known: readonly string[]): string[] {
  return keys.filter((k) => known.includes(k));
}

export function resolveTool(tool: StepTool, facts: StepFacts): ToolState {
  const src = tool.source;
  switch (src.kind) {
    case 'unbuilt':
      // Do not issue a COUNT. That the feature does not exist is known statically.
      return { kind: 'unbuilt' };

    case 'count': {
      const n = facts.counts[src.countKey];
      // Mixing values unreadable as numbers with 0 turns them into "not populated". Yet it is not "feature does not exist" either.
      // Report a failure to read as a failure to read.
      if (!isCount(n)) return { kind: 'unreadable' };
      return n > 0 ? { kind: 'present', count: n } : { kind: 'empty' };
    }

    case 'policies': {
      // `k in obj` also matches the prototype side (toString etc.), so it is not used.
      // Just writing a policy key named 'toString' in the config would make it count as present in the DB.
      const known = src.keys.filter((k) =>
        Object.prototype.hasOwnProperty.call(facts.policyBodies, k),
      );
      if (known.length === 0) return { kind: 'empty' };
      // **The denominator is "the number of required policies", not "the number present in the DB".**
      // If only those present in the DB were the denominator, when one required policy is missing,
      // the rest being complete would be enough for "usable". Count what is missing as insufficient.
      const substantive = src.keys.filter((k) => facts.policyBodies[k] === true).length;
      if (substantive < src.keys.length) {
        return { kind: 'placeholder', count: substantive, total: src.keys.length };
      }
      return { kind: 'present', count: substantive };
    }

    case 'calendar': {
      const present = countKnown(src.keys, facts.calendarKeys);
      if (present.length === 0) return { kind: 'empty' };
      // Do not call a partially present state "usable". That would mean operating with parts of the schedule missing.
      if (present.length < src.keys.length) {
        return { kind: 'placeholder', count: present.length, total: src.keys.length };
      }
      return { kind: 'present', count: present.length };
    }

    case 'roles': {
      const present = countKnown(src.keys, facts.roleKeys);
      if (present.length === 0) return { kind: 'empty' };
      if (present.length < src.keys.length) {
        return { kind: 'placeholder', count: present.length, total: src.keys.length };
      }
      return { kind: 'present', count: present.length };
    }

    case 'annexA': {
      const { total, wellFormed } = facts.annexA;
      // If the aggregate itself cannot be read, say neither 0 items nor populated.
      // If the DB itself is down, the query throws and the screen returns 500 (that is the correct behavior).
      // What this guards against is the case where "the query returned but the value is broken as a number".
      if (!isCount(total) || !isCount(wellFormed)) return { kind: 'unreadable' };
      // A well-formed count exceeding the total means the aggregation is broken. Do not tip it toward usable.
      if (wellFormed > total) return { kind: 'malformed', wellFormed, total };
      if (total === 0) return { kind: 'empty' };
      // Looking only at the count, linking controls that are not from Annex A would still pass.
      // If even one code has a different shape, do not say Annex A is present.
      if (wellFormed !== total) return { kind: 'malformed', wellFormed, total };
      return { kind: 'present', count: total };
    }

    case 'verifiedCheckRuns': {
      const n = facts.verifiedCheckRuns;
      if (n === null) return { kind: 'unreadable' };
      // Do not let NaN turn into "not populated" like 0, or Infinity into "usable".
      if (!isCount(n)) return { kind: 'unreadable' };
      return n > 0 ? { kind: 'present', count: n } : { kind: 'empty' };
    }

    case 'register': {
      // Failing to read a register (no tenant context, etc.) is not 0 items.
      if (facts.registers === null) return { kind: 'unreadable' };
      const n = facts.registers[src.registerKey];
      // Do not let NaN turn into "not populated" or Infinity into "usable".
      if (!isCount(n)) return { kind: 'unreadable' };
      return n > 0 ? { kind: 'present', count: n } : { kind: 'empty' };
    }
  }
}

export type StepStatus =
  /** Everything required has both its baseline and its records in place */
  | 'usable'
  /** Only part of what is required is in place */
  | 'partial'
  /** None of what is required is in place */
  | 'none';

export type StepAssessment = {
  status: StepStatus;
  /** Whether all required baselines are in place */
  referencesReady: boolean;
  /** Whether all required records are in place */
  recordsReady: boolean;
  /** Whether there are unreadable items. Shown alongside the status, separately (do not tip the status toward the better side) */
  hasUnreadable: boolean;
  tools: { tool: StepTool; state: ToolState }[];
  /** Tools that are required but not in place */
  missingRequired: StepTool[];
};

/**
 * The wording shown in a stage's heading.
 *
 * After splitting status into 3, it distinguishes only the **common case** of partial
 * (baselines are in place but there is no feature to keep records).
 * Applying "baseline only" to every partial case would show that wording even for stages that have records but lack a baseline,
 * and the screen would lie.
 */
export function statusLabel(a: StepAssessment): string {
  if (a.status === 'usable') return '記録まで残せる';
  if (a.status === 'none') return 'まだ何も無い';
  if (a.referencesReady && !a.recordsReady) return '下敷きだけある';
  return '一部だけそろっている';
}

export function statusNote(a: StepAssessment): string {
  if (a.status === 'usable') return '下敷きも、自社が回した記録も、この仕組みの中にある';
  if (a.status === 'none') return '下敷きも記録も、この仕組みにはまだ無い';
  if (a.referencesReady && !a.recordsReady) {
    return '参照できる下敷きはあるが、実施した記録をここに残す機能がまだ無い';
  }
  return '要るものの一部しかそろっていない。足りないものは各段階に挙げる';
}

/** The list of headings used for aggregation. Wording not listed here never comes out of statusLabel. */
export const STATUS_BUCKETS: readonly string[] = [
  '記録まで残せる',
  '下敷きだけある',
  '一部だけそろっている',
  'まだ何も無い',
];

/**
 * Derives a stage's status from measured values.
 *
 * Only present is counted as present. placeholder, malformed, empty, unbuilt, and unreadable
 * are all counted on the "unusable" side. The moment unusable things are mixed into the usable side, this screen starts lying.
 *
 * The evaluation order is fixed. If required is empty, every() is true and turns into usable, so
 * "every stage has at least one required reference and record" is enforced by unit tests.
 */
export function assessStep(step: IsoStep, facts: StepFacts): StepAssessment {
  const tools = step.tools.map((tool) => ({ tool, state: resolveTool(tool, facts) }));
  const required = tools.filter((t) => t.tool.required);
  const isPresent = (t: { state: ToolState }) => t.state.kind === 'present';

  const requiredRefs = required.filter((t) => t.tool.role === 'reference');
  const requiredRecs = required.filter((t) => t.tool.role === 'record');

  // An empty every() is true. To avoid reading a stage with no required items as "complete",
  // the length is included in the condition (the invariant itself is enforced by unit tests).
  const referencesReady = requiredRefs.length > 0 && requiredRefs.every(isPresent);
  const recordsReady = requiredRecs.length > 0 && requiredRecs.every(isPresent);

  let status: StepStatus;
  if (!required.some(isPresent)) {
    status = 'none';
  } else if (referencesReady && recordsReady) {
    status = 'usable';
  } else {
    status = 'partial';
  }

  return {
    status,
    referencesReady,
    recordsReady,
    hasUnreadable: tools.some((t) => t.state.kind === 'unreadable'),
    tools,
    missingRequired: required.filter((t) => !isPresent(t)).map((t) => t.tool),
  };
}

export function getStep(key: string): IsoStep | null {
  return ISO_STEPS.find((s) => s.key === key) ?? null;
}

/** The previous and next stages. Returns null at the ends. */
export function stepNeighbors(key: string): { prev: IsoStep | null; next: IsoStep | null } {
  const i = ISO_STEPS.findIndex((s) => s.key === key);
  if (i < 0) return { prev: null, next: null };
  return {
    prev: i > 0 ? ISO_STEPS[i - 1] : null,
    next: i < ISO_STEPS.length - 1 ? ISO_STEPS[i + 1] : null,
  };
}

/**
 * Status of a single policy's body. Re-deriving this on each screen produces different wording per screen.
 * missing ... in the assignment table but not in the DB
 */
export type PolicyBodyState = 'substantive' | 'placeholder' | 'missing';

export function policyBodyState(facts: StepFacts, key: string): PolicyBodyState {
  if (!Object.prototype.hasOwnProperty.call(facts.policyBodies, key)) return 'missing';
  return facts.policyBodies[key] === true ? 'substantive' : 'placeholder';
}

/** All role keys assigned to stages (including duplicates; a role may appear in multiple stages). */
export function assignedRoleKeys(): string[] {
  return Array.from(new Set(ISO_STEPS.flatMap((s) => s.roleKeys)));
}

/** All policy keys assigned to stages. */
export function assignedPolicyKeys(): string[] {
  return ISO_STEPS.flatMap((s) => s.policyKeys);
}

/** All annual event keys assigned to stages. */
export function assignedCalendarKeys(): string[] {
  return ISO_STEPS.flatMap((s) => s.calendarKeys);
}

/**
 * Checks for gaps in assignments **in both directions**.
 *
 * One direction only (in the DB but not in the config) cannot catch typos or non-existent keys on the config side.
 * Both the case of adding a row to the seed and forgetting to assign it, and the case of writing a fictitious key in the config,
 * are shown on screen (the external check verifies both are 0).
 */
export type Unassigned = {
  /** Present in the DB but not assigned to any stage */
  inDbOnly: string[];
  /** Listed in a stage but not in the DB */
  inConfigOnly: string[];
};

export function diffAssignment(assigned: string[], inDb: string[]): Unassigned {
  const a = new Set(assigned);
  const d = new Set(inDb);
  return {
    inDbOnly: inDb.filter((k) => !a.has(k)).sort(),
    inConfigOnly: assigned.filter((k) => !d.has(k)).sort(),
  };
}
