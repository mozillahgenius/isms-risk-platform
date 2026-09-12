// Pure function that decides which screen to send a diagram node ID to.
//
// The diagram renderer (ported as is from another implementation) only knows how to push to `/n/<id>`.
// This module's job is to decode the ID and send it to the matching screen. Derived nodes (intermediate headings, not DB rows)
// have no detail page, so they go to a list filtered by that condition. IDs whose destination cannot be determined return null.

import { parseGroupKey } from './nodeid';

// Even if the ID's shape is correct, its content may not be valid as an identifier of the target
// (e.g. control.<base64url("abc")> decodes but is not a uuid).
// Sending malformed ones to a destination would 307-redirect to a page that 404s,
// making "broken ID" indistinguishable from "deleted item". Stop them here.
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
      // path = [framework_key, ...theme segments]
      const [framework, ...parts] = path;
      if (!framework || parts.length === 0) return null;
      const q = new URLSearchParams({ framework, theme: parts.join(' / ') });
      return `/catalog/controls?${q.toString()}`;
    }
    case 'dept': {
      // A division alone does not determine the domain (there are several with a Phase), so pass it as a search term.
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
