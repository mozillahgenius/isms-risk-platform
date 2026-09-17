import { ISO_STEPS, PHASE_LABEL, PHASE_ORDER, type StepPhase } from './isoSteps';

export type AppMode = 'risk' | 'isms';
export const ISMS_FRAMEWORK_KEY = 'ISO27001:2022';
export const RESOURCE_MANAGEMENT_NAME = 'リソースマネジメント';
export const ISMS_SHARED_LEDGER_DESCRIPTION =
  'ISMSは、リソースマネジメントの共通台帳にある同一の資産・リスクIDを、ISO 27001:2022の対象として表示するレンズです。';

export type NavigationItem = {
  href: string;
  label: string;
  /** A route that should highlight this item even though its URL differs. */
  also?: string[];
};

export type NavigationSection = {
  label: string;
  items: NavigationItem[];
  children?: NavigationSection[];
  collapsible?: boolean;
};

const ISMS_ROUTE_PREFIXES = ['/', '/steps', '/wizard', '/organization', '/graph', '/iso27001'];
// /analysis(AI分析)は両モードの共通画面。ISMS モードでは ISMS タグの項目だけで算出する(2026-09-13)。
const SHARED_ROUTE_PREFIXES = ['/operations', '/incidents', '/catalog', '/policies', '/settings', '/organization', '/cost', '/competency', '/training', '/analysis'];

/**
 * URL is the source of truth for the shell mode.  This deliberately has no
 * localStorage or React state so a shared URL always opens in the same mode.
 */
