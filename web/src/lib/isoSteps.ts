/**
 * ISMS を回す段階と、この仕組みが各段階に何を持っているか。
 *
 * ここが持つのは「段階の並び」と「各段階が要る道具」だけで、**状態は一切持たない**。
 * 状態は DB の実測（StepFacts）から毎回導出する。焼き込んだ進捗を置くと、
 * DB を空にしても緑のままになる。それは嘘なので作らない。
 *
 * 大事な前提: **ISO/IEC 27001 は導入手順を「段階」として規定していない**。
 * 規格が定めるのは要求事項（箇条）であって、着手の順番ではない。
 * ここに並ぶ 12 段階は、規格の要求事項を実務でよく使われる順に並べた一例で、
 * 各段階に箇条番号を併記して規格側と突き合わせられるようにしてある。
 * ギャップ分析（構築前の現状把握）と認証審査（第三者審査）は規格の要求事項ではないので
 * 番号を振らず、段階列の外に参考として置く（PREPARATION / CERTIFICATION）。
 *
 * 箇条は **このファイルが持つものだけ**を正式表示にする。
 * seed の clause_ref / clause_refs には既知の誤りがあるため、正式な対応としては使わない。
 *
 * このファイルは server-only を踏まない純粋なデータ + 関数にしてある（単体試験から直接呼ぶため）。
 */

/** counts のうち状態判定に使うキー。catalog.ts の Counts が構造的に満たす。 */
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
 * 自社の台帳。`app` スキーマにあり、テナント文脈が無いと読めない。
 * カタログ（全テナント共有の下敷き）とは出所が違うので、count とは別種別にする。
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
 * 箇条。
 * scope='cross' は「この段階だけのものではない」横断要求（4.4・6.1.1・7.1・7.4 など）。
 * 段階の専属であるかのように出すと、規格の構造を誤って伝える。
 */
export type ClauseScope = 'primary' | 'cross';
export type Clause = { ref: string; title: string; scope: ClauseScope; note?: string };

/**
 * 道具の役割。
 * reference … ルールの下敷き（カタログ側）。「参照できる」だけで、回した証拠にはならない
 * record    … 自社が ISMS を回した記録（運用側）。審査で証拠になるのはこちら
 */
export type ToolRole = 'reference' | 'record';

/**
 * 件数の取得元。present（＝使える）の意味を種別ごとにここで固定する。
 * これを増やすときは resolveTool の分岐と単体試験を同時に足すこと。
 */
export type ToolSource =
  /** catalog の行数。定義データなので reference にしか使わない */
  | { kind: 'count'; countKey: StepCountKey }
  /** 指定した規程キーのうち、本文が仮置きでないもの */
  | { kind: 'policies'; keys: string[] }
  /** 指定した年間行事キーのうち、DB に在るもの */
  | { kind: 'calendar'; keys: string[] }
  /** 指定したロールキーのうち、DB に在るもの。総数で代用しない */
  | { kind: 'roles'; keys: RoleKey[] }
  /** ISO/IEC 27001:2022 附属書 A の統制。件数だけでなくコードの形も見る */
  | { kind: 'annexA' }
  /** 落ちることを確かめた上で記録されたチェック結果。テナント文脈が要る */
  | { kind: 'verifiedCheckRuns' }
  /**
   * 自社の台帳（app スキーマ）の行数。テナント文脈が要る。
   *
   * 数えるのは**登録されている行**であって、承認済みの行ではない。
   * 承認や管理責任者の割り当てを数の条件にしない（2026-09-07 のユーザー判断）。
   * 段階の画面は ISMS のレンズなので、枠組みタグで絞った数を出す。
   * **数え方の実体は catalog.ts の getRegisterFacts の SQL 1 か所**。ここには写しを置かない。
   */
  | { kind: 'register'; registerKey: RegisterKey }
  /** 機能そのものがこの仕組みに無い。COUNT を投げない */
  | { kind: 'unbuilt' };

export type StepTool = {
  key: string;
  label: string;
  /** 行き先。まだ画面が無いものは null */
  href: string | null;
  /** 何の役に立つのか。1 行 */
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
  /** 動詞で終える。「資産」ではなく「資産を洗い出す」 */
  title: string;
  /** この段階で何を決めるのか */
  purpose: string;
  /** 規格がそう定めているわけではない、という但し書き。無い段階もある */
  caveat?: string;
  clauses: Clause[];
  /** 人がやること。画面の機能ではなく実務の手順 */
  actions: string[];
  tools: StepTool[];
  /** この段階に効く規程（seed の key）。段階間で一意 */
  policyKeys: string[];
  /** この段階に効く年間行事（seed の key）。段階間で一意 */
  calendarKeys: string[];
  /** 関わるロール（seed の key）。複数段階に出てよい */
  roleKeys: RoleKey[];
};

