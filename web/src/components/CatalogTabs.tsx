'use client';

import Link from 'next/link';
import { usePathname, useSearchParams } from 'next/navigation';

// Sub-navigation under the catalog. So that the current location shows even on detail pages (/catalog/controls/[id] etc.),
// match by prefix **at segment boundaries**. A plain startsWith would
// highlight "Controls" even on a different page like /catalog/controls-extra.
// The entry (/catalog) is matched by exact match only (a prefix match would match every page).

const TABS: { href: string; label: string }[] = [
  { href: '/catalog', label: '入口' },
  { href: '/catalog/controls', label: '統制' },
  { href: '/catalog/risks', label: 'リスクシナリオ雛形' },
  { href: '/catalog/policies', label: '規程' },
  { href: '/catalog/criteria', label: 'リスク基準' },
  { href: '/catalog/org', label: '体制・分類' },
  { href: '/catalog/calendar', label: '年間カレンダー' },
  { href: '/catalog/frameworks', label: 'フレームワーク' },
  { href: '/catalog/checks', label: '標準チェック' },
];

export function CatalogTabs() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const mode = searchParams.get('mode');
  return (
    <nav
      aria-label="カタログの下位ページ"
      className="-mx-1 mb-5 flex flex-wrap gap-1 border-b border-[var(--border)] pb-2"
    >
      {TABS.map((t) => {
        const active =
          t.href === '/catalog'
            ? pathname === '/catalog'
            : pathname === t.href || pathname.startsWith(`${t.href}/`);
        return (
          <Link
            key={t.href}
            href={mode ? `${t.href}?mode=${encodeURIComponent(mode)}` : t.href}
            aria-current={active ? 'page' : undefined}
            className={`rounded-[var(--radius-sm)] px-2.5 py-1 text-[13px] transition-colors ${
              active
                ? 'bg-[var(--accent-weak)] font-medium text-[var(--accent)]'
                : 'text-[var(--fg-2)] hover:bg-[var(--surface-2)]'
            }`}
          >
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}