export function resolveAppMode(pathname: string, search = ''): AppMode {
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const requestedMode = params.get('mode');
  if (requestedMode === 'isms' || requestedMode === 'risk') return requestedMode;
  if (params.get('framework') === 'ISO27001:2022') return 'isms';
  if (pathname === '/') return 'isms';
  return ISMS_ROUTE_PREFIXES.slice(1).some(
    (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`),
  )
    ? 'isms'
    : 'risk';
}

/**
 * ISMS 表示中は、URL に残った別枠組み指定より ISO 27001 を優先する。
 * サーバーコンポーネントでも使える純粋関数にして、表示と取得対象を一致させる。
 */
export function frameworkForMode(
  framework: string | string[] | undefined,
  mode: string | string[] | undefined,
): string | string[] | undefined {
  const requestedMode = Array.isArray(mode) ? mode[0] : mode;
  if (requestedMode === 'isms') return ISMS_FRAMEWORK_KEY;
  const requestedFramework = Array.isArray(framework) ? framework[0] : framework;
  if (requestedMode === 'risk' && requestedFramework === ISMS_FRAMEWORK_KEY) return 'RISK-MANAGEMENT';
  return framework;
}

export function isRouteActive(pathname: string, item: NavigationItem, search = ''): boolean {
  const currentSearch = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const routes = [item.href, ...(item.also ?? [])];
  return routes.some((route) => {
    const target = new URL(route, 'https://management.invalid');
    const pathMatches = target.pathname === '/'
      ? pathname === '/'
      : target.pathname === '/operations'
        ? pathname === target.pathname
        : pathname === target.pathname || pathname.startsWith(`${target.pathname}/`);
    if (!pathMatches) return false;
    for (const [key, value] of target.searchParams) {
      if (key === 'framework' && value === 'RISK-MANAGEMENT' && !currentSearch.has(key)) continue;
      if (currentSearch.get(key) !== value) return false;
    }
    if (!target.searchParams.has('framework') && currentSearch.has('framework') && target.pathname === pathname) return false;
    return true;
  });
}

function withMode(href: string, mode: AppMode): string {
  const target = new URL(href, 'https://management.invalid');
  target.searchParams.set('mode', mode);
  return `${target.pathname}?${target.searchParams.toString()}`;
}

function commonOperations(mode: AppMode): NavigationSection {
  return {
    label: '日常の統制',
    items: [
      { href: withMode('/operations', mode), label: '運用センター' },
      { href: withMode('/operations/device-control', mode), label: 'デバイス管理' },
      { href: withMode('/operations/passwords', mode), label: 'パスワード管理' },
      { href: withMode('/operations/identity-access', mode), label: 'ID・ライセンス管理' },
      { href: withMode('/operations/assignments', mode), label: '依頼・アサイン' },
      { href: withMode('/operations/external-resources', mode), label: '外部リソース' },
      { href: withMode('/operations/access', mode), label: '権限管理' },
      { href: withMode('/incidents', mode), label: 'インシデント' },
    ],
  };
}

function stepSections(): NavigationSection[] {
  return PHASE_ORDER.map((phase: StepPhase) => ({
    label: PHASE_LABEL[phase],
    items: ISO_STEPS.filter((step) => step.phase === phase).map((step) => ({
      href: `/steps/${step.key}`,
      label: `${step.ordinal}. ${step.title}`,
    })),
  }));
}

export const RISK_NAVIGATION: NavigationSection[] = [
  {
    label: '全体像',
    items: [
      { href: '/dashboard', label: 'ダッシュボード' },
      { href: '/risk-management?framework=RISK-MANAGEMENT', label: RESOURCE_MANAGEMENT_NAME, also: ['/iso27001'] },
      { href: '/risk-management?framework=IPO-KARTE', label: '上場準備で絞る' },
      { href: '/analysis', label: 'AI分析' },
      { href: '/cost', label: 'コスト管理' },
      { href: '/competency', label: '力量' },
      { href: '/training', label: '教育・訓練' },
    ],
  },
  commonOperations('risk'),
  {
    label: '設定と参照',
    items: [
      { href: '/catalog', label: '統制カタログ' },
      { href: '/policies', label: '規程' },
      { href: '/organization', label: '組織・メンバー', also: ['/wizard'] },
      { href: '/settings', label: '設定' },
    ],
  },
];

export const ISMS_NAVIGATION: NavigationSection[] = [
  {
    label: 'ISMS',
    collapsible: true,
    items: [
      { href: '/', label: '進捗と次の一手', also: ['/wizard'] },
      { href: '/analysis', label: 'AI分析' },
    ],
    children: [
      {
        label: 'ステップ',
        collapsible: true,
        items: [],
        children: stepSections(),
      },
    ],
  },
  commonOperations('isms'),
  {
    label: '組織管理',
    items: [
      { href: '/organization', label: '組織・メンバー', also: ['/wizard'] },
    ],
  },
  {
    label: '参照',
    items: [
      { href: '/catalog', label: '統制カタログ' },
      { href: '/policies', label: '規程' },
      { href: '/cost', label: 'コスト管理' },
      { href: '/competency', label: '力量' },
      { href: '/training', label: '教育・訓練' },
      { href: '/graph', label: '図で見る' },
    ],
  },
];

export const APP_MODE_DESTINATIONS: Record<AppMode, string> = {
  risk: '/dashboard',
  isms: '/',
};

export function modeDestination(pathname: string, search: string, mode: AppMode): string {
  const shared = SHARED_ROUTE_PREFIXES.some(
    (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`),
  );
  if (!shared) return APP_MODE_DESTINATIONS[mode];
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  params.set('mode', mode);
  if (mode === 'risk' && params.get('framework') === ISMS_FRAMEWORK_KEY) {
    params.set('framework', 'RISK-MANAGEMENT');
  }
  return `${pathname}?${params.toString()}`;
}

export function navigationForMode(mode: AppMode): NavigationSection[] {
  const sections = mode === 'isms' ? ISMS_NAVIGATION : RISK_NAVIGATION;
  const mapSection = (section: NavigationSection): NavigationSection => ({
    ...section,
    items: section.items.map((item) => {
      const target = new URL(item.href, 'https://management.invalid');
      const shared = SHARED_ROUTE_PREFIXES.some(
        (prefix) => target.pathname === prefix || target.pathname.startsWith(`${prefix}/`),
      );
      return shared ? { ...item, href: withMode(item.href, mode) } : item;
    }),
    children: section.children?.map(mapSection),
  });
  return sections.map(mapSection);
}
