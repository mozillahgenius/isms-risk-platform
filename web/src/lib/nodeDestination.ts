// 図のノード ID から「どの画面へ送るか」を決める純関数。
//
// 図の描画側（Kaname から移植したまま）は `/n/<id>` へ push することしか知らない。
// ID を解いて対応する画面へ送るのがここの役目。導出ノード（DB の行ではない中間の見出し）には
// 詳細ページが無いので、その条件で絞り込んだ一覧へ送る。行き先が決められない ID は null。

import { parseGroupKey } from './nodeid';

// ID の形が正しくても、中身が対象の識別子として成立しないことがある
// （例: control.<base64url("abc")> は decode できるが uuid ではない）。
// 形の合わないものを遷移先へ送ると、404 になるページへ 307 で飛ばすことになり、
// 「壊れた ID」と「消えた項目」が区別できなくなる。ここで止める。
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KEY_RE = /^[a-z0-9_]{1,64}$/;
const FRAMEWORK_RE = /^[A-Za-z0-9:.\-]{1,64}$/;
const FRAMES = ['管理可能性', '精度', 'スピード'];

export function destinationOf(type: string, key: string): string | null {
  switch (type) {
    case 'dom':
      return '/';
    case 'control':
      return UUID_RE.test(key) ? `/catalog/controls/${encodeURIComponent(key)}` : null;
    case 'risk':
      return UUID_RE.test(key) ? `/catalog/risks/${encodeURIComponent(key)}` : null;
    case 'policy':
      return KEY_RE.test(key) ? `/catalog/policies/${encodeURIComponent(key)}` : null;
    case 'framework':
      return FRAMEWORK_RE.test(key) ? `/catalog/controls?framework=${encodeURIComponent(key)}` : null;
    case 'role':
    case 'asset':
      return KEY_RE.test(key) ? '/catalog/org' : null;
    case 'calendar':
      return KEY_RE.test(key) ? '/catalog/calendar' : null;
    case 'frame':
      return FRAMES.includes(key) ? `/catalog/risks?frame=${encodeURIComponent(key)}` : null;
    case 'group':
      return groupDestination(key);
    default:
      return null;
  }
}

function groupDestination(key: string): string | null {
  const { kind, path } = parseGroupKey(key);
  switch (kind) {
    case 'section':
      return (
        {
          controls: '/catalog/controls',
          risks: '/catalog/risks',
          policies: '/catalog/policies',
          org: '/catalog/org',
          calendar: '/catalog/calendar',
        }[path[0]] ?? null
      );
    case 'theme': {
      // path = [framework_key, ...theme の段]
      const [framework, ...parts] = path;
      if (!framework || parts.length === 0) return null;
      const q = new URLSearchParams({ framework, theme: parts.join(' / ') });
      return `/catalog/controls?${q.toString()}`;
    }
    case 'dept': {
      // 部門だけでは domain が決まらない（Phase 付きが複数ある）ので、検索語として渡す。
      if (!path[0]) return null;
      return `/catalog/risks?q=${encodeURIComponent(path[0])}`;
    }
    case 'phase': {
      const [dept, phase] = path;
      if (!dept || !phase) return null;
      return `/catalog/risks?domain=${encodeURIComponent(`${dept}（${phase}）`)}`;
    }
    case 'rtheme': {
      const [domain, theme] = path;
      if (!domain || !theme) return null;
      const q = new URLSearchParams({ domain, q: theme });
      return `/catalog/risks?${q.toString()}`;
    }
    case 'measure': {
      const [domain, , measure] = path;
      if (!domain || !measure) return null;
      const q = new URLSearchParams({ domain, q: measure });
      return `/catalog/risks?${q.toString()}`;
    }
    case 'cadence':
      return '/catalog/calendar';
    case 'org':
      return '/catalog/org';
    case 'empty':
      return (
        {
          checks: '/catalog/checks',
          framework_mappings: '/catalog/frameworks',
          risk_template_controls: '/catalog/risks',
        }[path[0]] ?? null
      );
    default:
      return null;
  }
}
