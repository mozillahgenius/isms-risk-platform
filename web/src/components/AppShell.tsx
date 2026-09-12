'use client';

import {
  Books,
  CaretDown,
  ChartLineUp,
  ClipboardText,
  DeviceMobile,
  FileText,
  Gear,
  House,
  Key,
  ListChecks,
  ShieldCheck,
  WarningCircle,
} from '@phosphor-icons/react';
import Link from 'next/link';
import { usePathname, useSearchParams } from 'next/navigation';
import type { ComponentType } from 'react';
import { ThemeToggle } from '@/components/ThemeToggle';
import {
  isRouteActive,
  ISMS_SHARED_LEDGER_DESCRIPTION,
  modeDestination,
  navigationForMode,
  RESOURCE_MANAGEMENT_NAME,
  resolveAppMode,
  type NavigationItem,
  type NavigationSection,
} from '@/lib/navigation';

type Icon = ComponentType<{ size?: number; weight?: 'bold' | 'regular' | 'fill' }>;

const itemIcons: Record<string, Icon> = {
  'ダッシュボード': House,
  '全リスク': ClipboardText,
  '上場準備で絞る': ClipboardText,
  'AI分析': ChartLineUp,
  '運用センター': ListChecks,
  'デバイス管理': DeviceMobile,
  'パスワード管理': Key,
  'ID・ライセンス管理': Gear,
  '依頼・アサイン': ListChecks,
  '外部リソース': Books,
  '権限管理': ShieldCheck,
  'インシデント': WarningCircle,
  '統制カタログ': Books,
  '規程': FileText,
  '組織情報': ShieldCheck,
  '組織・メンバー': ShieldCheck,
  '設定': Gear,
  '進捗と次の一手': ListChecks,
  '図で見る': ChartLineUp,
};

function NavigationLink({ item, pathname, search, compact = false }: { item: NavigationItem; pathname: string; search: string; compact?: boolean }) {
  const active = isRouteActive(pathname, item, search);
  const ItemIcon = itemIcons[item.label];
  const prefetchEducationWorkspace = item.href.startsWith('/competency') || item.href.startsWith('/training');
  return (
    <Link
      href={item.href}
      prefetch={prefetchEducationWorkspace ? true : undefined}
      aria-current={active ? 'page' : undefined}
      className={`group flex min-h-9 items-center gap-2 rounded-[var(--radius-sm)] px-2.5 py-1.5 text-[13px] leading-snug transition-colors active:translate-y-px ${
        active
          ? 'bg-[var(--accent-weak)] font-medium text-[var(--accent)]'
          : 'text-[var(--fg-2)] hover:bg-[var(--surface-3)] hover:text-[var(--foreground)]'
      } ${compact ? 'px-2' : ''}`}
    >
      {ItemIcon ? <ItemIcon size={16} weight={active ? 'fill' : 'regular'} aria-hidden="true" /> : null}
      <span>{item.label}</span>
    </Link>
  );
}

function sectionHasActiveItem(section: NavigationSection, pathname: string, search: string): boolean {
  return section.items.some((item) => isRouteActive(pathname, item, search))
    || section.children?.some((child) => sectionHasActiveItem(child, pathname, search)) === true;
}

function NavigationSectionView({
  section,
  pathname,
  search,
  compact = false,
  depth = 0,
}: {
  section: NavigationSection;
  pathname: string;
  search: string;
  compact?: boolean;
  depth?: number;
}) {
  const active = sectionHasActiveItem(section, pathname, search);
  const links = (
    <div className={depth === 0 ? 'space-y-0.5' : 'space-y-1'}>
      {section.items.map((item) => (
        <NavigationLink key={item.href} item={item} pathname={pathname} search={search} compact={compact} />
      ))}
      {section.children?.map((child) => (
        <NavigationSectionView
          key={child.label}
          section={child}
          pathname={pathname}
          search={search}
          compact={compact}
          depth={depth + 1}
        />
      ))}
    </div>
  );

  if (section.collapsible) {
    return (
      <details
        open={active || undefined}
        className={depth === 0
          ? 'rounded-[var(--radius)] border border-[var(--border)] bg-[var(--surface-2)]/60 p-1.5'
          : 'border-l border-[var(--accent-line)] pl-2'}
      >
        <summary className="flex cursor-pointer list-none items-center justify-between gap-2 rounded-[var(--radius-sm)] px-2 py-2 text-[12px] font-semibold text-[var(--fg-2)] marker:content-none hover:bg-[var(--surface-3)] hover:text-[var(--foreground)]">
          <span className={active ? 'text-[var(--accent)]' : undefined}>{section.label}</span>
          <CaretDown size={14} aria-hidden="true" />
        </summary>
        <div className="mt-1 space-y-2 px-1 pb-1">{links}</div>
      </details>
    );
  }

  return (
    <section aria-label={section.label} className={depth > 0 ? 'pt-1' : undefined}>
      <h2 className="px-2.5 pb-1 text-[11px] font-semibold tracking-wide text-[var(--muted)]">
        {section.label}
      </h2>
      {links}
    </section>
  );
}