/** 番号を振らない参考の工程。規格の要求事項ではない。 */
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
        // 記述と承認を 1 行にまとめない。書いてあることと承認されたことは別。
        key: 'scope-approval',
        label: '適用範囲の承認記録',
        href: '/operations?mode=isms',
        note: '誰がいつ承認したか。件数は自社の適用範囲に対する、承認者と承認日の入った記録の数',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'scopeApprovals' },
      },
      {
        // 4.1 は課題を「決定する」ことを求めるが、文書化情報は求めない。件数を出すだけで必須にしない。
        key: 'context-issues',
        label: '組織の課題（外部・内部）',
        href: '/iso27001/records?mode=isms#context',
        note: 'ISMS の成果に影響する外部・内部の課題と、それが ISMS にどう効くか。件数は有効な課題の数',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'contextIssues' },
      },
      {
        // 4.2 も同じ。利害関係者と要求を決め、そのうち ISMS で扱うものを決める。
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
        // 総数ではなくキーで見る。5 件あることと、要る役割が在ることは別。
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
        // **数えているものを label と note に書く。** 受講記録と有効性の評価は
        // 「誰が受けたか」の実績で、講座を登録しただけでは存在しない。
        // ここで一緒に数えると、受講 0 件でも記録があることになる。
        note: 'eラーニングの ISMS・リスクマネジメント講座を同期する。件数は ISO 対象として登録されている講座の数。受講記録と有効性の評価は教育の画面で入れる',
        role: 'record',
        required: true,
        source: { kind: 'register', registerKey: 'trainings' },
      },
      {
        key: 'competency-records',
        label: '力量要件',
        href: '/competency?mode=isms',
        // メンバーごとの充足評価は実績なので、要件の数と一緒に数えない。
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
        // A.5.31 は附属書 A の統制。適用するかは適用宣言書で決まるので、件数を出すだけで必須にしない
        // （適用除外にした会社の段階まで「そろっていない」と出すのは誤った表示になる。2026-09-12 決定）。
        key: 'legal-requirements',
        label: '法令・規制・契約上の要求事項',
        href: '/iso27001/records?mode=isms#legal',
        note: '情報セキュリティに関係する要求と、応える統制・証跡、適合の評価。件数は有効な要求事項の数',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'legalRequirements' },
      },
      {
        // A.5.29 / 5.30 も附属書 A の統制。件数表示だけで必須にしない（2026-09-12 決定）。
        // 計画と試験は別の欄にする。計画があることと、試して動いたことは別。
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
        // A.8.8 も附属書 A の統制。件数表示だけで必須にしない（2026-09-12 決定）。
        key: 'vulnerabilities',
        label: '技術的脆弱性の記録',
        href: '/iso27001/records?mode=isms#vulnerabilities',
        note: '検知した脆弱性と、対応期限・状態。件数は登録されている脆弱性の数（誤検知は数えない）',
        role: 'record',
        required: false,
        source: { kind: 'register', registerKey: 'vulnerabilities' },
      },
      {
        // A.8.32 も附属書 A の統制。件数表示だけで必須にしない（2026-09-12 決定）。
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
        // 9.1 は「監視・測定」だけでなく有効性の評価を求める。実施した記録（施策）とは別に数える。
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
        // ロールの総数で代用しない。5 件あっても監査人が居なければ独立性は担保されない。
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
        // 指摘と是正は別に数える。指摘だけ在って是正が 0 件という状態を隠さない。
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
// 状態の導出
// ---------------------------------------------------------------------------

/**
 * 実測。ここに入るのは DB から読んだ値だけで、既定値を持たせない。
 * 既定値を持たせると、読めなかったときに「0 件」に化ける。
 */
export type StepFacts = {
  counts: StepCounts;
  /** DB に在る規程キー -> 本文が実質を伴うか（仮置きでないか） */
  policyBodies: Record<string, boolean>;
  /** DB に在る年間行事キー */
  calendarKeys: string[];
  /** DB に在るロールキー */
  roleKeys: string[];
  /** ISO/IEC 27001:2022 の統制。total は件数、wellFormed は A.x.y の形をしている件数 */
  annexA: { total: number; wellFormed: number };
  /** 逆向きの確認が済んだチェック結果の件数。読めないときは null */
  verifiedCheckRuns: number | null;
  /**
   * 自社の台帳の行数。テナント文脈が無い・DB が読めないときは null。
   * **null と「0 件」を混ぜない。**前者は読めていない、後者は測れて 0 だった。
   */
  registers: Record<RegisterKey, number> | null;
};

/**
 * 件数として信用してよい値か。
 *
 * NaN・Infinity・非数値をそのまま比較に流すと、`> 0` が真になったり偽になったりして
 * 「使える」「未投入」のどちらにも化ける。読めない値は読めないものとして扱う。
 * 件数なので**非負の整数**だけを通す。1.5 件のような値は数え方が壊れている。
 */
function isCount(n: unknown): n is number {
  return typeof n === 'number' && Number.isInteger(n) && n >= 0;
}

export type ToolState =
  /** 使える */
  | { kind: 'present'; count: number }
  /** 行はあるが中身が仮置き */
  | { kind: 'placeholder'; count: number; total: number }
  /** 件数はあるが、あるべき形をしていない */
  | { kind: 'malformed'; wellFormed: number; total: number }
  /** 表はあるが 0 件 */
  | { kind: 'empty' }
  /** 機能そのものが無い */
  | { kind: 'unbuilt' }
  /** 読める状態にない（0 件でも未実装でもない） */
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
 * 附属書 A の統制コードの形。
 *
 * 2022 年版の附属書 A は A.5（組織的）・A.6（人的）・A.7（物理的）・A.8（技術的）の 4 区分しかない。
 * `A\.\d+\.\d+` まで緩めると A.9.1 のような実在しない区分も通り、
 * 「附属書 A の統制が入っている」の根拠にならなくなる。
 */
export const ANNEX_A_CODE = /^A\.[5-8]\.\d{1,2}$/;

/** 集合に含まれるキーだけを数える。所有プロパティだけを見る。 */
function countKnown(keys: readonly string[], known: readonly string[]): string[] {
  return keys.filter((k) => known.includes(k));
}

export function resolveTool(tool: StepTool, facts: StepFacts): ToolState {
  const src = tool.source;
  switch (src.kind) {
    case 'unbuilt':
      // COUNT を投げない。機能が無いことは静的に分かっている。
      return { kind: 'unbuilt' };

    case 'count': {
      const n = facts.counts[src.countKey];
      // 数として読めない値を 0 と混ぜると「未投入」に化ける。かといって「機能が無い」でもない。
      // 読めなかったことは、読めなかったこととして出す。
      if (!isCount(n)) return { kind: 'unreadable' };
      return n > 0 ? { kind: 'present', count: n } : { kind: 'empty' };
    }

    case 'policies': {
      // `k in obj` はプロトタイプ側（toString など）にも当たるので使わない。
      // 'toString' という規程キーを設定に書いただけで、DB に在ることになってしまう。
      const known = src.keys.filter((k) =>
        Object.prototype.hasOwnProperty.call(facts.policyBodies, k),
      );
      if (known.length === 0) return { kind: 'empty' };
      // **分母は「要る規程の数」であって「DB に在る数」ではない。**
      // DB に在るものだけを分母にすると、要る規程が 1 本抜け落ちたときに
      // 残りがそろっているだけで「使える」になる。抜けは足りないこととして数える。
      const substantive = src.keys.filter((k) => facts.policyBodies[k] === true).length;
      if (substantive < src.keys.length) {
        return { kind: 'placeholder', count: substantive, total: src.keys.length };
      }
      return { kind: 'present', count: substantive };
    }

    case 'calendar': {
      const present = countKnown(src.keys, facts.calendarKeys);
      if (present.length === 0) return { kind: 'empty' };
      // 一部しか無い状態を「使える」と言わない。予定が欠けたまま回すことになる。
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
      // 集計そのものが読めないなら、0 件とも入っているとも言わない。
      // DB そのものが落ちている場合は問い合わせが例外になり、画面は 500 になる（そちらが正）。
      // ここが守るのは「問い合わせは返ったが値が数として壊れている」場合。
      if (!isCount(total) || !isCount(wellFormed)) return { kind: 'unreadable' };
      // 形の合う件数が総数を超えるのは、集計が壊れている。使える側へ倒さない。
      if (wellFormed > total) return { kind: 'malformed', wellFormed, total };
      if (total === 0) return { kind: 'empty' };
      // 件数だけ見ると、附属書 A ではない統制を紐付けても通ってしまう。
      // コードの形が 1 件でも違えば、附属書 A が入っているとは言わない。
      if (wellFormed !== total) return { kind: 'malformed', wellFormed, total };
      return { kind: 'present', count: total };
    }

    case 'verifiedCheckRuns': {
      const n = facts.verifiedCheckRuns;
      if (n === null) return { kind: 'unreadable' };
      // NaN を 0 と同じ「未投入」に、Infinity を「使える」に化けさせない。
      if (!isCount(n)) return { kind: 'unreadable' };
      return n > 0 ? { kind: 'present', count: n } : { kind: 'empty' };
    }

    case 'register': {
      // 台帳が読めなかったこと（テナント文脈が無い等）は 0 件ではない。
      if (facts.registers === null) return { kind: 'unreadable' };
      const n = facts.registers[src.registerKey];
      // NaN を「未投入」に、Infinity を「使える」に化けさせない。
      if (!isCount(n)) return { kind: 'unreadable' };
      return n > 0 ? { kind: 'present', count: n } : { kind: 'empty' };
    }
  }
}

export type StepStatus =
  /** 要るものが下敷きも記録もそろっている */
  | 'usable'
  /** 要るものの一部だけそろっている */
  | 'partial'
  /** 要るものがひとつもそろっていない */
  | 'none';

export type StepAssessment = {
  status: StepStatus;
  /** required な下敷きがすべてそろっているか */
  referencesReady: boolean;
  /** required な記録がすべてそろっているか */
  recordsReady: boolean;
  /** 読めない項目があるか。状態とは別に併記する（状態を良い方へ倒さない） */
  hasUnreadable: boolean;
  tools: { tool: StepTool; state: ToolState }[];
  /** 要るのにそろっていない道具 */
  missingRequired: StepTool[];
};

/**
 * 段階の見出しに出す言葉。
 *
 * 状態を 3 つに割ったうえで、partial のうち**よくある形**
 * （下敷きはそろっているが記録を残す機能が無い）だけを言い分ける。
 * 「下敷きだけある」を partial 全部に当てると、記録だけあって下敷きが欠けている段階にも
 * その言葉が出て、画面が嘘をつく。
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

/** 集計に使う見出しの並び。ここに無い言葉は statusLabel から出ない。 */
export const STATUS_BUCKETS: readonly string[] = [
  '記録まで残せる',
  '下敷きだけある',
  '一部だけそろっている',
  'まだ何も無い',
];

/**
 * 段階の状態を実測から導出する。
 *
 * present に数えるのは present だけ。placeholder・malformed・empty・unbuilt・unreadable は
 * どれも「使えない」側に数える。使えないものを使える側に混ぜた瞬間、この画面は嘘をつき始める。
 *
 * 評価の順番は固定する。required が空だと every() が真になって usable に化けるので、
 * 「どの段階も required の reference と record を 1 つ以上持つ」ことは単体試験で強制する。
 */
export function assessStep(step: IsoStep, facts: StepFacts): StepAssessment {
  const tools = step.tools.map((tool) => ({ tool, state: resolveTool(tool, facts) }));
  const required = tools.filter((t) => t.tool.required);
  const isPresent = (t: { state: ToolState }) => t.state.kind === 'present';

  const requiredRefs = required.filter((t) => t.tool.role === 'reference');
  const requiredRecs = required.filter((t) => t.tool.role === 'record');

  // 空の every() は真になる。required を持たない段階を「そろっている」と読ませないため、
  // 長さを条件に含める（不変条件そのものは単体試験で強制する）。
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

/** 前後の段階。端では null を返す。 */
export function stepNeighbors(key: string): { prev: IsoStep | null; next: IsoStep | null } {
  const i = ISO_STEPS.findIndex((s) => s.key === key);
  if (i < 0) return { prev: null, next: null };
  return {
    prev: i > 0 ? ISO_STEPS[i - 1] : null,
    next: i < ISO_STEPS.length - 1 ? ISO_STEPS[i + 1] : null,
  };
}

/**
 * 規程 1 本の本文の状態。画面でこれを判定し直すと、画面ごとに違う言い方が生まれる。
 * missing … 割り当て表には在るが DB に無い
 */
export type PolicyBodyState = 'substantive' | 'placeholder' | 'missing';

export function policyBodyState(facts: StepFacts, key: string): PolicyBodyState {
  if (!Object.prototype.hasOwnProperty.call(facts.policyBodies, key)) return 'missing';
  return facts.policyBodies[key] === true ? 'substantive' : 'placeholder';
}

/** 段階に割り当てたロールキーの全体（重複を含む。ロールは複数段階に出てよい）。 */
export function assignedRoleKeys(): string[] {
  return Array.from(new Set(ISO_STEPS.flatMap((s) => s.roleKeys)));
}

/** 段階に割り当てた規程キーの全体。 */
export function assignedPolicyKeys(): string[] {
  return ISO_STEPS.flatMap((s) => s.policyKeys);
}

/** 段階に割り当てた年間行事キーの全体。 */
export function assignedCalendarKeys(): string[] {
  return ISO_STEPS.flatMap((s) => s.calendarKeys);
}

/**
 * 割り当ての取りこぼしを**双方向**で見る。
 *
 * 片方向（DB にあって設定に無い）だけだと、設定側のタイポや存在しないキーを拾えない。
 * seed に行を足して割り当てを忘れた場合と、設定に架空のキーを書いた場合の
 * どちらも画面に出す（外形検査は両方 0 件であることを見る）。
 */
export type Unassigned = {
  /** DB に在るのに、どの段階にも割り当てていない */
  inDbOnly: string[];
  /** 段階に書いてあるのに、DB に無い */
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