function Sidebar({ pathname, search }: { pathname: string; search: string }) {
  const mode = resolveAppMode(pathname, search);
  const sections = navigationForMode(mode);
  return (
    <nav aria-label={mode === 'isms' ? 'ISMSの手順' : `${RESOURCE_MANAGEMENT_NAME}のメニュー`} className="space-y-4">
      {sections.map((section) => (
        <NavigationSectionView key={section.label} section={section} pathname={pathname} search={search} />
      ))}
    </nav>
  );
}

function ModeSwitch({ pathname, search }: { pathname: string; search: string }) {
  const mode = resolveAppMode(pathname, search);
  return (
    <nav aria-label="表示モード" className="flex rounded-[var(--radius)] border border-[var(--border)] bg-[var(--surface-2)] p-0.5">
      {(['risk', 'isms'] as const).map((candidate) => {
        const selected = mode === candidate;
        return (
          <Link
            key={candidate}
            href={modeDestination(pathname, search, candidate)}
            prefetch
            aria-current={selected ? 'page' : undefined}
            className={`whitespace-nowrap rounded-[6px] px-2.5 py-1.5 text-[12px] font-medium transition-colors active:translate-y-px sm:px-3 ${
              selected
                ? 'bg-[var(--surface)] text-[var(--foreground)] shadow-[var(--shadow-sm)]'
                : 'text-[var(--muted)] hover:text-[var(--fg-2)]'
            }`}
          >
            {candidate === 'risk' ? RESOURCE_MANAGEMENT_NAME : 'ISMS（ISO対象）'}
          </Link>
        );
      })}
    </nav>
  );
}

function MobileMenu({ pathname, search }: { pathname: string; search: string }) {
  const mode = resolveAppMode(pathname, search);
  const sections = navigationForMode(mode);
  return (
    <details className="border-b border-[var(--border)] bg-[var(--surface)] lg:hidden">
      <summary className="mx-auto flex max-w-[1400px] cursor-pointer list-none items-center justify-between px-5 py-3 text-sm font-medium marker:content-none">
        <span>{mode === 'isms' ? 'ISMSの手順を開く' : `${RESOURCE_MANAGEMENT_NAME}のメニューを開く`}</span>
        <CaretDown size={16} aria-hidden="true" />
      </summary>
      <nav aria-label="モバイルメニュー" className="mx-auto grid max-w-[1400px] gap-4 border-t border-[var(--border)] px-5 py-4 sm:grid-cols-2">
        {sections.map((section) => (
          <NavigationSectionView
            key={section.label}
            section={section}
            pathname={pathname}
            search={search}
            compact
          />
        ))}
      </nav>
    </details>
  );
}

export function AppHeader() {
  const pathname = usePathname() ?? '/dashboard';
  const search = useSearchParams().toString();
  return (
    <header className="sticky top-0 z-10 border-b border-[var(--border)] bg-[var(--surface)]/95 backdrop-blur">
      <div className="mx-auto flex h-[68px] max-w-[1400px] items-center gap-3 px-5">
        <Link
          href="/dashboard"
          className="shrink-0 text-[15px] font-semibold tracking-tight"
          title={ISMS_SHARED_LEDGER_DESCRIPTION}
        >
          {RESOURCE_MANAGEMENT_NAME}
        </Link>
        <div className="ms-auto flex items-center gap-2">
          <ModeSwitch pathname={pathname} search={search} />
          <ThemeToggle />
        </div>
      </div>
    </header>
  );
}

export function AppMobileNavigation() {
  const pathname = usePathname() ?? '/dashboard';
  const search = useSearchParams().toString();
  return <MobileMenu pathname={pathname} search={search} />;
}

export function AppSidebarNavigation() {
  const pathname = usePathname() ?? '/dashboard';
  const search = useSearchParams().toString();
  return <Sidebar pathname={pathname} search={search} />;
}
